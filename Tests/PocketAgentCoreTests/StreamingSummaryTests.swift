import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// The bounded maintenance collector against producers that call back in
/// their own task, as AgentKit's bounded `consume` does.
struct StreamingSummaryTests {
    private let request = AgentModelRequest(systemPrompt: "s", messages: [], tools: [])

    private actor Deliveries {
        var calls = 0, total = 0
        func add(_ count: Int) { calls += 1; total += count }
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
        }, progress: progress)
        #expect(text == String(repeating: "a", count: 10_000))
        try await Task.sleep(for: .milliseconds(200))
        let calls = await deliveries.calls, total = await deliveries.total
        #expect(total == 20_000 && calls < 20_000)
    }

    @Test func rejectsLengthToolCallsMissingTerminalAndOversizeImmediately() async throws {
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in
                try onEvent(.textDelta("x")); try onEvent(.finished(.length))
            })
        }
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in try onEvent(.textDelta("x")) })
        }
        let after = CallCounter()
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in
                try onEvent(.toolCallSnapshot(id: "t", providerItemID: nil, name: "tap", arguments: "{}"))
                after.increment()
            })
        }
        #expect(after.count == 0) // the producer stopped at the refusing callback
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in
                for _ in 0..<100 { try onEvent(.textDelta(String(repeating: "长", count: 1_000))) }
                after.increment()
            })
        }
        #expect(after.count == 0)
    }

    @Test func idleAndTotalDeadlinesEndTheAttempt() async throws {
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in
                try onEvent(.textDelta("开始"))
                try await Task.sleep(for: .seconds(5))
                try onEvent(.finished(.completed))
            }, idleSeconds: 0.5)
        }
        await #expect(throws: SummaryPreparationError.self) {
            try await StreamingSummary.run(request, producer: { _, onEvent in
                for _ in 0..<50 { try onEvent(.textDelta("…")); try await Task.sleep(for: .milliseconds(100)) }
                try onEvent(.finished(.completed))
            }, totalSeconds: 1, idleSeconds: 10)
        }
    }
}
