import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

struct PhoneToolResultTests {
    private func observation(label: String, sourceTruncated: Bool = false) -> String {
        let nodes: [AgentJSONValue] = (1...180).map { node in
            .object(["node": .number(Double(node)), "type": .string("Button"), "label": .string(label),
                     "enabled": .bool(true), "rect": .object(["x": .number(0), "y": .number(0),
                         "width": .number(40), "height": .number(20)])])
        }
        return AgentJSONValue.object([
            "snapshot_id": .number(37), "app": .string("example.app"),
            "screen": .object(["width": .number(390), "height": .number(844)]),
            "elements": .array(nodes), "truncated": .bool(sourceTruncated),
        ]).encodedString
    }

    @Test(arguments: ["short", "long", "escape"])
    func textOnlyModelReceivesBoundedActionableObservation(kind: String) async throws {
        let label = kind == "short" ? "row" : kind == "long" ? String(repeating: "长内容", count: 650)
            : String(repeating: "\u{1}", count: 2000)
        let content = observation(label: label)
        let model = ScriptedModel(turns: [[
            .toolCallSnapshot(id: "observe", providerItemID: nil, name: "observe_screen", arguments: "{}"),
            .finished(.toolCalls),
        ], [.textDelta("done"), .finished(.completed)]])
        let tool = AnyAgentTool(descriptor: ToolCatalog.spec("observe_screen")!.descriptor) { invocation, _ in
            try PhoneToolResult.make(callID: invocation.call.id, content: content, isError: false)
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
        let object = try #require(AgentToolResult.decodeStructuredPayload(projected)?.objectValue)
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
        let fields = try #require(try AgentJSONValue.decode(Data(projected.utf8)).objectValue)
        #expect(fields["truncated"] == .bool(true))
        #expect(fields["snapshot_id"] == .number(37))
    }

    @Test func oversizedObservationMetadataFailsInsteadOfPublishingAnUnboundedProjection() throws {
        var fields = try #require(try AgentJSONValue.decode(Data(observation(label: "row").utf8)).objectValue)
        fields["app"] = .string(String(repeating: "x", count: PhoneToolResult.maximumModelBytes + 1))
        #expect(throws: (any Error).self) {
            try PhoneToolResult.make(callID: "c", content: AgentJSONValue.object(fields).encodedString, isError: false)
        }
    }

    @Test func nonObservationErrorsKeepTheExistingSDKProjectionPath() throws {
        let result = try PhoneToolResult.make(callID: "c", content: #"{"error":"not available"}"#, isError: true)
        #expect(result.isError && result.modelContent == nil)
        #expect(result.content == #"{"error":"not available"}"#)
    }
}
