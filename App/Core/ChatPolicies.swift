import AgentKit
import Foundation

/// The whole composer as it was just before an accepted turn consumed it,
/// with the session's transient edit revision at that moment.
nonisolated struct DraftSnapshot: Hashable, Sendable {
    var text: String
    var attachments: [ChatAttachment]
    var revision: Int
}

nonisolated enum DraftRestore {
    /// Puts the entire pre-send draft back for a turn that never started, but
    /// only if the user has not edited the composer since (text, image removal
    /// or a chosen image counts, including clearing to empty). An edited draft
    /// is left exactly as is; drafts are never merged. The failed prompt and
    /// its images remain in history. Work that started is never restored.
    /// Returns whether the draft was restored.
    @discardableResult
    static func apply(_ saved: DraftSnapshot, to session: inout ChatSession, started: Bool, currentRevision: Int) -> Bool {
        guard !started, currentRevision == saved.revision else { return false }
        session.draft = saved.text
        session.draftAttachments = saved.attachments
        return true
    }

    /// Status text appended to the turn's detail; empty when nothing was restored.
    static func note(restored: Bool) -> String { restored ? " 草稿已恢复。" : "" }
}

nonisolated enum AttachmentCapacity {
    /// Slots still free for a draft, counting imports already reserved.
    static func room(committed: Int, reserved: Int) -> Int {
        max(0, ChatAttachment.maxPerMessage - committed - reserved)
    }
    /// How many of `incoming` fit when an import commits.
    static func accepted(incoming: Int, committed: Int) -> Int {
        min(incoming, max(0, ChatAttachment.maxPerMessage - committed))
    }
}

/// Changes whenever any rendered message changes, wherever it sits (a live
/// reply is shown above pending steering, so it is often not the last row).
nonisolated struct TranscriptProgress: Hashable, Sendable {
    var count = 0
    var textLength = 0
    var reasoningLength = 0
    var toolCalls = 0
    var lastID: UUID?

    init(_ messages: [AgentTranscriptMessage]) {
        count = messages.count
        lastID = messages.last?.id
        for message in messages {
            textLength += message.text.utf16.count
            reasoningLength += message.reasoning.reduce(0) { $0 + $1.text.utf16.count }
            toolCalls += message.toolCalls.count
        }
    }
}

/// Which remote image URLs may be fetched after the user taps "加载": HTTPS
/// with a public-looking host and no credentials. Applied to the first URL,
/// every redirect and the final response URL. Local hosts and private or
/// loopback addresses are refused even though ATS allows local networking.
nonisolated enum RemoteImagePolicy {
    static let maxBytes: Int64 = 20 * 1024 * 1024

    static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty
        else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || !host.contains(".") && !host.contains(":") {
            return false
        }
        if host.contains(":") { return !isLocalIPv6(host) }
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return !isLocalIPv4(parts.compactMap { UInt8($0) }) }
        return true
    }

    /// A declared length over the limit is refused before any body arrives.
    static func acceptsDeclaredLength(_ length: Int64) -> Bool { length < 0 || length <= maxBytes }

    private static func isLocalIPv4(_ b: [UInt8]) -> Bool {
        b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 || (b[0] == 169 && b[1] == 254)
            || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && (64...127).contains(b[1]))
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        let h = host.split(separator: "%").first.map(String.init) ?? host
        return h == "::" || h == "::1" || h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb")
            || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("::ffff:")
    }
}

/// Accumulates a download and refuses to grow past `limit`.
nonisolated struct BoundedBuffer: Sendable {
    let limit: Int64
    private(set) var data = Data()
    init(limit: Int64) { self.limit = limit }

    /// False once the limit would be exceeded; nothing past it is stored.
    mutating func append(_ chunk: Data) -> Bool {
        guard Int64(data.count) + Int64(chunk.count) <= limit else { return false }
        data.append(chunk)
        return true
    }
}
