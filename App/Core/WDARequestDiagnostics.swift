import Foundation

nonisolated enum WDARequestDiagnostics {
    /// Record the endpoint shape, never session IDs, element IDs or query data.
    static func route(_ path: String) -> String {
        let path = path.split(separator: "?", maxSplits: 1).first ?? ""
        let parts = path.split(separator: "/").map(String.init)
        return "/" + parts.enumerated().map { index, part in
            if index > 0, ["session", "element"].contains(parts[index - 1]) { return ":id" }
            return part
        }.joined(separator: "/")
    }
}
