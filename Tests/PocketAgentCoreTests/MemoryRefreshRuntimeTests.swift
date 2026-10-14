import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

/// The production per-request preparation (`AssistantRequestPreparer`, which
/// the app's turn support delegates to) under the pinned AgentRuntime and the
/// main-model gate: a memory change made during a run is what the run's next
/// request carries and registers; a forget of something the run already read
/// stops it before the next request.
@MainActor
struct MemoryRefreshRuntimeTests {
    private enum Change { case correct, forget }
    private static let old = "PKATEST_GAPS_组会：每周五下午"
    private static let new = "PKATEST_GAPS_组会：每周四上午"

    private struct Outcome { var requests: [AgentModelRequest]; var terminal: AgentRunState?; var reads: [MemoryReadRevision] }

    private func run(_ change: Change) async throws -> Outcome {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        let entry = try #require(try file.applyMemoryEdit(.add(target: .memory, scope: .global, content: Self.old, origin: .panel,
                                                                sourceRootPromptIDs: [], sourceMessageIDs: [])).entryIDs.first)
        let current = try file.acceptCurrent("PKATEST_GAPS 组会是哪天？", in: primary, scope: .general)
        let prompt = try #require(file.session(primary)?.messages.first { $0.id == current })
        let owner = HistoryOwner(file: file, writer: { _ in })
        owner.barrier.open(epoch: 1, seed: [prompt.id: try CommittedMessage(prompt)])
        let preparer = AssistantRequestPreparer(owner: owner, sessionID: primary, promptID: current, scope: .general,
                                                budget: .unknown, estimator: { ContextEstimator() })
        let base = ScriptedModel(turns: [
            [.toolCallSnapshot(id: "c1", providerItemID: nil, name: ToolCatalog.phoneTools[0].descriptor.name, arguments: "{}"),
             .finished(.toolCalls)],
            [.textDelta("完成"), .finished(.completed)],
        ])
        let model = CommitGatedModel(base: base, barrier: owner.barrier, epoch: 1, promptID: current, synthetic: { [] },
                                     prepare: { request in try await MainActor.run { try preparer.prepare(request) } },
                                     commitTimeout: .seconds(5))
        // The user's edit lands while the run's tool step runs.
        let tool = AnyAgentTool(descriptor: ToolCatalog.phoneTools[0].descriptor) { invocation, _ in
            try await MainActor.run {
                try owner.transact { file in
                    switch change {
                    case .correct:
                        _ = try file.applyMemoryEdit(.replace(entryID: entry, expectedRevision: file.assistant.memory.entry(entry)!.revision,
                                                              content: Self.new))
                    case .forget:
                        _ = try file.commitForget(try file.forgetPreview([entry], activeRoot: current), activeRoot: current)
                    }
                }
            }
            return AgentToolResult(callID: invocation.call.id, content: #"{"ok":true}"#)
        }
        let approval = CommitGatedApproval(barrier: owner.barrier, epoch: 1, decide: { _ in .allow }, commitTimeout: .seconds(5))
        var loop = AgentLoopConfiguration()
        loop.toolExecution = .sequential; loop.maximumToolConcurrency = 1; loop.modelRetryPolicy = .disabled
        let runtime = AgentRuntime(model: model, tools: [tool], approval: approval, configuration: loop)
        func record(_ message: AgentTranscriptMessage, result: TranscriptCommitBarrier.ResultKey? = nil) {
            let stored = ChatSession.forHistory(message)
            let commit = try? CommittedMessage(stored)
            owner.record(commit: commit.map { .init(epoch: 1, messages: [stored.id: $0], results: result.map { [$0] } ?? []) }) {
                try $0.appendEvent(stored, to: primary, root: current)
            }
        }
        var terminal: AgentRunState?
        for await event in await runtime.start(AgentRunRequest(conversationID: primary, promptID: current, prompt: prompt.text,
                                                                permissionMode: .fullAccess,
                                                                systemPrompt: "s\n" + AssistantContextPipeline.memorySlot,
                                                                priorMessages: [])) {
            switch event {
            case .messageFinished(let message): record(message)
            case .toolFinished(let invocation, let result):
                record(AgentTranscriptMessage(id: AgentTranscriptMessage.toolResultID(runID: invocation.runID, callID: result.callID),
                                              role: .tool, text: result.content, toolCallID: result.callID,
                                              toolName: invocation.call.name, isError: result.isError, modelText: result.modelContent),
                       result: .init(runID: invocation.runID, callID: result.callID))
            case .runFinished(let summary): terminal = summary.state
            default: break
            }
        }
        let reads = owner.file.assistant.scopeIndex.scopedRoot(current)?.dependencies.memoryReads ?? []
        return Outcome(requests: base.requests, terminal: terminal, reads: reads)
    }

    @Test func aCorrectionDuringTheRunIsWhatTheNextRequestCarriesAndRegisters() async throws {
        let outcome = try await run(.correct)
        #expect(outcome.requests.count == 2 && outcome.terminal == .completed)
        #expect(outcome.requests[0].systemPrompt.contains(Self.old))
        #expect(outcome.requests[1].systemPrompt.contains(Self.new) && !outcome.requests[1].systemPrompt.contains(Self.old))
        #expect(outcome.reads.map(\.revision) == [1, 2])
    }

    @Test func aForgetOfWhatTheRunReadStopsItBeforeTheNextRequest() async throws {
        let outcome = try await run(.forget)
        #expect(outcome.requests.count == 1 && outcome.terminal == .failed)
        #expect(outcome.requests[0].systemPrompt.contains(Self.old))
    }
}
