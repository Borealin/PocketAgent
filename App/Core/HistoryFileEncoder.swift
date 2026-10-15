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
    /// Sorted keys make an unchanged value encode to the same bytes (the
    /// default key order differs between encodes), which `HistoryLayout`
    /// relies on to leave unchanged regions alone.
    private let shellEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

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
        let shell = try fileShell(file, sentinel: sentinel)
        if let spliced = Self.splice(shell, key: "sessions", sentinel: sentinel, elements: sessions) { return spliced }
        return try encoder.encode(file)
    }

    /// The file with `"sessions":"<sentinel>"` in place of its sessions and
    /// the scope-index rows spliced from the row caches (`HistoryLayout`
    /// shares it).
    func fileShell(_ file: HistoryFile, sentinel: String) throws -> Data {
        let rows = sentinel + "-rows"
        shellEncoder.userInfo[ScopeIndex.rowsPlaceholderKey] = rows
        let shell = try shellEncoder.encode(FileShell(file: file, sentinel: sentinel))
        let index = file.assistant.scopeIndex
        if let members = Self.splice(shell, key: "messageRoots", sentinel: rows + "-members", elements: try memberElements(index)),
           let rooted = Self.splice(members, key: "roots", sentinel: rows + "-roots", elements: try rootElements(index)) {
            return rooted
        }
        return try encoder.encode(FileShell(file: file, sentinel: sentinel))
    }

    /// The session with `"messages":"<sentinel>"` in place of its messages.
    func sessionShell(_ session: ChatSession, sentinel: String) throws -> Data {
        try sortedEncoder.encode(SessionShell(session: session, sentinel: sentinel))
    }

    /// Scope-index rows encoded ahead of a write (off the main actor while a
    /// launched file is checked); installed rows are still compared with the
    /// index on use.
    struct RowSeed: Sendable {
        struct Member: Sendable { var root: UUID; var data: Data }
        struct Root: Sendable { var root: ScopedRoot; var key: String; var data: Data }
        var members: [UUID: Member] = [:]
        var roots: [UUID: Root] = [:]

        static func encoding(_ index: ScopeIndex) throws -> RowSeed {
            let members = Array(index.messageRoots)
            let roots = Array(index.roots)
            let memberData = try ParallelEncoding.encode(members.map { MessageRootRow(messageID: $0.key, rootPromptID: $0.value) })
            let rootData = try ParallelEncoding.encode(roots.map { ScopedRootRow(rootPromptID: $0.key, root: $0.value) })
            var seed = RowSeed()
            seed.members.reserveCapacity(members.count)
            for (row, data) in zip(members, memberData) { seed.members[row.key] = Member(root: row.value, data: data) }
            seed.roots.reserveCapacity(roots.count)
            for (row, data) in zip(roots, rootData) { seed.roots[row.key] = Root(root: row.value, key: row.key.uuidString, data: data) }
            return seed
        }
    }

    func install(_ seed: RowSeed) {
        for (id, member) in seed.members { memberRows[id] = (member.root, member.data) }
        for (id, root) in seed.roots { rootRows[id] = (root.root, root.key, root.data) }
    }

    /// Membership rows in the index's own order (order carries no meaning).
    /// Rows missing from the cache are encoded together (in parallel when many).
    private func memberElements(_ index: ScopeIndex) throws -> [Data] {
        var parts: [Data] = []
        parts.reserveCapacity(index.messageRoots.count)
        var misses: [(position: Int, row: MessageRootRow)] = []
        for (message, root) in index.messageRoots {
            if let cached = memberRows[message], cached.root == root {
                parts.append(cached.data)
            } else {
                misses.append((parts.count, MessageRootRow(messageID: message, rootPromptID: root)))
                parts.append(Data())
            }
        }
        for (miss, data) in zip(misses, try ParallelEncoding.encode(misses.map(\.row))) {
            memberRows[miss.row.messageID] = (miss.row.rootPromptID, data)
            parts[miss.position] = data
        }
        if memberRows.count > index.messageRoots.count { memberRows = memberRows.filter { index.messageRoots[$0.key] != nil } }
        return parts
    }

    /// Root rows sorted by root ID string, as `ScopeIndex` writes them.
    private func rootElements(_ index: ScopeIndex) throws -> [Data] {
        var rows: [(key: String, data: Data)] = []
        rows.reserveCapacity(index.roots.count)
        var misses: [(position: Int, row: ScopedRootRow)] = []
        for (id, root) in index.roots {
            if let cached = rootRows[id], cached.root == root {
                rows.append((cached.key, cached.data))
            } else {
                misses.append((rows.count, ScopedRootRow(rootPromptID: id, root: root)))
                rows.append((id.uuidString, Data()))
            }
        }
        for (miss, data) in zip(misses, try ParallelEncoding.encode(misses.map(\.row))) {
            rootRows[miss.row.rootPromptID] = (miss.row.root, rows[miss.position].key, data)
            rows[miss.position].data = data
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
