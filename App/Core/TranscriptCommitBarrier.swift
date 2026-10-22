import AgentKit
import CryptoKit
import Foundation

/// Why a turn may not issue its next model request or tool effect.
nonisolated enum StorageCommitError: LocalizedError, Equatable {
    case saveFailed(String)
    case storageUnavailable
    case jobReplaced
    case cancelled
    case timedOut
    var errorDescription: String? {
        switch self {
        case .saveFailed(let detail): "历史保存失败，已停止后续模型请求与手机动作：\(detail)"
        case .storageUnavailable: "历史存储不可用，已停止后续模型请求与手机动作。"
        case .jobReplaced: "本轮已被替换或结束，旧请求不再执行。"
        case .cancelled: "本轮已取消。"
        case .timedOut: "等待历史保存确认超时，已停止后续模型请求与手机动作。"
        }
    }
}

/// What a successful write made durable for one message.
nonisolated struct CommittedMessage: Hashable, Sendable {
    var digest: String
    /// Assistant tool calls in source order: call ID and argument digest.
    var calls: [Call]
    struct Call: Hashable, Sendable { var id: String; var digest: String }

    init(digest: String, calls: [Call] = []) { self.digest = digest; self.calls = calls }

    /// `imageIDs`: attachment IDs stored with this message (user images).
    init(_ message: AgentTranscriptMessage, imageIDs: [UUID] = []) throws {
        digest = try MessageDigestDTO.requestDigest(message, imageIDs: imageIDs)
        calls = try message.toolCalls.map { Call(id: $0.id, digest: try MessageDigestDTO.callDigest($0)) }
    }
}

/// Awaited save acknowledgements for one accepted job (identified by its
/// epoch). The history owner — the only writer — reports what each
/// successful write made durable; model and tool gates wait here before any
/// request or effect. `AgentEventChannel.emit` only yields: it is not an ACK.
/// Save failure, cancellation, timeout and job replacement release every
/// waiter with an error instead of letting it hang.
nonisolated final class TranscriptCommitBarrier: @unchecked Sendable {
    enum Requirement: Sendable {
        /// Exact real messages with their expected request-view digests
        /// (`MessageDigestDTO.requestDigest`).
        case messages([UUID: String])
        /// A tool call may run once its assistant message (with this call's
        /// arguments) and every earlier call's result in that message are saved.
        case toolDispatch(runID: UUID, sourceMessageID: UUID, callID: String, callDigest: String)
        case toolResult(runID: UUID, callID: String)
    }

    private struct Waiter {
        let requirement: Requirement
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// Per-call durability: the run's result for this call is saved, or the
    /// call was answered by the provider itself and its assistant payload is saved.
    struct ResultKey: Hashable, Sendable {
        var runID: UUID
        var callID: String
    }

    private struct EpochState {
        var committed: [UUID: CommittedMessage] = [:]
        var results: Set<ResultKey> = []
        var failure: StorageCommitError?
        var waiters: [UUID: Waiter] = [:]
    }

    private let lock = NSLock()
    private var epochs: [UInt64: EpochState] = [:]

    init() {}

    func open(epoch: UInt64, seed: [UUID: CommittedMessage] = [:]) {
        lock.withLock { epochs[epoch] = EpochState(committed: seed) }
    }

    /// Records durable messages after a successful write and releases waiters
    /// whose requirements are now satisfied.
    func commit(epoch: UInt64, _ messages: [UUID: CommittedMessage], results: Set<ResultKey> = []) {
        let ready: [CheckedContinuation<Void, any Error>] = lock.withLock {
            guard var state = epochs[epoch], state.failure == nil else { return [] }
            state.committed.merge(messages) { _, new in new }
            state.results.formUnion(results)
            var resumed: [CheckedContinuation<Void, any Error>] = []
            for (id, waiter) in state.waiters where Self.satisfied(waiter.requirement, in: state.committed, results: state.results) {
                resumed.append(waiter.continuation)
                state.waiters[id] = nil
            }
            epochs[epoch] = state
            return resumed
        }
        ready.forEach { $0.resume() }
    }

    /// Storage failed or the job must stop: every current and future wait of
    /// this epoch fails.
    func fail(epoch: UInt64, _ error: StorageCommitError) {
        let waiting: [CheckedContinuation<Void, any Error>] = lock.withLock {
            guard var state = epochs[epoch] else { return [] }
            if state.failure == nil { state.failure = error }
            let list = state.waiters.values.map(\.continuation)
            state.waiters = [:]
            epochs[epoch] = state
            return list
        }
        waiting.forEach { $0.resume(throwing: error) }
    }

    func failAll(_ error: StorageCommitError) {
        let ids = lock.withLock { Array(epochs.keys) }
        ids.forEach { fail(epoch: $0, error) }
    }

    /// The owner replaced or removed the job: waiters fail at once, and the
    /// epoch is forgotten so a late event cannot satisfy a stale wait.
    func close(epoch: UInt64) {
        let waiting: [CheckedContinuation<Void, any Error>] = lock.withLock {
            let list = epochs[epoch]?.waiters.values.map(\.continuation) ?? []
            epochs[epoch] = nil
            return list
        }
        waiting.forEach { $0.resume(throwing: StorageCommitError.jobReplaced) }
    }

    func isCommitted(epoch: UInt64, _ id: UUID) -> Bool { lock.withLock { epochs[epoch]?.committed[id] != nil } }

    func wait(epoch: UInt64, _ requirement: Requirement, timeout: Duration = .seconds(30)) async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Bool, StorageCommitError> = lock.withLock {
                    guard var state = epochs[epoch] else { return .failure(.jobReplaced) }
                    if let failure = state.failure { return .failure(failure) }
                    if Task.isCancelled { return .failure(.cancelled) }
                    if Self.satisfied(requirement, in: state.committed, results: state.results) { return .success(true) }
                    state.waiters[token] = Waiter(requirement: requirement, continuation: continuation)
                    epochs[epoch] = state
                    return .success(false)
                }
                switch outcome {
                case .failure(let error): continuation.resume(throwing: error)
                case .success(true): continuation.resume()
                case .success(false):
                    Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        self?.release(epoch: epoch, token: token, error: .timedOut)
                    }
                }
            }
        } onCancel: {
            release(epoch: epoch, token: token, error: .cancelled)
        }
    }

    private func release(epoch: UInt64, token: UUID, error: StorageCommitError) {
        let waiter: Waiter? = lock.withLock {
            guard var state = epochs[epoch], let waiter = state.waiters.removeValue(forKey: token) else { return nil }
            epochs[epoch] = state
            return waiter
        }
        waiter?.continuation.resume(throwing: error)
    }

    static func satisfied(_ requirement: Requirement, in committed: [UUID: CommittedMessage],
                          results: Set<ResultKey> = []) -> Bool {
        switch requirement {
        case .messages(let expected):
            return expected.allSatisfy { committed[$0.key]?.digest == $0.value }
        case .toolDispatch(let runID, let source, let callID, let callDigest):
            guard let message = committed[source],
                  let index = message.calls.firstIndex(where: { $0.id == callID }),
                  message.calls[index].digest == callDigest else { return false }
            // Each earlier call's own watermark, not the existence of a local
            // result message: provider-answered calls have none.
            return message.calls[..<index].allSatisfy { results.contains(ResultKey(runID: runID, callID: $0.id)) }
        case .toolResult(let runID, let callID):
            return results.contains(ResultKey(runID: runID, callID: callID))
        }
    }
}

/// The real messages a model request must not be sent without: everything
/// from this run's prompt on, minus request-only synthetic messages (summary,
/// memory and repair projections the host built, and AgentKit's replay of
/// context snapshots, whose IDs derive from their owning message).
nonisolated enum RequestCommitRequirement {
    struct MissingPrompt: LocalizedError {
        var errorDescription: String? { "请求中缺少本轮原始消息，已停止。" }
    }

    static func messages(in request: [AgentTranscriptMessage], promptID: UUID,
                         synthetic: Set<UUID>) throws -> [UUID: String] {
        guard let start = request.firstIndex(where: { $0.id == promptID }) else { throw MissingPrompt() }
        var replayed: Set<UUID> = []
        for message in request where message.role == .user && message.contextSnapshot != nil {
            for index in 0..<8 { replayed.insert(snapshotReplayID(message.id, index: index)) }
        }
        var required: [UUID: String] = [:]
        for message in request[start...] where !synthetic.contains(message.id) && !replayed.contains(message.id) {
            required[message.id] = try MessageDigestDTO.requestDigest(message)
        }
        return required
    }

    /// Mirrors `AgentContextSnapshotReplay`'s deterministic block IDs.
    static func snapshotReplayID(_ owner: UUID, index: Int) -> UUID {
        let digest = Array(SHA256.hash(data: Data("\(owner):context:\(index)".utf8)).prefix(16))
        return digest.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}
