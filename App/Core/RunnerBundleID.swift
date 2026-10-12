import Foundation

/// Selects only an installed companion, without persisting inferred signing IDs.
nonisolated enum RunnerBundleID {
    static let canonicalAssistantBundleID = "io.github.borealin.PocketAgent"
    static let canonicalRunnerBundleID = "io.github.borealin.PocketAgent.WDA.xctrunner"

    static func resolve(override: String?, embeddedDefaultID: String,
                        assistantBundleID: String, installedIDs: Set<String>) throws -> String {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            guard installedIDs.contains(override) else { throw ResolutionError.overrideNotInstalled }
            return override
        }
        // Only the known public pair has a suffix relationship. Local build
        // overrides remain exact IDs; a display name or another account's ID
        // is never a basis for guessing a companion.
        let prefix = canonicalAssistantBundleID + "."
        if embeddedDefaultID == canonicalRunnerBundleID, assistantBundleID.hasPrefix(prefix) {
            let suffix = String(assistantBundleID.dropFirst(prefix.count))
            if !suffix.isEmpty, suffix.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }) {
                let candidate = canonicalRunnerBundleID + "." + suffix
                if installedIDs.contains(candidate) { return candidate }
            }
        }
        guard installedIDs.contains(embeddedDefaultID) else { throw ResolutionError.automationNotInstalled }
        return embeddedDefaultID
    }

    enum ResolutionError: LocalizedError, Equatable {
        case overrideNotInstalled, automationNotInstalled

        var errorDescription: String? {
            switch self {
            case .overrideNotInstalled:
                "手动指定的 Automation Bundle ID 未安装。请安装对应的 PocketAgent Automation，或在设置的“高级设备设置”中修正该 ID；留空可自动匹配。"
            case .automationNotInstalled:
                "未找到对应的 PocketAgent Automation。请通过 SideStore / AltStore 安装 Automation，或在设置的“高级设备设置”中填写已安装的 Automation Bundle ID。"
            }
        }
    }
}
