import AgentKit
import Testing
@testable import PocketAgentCore

struct KeyboardInputTests {
    @Test func keyboardPositionsDoNotTreatDigitsAsRawUsages() throws {
        let sequence = try KeyboardSequence(keys: ["a", "b", "c", "1", "9"], modifiers: ["shift"], clipboardAllowed: false)
        #expect(sequence.keys == [4, 5, 6, 30, 38])
        #expect(sequence.modifiers == [225])
        #expect(!sequence.clipboardShortcut)
        #expect(throws: KeyboardSequence.Issue.invalid) {
            try KeyboardSequence(keys: ["你好"], modifiers: [], clipboardAllowed: true)
        }
    }

    @Test func invalidSequenceCannotSubmitAnEarlierValidPrefix() {
        for keys in [[], Array(repeating: "a", count: 33), ["a", "unsupported"]] {
            #expect(throws: KeyboardSequence.Issue.invalid) {
                try KeyboardSequence(keys: keys, modifiers: [], clipboardAllowed: true)
            }
        }
        #expect(throws: KeyboardSequence.Issue.invalid) {
            try KeyboardSequence(keys: ["a"], modifiers: ["command", "command"], clipboardAllowed: true)
        }
        #expect(throws: KeyboardSequence.Issue.invalid) {
            try KeyboardSequence(arguments: ["keys": .array([.string("a"), .number(4)]), "modifiers": .array([])], clipboardAllowed: true)
        }
    }

    @Test func clipboardShortcutsAreDeniedEvenWithAdditionalModifiers() throws {
        for key in ["c", "x", "v"] {
            for modifier in ["command", "control"] {
                #expect(throws: KeyboardSequence.Issue.clipboardDenied) {
                    try KeyboardSequence(keys: ["a", key], modifiers: [modifier, "shift"], clipboardAllowed: false)
                }
            }
        }
        #expect(try KeyboardSequence(keys: ["v"], modifiers: ["command"], clipboardAllowed: true).clipboardShortcut)
        #expect(try KeyboardSequence(keys: ["a"], modifiers: ["command"], clipboardAllowed: false).keys == [4])
        #expect(try KeyboardSequence(keys: ["space"], modifiers: ["control"], clipboardAllowed: false).keys == [44])
    }

    @Test func clipboardPolicyAndBackendApplyToDefinitionsAndScriptRequests() {
        let denied = ToolCapabilities(phoneBackend: .ddi, clipboardAllowed: false)
        #expect(ToolCatalog.available(denied).contains { $0.name == "type_text" })
        #expect(ToolCatalog.available(denied).contains { $0.name == "press_keys" })
        #expect(ToolCatalog.decision(for: "type_text", capabilities: denied) == .allow)
        #expect(ToolCatalog.scriptDecision(for: "type_text", capabilities: denied) == .allow)
        #expect(ToolCatalog.scriptDecision(for: "press_keys", capabilities: denied) == .allow)
        let wda = ToolCapabilities(phoneBackend: .wda, clipboardAllowed: false)
        #expect(ToolCatalog.decision(for: "type_text", capabilities: wda) == .allow)
        #expect(ToolCatalog.decision(for: "press_keys", capabilities: wda) != .allow)
        #expect(ToolCatalog.scriptDecision(for: "press_keys", capabilities: wda) != .allow)
        #expect(ToolCatalog.spec("type_text")?.required.sorted() == ["clear", "node", "snapshot_id", "text"])
        #expect(ToolCatalog.spec("type_text")?.properties["method"] != nil)
        #expect(ToolCatalog.prompt(denied, workspaceName: nil).contains("method=ax"))
    }
}
