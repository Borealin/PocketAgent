import AgentKit
import Foundation

/// Produces the same JSON value as `HistoryCodec.encode` (key order may
/// differ) while re-encoding only messages and scope-index rows (membership,
/// roots) that changed since the previous write. History stays one atomic
/// file in the current format.
///
/// Splicing is structural, not a search for a field name: each shell is
/// encoded with a fresh per-write sentinel string in place of its message or
/// session array, and the sentinel's `"key":"sentinel"` pair must occur
/// exactly once in that shell. The real pair is always emitted, so a single
/// occurrence is the real field; otherwise the shell is encoded whole by
/// JSONEncoder. Nested same-named fields (for example an attachments key
/// called "messages") and any key order are therefore safe.
nonisolated final class HistoryFileEncoder {
    private struct Cached {
        var message: AgentTranscriptMessage
        var data: Data
    }
    private var cache: [UUID: Cached] = [:]
    /// Encoded scope-index rows, reused while the row is unchanged.
    private var memberRows: [UUID: (root: UUID, data: Data)] = [:]
    private var rootRows: [UUID: (root: ScopedRoot, key: String, data: Data)] = [:]
    private let encoder = JSONEncoder()
    /// Encodes the file shell with the scope-index row arrays as placeholders.
    private let shellEncoder = JSONEncoder()

    init() {}

    /// Encodes `shell` and replaces its unique `"key":"sentinel"` pair with
    /// `"key":[elements]`. Nil when the pair is not unique.
    static func splice(_ shell: Data, key: String, sentinel: String, elements: [Data]) -> Data? {
        let pair = Data("\"\(key)\":\"\(sentinel)\"".utf8)
        guard let range = shell.range(of: pair),
              shell.range(of: pair, in: range.upperBound..<shell.endIndex) == nil else { return nil }
        var output = Data()
        output.reserveCapacity(shell.count + elements.reduce(0) { $0 + $1.count + 1 })
        output.append(shell[shell.startIndex..<range.lowerBound])
        output.append(contentsOf: Array("\"\(key)\":[".utf8))
        for (index, element) in elements.enumerated() {
            if index > 0 { output.append(0x2C) }
            output.append(element)
        }
        output.append(0x5D)
        output.append(shell[range.upperBound...])
        return output
    }

    func encode(_ file: HistoryFile) throws -> Data {
        try HistoryCodec.validate(file)
        let sentinel = "pocketagent-splice-" + UUID().uuidString
        var live: Set<UUID> = []
        var sessions: [Data] = []
        sessions.reserveCapacity(file.sessions.count)
        for session in file.sessions {
            var parts: [Data] = []
            parts.reserveCapacity(session.messages.count)
            for message in session.messages {
                live.insert(message.id)
                // Conflict copies share IDs with different values; a mismatch re-encodes.
                if let cached = cache[message.id], cached.message == message {
                    parts.append(cached.data)
                } else {
                    let data = try encoder.encode(message)
                    cache[message.id] = Cached(message: message, data: data)
                    parts.append(data)
                }
            }
            let shell = try encoder.encode(SessionShell(session: session, sentinel: sentinel))
            if let spliced = Self.splice(shell, key: "messages", sentinel: sentinel, elements: parts) {
                sessions.append(spliced)
            } else {
                sessions.append(try encoder.encode(session))
            }
        }
        if cache.count > live.count { cache = cache.filter { live.contains($0.key) } }
        let rows = sentinel + "-rows"
        shellEncoder.userInfo[ScopeIndex.rowsPlaceholderKey] = rows
        var shell = try shellEncoder.encode(FileShell(file: file, sentinel: sentinel))
        let index = file.assistant.scopeIndex
        if let members = Self.splice(shell, key: "messageRoots", sentinel: rows + "-members", elements: try memberElements(index)),
           let rooted = Self.splice(members, key: "roots", sentinel: rows + "-roots", elements: try rootElements(index)) {
            shell = rooted
        } else {
            shell = try encoder.encode(FileShell(file: file, sentinel: sentinel))
        }
        if let spliced = Self.splice(shell, key: "sessions", sentinel: sentinel, elements: sessions) { return spliced }
        return try encoder.encode(file)
    }

    /// Membership rows in the index's own order (order carries no meaning).
    private func memberElements(_ index: ScopeIndex) throws -> [Data] {
        var parts: [Data] = []
        parts.reserveCapacity(index.messageRoots.count)
        for (message, root) in index.messageRoots {
            if let cached = memberRows[message], cached.root == root {
                parts.append(cached.data)
            } else {
                let data = try encoder.encode(MessageRootRow(messageID: message, rootPromptID: root))
                memberRows[message] = (root, data)
                parts.append(data)
            }
        }
        if memberRows.count > index.messageRoots.count { memberRows = memberRows.filter { index.messageRoots[$0.key] != nil } }
        return parts
    }

    /// Root rows sorted by root ID string, as `ScopeIndex` writes them.
    private func rootElements(_ index: ScopeIndex) throws -> [Data] {
        var rows: [(key: String, data: Data)] = []
        rows.reserveCapacity(index.roots.count)
        for (id, root) in index.roots {
            if let cached = rootRows[id], cached.root == root {
                rows.append((cached.key, cached.data))
            } else {
                let key = id.uuidString
                let data = try encoder.encode(ScopedRootRow(rootPromptID: id, root: root))
                rootRows[id] = (root, key, data)
                rows.append((key, data))
            }
        }
        if rootRows.count > index.roots.count { rootRows = rootRows.filter { index.roots[$0.key] != nil } }
        return rows.sorted { $0.key < $1.key }.map(\.data)
    }

    /// The session with `messages` replaced by the sentinel string.
    private struct SessionShell: Encodable {
        let session: ChatSession
        let sentinel: String
        func encode(to encoder: any Encoder) throws {
            try session.encode(to: encoder, messagesPlaceholder: sentinel)
        }
    }

    private struct FileShell: Encodable {
        let file: HistoryFile
        let sentinel: String
        func encode(to encoder: any Encoder) throws {
            try file.encode(to: encoder, sessionsPlaceholder: sentinel)
        }
    }
}
