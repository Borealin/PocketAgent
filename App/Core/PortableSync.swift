import AgentKit
import Foundation

// Portable data shared through a user-chosen folder. Only conversation text,
// tool call/result pairs and nonsecret provider configuration are represented;
// keys, pairing data, drafts, run state, selected session, logs, images and
// attachments have no field here.

nonisolated struct PortableToolCall: Hashable, Codable, Sendable {
    var id: String
    var name: String
    var arguments: AgentJSONValue
}

nonisolated struct PortableMessage: Hashable, Codable, Sendable {
    var id: UUID
    var role: AgentTranscriptRole
    var text: String
    var toolCalls: [PortableToolCall]
    var toolCallID: String?
    var toolName: String?
    var isError: Bool
    var modelText: String?
    var createdAtMs: Int64
    var attribution: String?

    init(_ message: AgentTranscriptMessage, attribution: String?) {
        id = message.id; role = message.role; text = message.text
        toolCalls = message.toolCalls.map { PortableToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) }
        toolCallID = message.toolCallID; toolName = message.toolName; isError = message.isError
        modelText = message.modelText; createdAtMs = PortableTime.ms(message.createdAt)
        self.attribution = attribution
    }

    var transcript: AgentTranscriptMessage {
        AgentTranscriptMessage(id: id, role: role, text: text,
                               toolCalls: toolCalls.map { AgentToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) },
                               toolCallID: toolCallID, toolName: toolName, isError: isError, modelText: modelText,
                               createdAt: PortableTime.date(createdAtMs))
    }
}

nonisolated struct PortableSession: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var selection: ModelSelection?
    /// 0 on a conflict copy means "never edited": its title and selection
    /// follow the original conversation's merged metadata.
    var metadataUpdatedMs: Int64
    var messages: [PortableMessage]
    /// Set on conflict copies: the conversation the branch was split from.
    var conflictOf: UUID?

    /// Empty conversations stay local; every device starts with one.
    init?(_ session: ChatSession) {
        guard !session.messages.isEmpty else { return nil }
        id = session.id; title = session.title; selection = session.selection
        metadataUpdatedMs = PortableTime.ms(session.metadataUpdatedAt)
        messages = session.messages.map { PortableMessage($0, attribution: session.attributions[$0.id.uuidString]) }
        conflictOf = session.conflictOf
    }
    init(id: UUID, title: String, selection: ModelSelection?, metadataUpdatedMs: Int64, messages: [PortableMessage],
         conflictOf: UUID? = nil) {
        self.id = id; self.title = title; self.selection = selection
        self.metadataUpdatedMs = metadataUpdatedMs; self.messages = messages; self.conflictOf = conflictOf
    }
}

nonisolated struct PortableProvider: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var format: ModelAPIFormat
    var isEnabled: Bool
    var inferenceURL: String
    var modelsBaseURL: String
    var models: [ProviderModelEntry]
    var updatedAtMs: Int64

    init(_ record: ProviderRecord) {
        id = record.id; name = record.name; format = record.format; isEnabled = record.isEnabled
        inferenceURL = record.inferenceURL; modelsBaseURL = record.modelsBaseURL; models = record.models
        updatedAtMs = PortableTime.ms(record.updatedAt)
    }
    var record: ProviderRecord {
        ProviderRecord(id: id, name: name, format: format, isEnabled: isEnabled, inferenceURL: inferenceURL,
                       modelsBaseURL: modelsBaseURL, models: models, updatedAt: PortableTime.date(updatedAtMs))
    }
}

nonisolated struct PortableTombstone: Hashable, Codable, Sendable {
    var id: UUID
    var deletedAtMs: Int64
    init(id: UUID, deletedAtMs: Int64) { self.id = id; self.deletedAtMs = deletedAtMs }
    init(_ tombstone: Tombstone) { id = tombstone.id; deletedAtMs = PortableTime.ms(tombstone.deletedAt) }
    var local: Tombstone { Tombstone(id: id, deletedAt: PortableTime.date(deletedAtMs)) }
}

nonisolated struct PortableSnapshot: Hashable, Codable, Sendable {
    static let currentSchema = 1
    var schemaVersion = PortableSnapshot.currentSchema
    var sessions: [PortableSession] = []
    var providers: [PortableProvider] = []
    var deletedSessions: [PortableTombstone] = []
    var deletedProviders: [PortableTombstone] = []

    init(sessions: [PortableSession] = [], providers: [PortableProvider] = [],
         deletedSessions: [PortableTombstone] = [], deletedProviders: [PortableTombstone] = []) {
        self.sessions = sessions; self.providers = providers
        self.deletedSessions = deletedSessions; self.deletedProviders = deletedProviders
    }

    /// Local snapshot. Sessions with active work are excluded by the caller.
    init(sessions: [ChatSession], sessionTombstones: [Tombstone],
         providers: [ProviderRecord], providerTombstones: [Tombstone]) {
        self.init(sessions: sessions.compactMap(PortableSession.init),
                  providers: providers.map(PortableProvider.init),
                  deletedSessions: sessionTombstones.map(PortableTombstone.init),
                  deletedProviders: providerTombstones.map(PortableTombstone.init))
        self = PortableMerge.canonical(self)
    }
}

nonisolated enum PortableTime {
    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}

nonisolated enum SyncError: LocalizedError, Equatable {
    case unreadable(String)
    case newerVersion(Int)
    case invalidContent(String)
    case notDownloaded
    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): "同步文件无法读取，未覆盖：\(detail)"
        case .newerVersion(let version): "同步文件版本 \(version) 较新，请先更新 App；未覆盖。"
        case .invalidContent(let detail): "同步文件内容无效，未覆盖：\(detail)"
        case .notDownloaded: "同步文件尚未从 iCloud 下载完成，请稍后重试；未覆盖。"
        }
    }
}

nonisolated enum PortableCodec {
    /// Reads the schema version before anything else; an unknown or newer
    /// version is a failure so the caller leaves every file untouched.
    static func decode(_ data: Data) throws -> PortableSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.unreadable("不是 JSON 对象")
        }
        guard let version = root["schemaVersion"] as? Int else { throw SyncError.unreadable("缺少 schemaVersion") }
        guard version <= PortableSnapshot.currentSchema else { throw SyncError.newerVersion(version) }
        guard version == PortableSnapshot.currentSchema else { throw SyncError.unreadable("未知版本 \(version)") }
        let snapshot: PortableSnapshot
        do { snapshot = try JSONDecoder().decode(PortableSnapshot.self, from: data) }
        catch { throw SyncError.unreadable(String(describing: error).prefix(200).description) }
        try validate(snapshot)
        return snapshot
    }

    static func encode(_ snapshot: PortableSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(PortableMerge.canonical(snapshot))
    }

    static func validate(_ snapshot: PortableSnapshot) throws {
        guard Set(snapshot.sessions.map(\.id)).count == snapshot.sessions.count else {
            throw SyncError.invalidContent("重复会话 ID")
        }
        guard Set(snapshot.providers.map(\.id)).count == snapshot.providers.count else {
            throw SyncError.invalidContent("重复服务商 ID")
        }
        for session in snapshot.sessions where Set(session.messages.map(\.id)).count != session.messages.count {
            throw SyncError.invalidContent("会话内重复消息 ID")
        }
        for provider in snapshot.providers {
            do { _ = try provider.record.validated() }
            catch { throw SyncError.invalidContent("服务商 \(provider.name)：\(error.localizedDescription)") }
        }
    }
}

nonisolated enum StableHash {
    static func fnv1a(_ bytes: Data, seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in bytes { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return hash
    }
    static func digest(_ data: Data) -> String {
        String(format: "%016llx%016llx", fnv1a(data, seed: 0xcbf29ce484222325), fnv1a(data, seed: 0x84222325cbf29ce4))
    }
    /// Deterministic across processes and devices; never `Hasher`.
    static func uuid(_ parts: [String]) -> UUID {
        let data = Data(parts.joined(separator: "\u{1F}").utf8)
        let a = fnv1a(data, seed: 0xcbf29ce484222325), b = fnv1a(data, seed: 0x84222325cbf29ce4)
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: a >> (8 * $0)) } + (0..<8).map { UInt8(truncatingIfNeeded: b >> (8 * $0)) }
        bytes[6] = (bytes[6] & 0x0F) | 0x80 // RFC 9562 version 8 (custom)
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    static func canonical<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }
}

/// Deterministic, commutative, associative and idempotent merge of portable
/// snapshots. Conversation metadata is session-level last-writer-wins;
/// conflict copies hold diverging branches and are identified by content only.
nonisolated enum PortableMerge {
    static let conflictSuffix = "（冲突副本）"

    static func merge(_ a: PortableSnapshot, _ b: PortableSnapshot) -> PortableSnapshot {
        let deletedSessions = union(a.deletedSessions, b.deletedSessions)
        let deletedProviders = union(a.deletedProviders, b.deletedProviders)
        let deadSessions = Set(deletedSessions.map(\.id)), deadProviders = Set(deletedProviders.map(\.id))

        var sessions: [UUID: PortableSession] = [:]
        func insert(_ session: PortableSession) {
            // Deletion is final: a tombstone prevents any resurrection.
            guard !deadSessions.contains(session.id) else { return }
            guard let existing = sessions[session.id] else { sessions[session.id] = session; return }
            let (merged, conflict) = mergeSession(existing, session)
            sessions[session.id] = merged
            if let conflict { insert(conflict) }
        }
        for session in a.sessions + b.sessions { insert(session) }
        pruneRedundantCopies(&sessions)
        inheritCopyMetadata(&sessions)

        var providers: [UUID: PortableProvider] = [:]
        for provider in a.providers + b.providers where !deadProviders.contains(provider.id) {
            providers[provider.id] = providers[provider.id].map { newer($0, provider) } ?? provider
        }
        return canonical(PortableSnapshot(sessions: Array(sessions.values), providers: Array(providers.values),
                                          deletedSessions: deletedSessions, deletedProviders: deletedProviders))
    }

    /// Same conversation ID on both sides. Prefix-compatible histories keep
    /// the longer one. Divergent histories (including the same message ID
    /// edited differently) keep a deterministic winner and preserve the other
    /// branch as a conflict copy. The copy ID depends only on the conversation
    /// and the branch tip, never on which branch it happened to be compared
    /// with, so every merge order yields the same copies.
    static func mergeSession(_ a: PortableSession, _ b: PortableSession) -> (PortableSession, PortableSession?) {
        let prefix = zip(a.messages, b.messages).prefix { $0 == $1 }.count
        var conflict: PortableSession?
        let messages: [PortableMessage]
        let meta = newerMetadata(a, b)
        if prefix == b.messages.count { messages = a.messages }
        else if prefix == a.messages.count { messages = b.messages }
        else {
            let (winner, loser) = order(a, b)
            messages = winner.messages
            conflict = PortableSession(id: conflictID(of: a.id, branch: loser.messages),
                                       title: meta.title + conflictSuffix, selection: meta.selection,
                                       metadataUpdatedMs: 0, messages: loser.messages, conflictOf: a.id)
        }
        return (PortableSession(id: a.id, title: meta.title, selection: meta.selection,
                                metadataUpdatedMs: meta.metadataUpdatedMs, messages: messages,
                                conflictOf: a.conflictOf ?? b.conflictOf), conflict)
    }

    static func conflictID(of sessionID: UUID, branch: [PortableMessage]) -> UUID {
        let tip = branch.last
        return StableHash.uuid(["conflict", sessionID.uuidString, tip?.id.uuidString ?? "",
                                tip.map { StableHash.digest(StableHash.canonical($0)) } ?? ""])
    }

    /// An unedited conflict copy whose whole history is contained in another
    /// live conversation adds nothing (typically: a device kept chatting on
    /// the branch that was copied). Dropping it never loses a message. Copies
    /// the user renamed or re-pointed carry explicit metadata and are kept.
    private static func pruneRedundantCopies(_ sessions: inout [UUID: PortableSession]) {
        let byRoot = Dictionary(grouping: sessions.values.filter { !$0.messages.isEmpty }, by: { $0.messages[0].id })
        for copy in sessions.values where copy.conflictOf != nil && copy.metadataUpdatedMs == 0 && !copy.messages.isEmpty {
            let covered = byRoot[copy.messages[0].id, default: []].contains { other in
                guard other.id != copy.id, other.messages.count >= copy.messages.count,
                      Array(other.messages.prefix(copy.messages.count)) == copy.messages else { return false }
                // Identical copies: keep the original or the lowest ID.
                return other.messages.count > copy.messages.count || other.conflictOf == nil
                    || other.id.uuidString < copy.id.uuidString
            }
            if covered { sessions[copy.id] = nil }
        }
    }

    /// Unedited copies (metadataUpdatedMs == 0) follow the merged title and
    /// selection of the conversation they came from, so the result does not
    /// depend on merge order. A user edit on the copy takes precedence.
    private static func inheritCopyMetadata(_ sessions: inout [UUID: PortableSession]) {
        func resolved(_ id: UUID, depth: Int) -> PortableSession? {
            guard var session = sessions[id] else { return nil }
            guard session.metadataUpdatedMs == 0, let parentID = session.conflictOf, depth < 16,
                  let parent = resolved(parentID, depth: depth + 1) else { return session }
            session.title = parent.title + conflictSuffix
            session.selection = parent.selection
            return session
        }
        for id in Array(sessions.keys) { sessions[id] = resolved(id, depth: 0) }
    }

    static func canonical(_ snapshot: PortableSnapshot) -> PortableSnapshot {
        var result = snapshot
        result.sessions.sort { $0.id.uuidString < $1.id.uuidString }
        result.providers.sort { $0.id.uuidString < $1.id.uuidString }
        result.deletedSessions = union(snapshot.deletedSessions, [])
        result.deletedProviders = union(snapshot.deletedProviders, [])
        return result
    }

    private static func order(_ a: PortableSession, _ b: PortableSession) -> (PortableSession, PortableSession) {
        if a.messages.count != b.messages.count { return a.messages.count > b.messages.count ? (a, b) : (b, a) }
        return StableHash.digest(StableHash.canonical(a.messages)) >= StableHash.digest(StableHash.canonical(b.messages)) ? (a, b) : (b, a)
    }

    private static func newerMetadata(_ a: PortableSession, _ b: PortableSession) -> PortableSession {
        if a.metadataUpdatedMs != b.metadataUpdatedMs { return a.metadataUpdatedMs > b.metadataUpdatedMs ? a : b }
        let ka = StableHash.digest(StableHash.canonical([a.title, a.selection.map { "\($0.providerID)/\($0.modelID)" } ?? ""]))
        let kb = StableHash.digest(StableHash.canonical([b.title, b.selection.map { "\($0.providerID)/\($0.modelID)" } ?? ""]))
        return ka >= kb ? a : b
    }

    private static func newer(_ a: PortableProvider, _ b: PortableProvider) -> PortableProvider {
        if a.updatedAtMs != b.updatedAtMs { return a.updatedAtMs > b.updatedAtMs ? a : b }
        return StableHash.digest(StableHash.canonical(a)) >= StableHash.digest(StableHash.canonical(b)) ? a : b
    }

    private static func union(_ a: [PortableTombstone], _ b: [PortableTombstone]) -> [PortableTombstone] {
        var latest: [UUID: Int64] = [:]
        for t in a + b { latest[t.id] = max(latest[t.id] ?? .min, t.deletedAtMs) }
        return latest.map { PortableTombstone(id: $0.key, deletedAtMs: $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

/// Outcome of one sync round, computed off the main actor.
nonisolated struct SyncPlan: Sendable {
    var merged: PortableSnapshot
    /// Data to write, or nil when the remote file already holds it.
    var output: PortableSnapshot?

    /// Sessions with active local work are left out of the local side, so the
    /// remote copy of such a session passes through unchanged and its newer
    /// local content is exported in a later round. `conflictVersions` are
    /// competing file versions kept by the file provider; all are merged.
    static func make(local: PortableSnapshot, remote: PortableSnapshot?, conflictVersions: [PortableSnapshot] = [],
                     deferred: Set<UUID>) -> SyncPlan {
        var local = local
        local.sessions.removeAll { deferred.contains($0.id) }
        let remotes = conflictVersions.reduce(remote ?? PortableSnapshot(), PortableMerge.merge)
        let merged = PortableMerge.merge(local, remotes)
        let unchanged = remote.map { PortableMerge.canonical($0) == merged } ?? false
        return SyncPlan(merged: merged, output: unchanged ? nil : merged)
    }
}

/// Applies a merged snapshot to local state without touching drafts, run
/// state or sessions changed after `base` was captured (those export later).
nonisolated enum SyncApplication {
    struct SessionResult: Sendable {
        var sessions: [ChatSession]
        var tombstones: [Tombstone]
        var deferred: Int
        /// Local ID → ID of the copy that preserved its concurrent edits.
        var replaced: [UUID: UUID] = [:]
    }
    struct ProviderResult: Sendable {
        var providers: [ProviderRecord]
        var tombstones: [Tombstone]
        var removed: [UUID]
    }

    static func sessions(_ current: [ChatSession], tombstones: [Tombstone], merged: PortableSnapshot,
                         base: PortableSnapshot, deferred: Set<UUID>, now: Date = Date()) -> SessionResult {
        let dead = Set(merged.deletedSessions.map(\.id))
        let localDead = Set(tombstones.map(\.id))
        let remote = Dictionary(uniqueKeysWithValues: merged.sessions.map { ($0.id, $0) })
        let baseSessions = Dictionary(uniqueKeysWithValues: base.sessions.map { ($0.id, $0) })
        var result: [ChatSession] = []
        var replaced: [UUID: UUID] = [:]
        var skipped = 0
        for session in current {
            if deferred.contains(session.id) {
                if remote[session.id].map({ $0 != PortableSession(session) }) ?? dead.contains(session.id) { skipped += 1 }
                result.append(session); continue
            }
            let currentPortable = PortableSession(session)
            let changedSinceBase = currentPortable != baseSessions[session.id]
            if dead.contains(session.id) {
                // Deleted elsewhere while this device was still writing to it:
                // honor the deletion, keep the unsynced text as a new conversation.
                if changedSinceBase, let currentPortable {
                    let preserved = preserve(session, portable: currentPortable, now: now)
                    replaced[session.id] = preserved.id
                    result.append(preserved)
                }
                continue
            }
            guard let incoming = remote[session.id] else {
                // Exported but absent without a tombstone: a redundant conflict
                // copy whose history is contained in another conversation.
                if baseSessions[session.id] != nil, !changedSinceBase, session.conflictOf != nil { continue }
                result.append(session); continue
            }
            if currentPortable == incoming { result.append(session); continue }
            if changedSinceBase { skipped += 1; result.append(session); continue }
            result.append(adopt(incoming, into: session, now: now))
        }
        let present = Set(current.map(\.id))
        for incoming in merged.sessions where !present.contains(incoming.id)
            && !localDead.contains(incoming.id) && baseSessions[incoming.id] == nil {
            result.append(adopt(incoming, into: ChatSession(), now: now))
        }
        var latest = Dictionary(tombstones.map { ($0.id, $0.deletedAt) }, uniquingKeysWith: max)
        for t in merged.deletedSessions { latest[t.id] = max(latest[t.id] ?? .distantPast, t.local.deletedAt) }
        return SessionResult(sessions: result,
                             tombstones: latest.map { Tombstone(id: $0.key, deletedAt: $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString },
                             deferred: skipped, replaced: replaced)
    }

    private static func preserve(_ session: ChatSession, portable: PortableSession, now: Date) -> ChatSession {
        var copy = session
        copy.id = StableHash.uuid(["deleted-edit", session.id.uuidString,
                                   StableHash.digest(StableHash.canonical(portable.messages))])
        copy.title = session.title + PortableMerge.conflictSuffix
        copy.conflictOf = nil
        copy.metadataUpdatedAt = now
        copy.updatedAt = now
        return copy
    }

    static func providers(_ current: [ProviderRecord], tombstones: [Tombstone], merged: PortableSnapshot,
                          base: PortableSnapshot) -> ProviderResult {
        let dead = Set(merged.deletedProviders.map(\.id))
        let localDead = Set(tombstones.map(\.id))
        let remote = Dictionary(uniqueKeysWithValues: merged.providers.map { ($0.id, $0) })
        let baseProviders = Dictionary(uniqueKeysWithValues: base.providers.map { ($0.id, $0) })
        var result: [ProviderRecord] = []
        var removed: [UUID] = []
        for provider in current {
            if dead.contains(provider.id) { removed.append(provider.id); continue }
            guard let incoming = remote[provider.id], PortableProvider(provider) == baseProviders[provider.id] else {
                result.append(provider); continue
            }
            result.append(incoming.record)
        }
        let present = Set(current.map(\.id))
        for incoming in merged.providers where !present.contains(incoming.id)
            && !localDead.contains(incoming.id) && baseProviders[incoming.id] == nil {
            result.append(incoming.record)
        }
        var latest = Dictionary(tombstones.map { ($0.id, $0.deletedAt) }, uniquingKeysWith: max)
        for t in merged.deletedProviders { latest[t.id] = max(latest[t.id] ?? .distantPast, t.local.deletedAt) }
        return ProviderResult(providers: result,
                              tombstones: latest.map { Tombstone(id: $0.key, deletedAt: $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString },
                              removed: removed)
    }

    /// Keeps local message values (with images and provider state) whose
    /// portable projection is unchanged; drafts and run state stay local.
    private static func adopt(_ incoming: PortableSession, into session: ChatSession, now: Date) -> ChatSession {
        var session = session
        let local = Dictionary(session.messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let attributions = session.attributions
        session.id = incoming.id
        session.title = incoming.title
        session.selection = incoming.selection
        session.metadataUpdatedAt = PortableTime.date(incoming.metadataUpdatedMs)
        session.conflictOf = incoming.conflictOf
        session.messages = incoming.messages.map { message in
            if let existing = local[message.id],
               PortableMessage(existing, attribution: attributions[message.id.uuidString]) == message { return existing }
            return message.transcript
        }
        session.attributions = Dictionary(uniqueKeysWithValues: incoming.messages.compactMap { m in
            m.attribution.map { (m.id.uuidString, $0) }
        })
        session.updatedAt = now
        return session
    }
}
