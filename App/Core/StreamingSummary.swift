import AgentKit
import CryptoKit
import Foundation

/// Coalesces real-work notifications into at most one pending MainActor
/// delivery, so a fast producer never queues a Task per event. Counts are
/// preserved: each delivery carries every event noted since the last one.
nonisolated final class ProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var count = 0
    private let deliver: @MainActor @Sendable (Int) -> Void

    init(deliver: @escaping @MainActor @Sendable (Int) -> Void) { self.deliver = deliver }

    func note() {
        let schedule: Bool = lock.withLock {
            count += 1
            guard !pending else { return false }
            pending = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor [self] in deliver(take()) }
    }

    private func take() -> Int {
        lock.withLock { defer { count = 0; pending = false }; return count }
    }
}

/// Accumulates one maintenance response delivered event by event in the
/// producer's task: only text is kept (≤ 64 KiB; delta appends, snapshot
/// replaces), new non-empty text or reasoning counts as work (reasoning is
/// never kept; repeated or empty snapshots do not count), tool calls and
/// oversize text fail immediately, and only `finished(.completed)` succeeds.
nonisolated final class SummaryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    /// 16-byte digest identities of every snapshot seen in this response (no
    /// reasoning text kept), so a repeated or cycling snapshot never counts as
    /// new work again. Bounded by AgentKit's per-response event limit.
    private var seenSnapshots: Set<UUID> = []
    static let maximumSnapshots = 65_536
    private func isNew(_ kind: UInt8, _ snapshot: String) throws -> Bool {
        var data = Data([kind])
        data.append(contentsOf: snapshot.utf8)
        let identity = Array(SHA256.hash(data: data).prefix(16)).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        guard seenSnapshots.count < Self.maximumSnapshots || seenSnapshots.contains(identity) else {
            throw SummaryPreparationError(detail: "摘要响应的快照数超过上限")
        }
        return seenSnapshots.insert(identity).inserted
    }
    private var finished: AgentStopReason?
    private var lastWork = ProcessInfo.processInfo.systemUptime
    private(set) var work = 0
    private let progress: ProgressCoalescer?

    init(progress: ProgressCoalescer? = nil) { self.progress = progress }

    var secondsSinceWork: TimeInterval { lock.withLock { ProcessInfo.processInfo.systemUptime - lastWork } }

    func accept(_ event: AgentModelStreamEvent) throws {
        var counted = false
        try lock.withLock {
            switch event {
            case .textDelta(let delta):
                guard text.utf8.count + delta.utf8.count <= SummaryResponse.maximumBytes else {
                    throw SummaryPreparationError(detail: "摘要超过 64 KiB 上限")
                }
                text += delta; counted = !delta.isEmpty
            case .textSnapshot(let snapshot):
                guard snapshot.utf8.count <= SummaryResponse.maximumBytes else {
                    throw SummaryPreparationError(detail: "摘要超过 64 KiB 上限")
                }
                // Only new, non-empty content is real work; a repeated or empty
                // snapshot neither refreshes idle nor counts as progress. An
                // empty snapshot does not erase received text.
                guard !snapshot.isEmpty else { break }
                counted = try isNew(0x74, snapshot) && snapshot != text
                text = snapshot
            case .reasoningDelta(let delta): counted = !delta.isEmpty
            case .reasoningSnapshot(let snapshot):
                guard !snapshot.isEmpty else { break }
                counted = try isNew(0x72, snapshot)
            case .toolCallDelta, .toolCallSnapshot: throw SummaryPreparationError(detail: "摘要响应包含工具调用")
            case .finished(let reason): finished = reason
            case .providerItem, .usage, .webSearch: break
            }
            if counted { lastWork = ProcessInfo.processInfo.systemUptime; work += 1 }
        }
        if counted { progress?.note() }
    }

    func result() throws -> String {
        let snapshot: (text: String, finished: AgentStopReason?) = lock.withLock { (text, finished) }
        var events: [AgentModelStreamEvent] = [.textSnapshot(snapshot.text)]
        if let reason = snapshot.finished { events.append(.finished(reason)) }
        return try SummaryResponse.validate(events)
    }
}

/// One maintenance budget shared by every fold of a turn's context
/// preparation: at most 150 s from its start and never past the turn's own
/// deadline. Reaching a turn-bound end stops the whole turn.
nonisolated struct MaintenanceDeadline: Sendable {
    static let total: TimeInterval = 150
    static let idle: TimeInterval = 45

    /// Monotonic end (`systemUptime`).
    let end: TimeInterval
    /// True when the turn deadline, not the maintenance limit, is the end.
    let turnBound: Bool
    let maintenanceLimit: TimeInterval

    init(turnRemaining: TimeInterval, total: TimeInterval = MaintenanceDeadline.total,
         now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let budget = max(0, min(total, turnRemaining))
        end = now + budget
        turnBound = turnRemaining <= total
        maintenanceLimit = max(0, total)
    }

    var remaining: TimeInterval { end - ProcessInfo.processInfo.systemUptime }
}

/// The turn's own deadline ended during context maintenance: the whole turn
/// stops (no main request is sent without its context).
nonisolated struct TurnDeadlineReached: LocalizedError, Equatable {
    var errorDescription: String? { "本轮已达到 10 分钟上限；请发送新消息继续。" }
}

/// The exact summarizer request for one fold: AgentKit's fixed skeleton
/// prompt, the previous summary (folded forward) and the serialized history
/// as untrusted data. No tools.
nonisolated enum SummaryRequest {
    static func make(messages: [AgentTranscriptMessage], previous: String?) -> AgentModelRequest {
        var body = ""
        if let previous { body += "<previous-summary>\n\(previous)\n</previous-summary>\n" }
        body += "<untrusted-data>\n\(AssistantContext.serialized(messages))\n</untrusted-data>"
        return AgentModelRequest(
            systemPrompt: AgentCompactionService.systemPrompt(
                instructions: "使用对话所用的语言。合并 previous-summary 与新内容，保留用户明确的偏好、决定、未完成事项和未确认的动作结果。"),
            messages: [AgentTranscriptMessage(role: .user, text: body)], tools: [])
    }
}

/// Bounded streaming maintenance over a producer that calls back in its own
/// task (AgentKit `consume`, which bounds transport bytes, SSE lines and
/// events). The shared deadline and an idle limit refreshed only by new real
/// text or reasoning end an attempt with no retry. Cancellation propagates as
/// `CancellationError`; a turn-bound deadline as `TurnDeadlineReached`.
nonisolated enum StreamingSummary {
    typealias Producer = @Sendable (AgentModelRequest, (AgentModelStreamEvent) throws -> Void) async throws -> Void

    static func run(_ request: AgentModelRequest, producer: @escaping Producer, deadline: MaintenanceDeadline,
                    idleSeconds: TimeInterval = MaintenanceDeadline.idle,
                    progress: ProgressCoalescer? = nil) async throws -> String {
        try Task.checkCancellation()
        guard deadline.remaining > 0 else { throw expired(deadline) }
        let collector = SummaryCollector(progress: progress)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await producer(request) { try collector.accept($0) } }
                group.addTask {
                    while true {
                        try await Task.sleep(for: .milliseconds(200))
                        if deadline.remaining <= 0 { throw expired(deadline) }
                        if collector.secondsSinceWork > idleSeconds {
                            throw SummaryPreparationError(detail: "整理 \(Int(idleSeconds)) 秒没有新内容，已停止")
                        }
                    }
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            // A transport error caused by our own cancellation is cancellation.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        return try collector.result()
    }

    private static func expired(_ deadline: MaintenanceDeadline) -> any Error {
        deadline.turnBound ? TurnDeadlineReached()
            : SummaryPreparationError(detail: "上下文整理超过 \(Int(deadline.maintenanceLimit)) 秒，未生成新的摘要")
    }
}
