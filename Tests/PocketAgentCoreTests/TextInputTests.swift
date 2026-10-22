import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

struct TextInputTests {
    private func arguments(text: String = "hello", clear: Bool = true, method: String? = nil) -> [String: AgentJSONValue] {
        var values: [String: AgentJSONValue] = ["text": .string(text), "clear": .bool(clear)]
        if let method { values["method"] = .string(method) }
        return values
    }

    @Test func omittedMethodPreservesPasteAndExplicitPasteRespectsFrozenClipboardPolicy() throws {
        let legacy = try TextInputRequest(arguments: arguments(), backend: .ddi, clipboardAllowed: true)
        #expect(legacy.method == .paste)
        #expect(legacy.clear)

        #expect(throws: TextInputRequest.Issue.pasteClipboardDenied) {
            try TextInputRequest(arguments: arguments(), backend: .ddi, clipboardAllowed: false)
        }
        let explicit = try TextInputRequest(arguments: arguments(method: "paste"), backend: .wda, clipboardAllowed: false)
        #expect(explicit.method == .paste)
    }

    @Test func explicitMethodsKeepTheirRoutesAndNonStringMethodsFail() throws {
        #expect(throws: TextInputRequest.Issue.pasteClipboardDenied) {
            try TextInputRequest(arguments: arguments(method: "paste"), backend: .ddi, clipboardAllowed: false)
        }
        #expect(try TextInputRequest(arguments: arguments(method: "paste"), backend: .ddi, clipboardAllowed: true).method == .paste)
        #expect(try TextInputRequest(arguments: arguments(method: "ax"), backend: .ddi, clipboardAllowed: false).method == .ax)
        #expect(throws: TextInputRequest.Issue.axRequiresDDI) {
            try TextInputRequest(arguments: arguments(method: "ax"), backend: .wda, clipboardAllowed: true)
        }
        for invalid: AgentJSONValue in [.bool(true), .string(""), .string("PASTE"), .array([]), .object([:])] {
            var values = arguments()
            values["method"] = invalid
            #expect(throws: TextInputRequest.Issue.invalidMethod) {
                try TextInputRequest(arguments: values, backend: .ddi, clipboardAllowed: true)
            }
        }
    }

    @Test func axRequiresDDIAndWholeFieldReplacementWithinByteLimit() throws {
        let ax = try TextInputRequest(arguments: arguments(text: "天气", method: "ax"), backend: .ddi, clipboardAllowed: false)
        #expect(ax.method == .ax)
        #expect(throws: TextInputRequest.Issue.axRequiresDDI) {
            try TextInputRequest(arguments: arguments(method: "ax"), backend: .wda, clipboardAllowed: true)
        }
        #expect(throws: TextInputRequest.Issue.axRequiresReplacement) {
            try TextInputRequest(arguments: arguments(text: "", method: "ax"), backend: .ddi, clipboardAllowed: false)
        }
        #expect(throws: TextInputRequest.Issue.axRequiresReplacement) {
            try TextInputRequest(arguments: arguments(clear: false, method: "ax"), backend: .ddi, clipboardAllowed: false)
        }
        #expect(throws: TextInputRequest.Issue.axTextTooLong) {
            let oversized = String(repeating: "a" + String(repeating: "\u{301}", count: 8), count: 1_000)
            #expect(oversized.count <= 4_000)
            #expect(oversized.utf8.count > 16_000)
            try TextInputRequest(arguments: arguments(text: oversized, method: "ax"), backend: .ddi, clipboardAllowed: false)
        }
        #expect(throws: TextInputRequest.Issue.invalidText) {
            try TextInputRequest(arguments: arguments(text: String(repeating: "x", count: 4_001), method: "ax"), backend: .ddi, clipboardAllowed: false)
        }
    }

    @Test func axOnlyAcceptsOrdinaryTextAndSearchFields() throws {
        let request = try TextInputRequest(arguments: arguments(method: "ax"), backend: .ddi, clipboardAllowed: false)
        try request.validateTarget(["type": "XCUIElementTypeTextField"])
        try request.validateTarget(["type": "XCUIElementTypeSearchField"])
        for type in ["XCUIElementTypeSecureTextField", "XCUIElementTypeTextView", "XCUIElementTypeButton", ""] {
            #expect(throws: TextInputRequest.Issue.axTargetUnsupported) {
                try request.validateTarget(["type": type])
            }
        }
    }

    @Test func axConfirmationRequiresExactNonemptyValueOnAnOrdinaryField() {
        #expect(TextInputRequest.confirmsAXInput(["type": "XCUIElementTypeTextField", "value": "hello"], text: "hello"))
        #expect(TextInputRequest.confirmsAXInput(["type": "XCUIElementTypeSearchField", "value": "hello"], text: "hello"))
        #expect(!TextInputRequest.confirmsAXInput(["type": "XCUIElementTypeTextField", "value": ""], text: ""))
        #expect(!TextInputRequest.confirmsAXInput(["type": "XCUIElementTypeTextField"], text: "hello"))
        #expect(!TextInputRequest.confirmsAXInput(["type": "XCUIElementTypeTextField", "value": "query", "placeholder": "query"], text: "query"))
        for type in ["XCUIElementTypeSecureTextField", "XCUIElementTypeTextView", "XCUIElementTypeButton"] {
            #expect(!TextInputRequest.confirmsAXInput(["type": type, "value": "hello"], text: "hello"))
        }
    }

    @Test func invalidMethodAndArgumentsAreTypedIssues() {
        #expect(throws: TextInputRequest.Issue.invalidMethod) {
            try TextInputRequest(arguments: arguments(method: "fallback"), backend: .ddi, clipboardAllowed: true)
        }
        #expect(throws: TextInputRequest.Issue.invalidClear) {
            try TextInputRequest(arguments: ["text": .string("hi"), "clear": .string("true")], backend: .ddi, clipboardAllowed: true)
        }
        for invalid: AgentJSONValue in [.bool(true), .number(1), .string(""), .string("PASTE"), .array([]), .object([:])] {
            var values = arguments()
            values["method"] = invalid
            #expect(throws: TextInputRequest.Issue.invalidMethod) {
                try TextInputRequest(arguments: values, backend: .ddi, clipboardAllowed: true)
            }
        }
    }

    /// Review finding R4: `method: null` is exactly an omitted method on every
    /// backend and clipboard policy, the default paste route included.
    @Test func nullMethodBehavesExactlyLikeOmittedMethod() throws {
        var null = arguments()
        null["method"] = .null
        for backend in PhoneBackendKind.allCases {
            for clipboardAllowed in [true, false] {
                func make(_ values: [String: AgentJSONValue]) -> Result<TextInputRequest, any Error> {
                    Result { try TextInputRequest(arguments: values, backend: backend, clipboardAllowed: clipboardAllowed) }
                }
                switch (make(arguments()), make(null)) {
                case let (.success(omitted), .success(explicit)):
                    #expect(omitted.method == .paste && explicit.method == .paste)
                    #expect(omitted.text == explicit.text && omitted.clear == explicit.clear)
                case let (.failure(omitted), .failure(explicit)):
                    #expect(omitted as? TextInputRequest.Issue == explicit as? TextInputRequest.Issue)
                default:
                    Issue.record("null and omitted method diverged for \(backend), clipboard \(clipboardAllowed)")
                }
            }
        }
        // Frozen clipboard denial still governs default paste on DDI; WDA's
        // paste route is unchanged.
        #expect(throws: TextInputRequest.Issue.pasteClipboardDenied) {
            try TextInputRequest(arguments: null, backend: .ddi, clipboardAllowed: false)
        }
        #expect(try TextInputRequest(arguments: null, backend: .wda, clipboardAllowed: false).method == .paste)
        #expect(try TextInputRequest(arguments: null, backend: .ddi, clipboardAllowed: true).method == .paste)
    }

    /// The same through the pinned AgentKit: its OpenAI strict wire schema
    /// makes `method` required and nullable; its validator, run by the
    /// runtime before every tool, accepts null as omission and passes it on
    /// unchanged; the host then parses exactly what the tool receives.
    /// Invalid types never reach the host.
    @Test func aStrictProvidersNullMethodReachesTheHostAsDefaultPaste() async throws {
        let descriptor = try #require(ToolCatalog.phoneTools.first { $0.name == "type_text" }).descriptor
        let strict = try #require(AgentProviderClient.openAIStrictSchema(descriptor.inputSchema).objectValue)
        #expect(strict["required"]?.arrayValue?.contains(.string("method")) == true)
        #expect(strict["properties"]?.objectValue?["method"]?.objectValue?["type"] == .array([.string("string"), .string("null")]))
        #expect(descriptor.inputSchema.objectValue?["required"]?.arrayValue?.contains(.string("method")) == false)

        func run(_ method: String, clipboardAllowed: Bool) async throws -> (executed: Bool, result: AgentToolResult?) {
            let executed = CallCounter()
            let tool = AnyAgentTool(descriptor: descriptor) { invocation, _ in
                executed.increment()
                let content: String
                do {
                    let request = try TextInputRequest(arguments: invocation.call.arguments.objectValue ?? [:], backend: .ddi,
                                                       clipboardAllowed: clipboardAllowed)
                    content = "method=" + request.method.rawValue
                } catch let issue as TextInputRequest.Issue { content = "issue=" + issue.code }
                return AgentToolResult(callID: invocation.call.id, content: content)
            }
            let model = ScriptedModel(turns: [
                [.toolCallSnapshot(id: "c1", providerItemID: nil, name: "type_text",
                                   arguments: #"{"node":1,"text":"你好","clear":true,"snapshot_id":3,"method":\#(method)}"#),
                 .finished(.toolCalls)],
                [.textDelta("完成"), .finished(.completed)],
            ])
            var loop = AgentLoopConfiguration()
            loop.toolExecution = .sequential; loop.maximumToolConcurrency = 1; loop.modelRetryPolicy = .disabled
            let runtime = AgentRuntime(model: model, tools: [tool], approval: CommitGatedApprovalFree(), configuration: loop)
            var result: AgentToolResult?
            for await event in await runtime.start(AgentRunRequest(conversationID: UUID(), promptID: UUID(), prompt: "输入",
                                                                    permissionMode: .fullAccess, systemPrompt: "s", priorMessages: [])) {
                if case .toolFinished(_, let finished) = event { result = finished }
            }
            return (executed.count == 1, result)
        }
        let allowed = try await run("null", clipboardAllowed: true)
        #expect(allowed.executed && allowed.result?.content == "method=paste" && allowed.result?.isError == false)
        let denied = try await run("null", clipboardAllowed: false)
        #expect(denied.executed && denied.result?.content == "issue=pasteClipboardDenied")
        let ax = try await run(#""ax""#, clipboardAllowed: false)
        #expect(ax.executed && ax.result?.content == "method=ax")
        for invalid in ["7", "true", #""PASTE""#, "[]"] {
            let outcome = try await run(invalid, clipboardAllowed: true)
            #expect(!outcome.executed && outcome.result?.isError == true, "\(invalid)")
        }
    }
}

/// Allows every call, as the app's approval does for permitted tools.
private struct CommitGatedApprovalFree: AgentApprovalHandling {
    func authorize(_ request: AgentApprovalRequest, mode: AgentPermissionMode) async -> AgentApprovalDecision { .allow }
}
