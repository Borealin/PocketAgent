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

    @Test func idleAndSharedDeadlinesEndTheAttempt() async throws {
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in
                try onEvent(.textDelta("开始"))
                try await Task.sleep(for: .seconds(5))
                try onEvent(.finished(.completed))
            }, deadline: long, idleSeconds: 0.5)
        }
        // One maintenance budget across folds: the second fold only gets what is left.
        let shared = MaintenanceDeadline(turnRemaining: 600, total: 1)
        let slow: StreamingSummary.Producer = { _, onEvent in
            for _ in 0..<7 { try onEvent(.textDelta("…")); try await Task.sleep(for: .milliseconds(100)) }
            try onEvent(.finished(.completed))
        }
        let first = try await StreamingSummary.run(request, producer: slow, deadline: shared, idleSeconds: 10)
        #expect(!first.isEmpty)
        let started = ProcessInfo.processInfo.systemUptime
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: slow, deadline: shared, idleSeconds: 10)
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 0.7)
        // When the turn's own deadline is the bound, the whole turn stops.
        let turnBound = MaintenanceDeadline(turnRemaining: 0.5)
        #expect(turnBound.turnBound)
        await #expect(throws: TurnDeadlineReached.self) {
            try await StreamingSummary.run(request, producer: slow, deadline: turnBound, idleSeconds: 10)
        }
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
