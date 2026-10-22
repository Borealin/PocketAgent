import AgentKit
import Testing
@testable import PocketAgentCore

struct ProviderToolSchemaTests {
    @Test func geminiWireDropsUnsupportedKeywordsWithoutWeakeningLocalPolicy() throws {
        let capabilities = ToolCapabilities(phoneBackend: .ddi, clipboardAllowed: false)
        let tools = ToolCatalog.available(capabilities).map(\.descriptor)
        let original = AgentModelRequest(systemPrompt: "test", messages: [], tools: tools)
        let wire = ProviderToolSchema.prepare(original, format: .generateContent)
        let keys = try #require(wire.tools.first { $0.name == "press_keys" })
        #expect(keys.inputSchema.objectValue?["additionalProperties"] == nil)
        let modifiers = keys.inputSchema.objectValue?["properties"]?.objectValue?["modifiers"]?.objectValue
        #expect(modifiers?["uniqueItems"] == nil)
        #expect(modifiers?["maxItems"] == .number(4))
        let local = try #require(original.tools.first { $0.name == "press_keys" })
        #expect(local.inputSchema.objectValue?["additionalProperties"] == .bool(false))
        #expect(local.inputSchema.objectValue?["properties"]?.objectValue?["modifiers"]?.objectValue?["uniqueItems"] == .bool(true))
        #expect(throws: KeyboardSequence.Issue.invalid) {
            try KeyboardSequence(keys: ["a"], modifiers: ["shift", "shift"], clipboardAllowed: false)
        }
        #expect(wire.tools.map(\.name) == original.tools.map(\.name))
    }

    @Test func otherProviderSchemasAreKeptVerbatim() {
        let request = AgentModelRequest(systemPrompt: "test", messages: [], tools: ToolCatalog.phoneTools.map(\.descriptor))
        for format in [ModelAPIFormat.chatCompletions, .responses, .messages] {
            #expect(ProviderToolSchema.prepare(request, format: format).tools == request.tools)
        }
    }

    @Test func schemaKeywordNamesRemainValidParameterNames() throws {
        let schema: AgentJSONValue = .object(["type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object(["additionalProperties": .object(["type": .string("string")]),
                "nested": .object(["type": .string("array"), "uniqueItems": .bool(true),
                    "items": .object(["type": .string("object"), "additionalProperties": .bool(false)])])])])
        let descriptor = AgentToolDescriptor(name: "test", summary: "test", inputSchema: schema, target: .local, approvalPolicy: .approve)
        let request = AgentModelRequest(systemPrompt: "test", messages: [], tools: [descriptor])
        let result = ProviderToolSchema.prepare(request, format: .generateContent).tools[0].inputSchema
        let properties = try #require(result.objectValue?["properties"]?.objectValue)
        #expect(properties["additionalProperties"] != nil)
        let nested = try #require(properties["nested"]?.objectValue)
        #expect(nested["uniqueItems"] == nil)
        #expect(nested["items"]?.objectValue?["additionalProperties"] == nil)
    }
}
