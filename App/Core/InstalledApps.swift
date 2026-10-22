import Foundation

/// A device-reported app. Names are optional: never invent one from a bundle ID.
nonisolated struct InstalledApp: Codable, Hashable, Sendable {
    let bundleID: String
    let names: [String]
    var name: String? { names.first }
}

nonisolated enum InstalledApps {
    static func isLaunchable(packageType: String?, path: String?, hasExtensionDefinition: Bool,
                             tags: [String] = [], isDemoted: Bool = false) -> Bool {
        guard packageType == "APPL", !hasExtensionDefinition, !isDemoted,
              !tags.contains("hidden") else { return false }
        if let path, path.lowercased().hasSuffix(".appex") { return false }
        return true
    }

    /// Installation Proxy supplies localized names for both user and system
    /// apps. Hidden system hosts (including CarPlay Settings) are not phone
    /// launch targets, even when their display name matches a visible app.
    static func fromMetadata(_ entries: [[String: Any]]) -> [InstalledApp] {
        var records: [String: InstalledApp] = [:]
        for entry in entries {
            guard let identifier = entry["CFBundleIdentifier"] as? String, !identifier.isEmpty,
                  isLaunchable(packageType: entry["CFBundlePackageType"] as? String,
                               path: (entry["Path"] as? String) ?? (entry["BundlePath"] as? String),
                               hasExtensionDefinition: entry["NSExtension"] != nil,
                               tags: entry["SBAppTags"] as? [String] ?? [],
                               isDemoted: entry["IsDemotedApp"] as? Bool ?? false) else { continue }
            var names = records[identifier]?.names ?? []
            for key in ["CFBundleDisplayName", "CFBundleName", "DisplayName", "displayName", "name"] {
                guard let raw = entry[key] as? String else { continue }
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && !names.contains(name) { names.append(name) }
            }
            records[identifier] = InstalledApp(bundleID: identifier, names: names)
        }
        return records.values.sorted { $0.bundleID < $1.bundleID }
    }
    enum Resolution: Equatable {
        case found(InstalledApp), notFound, ambiguous([InstalledApp])
    }

    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func search(_ query: String, in apps: [InstalledApp]) -> [InstalledApp] {
        let query = normalize(query)
        return apps.filter { app in
            query.isEmpty || normalize(app.bundleID).contains(query) || app.names.contains { normalize($0).contains(query) }
        }.sorted {
            let leftExact = $0.names.contains { normalize($0) == query }
            let rightExact = $1.names.contains { normalize($0) == query }
            if leftExact != rightExact { return leftExact }
            return $0.bundleID < $1.bundleID
        }
    }

    /// Open names only on an exact device-reported match. Partial matches are
    /// candidates for the model to inspect, never an implicit launch choice.
    static func resolve(name: String, in apps: [InstalledApp]) -> Resolution {
        let name = normalize(name)
        guard !name.isEmpty else { return .notFound }
        let matches = apps.filter { $0.names.contains { normalize($0) == name } }
        guard matches.count == 1 else { return matches.isEmpty ? .notFound : .ambiguous(matches.sorted { $0.bundleID < $1.bundleID }) }
        return .found(matches[0])
    }
}

/// Read-only recovery can replace a stale screen; it must never replay an action.
nonisolated enum PhoneObservationIssue: Error, LocalizedError {
    case foregroundChanged, staleSnapshot, nodeChanged, geometryChanged
    /// Refused before any touch: the point is not confirmed to belong to the
    /// app of the snapshot observed for it (no current snapshot, another
    /// foreground, or UI of another process at or around the point).
    case targetCovered
    var code: String {
        switch self {
        case .foregroundChanged: "foreground_changed"
        case .staleSnapshot: "stale_snapshot"
        case .nodeChanged: "node_changed"
        case .geometryChanged: "geometry_changed"
        case .targetCovered: "target_covered"
        }
    }
    var errorDescription: String? {
        switch self {
        case .foregroundChanged: "前台 App 已改变。"
        case .staleSnapshot: "屏幕引用已过期。"
        case .nodeChanged: "目标元素已移动、消失或不可用。"
        case .geometryChanged: "屏幕方向或尺寸已变化。"
        case .targetCovered: "目标位置无法确认属于刚观察的 App（可能被其他进程的界面覆盖，如键盘建议栏），未点击。"
        }
    }
}
