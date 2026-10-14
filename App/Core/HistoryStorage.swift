import Foundation

/// File locations of the assistant-v1 namespace. Earlier namespaces (the
/// Documents history, the root providers file and attachment directory, the
/// old sync file) are never scanned, read, converted or removed.
nonisolated struct AssistantNamespace: Sendable {
    static let directoryName = "assistant-v1"
    let directory: URL
    init(applicationSupport: URL) { directory = applicationSupport.appendingPathComponent(Self.directoryName, isDirectory: true) }
    var history: URL { directory.appendingPathComponent("history.json") }
    var providers: URL { directory.appendingPathComponent("providers.json") }
    var attachments: URL { directory.appendingPathComponent("Attachments", isDirectory: true) }
}

/// Reads and atomically replaces the single history file. Reading is pure; a
/// current-format file that cannot be decoded is never treated as absent.
nonisolated struct HistoryStorage: Sendable {
    enum Loaded: Sendable {
        case absent
        case loaded(HistoryFile)
    }

    let url: URL

    func load() throws -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw HistoryError.unreadable(error.localizedDescription) }
        return .loaded(try HistoryCodec.decode(data))
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Explicit user reset of an unreadable current file: the file is moved
    /// aside (never deleted) so a fresh namespace can start.
    func quarantine(now: Date = Date()) throws -> URL {
        let stamp = Int(now.timeIntervalSince1970)
        var target = url.deletingLastPathComponent().appendingPathComponent("history.unreadable-\(stamp).json")
        var attempt = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("history.unreadable-\(stamp)-\(attempt).json")
            attempt += 1
        }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}
