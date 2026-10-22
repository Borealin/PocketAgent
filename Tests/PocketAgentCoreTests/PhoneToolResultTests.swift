import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

struct PhoneToolResultTests {
    private func observation(label: String, sourceTruncated: Bool = false, unconfirmed: Bool = false) throws -> String {
        let nodes: [[String: Any]] = (1...180).map { node in
            ["node": node, "type": "Button", "label": label, "enabled": true,
             "rect": ["x": 0, "y": 0, "width": 40, "height": 20]]
        }
        let screen: [String: Any] = ["snapshot_id": 37, "app": "example.app",
            "screen": ["width": 390, "height": 844], "elements": nodes, "truncated": sourceTruncated]
        var envelope: [String: Any] = ["ok": !unconfirmed, "screen": screen]
        if unconfirmed {
            envelope.merge(["code": "ddi_input_release_unconfirmed", "action_issued": true,
                "action_outcome": "unconfirmed", "replay_allowed": false,
                "input_method": "ax", "input_verified": false, "recovery": "fresh_observation"]) { _, new in new }
        }
        return try PhoneToolResult.encode(envelope, isError: unconfirmed).content
    }

    @Test(arguments: ["short", "long", "escape", "unconfirmed"])
    func textOnlyModelReceivesBoundedActionableObservation(kind: String) async throws {
        let label = kind == "short" ? "row" : kind == "long" ? String(repeating: "长内容", count: 650)
            : String(repeating: "\u{1}", count: 2000)
        let content = try observation(label: label, unconfirmed: kind == "unconfirmed")
        let model = ScriptedModel(turns: [[
            .toolCallSnapshot(id: "observe", providerItemID: nil, name: "observe_screen", arguments: "{}"),
            .finished(.toolCalls),
        ], [.textDelta("done"), .finished(.completed)]])
        let tool = AnyAgentTool(descriptor: ToolCatalog.spec("observe_screen")!.descriptor) { invocation, _ in
            try PhoneToolResult.make(callID: invocation.call.id, content: content, isError: kind == "unconfirmed")
        }
        let runtime = AgentRuntime(model: model, tools: [tool], approval: AllowEverything(),
                                   configuration: AgentInstructions.loopConfiguration())
        var rawRetained = false
        for await event in await runtime.start(AgentRunRequest(conversationID: UUID(), prompt: "read", permissionMode: .fullAccess)) {
            if case .toolFinished(_, let result) = event { rawRetained = result.content == content }
        }
        let request = try #require(model.requests.dropFirst().first)
        #expect(request.messages.allSatisfy { $0.images.isEmpty })
        #expect(!request.tools.contains { $0.name == "scratch_read" })
        let result = try #require(request.messages.first { $0.toolCallID == "observe" })
        #expect(rawRetained) // complete event content stays available to the host's history writer
        let projected = try #require(result.modelText)
        #expect(projected.utf8.count <= PhoneToolResult.maximumModelBytes)
        let envelope = try #require(AgentToolResult.decodeStructuredPayload(projected)?.objectValue)
        let object = try #require(envelope["screen"]?.objectValue)
        #expect(envelope["ok"] == .bool(kind != "unconfirmed"))
        if kind == "unconfirmed" {
            #expect(result.isError)
            #expect(envelope["action_issued"] == .bool(true))
            #expect(envelope["action_outcome"] == .string("unconfirmed"))
            #expect(envelope["replay_allowed"] == .bool(false))
            #expect(envelope["input_method"] == .string("ax"))
            #expect(envelope["input_verified"] == .bool(false))
            #expect(envelope["recovery"] == .string("fresh_observation"))
        }
        #expect(object["snapshot_id"] == .number(37))
        #expect(object["app"] == .string("example.app"))
        #expect(object["screen"]?.objectValue?["width"] == .number(390))
        let kept = try #require(object["elements"]?.arrayValue)
        #expect(!kept.isEmpty)
        #expect(kept.enumerated().allSatisfy { $0.element.objectValue?["node"] == .number(Double($0.offset + 1)) })
        #expect(object["truncated"] == .bool(kept.count < 180))
        if kind == "short" { #expect(kept.count == 180) }
        else { #expect(kept.count < 180) }
    }

    @Test func projectionRedactsAndRetainsSourceTruncation() throws {
        var object = try #require(try AgentJSONValue.decode(Data(observation(label: "row", sourceTruncated: true).utf8)).objectValue)
        object["authorization"] = .string("private-test-value")
        let content = AgentJSONValue.object(object).encodedString
        let result = try PhoneToolResult.make(callID: "c", content: content, isError: false)
        let projected = try #require(result.modelContent)
        #expect(result.content == content && !result.isError)
        #expect(!projected.contains("private-test-value"))
        let envelope = try #require(try AgentJSONValue.decode(Data(projected.utf8)).objectValue)
        let fields = try #require(envelope["screen"]?.objectValue)
        #expect(fields["truncated"] == .bool(true))
        #expect(fields["snapshot_id"] == .number(37))
    }

    @Test func oversizedObservationMetadataFailsInsteadOfPublishingAnUnboundedProjection() throws {
        var fields = try #require(try AgentJSONValue.decode(Data(observation(label: "row").utf8)).objectValue)
        var screen = try #require(fields["screen"]?.objectValue)
        screen["app"] = .string(String(repeating: "x", count: PhoneToolResult.maximumModelBytes + 1))
        fields["screen"] = .object(screen)
        #expect(throws: (any Error).self) {
            try PhoneToolResult.make(callID: "c", content: AgentJSONValue.object(fields).encodedString, isError: false)
        }
    }

    @Test func nonObservationErrorsKeepTheExistingSDKProjectionPath() throws {
        let result = try PhoneToolResult.make(callID: "c", content: #"{"error":"not available"}"#, isError: true)
        #expect(result.isError && result.modelContent == nil)
        #expect(result.content == #"{"error":"not available"}"#)
    }

    @Test func oversizedFailureExplanationRetainsTheActionOutcomeAndNoReplayContract() throws {
        var envelope = try #require(try AgentJSONValue.decode(Data(observation(label: "row", unconfirmed: true).utf8)).objectValue)
        envelope["message"] = .string(String(repeating: "详情", count: PhoneToolResult.maximumModelBytes))
        let content = AgentJSONValue.object(envelope).encodedString
        let result = try PhoneToolResult.make(callID: "c", content: content, isError: true)
        let projected = try #require(result.modelContent)
        #expect(projected.utf8.count <= PhoneToolResult.maximumModelBytes)
        let fields = try #require(try AgentJSONValue.decode(Data(projected.utf8)).objectValue)
        #expect(result.isError && result.content == content)
        #expect(fields["action_issued"] == .bool(true))
        #expect(fields["action_outcome"] == .string("unconfirmed"))
        #expect(fields["replay_allowed"] == .bool(false))
        #expect(fields["screen"]?.objectValue?["snapshot_id"] == .number(37))
        #expect(fields["projection_shortened_fields"] == .array([.string("message")]))
    }
}
