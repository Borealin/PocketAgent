import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

@MainActor
struct TranscriptEventCommitTests {
    @Test(arguments: ["none", "message", "result", "cancel"])
    func sdkDrainAwaitsTheAuthoritativeOwnerAndStopsAfterWriteFailure(failure: String) async throws {
        let writer = EventCommitWriter()
        let owner = HistoryOwner(file: .initial(selection: nil), writer: { try writer.write($0) })
        let session = owner.file.assistant.primarySessionID
        let prompt = AgentTranscriptMessage(role: .user, text: "检查两次")
        try owner.transact { try $0.acceptRoot(prompt, attachments: [], in: session, scope: .general) }
        owner.barrier.open(epoch: 1, seed: [prompt.id: try CommittedMessage(prompt)])
        let model = ScriptedModel(turns: [[
            .toolCallSnapshot(id: "first", providerItemID: nil, name: "observe_screen", arguments: "{}"),
            .toolCallSnapshot(id: "second", providerItemID: nil, name: "observe_screen", arguments: "{}"),
            .finished(.toolCalls),
        ], [.textDelta("完成"), .finished(.completed)]])
        let calls = CallCounter()
        let tool = AnyAgentTool(descriptor: ToolCatalog.phoneTools[0].descriptor) { invocation, _ in
            calls.increment()
            return AgentToolResult(callID: invocation.call.id, content: "screen")
        }
        let repository = InMemoryAgentRunRepository()
        let commit = TranscriptEventCommit(barrier: owner.barrier, epoch: 1, timeout: .seconds(10))
        let channel = AgentEventChannel(repository: repository, committing: { try await commit.commit($0) })
        var loop = AgentLoopConfiguration()
        loop.toolExecution = .sequential
        loop.modelRetryPolicy = .disabled
        let gatedModel = CommitGatedModel(base: model, barrier: owner.barrier, epoch: 1, promptID: prompt.id,
                                          synthetic: { [] }, prepare: { $0 })
        let approval = CommitGatedApproval(barrier: owner.barrier, epoch: 1, decide: { _ in .allow })
        let runtime = AgentRuntime(model: gatedModel, tools: [tool], approval: approval,
            repository: repository, configuration: loop, channel: channel)
        var terminal: AgentRunState?
        for await event in await runtime.start(AgentRunRequest(conversationID: session, promptID: prompt.id,
                prompt: prompt.text, permissionMode: .fullAccess)) {
            switch event {
            case .messageFinished(let message):
                if failure == "cancel" { await runtime.cancel() }
                if failure == "message" { writer.fail = true }
                let stored = ChatSession.forHistory(message)
                owner.record(commit: .init(epoch: 1, messages: [stored.id: try CommittedMessage(stored)])) {
                    try $0.appendEvent(stored, to: session, root: prompt.id)
                }
            case .toolFinished(let invocation, let result):
                if failure == "result" { writer.fail = true }
                let stored = AgentTranscriptMessage(
                    id: AgentTranscriptMessage.toolResultID(runID: invocation.runID, callID: result.callID),
                    role: .tool, text: result.content, toolCallID: result.callID,
                    toolName: invocation.call.name, isError: result.isError, modelText: result.modelContent)
                owner.record(commit: .init(epoch: 1, messages: [stored.id: try CommittedMessage(stored)],
                    results: [.init(runID: invocation.runID, callID: result.callID)])) {
                    try $0.appendEvent(stored, to: session, root: prompt.id)
                }
            case .runFinished(let summary): terminal = summary.state
            default: break
            }
        }
        #expect(calls.count == (failure == "none" ? 2 : failure == "result" ? 1 : 0))
        #expect(model.requests.count == (failure == "none" ? 2 : 1))
        #expect(terminal == (failure == "none" ? .completed : failure == "cancel" ? .cancelled : .failed))
        if failure == "none" || failure == "cancel" {
            let saved = try HistoryCodec.decode(try #require(writer.last))
            #expect(owner.health.isReady)
            #expect(saved.primary?.messages.map(\.role) == (failure == "cancel"
                ? [.user, .assistant, .tool, .tool] : [.user, .assistant, .tool, .tool, .assistant]))
            if failure == "cancel" {
                #expect(saved.primary?.messages.suffix(2).map(\.toolCallID) == ["first", "second"])
                #expect(saved.primary?.messages.suffix(2).allSatisfy(\.isError) == true)
            }
        } else {
            #expect(!owner.health.isReady)
            // An effect which happened remains visible even when its write fails.
            if failure == "result" { #expect(owner.file.primary?.messages.contains { $0.toolCallID == "first" } == true) }
        }
    }
}

@MainActor private final class EventCommitWriter {
    var fail = false
    var last: Data?
    func write(_ data: Data) throws {
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        last = data
    }
}
