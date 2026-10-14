import AgentKit
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
    /// Digests of snapshots already seen (bounded; no reasoning text kept), so a
    /// repeated or alternating snapshot is not counted as new work again.
    private var seenSnapshots: [String] = []
    private func isNew(_ kind: String, _ snapshot: String) -> Bool {
        let digest = kind + CanonicalDigest.hex(Data(snapshot.utf8))
        guard !seenSnapshots.contains(digest) else { return false }
        seenSnapshots.append(digest)
        if seenSnapshots.count > 64 { seenSnapshots.removeFirst() }
        return true
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
                counted = snapshot != text && isNew("t", snapshot)
                text = snapshot
            case .reasoningDelta(let delta): counted = !delta.isEmpty
            case .reasoningSnapshot(let snapshot):
                guard !snapshot.isEmpty else { break }
                counted = isNew("r", snapshot)
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

/// Bounded streaming maintenance over a producer that calls back in its own
/// task (AgentKit `consume`). One total deadline (150 s default, never past
/// the turn deadline) and an idle limit refreshed only by real text or
/// reasoning; either ends the attempt with no retry.
nonisolated enum StreamingSummary {
    typealias Producer = @Sendable (AgentModelRequest, (AgentModelStreamEvent) throws -> Void) async throws -> Void

    static func run(_ request: AgentModelRequest, producer: @escaping Producer, totalSeconds: TimeInterval = 150,
                    idleSeconds: TimeInterval = 45, progress: ProgressCoalescer? = nil) async throws -> String {
        let collector = SummaryCollector(progress: progress)
        let total = max(1, totalSeconds)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await producer(request) { try collector.accept($0) } }
            group.addTask {
                let started = ProcessInfo.processInfo.systemUptime
                while true {
                    try await Task.sleep(for: .milliseconds(200))
                    if ProcessInfo.processInfo.systemUptime - started > total {
                        throw SummaryPreparationError(detail: "整理超过 \(Int(total)) 秒，本轮不使用摘要")
                    }
                    if collector.secondsSinceWork > idleSeconds {
                        throw SummaryPreparationError(detail: "整理 \(Int(idleSeconds)) 秒没有新内容，已停止")
                    }
                }
            }
            defer { group.cancelAll() }
            try await group.next()
        }
        return try collector.result()
    }
}
