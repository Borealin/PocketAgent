import Foundation

nonisolated enum PhoneBackendKind: String, CaseIterable, Codable, Sendable {
    case ddi, wda
    static let defaultBackend = PhoneBackendKind.ddi
    var label: String { self == .ddi ? "DDI" : "WDA" }
}

nonisolated enum DDIResultError: LocalizedError, Equatable {
    case outsideCount
    var errorDescription: String? { "DDI 观察结果格式无效：缺少有效的应用外元素计数。" }
}

/// Normalize only device-reported AX semantics. AX role codes differ from
/// XCTest enums; unknown roles retain Other, and absent states stay absent.
nonisolated enum DDINodeMapping {
    static func attributes(_ raw: [String: Any]) throws -> [String: String]? {
        guard let r = raw["21"] as? [String: Any], let x = r["x"] as? Double, let y = r["y"] as? Double,
              let w = r["width"] as? Double, let h = r["height"] as? Double,
              [x,y,w,h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
        let role = (raw["45"] as? NSNumber)?.intValue
        if role == 1 { return nil }
        let subrole = (raw["51"] as? NSNumber)?.intValue
        let traits = (raw["77"] as? NSNumber)?.uint64Value ?? 0
        let type: String
        switch role {
        case 2: type = "Button"
        case 3: type = subrole == 3 ? "Switch" : "Other"
        case 6,14: type = "StaticText"
        case 15: type = subrole == 5 ? "SecureTextField" : subrole == 1 ? "SearchField" : "TextField"
        case 17 where traits & ((1 << 18) | (1 << 47)) == ((1 << 18) | (1 << 47)): type = "TextView"
        default: type = "Other"
        }
        var a = ["type": "XCUIElementType" + type, "x": String(x), "y": String(y), "width": String(w), "height": String(h)]
        for (key,name) in [("3","label"),("25","name"),("42","placeholder"),("53","value"),("identity","ddi_identity")] {
            if let s = raw[key] as? String { a[name] = s }
        }
        // Description is the device's semantic text; retain its provenance.
        if a["label"] == nil, let description = raw["33"] as? String { a["label"] = description; a["ddi_text_source"] = "description" }
        for (key,name) in [("27","enabled"),("28","focused"),("32","visible")] {
            if let n = raw[key] as? NSNumber, n == 0 || n == 1 { a[name] = n.boolValue ? "true" : "false" }
        }
        // The tested focused editable UITextView may omit all text attributes.
        // Preserve that shape without asserting it is empty. A pending paste
        // can defer confirmation to the exact final value; clear-only cannot.
        if type == "TextView", raw["53"] == nil, a["focused"] == "true", a["enabled"] == "true",
           (a["label"] ?? "").isEmpty, raw["33"] == nil || (raw["33"] as? String)?.isEmpty == true {
            a["ddi_textview_value_omitted"] = "true"
        }
        if type == "SecureTextField" { a["ddi_value"] = a.removeValue(forKey: "value") }
        if a["visible"] == "false" { return nil }
        return a
    }

    /// Elements on screen hosted by another process that the observation did
    /// not read (native limit 32). Every DDI snapshot reports it; a missing,
    /// boolean, fractional, non-finite or out-of-range count is a malformed
    /// observation, never guessed.
    static let outsideLimit = 32
    static func outsideAppElements(_ result: [String: Any]) throws -> Int {
        guard let number = result["outside_app_elements"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw DDIResultError.outsideCount
        }
        let value = number.doubleValue
        guard value.isFinite, value == value.rounded(), (0...Double(outsideLimit)).contains(value) else {
            throw DDIResultError.outsideCount
        }
        return Int(value)
    }

    static func confirmsInput(_ node: [String: String], text: String) -> Bool {
        if node["value"] == text { return true }
        guard text.isEmpty else { return false }
        guard let value = node["value"], let placeholder = node["placeholder"] else { return false }
        return value == placeholder
    }
}
