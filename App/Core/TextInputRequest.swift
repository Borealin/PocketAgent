import AgentKit
import Foundation

nonisolated enum TextInputMethod: String, Sendable {
    case paste
    case ax
}

/// Validated input request shared by model calls and script phone calls.
nonisolated struct TextInputRequest: Sendable {
    enum Issue: String, Error, LocalizedError, Sendable {
        case invalidMethod
        case invalidText
        case invalidClear
        case axRequiresDDI
        case axRequiresReplacement
        case axTextTooLong
        case pasteClipboardDenied
        case axTargetUnsupported

        var code: String { rawValue }

        var errorDescription: String? {
            switch self {
            case .invalidMethod: "method 必须是 paste 或 ax。"
            case .invalidText: "请提供不超过 4000 字的 text。"
            case .invalidClear: "clear 必须是布尔值。"
            case .axRequiresDDI: "method=ax 当前只支持 DDI。"
            case .axRequiresReplacement: "method=ax 只支持非空且 clear=true 的整字段替换。"
            case .axTextTooLong: "method=ax 的 UTF-8 文本不能超过 16000 字节。"
            case .pasteClipboardDenied: "本轮禁止使用剪贴板，默认 paste 输入未执行。"
            case .axTargetUnsupported: "method=ax 只支持普通 TextField 或 SearchField；未执行输入。"
            }
        }
    }

    let method: TextInputMethod
    let text: String
    let clear: Bool

    init(arguments: [String: AgentJSONValue], backend: PhoneBackendKind, clipboardAllowed: Bool) throws {
        guard let text = arguments["text"]?.stringValue, text.count <= 4000 else { throw Issue.invalidText }
        guard let clear = arguments["clear"]?.boolValue else { throw Issue.invalidClear }
        let method: TextInputMethod
        if let rawMethod = arguments["method"]?.stringValue {
            guard let parsed = TextInputMethod(rawValue: rawMethod) else { throw Issue.invalidMethod }
            method = parsed
        } else if arguments["method"] == nil || arguments["method"] == .null {
            // A strict provider schema makes the optional field required and
            // nullable; the pinned AgentKit validator accepts null as omission
            // and passes it through, so null selects the same default paste.
            method = .paste
        } else {
            throw Issue.invalidMethod
        }

        switch method {
        case .paste:
            if backend == .ddi && !clipboardAllowed { throw Issue.pasteClipboardDenied }
        case .ax:
            guard backend == .ddi else { throw Issue.axRequiresDDI }
            guard !text.isEmpty, clear else { throw Issue.axRequiresReplacement }
            guard text.utf8.count <= 16_000 else { throw Issue.axTextTooLong }
        }
        self.method = method
        self.text = text
        self.clear = clear
    }

    /// Whether preparing this input writes the device clipboard, an effect:
    /// only nonempty paste text. Empty text prepares nothing on the device.
    var preparationWritesClipboard: Bool { method == .paste && !text.isEmpty }

    func validateTarget(_ attributes: [String: String]) throws {
        guard method == .ax else { return }
        guard ["XCUIElementTypeTextField", "XCUIElementTypeSearchField"].contains(attributes["type"] ?? "") else {
            throw Issue.axTargetUnsupported
        }
    }

    static func confirmsAXInput(_ attributes: [String: String], text: String) -> Bool {
        guard !text.isEmpty,
              ["XCUIElementTypeTextField", "XCUIElementTypeSearchField"].contains(attributes["type"] ?? ""),
              let value = attributes["value"], value == text else { return false }
        if let placeholder = attributes["placeholder"], value == placeholder { return false }
        return true
    }
}
