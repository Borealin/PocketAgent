import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// The bounded maintenance collector against producers that call back in
/// their own task, as AgentKit's bounded `consume` does.
struct StreamingSummaryTests {
    private let request = AgentModelRequest(systemPrompt: "s", messages: [], tools: [])
    private var long: MaintenanceDeadline { MaintenanceDeadline(turnRemaining: 600) }

    private actor Deliveries {
        var calls = 0, total = 0
        func add(_ count: Int) { calls += 1; total += count }
        /// Deliveries hop through the main actor, which other suites may keep
        /// busy: wait (bounded) until `expected` arrived, then a short grace
        /// for any extra one, instead of a fixed sleep.
        func settle(_ expected: Int) async throws {
            let end = ContinuousClock.now + .seconds(5)
            while total < expected, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    @Test func manyEventsKeepOnlyTextAndCoalesceProgress() async throws {
        let deliveries = Deliveries()
        let progress = ProgressCoalescer { count in Task { await deliveries.add(count) } }
        let text = try await StreamingSummary.run(request, producer: { _, onEvent in
            for index in 0..<20_000 {
                try onEvent(index % 2 == 0 ? .textDelta("a") : .reasoningDelta("思考"))
            }
            try onEvent(.usage(AgentTokenUsage(inputTokens: 10)))
            try onEvent(.finished(.completed))
        }, deadline: long, progress: progress)
        #expect(text == String(repeating: "a", count: 10_000))
        try await deliveries.settle(20_000)
        let calls = await deliveries.calls, total = await deliveries.total
        #expect(total == 20_000 && calls < 20_000)
    }

    @Test func rejectsLengthToolCallsMissingTerminalAndOversizeImmediately() async throws {
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in
                try onEvent(.textDelta("x")); try onEvent(.finished(.length))
            }, deadline: long)
        }
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in try onEvent(.textDelta("x")) }, deadline: long)
        }
        let after = CallCounter()
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in
                try onEvent(.toolCallSnapshot(id: "t", providerItemID: nil, name: "tap", arguments: "{}"))
                after.increment()
            }, deadline: long)
        }
        #expect(after.count == 0) // the producer stopped at the refusing callback
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in
                for _ in 0..<100 { try onEvent(.textDelta(String(repeating: "长", count: 1_000))) }
                after.increment()
            }, deadline: long)
        }
        #expect(after.count == 0)
    }

    /// Review finding: repeated or empty snapshots are not real work; they must
    /// neither keep an idle attempt alive nor inflate progress.
    @Test func repeatedOrEmptySnapshotsDoNotRefreshIdleOrCountProgress() async throws {
        let deliveries = Deliveries()
        let progress = ProgressCoalescer { count in Task { await deliveries.add(count) } }
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in
                try onEvent(.textSnapshot("## Goal"))
                try onEvent(.textSnapshot("## Goal\n旧"))
                try onEvent(.reasoningSnapshot("思考中"))
                for index in 0..<30 {
                    try onEvent(.textSnapshot(index % 2 == 0 ? "## Goal" : "## Goal\n旧"))
                    try onEvent(.textSnapshot("## Goal"))
                    try onEvent(.textSnapshot(""))
                    try onEvent(.reasoningSnapshot("思考中"))
                    try onEvent(.reasoningSnapshot(""))
                    try onEvent(.textDelta(""))
                    try await Task.sleep(for: .milliseconds(100))
                }
                try onEvent(.finished(.completed))
            }, deadline: long, idleSeconds: 0.6, progress: progress)
        }
        try await deliveries.settle(3)
        let delivered = await deliveries.total
        #expect(delivered == 3) // the two distinct texts and the first reasoning only
        let collector = SummaryCollector()
        try collector.accept(.textSnapshot("a"))
        try collector.accept(.textSnapshot("a"))
        try collector.accept(.reasoningSnapshot("r"))
        try collector.accept(.reasoningSnapshot("r"))
        try collector.accept(.reasoningSnapshot("r2"))
        #expect(collector.work == 3)
    }

    /// Streams real text every 50 ms for at least `seconds`, a fixture bound
    /// about 3 s past the deadline it is given: only that deadline can end it
    /// sooner, and a reset budget or a stop that much later lets it finish.
    /// Records its start and cancellation.
    private final class Streaming: @unchecked Sendable {
        private let lock = NSLock()
        private var state = (started: false, cancelled: false)
        private let ticks: Int
        init(seconds: Int) { ticks = seconds * 20 }
        var started: Bool { lock.withLock { state.started } }
        var cancelled: Bool { lock.withLock { state.cancelled } }
        var producer: StreamingSummary.Producer {
            { [self] _, onEvent in
                lock.withLock { state.started = true }
                do {
                    for _ in 0..<ticks { try onEvent(.textDelta("…")); try await Task.sleep(for: .milliseconds(50)) }
                } catch is CancellationError {
                    lock.withLock { state.cancelled = true }
                    throw CancellationError()
                }
                try onEvent(.finished(.completed))
            }
        }
    }

    @Test func idleAndSharedDeadlinesEndTheAttempt() async throws {
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in
                try onEvent(.textDelta("开始"))
                try await Task.sleep(for: .seconds(5))
                try onEvent(.finished(.completed))
            }, deadline: long, idleSeconds: 0.5)
        }
        // One maintenance budget across folds, never reset per fold. `now:`
        // starts the production 150 s budget 145 s ago, as the turn's earlier
        // folds would have; host load only shortens what is left of it.
        let overrun = SummaryPreparationError(detail: "上下文整理超过 150 秒，本轮不使用新的摘要")
        let shared = MaintenanceDeadline(turnRemaining: 600, now: ProcessInfo.processInfo.systemUptime - 145)
        let first = try await StreamingSummary.run(request, producer: { _, onEvent in
            try onEvent(.textDelta("摘要")); try onEvent(.finished(.completed))
        }, deadline: shared, idleSeconds: 60)
        #expect(first == "摘要")
        // The next fold gets what is left and streams until that end stops it.
        let stopped = Streaming(seconds: 8)
        await #expect(throws: overrun) {
            try await StreamingSummary.run(request, producer: stopped.producer, deadline: shared, idleSeconds: 60)
        }
        #expect(stopped.started && stopped.cancelled && shared.remaining <= 0)
        // Spent: the next fold of that budget is refused before its producer starts.
        let late = Streaming(seconds: 8)
        await #expect(throws: overrun) {
            try await StreamingSummary.run(request, producer: late.producer, deadline: shared, idleSeconds: 60)
        }
        #expect(!late.started)
        // When the turn's own deadline is the bound, the whole turn stops.
        let turnBound = MaintenanceDeadline(turnRemaining: 3)
        #expect(turnBound.turnBound)
        let cut = Streaming(seconds: 6)
        await #expect(throws: TurnDeadlineReached()) {
            try await StreamingSummary.run(request, producer: cut.producer, deadline: turnBound, idleSeconds: 60)
        }
        #expect(cut.started && cut.cancelled)
        #expect(!MaintenanceDeadline(turnRemaining: 600).turnBound)
        #expect(MaintenanceDeadline(turnRemaining: 600).remaining <= 150)
    }

    /// Cancelling the preparing turn surfaces as cancellation even when the
    /// transport reports its own error (URLSession cancellation).
    @Test func cancellationPropagatesAsCancellation() async throws {
        let task = Task {
            try await StreamingSummary.run(request, producer: { _, onEvent in
                try onEvent(.textDelta("部分"))
                do { try await Task.sleep(for: .seconds(10)) } catch { throw URLError(.cancelled) }
            }, deadline: long)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// A cycle of more distinct snapshots than any small window (A B … 70
    /// times round) is only new work the first time each appears.
    @Test func cyclingSnapshotsCountOnlyOnce() throws {
        let collector = SummaryCollector()
        let cycle = (0..<70).map { "## Goal \($0)" }
        for _ in 0..<3 { for text in cycle { try collector.accept(.textSnapshot(text)) } }
        #expect(collector.work == 70)
        let reasoning = (0..<70).map { "思考 \($0)" }
        for _ in 0..<3 { for text in reasoning { try collector.accept(.reasoningSnapshot(text)) } }
        #expect(collector.work == 140)
    }
}
