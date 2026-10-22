import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

struct TranscriptWindowTests {
    @Test func preservesCallGroupAtThePageBoundary() {
        let earlier = AgentTranscriptMessage(role: .user, text: "earlier")
        let call = AgentTranscriptMessage(role: .assistant, text: "", toolCalls: [
            AgentToolCall(id: "read", name: "read", arguments: .object([:]))
        ])
        let result = AgentTranscriptMessage(role: .tool, text: "value", toolCallID: "read")
        let page = TranscriptWindow(history: [earlier, call, result], partial: nil, pendingSteering: [], limit: 1)
        #expect(page.messages.map(\.id) == [call.id, result.id])
        #expect(page.hiddenCount == 1)
    }

    @Test func livePrecedesUndeliveredSteeringAndNeverDuplicatesSavedText() {
        let user = AgentTranscriptMessage(role: .user, text: "question")
        let steer = AgentTranscriptMessage(role: .user, text: "change")
        let live = AgentTranscriptMessage(role: .assistant, text: "partial")
        let page = TranscriptWindow(history: [user, steer], partial: live, pendingSteering: [steer.id], limit: 2)
        #expect(page.messages.map(\.id) == [live.id, steer.id])
        #expect(page.totalCount == 3)
        let saved = TranscriptWindow(history: [user, live, steer], partial: live, pendingSteering: [steer.id], limit: 3)
        #expect(saved.messages.map(\.id) == [user.id, live.id, steer.id])
    }

    @Test func streamingUpdatesOnlyTheVisibleRowWithoutRebuildingHistory() {
        let history = (0..<5_000).map { AgentTranscriptMessage(role: .user, text: "message \($0)") }
        let session = UUID()
        var live = AgentTranscriptMessage(role: .assistant, text: "")
        var cache = TranscriptWindowCache()
        for _ in 0..<1_000 {
            live.text += "字"
            let page = cache.page(session: session, revision: 1, history: history, partial: live,
                                  pendingSteering: [], limit: 400)
            #expect(page.messages.count == 400)
            #expect(page.messages.last?.text == live.text)
            #expect(page.hiddenCount == 4_601)
        }
        #expect(cache.rebuilds == 1)
        let finished = cache.page(session: session, revision: 2, history: history + [live], partial: nil,
                                  pendingSteering: [], limit: 400)
        #expect(finished.messages.last == live)
        #expect(cache.rebuilds == 2)
    }

    @Test func pageSelectionAndSteeringChangesInvalidateTheProjection() {
        let history = (0..<8).map { AgentTranscriptMessage(role: .user, text: "message \($0)") }
        let session = UUID()
        let live = AgentTranscriptMessage(role: .assistant, text: "live")
        var cache = TranscriptWindowCache()
        let first = cache.page(session: session, revision: 1, history: history, partial: live, pendingSteering: [], limit: 2)
        #expect(first.messages.map(\.id) == [history[7].id, live.id])
        let pending = cache.page(session: session, revision: 1, history: history, partial: live,
                                 pendingSteering: [history[5].id], limit: 2)
        #expect(pending.messages.map(\.id) == [history[6].id, history[7].id])
        let expanded = cache.page(session: session, revision: 1, history: history, partial: live,
                                  pendingSteering: [history[5].id], limit: 5)
        #expect(expanded.messages.map(\.id) == [history[4].id, live.id, history[5].id, history[6].id, history[7].id])
        #expect(cache.rebuilds == 3)
    }

    @Test func cachedToolTimelineAndLiveReasoningMatchTheOrderedProjection() {
        let call = AgentTranscriptMessage(role: .assistant, toolCalls: [
            AgentToolCall(id: "read", name: "observe_screen", arguments: .object([:]))
        ])
        let history = [AgentTranscriptMessage(role: .user, text: "check"), call,
                       AgentTranscriptMessage(role: .tool, text: "screen", toolCallID: "read")]
        var live = AgentTranscriptMessage(role: .assistant, text: "")
        var cache = TranscriptWindowCache()
        let session = UUID()
        for index in 0..<20 {
            live.text += "字"
            live.reasoning = [.init(text: "reasoning \(index)")]
            let page = cache.page(session: session, revision: 1, history: history, partial: live,
                                  pendingSteering: [], limit: 400)
            #expect(page.items == TranscriptItem.build(page.messages))
        }
        #expect(cache.rebuilds == 1)
        live.toolCalls = [AgentToolCall(id: "later", name: "read", arguments: .object([:]))]
        let withCall = cache.page(session: session, revision: 1, history: history, partial: live,
                                  pendingSteering: [], limit: 400)
        #expect(withCall.items == TranscriptItem.build(withCall.messages))
    }
}
