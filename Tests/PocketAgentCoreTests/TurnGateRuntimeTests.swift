import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// Scripted model turns; records every request it receives.
final class ScriptedModel: AgentModelStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [[AgentModelStreamEvent]]
    private var captured: [AgentModelRequest] = []
    var requests: [AgentModelRequest] { lock.withLock { captured } }
    init(turns: [[AgentModelStreamEvent]]) { self.turns = turns }
    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        let events: [AgentModelStreamEvent] = lock.withLock {
            captured.append(request)
            return turns.isEmpty ? [.textDelta("done"), .finished(.completed)] : turns.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Exercises the commit gates through the pinned AgentRuntime with its
/// default chat pipeline (snapshot replay included), as an independent task
/// uses it, and a host consumer that plays the history owner.
struct TurnGateRuntimeTests {
    private static let call = AgentToolCall(id: "c1", name: "observe_screen", arguments: .object([:]))

    private func run(commit: Bool, priorUnanswered: Bool, mixedNative: Bool = false)
        async throws -> (executed: Int, terminal: AgentRunState?, requests: [AgentModelRequest]) {
        let barrier = TranscriptCommitBarrier()
        let epoch: UInt64 = 1
        let prompt = AgentTranscriptMessage(role: .user, text: "看一下屏幕")
        barrier.open(epoch: epoch, seed: [prompt.id: try CommittedMessage(prompt)])
        let first: [AgentModelStreamEvent] = mixedNative
            ? [.webSearch(AgentWebSearchActivity(query: "天气", sources: [.init(title: "t", url: "https://example.com")])),
               .providerItem(.object(["id": .string("rs_1"), "type": .string("reasoning")])),
               .toolCallSnapshot(id: Self.call.id, providerItemID: nil, name: Self.call.name, arguments: "{}"),
               .toolCallSnapshot(id: "c2", providerItemID: nil, name: Self.call.name, arguments: "{}"),
               .finished(.toolCalls)]
            : [.toolCallSnapshot(id: Self.call.id, providerItemID: nil, name: Self.call.name, arguments: "{}"),
               .finished(.toolCalls)]
        let base = ScriptedModel(turns: [first, [.textDelta("完成"), .finished(.completed)]])
        let model = CommitGatedModel(base: base, barrier: barrier, epoch: epoch, promptID: prompt.id,
                                     synthetic: { [] }, prepare: { $0 }, commitTimeout: .milliseconds(400))
        let approval = CommitGatedApproval(barrier: barrier, epoch: epoch, decide: { _ in .allow },
                                           commitTimeout: .milliseconds(400))
        let executed = CallCounter()
        let tool = AnyAgentTool(descriptor: ToolCatalog.phoneTools[0].descriptor) { invocation, _ in
            executed.increment()
            return AgentToolResult(callID: invocation.call.id, content: "{\"ok\":true}")
        }
        var loop = AgentLoopConfiguration()
        loop.toolExecution = .sequential; loop.maximumToolConcurrency = 1
        loop.modelRetryPolicy = .disabled
        let runtime = AgentRuntime(model: model, tools: [tool], approval: approval, configuration: loop)
        var prior: [AgentTranscriptMessage] = []
        if priorUnanswered {
            prior = [AgentTranscriptMessage(role: .user, text: "以前"),
                     AgentTranscriptMessage(role: .assistant, toolCalls: [AgentToolCall(id: "old", name: "tap",
                                                                                         arguments: .object([:]))])]
        }
        var terminal: AgentRunState?
        for await event in await runtime.start(AgentRunRequest(conversationID: UUID(), promptID: prompt.id,
                prompt: prompt.text, permissionMode: .fullAccess, systemPrompt: "s", priorMessages: prior)) {
            guard commit else {
                if case .runFinished(let summary) = event { terminal = summary.state }
                continue
            }
            switch event {
            case .messageFinished(let message):
                barrier.commit(epoch: epoch, [message.id: try CommittedMessage(ChatSession.forHistory(message))])
            case .toolFinished(let invocation, let result) where !result.isProviderNative:
                let stored = AgentTranscriptMessage(id: AgentTranscriptMessage.toolResultID(runID: invocation.runID,
                                                                                            callID: result.callID),
                    role: .tool, text: result.content, toolCallID: result.callID, toolName: invocation.call.name,
                    isError: result.isError, modelText: result.modelContent)
                barrier.commit(epoch: epoch, [stored.id: try CommittedMessage(stored)],
                               results: [.init(runID: invocation.runID, callID: result.callID)])
            case .toolFinished(let invocation, let result):
                // Provider-native: no local message; acknowledged per call.
                _ = result
                barrier.commit(epoch: epoch, [:], results: [.init(runID: invocation.runID, callID: invocation.call.id)])
            case .runFinished(let summary): terminal = summary.state
            default: break
            }
        }
        return (executed.count, terminal, base.requests)
    }

    @Test func savedEventsLetTheRunProceedThroughReplayAndRepairedHistory() async throws {
        let result = try await run(commit: true, priorUnanswered: true)
        #expect(result.executed == 1 && result.terminal == .completed && result.requests.count == 2)
    }

    /// Review finding: a provider-answered (native) result adds no local tool
    /// message; local calls must not wait for a nonexistent result ID, and the
    /// assistant's provider replay items are part of what was saved.
    @Test func mixedProviderNativeAndLocalCallsProceedOnPerCallWatermarks() async throws {
        let result = try await run(commit: true, priorUnanswered: false, mixedNative: true)
        #expect(result.executed == 2 && result.terminal == .completed && result.requests.count == 2)
        let second = try #require(result.requests.last)
        #expect(second.messages.contains { !$0.providerItems.isEmpty })
    }

    @Test func unsavedAssistantCallNeverExecutesAndTheRunStops() async throws {
        let result = try await run(commit: false, priorUnanswered: false)
        #expect(result.executed == 0)
        #expect(result.terminal == .failed)
        // The second model request is never sent: its input was not saved.
        #expect(result.requests.count == 1)
    }

    @Test func requirementExcludesReplayAndHostSyntheticMessages() throws {
        let prompt = AgentTranscriptMessage(role: .user, text: "p", contextSnapshot: AgentTurnContextSnapshot())
        let replay = AgentTranscriptMessage(id: RequestCommitRequirement.snapshotReplayID(prompt.id, index: 0), role: .user,
                                            text: "Session context")
        let summary = AgentTranscriptMessage(role: .user, text: "摘要")
        let reply = AgentTranscriptMessage(role: .assistant, text: "r")
        let required = try RequestCommitRequirement.messages(in: [summary, replay, prompt, reply], promptID: prompt.id,
                                                             synthetic: [summary.id])
        #expect(Set(required.keys) == [prompt.id, reply.id])
        #expect(throws: RequestCommitRequirement.MissingPrompt.self) {
            try RequestCommitRequirement.messages(in: [reply], promptID: prompt.id, synthetic: [])
        }
    }

    /// A Stop while the request's preparation is suspended (memory refresh,
    /// projections, phone observation) must not reach the provider when the
    /// preparation returns afterwards. The positive control dispatches once.
    @Test(arguments: [true, false])
    func aStopDuringPreparationDispatchesNothing(cancelled: Bool) async throws {
        let barrier = TranscriptCommitBarrier()
        let prompt = AgentTranscriptMessage(role: .user, text: "p")
        barrier.open(epoch: 1, seed: [prompt.id: try CommittedMessage(prompt)])
        let base = ScriptedModel(turns: [])
        let held = HeldPreparation()
        let traces = CallCounter()
        var model = CommitGatedModel(base: base, barrier: barrier, epoch: 1, promptID: prompt.id, synthetic: { [] },
                                     prepare: { await held.prepare($0) })
        model.observe = { _ in traces.increment() }
        let request = AgentModelRequest(systemPrompt: "s", messages: [prompt], tools: [])
        let consumer = Task { for try await _ in model.stream(request) {} }
        while !(await held.entered) { try await Task.sleep(for: .milliseconds(5)) }
        if cancelled {
            consumer.cancel()
            _ = await consumer.result
        }
        await held.release()
        // Nothing awaits between the preparation's return and the provider
        // call, so its effect (or its absence) is settled once it returned.
        while !(await held.returned) { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        if !cancelled { _ = await consumer.result }
        #expect(base.requests.count == (cancelled ? 0 : 1))
        #expect(traces.count == (cancelled ? 0 : 2))
    }
}

/// A request preparation that suspends until released.
private actor HeldPreparation {
    private(set) var entered = false
    private(set) var returned = false
    private var held: CheckedContinuation<Void, Never>?
    func prepare(_ request: AgentModelRequest) async -> AgentModelRequest {
        entered = true
        await withCheckedContinuation { held = $0 }
        returned = true
        return request
    }
    func release() { held?.resume(); held = nil }
}
