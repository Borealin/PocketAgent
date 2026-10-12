import Foundation

/// A device-reported app. Names are optional: never invent one from a bundle ID.
nonisolated struct InstalledApp: Codable, Hashable, Sendable {
    let bundleID: String
    let names: [String]
    var name: String? { names.first }
}

nonisolated enum InstalledApps {
    static func isLaunchable(packageType: String?, path: String?, hasExtensionDefinition: Bool) -> Bool {
        guard !hasExtensionDefinition else { return false }
        if let packageType, !packageType.isEmpty, packageType != "APPL" { return false }
        if let path, path.lowercased().hasSuffix(".appex") { return false }
        return true
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
    var code: String {
        switch self {
        case .foregroundChanged: "foreground_changed"
        case .staleSnapshot: "stale_snapshot"
        case .nodeChanged: "node_changed"
        case .geometryChanged: "geometry_changed"
        }
    }
    var errorDescription: String? {
        switch self {
        case .foregroundChanged: "前台 App 已改变。"
        case .staleSnapshot: "屏幕引用已过期。"
        case .nodeChanged: "目标元素已移动、消失或不可用。"
        case .geometryChanged: "屏幕方向或尺寸已变化。"
        }
    }
}
