import Foundation

nonisolated enum PhoneBackendKind: String, CaseIterable, Sendable {
    case ddi, wda
    static let defaultBackend = PhoneBackendKind.ddi
    var label: String { self == .ddi ? "DDI" : "WDA" }
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
        if type == "SecureTextField" { a["ddi_value"] = a.removeValue(forKey: "value") }
        if a["visible"] == "false" { return nil }
        return a
    }
}
