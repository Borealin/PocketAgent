import AgentKit
import Foundation

/// Physical US-key positions, not Unicode text or an inferred input method.
nonisolated struct KeyboardSequence: Sendable {
    static let maximumKeys = 32
    static let keyUsages: [String: UInt16] = {
        var keys: [String: UInt16] = [:]
        for (index, letter) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            keys[String(letter)] = UInt16(4 + index)
        }
        for (index, digit) in "1234567890".enumerated() {
            keys[String(digit)] = UInt16(30 + index)
        }
        let other: [String: UInt16] = ["return": 40, "escape": 41, "delete": 42,
            "tab": 43, "space": 44, "-": 45, "=": 46, "[": 47, "]": 48,
            "\\": 49, ";": 51, "'": 52, "`": 53, ",": 54, ".": 55, "/": 56,
            "home": 74, "page_up": 75, "end": 77, "page_down": 78,
            "right": 79, "left": 80, "down": 81, "up": 82]
        keys.merge(other) { _, new in new }
        return keys
    }()
    static let modifierUsages: [String: UInt16] = ["control": 224, "shift": 225, "option": 226, "command": 227]
    let keys: [UInt16]
    let modifiers: [UInt16]
    let clipboardShortcut: Bool
    let clipboardAllowed: Bool

    enum Issue: String, Error, LocalizedError {
        case invalid, clipboardDenied
        var errorDescription: String? {
            switch self {
            case .invalid: "请提供 1–32 个列出的硬件键名和不重复的修饰键；不能把 Unicode 文本当成键名。"
            case .clipboardDenied: "本轮禁止使用剪贴板，复制、剪切和粘贴组合键未执行。"
            }
        }
    }

    init(keys names: [String], modifiers modifierNames: [String], clipboardAllowed: Bool) throws {
        guard (1...Self.maximumKeys).contains(names.count), modifierNames.count <= 4,
              Set(modifierNames).count == modifierNames.count else { throw Issue.invalid }
        let keys = names.compactMap { Self.keyUsages[$0] }
        let modifiers = modifierNames.compactMap { Self.modifierUsages[$0] }
        guard keys.count == names.count, modifiers.count == modifierNames.count else { throw Issue.invalid }
        let clipboardShortcut = !Set(modifierNames).isDisjoint(with: ["command", "control"])
            && !Set(names).isDisjoint(with: ["c", "x", "v"])
        guard clipboardAllowed || !clipboardShortcut else { throw Issue.clipboardDenied }
        self.keys = keys; self.modifiers = modifiers.sorted(); self.clipboardShortcut = clipboardShortcut
        self.clipboardAllowed = clipboardAllowed
    }

    init(arguments: [String: AgentJSONValue], clipboardAllowed: Bool) throws {
        guard case .array(let rawKeys)? = arguments["keys"], case .array(let rawModifiers)? = arguments["modifiers"] else {
            throw Issue.invalid
        }
        let keys = rawKeys.compactMap(\.stringValue), modifiers = rawModifiers.compactMap(\.stringValue)
        guard keys.count == rawKeys.count, modifiers.count == rawModifiers.count else { throw Issue.invalid }
        try self.init(keys: keys, modifiers: modifiers, clipboardAllowed: clipboardAllowed)
    }
}
