import Foundation

/// Anonymous evidence only. This report never selects or authorizes a display,
/// App, pane or input route. Native code retains the actual display identity.
nonisolated struct DDIControlSurface: Codable, Equatable, Sendable {
    let state: String
    let reason: String
    let displayCount: Int
    let activeDisplayCount: Int
    let deviceOrientation: String?
    let rotation: String?
    let activeDisplayIsPrimary: Bool?
    let touchscreenAssociation: String?

    enum CodingKeys: String, CodingKey {
        case state, reason, rotation
        case touchscreenAssociation = "touchscreen_association"
        case displayCount = "display_count", activeDisplayCount = "active_display_count"
        case deviceOrientation = "device_orientation", activeDisplayIsPrimary = "active_display_is_primary"
    }

    static func decode(_ value: Any?) throws -> Self? {
        guard let value else { return nil }
        guard value is [String: Any] else { throw DDIOperationFailure.DecodeIssue.malformed }
        let data = try JSONSerialization.data(withJSONObject: value)
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard ["single_display_portrait", "unavailable"].contains(result.state),
              (0...8).contains(result.displayCount), (0...result.displayCount).contains(result.activeDisplayCount) else {
            throw DDIOperationFailure.DecodeIssue.malformed
        }
        return result
    }

    var dictionary: [String: Any] {
        var value: [String: Any] = ["state": state, "reason": reason,
            "display_count": displayCount, "active_display_count": activeDisplayCount]
        if let deviceOrientation { value["device_orientation"] = deviceOrientation }
        if let rotation { value["rotation"] = rotation }
        if let touchscreenAssociation { value["touchscreen_association"] = touchscreenAssociation }
        if let activeDisplayIsPrimary { value["active_display_is_primary"] = activeDisplayIsPrimary }
        return value
    }
}
