import AgentKit
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
    }
}
