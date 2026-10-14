import AgentKit
import Foundation

// assistant-v1 local data. Every business nullable is encoded explicitly as
// null and decoded with `decode(Optional<T>.self)`, so a missing key is a
// format error rather than a silent default. There is no legacy decoder.

nonisolated enum StrictCodingError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let detail): "格式无效：\(detail)" }
    }
}

nonisolated extension KeyedDecodingContainer {
    /// The key must be present; its value may be null.
    func nullable<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T? {
        try decode(Optional<T>.self, forKey: key)
    }
}

/// Where an accepted root prompt's work belongs. Steering inherits its job's
/// root; scope controls information flow only, never file or phone capability.
nonisolated enum WorkScope: Hashable, Sendable, Codable {
    case general
    case workspace(UUID)

    private enum Keys: String, CodingKey { case kind, workspaceID }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "general": self = .general
        case "workspace": self = .workspace(try c.decode(UUID.self, forKey: .workspaceID))
        case let other: throw StrictCodingError.invalid("WorkScope \(other)")
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .general: try c.encode("general", forKey: .kind)
        case .workspace(let id): try c.encode("workspace", forKey: .kind); try c.encode(id, forKey: .workspaceID)
        }
    }
    var workspaceID: UUID? { if case .workspace(let id) = self { id } else { nil } }
    init(workspaceID: UUID?) { self = workspaceID.map(WorkScope.workspace) ?? .general }
}

/// Memory visibility: global (every scope) or one project.
nonisolated enum MemoryScope: Hashable, Sendable, Codable {
    case global
    case workspace(UUID)

    private enum Keys: String, CodingKey { case kind, workspaceID }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "global": self = .global
        case "workspace": self = .workspace(try c.decode(UUID.self, forKey: .workspaceID))
        case let other: throw StrictCodingError.invalid("MemoryScope \(other)")
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .global: try c.encode("global", forKey: .kind)
        case .workspace(let id): try c.encode("workspace", forKey: .kind); try c.encode(id, forKey: .workspaceID)
        }
    }
    /// A memory is readable from `work` when global or of the same project.
    func visible(in work: WorkScope) -> Bool {
        switch self {
        case .global: true
        case .workspace(let id): work.workspaceID == id
        }
    }
}

nonisolated enum MemoryOrigin: String, Hashable, Sendable, Codable {
    /// Memory panel edit.
    case panel
    /// Exact `记住：` / `/remember` host command.
    case command
    /// The user tapped a "save as memory" chip and confirmed the panel.
    case chatChip
}

nonisolated enum PrimaryNotice: Hashable, Sendable, Codable {
    /// The pointer names no session in this file.
    case missing
    /// Synchronization deleted the primary line; `localCopyID` holds local
    /// edits preserved under a new ID, if any.
    case remoteDeleted(localCopyID: UUID?)
    /// A conflict copy of the primary exists, or the primary stopped being a
    /// strict prefix extension of local history.
    case diverged(copyIDs: [UUID])

    private enum Keys: String, CodingKey { case kind, localCopyID, copyIDs }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "missing": self = .missing
        case "remoteDeleted": self = .remoteDeleted(localCopyID: try c.nullable(UUID.self, .localCopyID))
        case "diverged": self = .diverged(copyIDs: try c.decode([UUID].self, forKey: .copyIDs))
        case let other: throw StrictCodingError.invalid("PrimaryNotice \(other)")
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .missing: try c.encode("missing", forKey: .kind)
        case .remoteDeleted(let copy): try c.encode("remoteDeleted", forKey: .kind); try c.encode(copy, forKey: .localCopyID)
        case .diverged(let ids): try c.encode("diverged", forKey: .kind); try c.encode(ids, forKey: .copyIDs)
        }
    }
}

// MARK: Scope and dependencies

nonisolated struct MemoryReadRevision: Hashable, Sendable, Codable {
    var entryID: UUID
    var revision: UInt64
}

/// Known read paths of one root: memory entry revisions, direct root reads
/// (a DAG; ancestors reachable through another read are not repeated) and
/// exact historical messages read without a known root.
nonisolated struct RootDependencies: Hashable, Sendable, Codable {
    var memoryReads: [MemoryReadRevision] = []
    var rootReads: [UUID] = []
    var historicalMessageReads: [UUID] = []
    init(memoryReads: [MemoryReadRevision] = [], rootReads: [UUID] = [], historicalMessageReads: [UUID] = []) {
        self.memoryReads = memoryReads; self.rootReads = rootReads; self.historicalMessageReads = historicalMessageReads
    }
    var isEmpty: Bool { memoryReads.isEmpty && rootReads.isEmpty && historicalMessageReads.isEmpty }
}

nonisolated struct ScopedRoot: Hashable, Sendable, Codable {
    var scope: WorkScope
    var sourceSessionID: UUID
    /// Digest of this root's real messages in its source session; copies and
    /// synchronized content are checked against it.
    var segmentDigest: String
    var dependencies: RootDependencies
    var abandonedUnstarted: Bool
    /// Set by the startup permit commit, never by an asynchronous UI event.
    var dispatchAuthorized: Bool
    /// False after synchronization changed the segment or its source: the root
    /// is then unknown (no automatic context or search) until reselected.
    var verified: Bool
}

nonisolated struct MessageRootRow: Hashable, Sendable, Codable { var messageID: UUID; var rootPromptID: UUID }
nonisolated struct ScopedRootRow: Hashable, Sendable, Codable { var rootPromptID: UUID; var root: ScopedRoot }
/// Explicit forgetting masks a root (and every copy sharing its ID) or an
/// exact message read without a known root.
nonisolated struct MaskRow: Hashable, Sendable, Codable { var id: UUID; var tombstoneID: UUID }

/// Authoritative rows on disk; maps in memory. The decoder rejects duplicate
/// message or root IDs before building the maps.
nonisolated struct ScopeIndex: Hashable, Sendable, Codable {
    private(set) var dependencyRevision: UInt64 = 0
    private(set) var messageRoots: [UUID: UUID] = [:]
    private(set) var roots: [UUID: ScopedRoot] = [:]
    private(set) var maskedRoots: [UUID: Set<UUID>] = [:]
    private(set) var maskedMessages: [UUID: Set<UUID>] = [:]

    init() {}

    private enum Keys: String, CodingKey { case dependencyRevision, messageRoots, roots, maskedRoots, maskedMessages }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        dependencyRevision = try c.decode(UInt64.self, forKey: .dependencyRevision)
        for row in try c.decode([ScopedRootRow].self, forKey: .roots) {
            guard roots.updateValue(row.root, forKey: row.rootPromptID) == nil else {
                throw StrictCodingError.invalid("重复 root \(row.rootPromptID)")
            }
        }
        for row in try c.decode([MessageRootRow].self, forKey: .messageRoots) {
            guard roots[row.rootPromptID] != nil else { throw StrictCodingError.invalid("成员指向不存在的 root") }
            guard messageRoots.updateValue(row.rootPromptID, forKey: row.messageID) == nil else {
                throw StrictCodingError.invalid("重复成员消息 \(row.messageID)")
            }
        }
        for row in try c.decode([MaskRow].self, forKey: .maskedRoots) {
            guard maskedRoots[row.id, default: []].insert(row.tombstoneID).inserted else {
                throw StrictCodingError.invalid("重复 root 屏蔽")
            }
        }
        for row in try c.decode([MaskRow].self, forKey: .maskedMessages) {
            guard maskedMessages[row.id, default: []].insert(row.tombstoneID).inserted else {
                throw StrictCodingError.invalid("重复消息屏蔽")
            }
        }
        // A root is its own prompt's member, unless its source is gone and only
        // its identity/graph is kept for readers (then it is unknown).
        for (id, root) in roots {
            if let member = messageRoots[id] {
                guard member == id else { throw StrictCodingError.invalid("root 的原始请求属于其他 root") }
            } else if root.verified {
                throw StrictCodingError.invalid("root 缺少自身成员")
            }
        }
        try Self.validateGraph(roots)
    }

    /// Direct read edges name existing roots, never the reader itself, and
    /// form no cycle. Iterative (Kahn): linear in roots + edges, no recursion,
    /// so an arbitrarily long chain of roots cannot exhaust the call stack.
    static func validateGraph(_ roots: [UUID: ScopedRoot]) throws {
        var indegree: [UUID: Int] = [:]
        indegree.reserveCapacity(roots.count)
        for (id, root) in roots {
            if indegree[id] == nil { indegree[id] = 0 }
            for target in root.dependencies.rootReads {
                guard target != id, roots[target] != nil else { throw StrictCodingError.invalid("依赖指向不存在的 root") }
                indegree[target, default: 0] += 1
            }
        }
        var ready = indegree.filter { $0.value == 0 }.map(\.key)
        var processed = 0
        while let id = ready.popLast() {
            processed += 1
            for target in roots[id]?.dependencies.rootReads ?? [] {
                indegree[target]! -= 1
                if indegree[target] == 0 { ready.append(target) }
            }
        }
        guard processed == roots.count else { throw StrictCodingError.invalid("依赖图存在环") }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(dependencyRevision, forKey: .dependencyRevision)
        // Row order carries no meaning; the decoder rejects duplicates.
        try c.encode(messageRoots.map { MessageRootRow(messageID: $0.key, rootPromptID: $0.value) }, forKey: .messageRoots)
        try c.encode(roots.map { ScopedRootRow(rootPromptID: $0.key, root: $0.value) }
            .sorted { $0.rootPromptID.uuidString < $1.rootPromptID.uuidString }, forKey: .roots)
        try c.encode(Self.rows(maskedRoots), forKey: .maskedRoots)
        try c.encode(Self.rows(maskedMessages), forKey: .maskedMessages)
    }
    private static func rows(_ map: [UUID: Set<UUID>]) -> [MaskRow] {
        map.flatMap { key, values in values.map { MaskRow(id: key, tombstoneID: $0) } }
            .sorted { ($0.id.uuidString, $0.tombstoneID.uuidString) < ($1.id.uuidString, $1.tombstoneID.uuidString) }
    }

    // MARK: Queries

    func root(of messageID: UUID) -> UUID? { messageRoots[messageID] }
    func scopedRoot(_ id: UUID) -> ScopedRoot? { roots[id] }
    func isMasked(root id: UUID) -> Bool { !(maskedRoots[id]?.isEmpty ?? true) }
    func isMasked(message id: UUID) -> Bool {
        !(maskedMessages[id]?.isEmpty ?? true) || messageRoots[id].map(isMasked(root:)) == true
    }

    // MARK: Mutations (each advances dependencyRevision)

    struct RevisionOverflow: LocalizedError {
        var errorDescription: String? { "依赖版本已达上限，事务已拒绝。" }
    }

    private mutating func bump() throws {
        guard dependencyRevision < UInt64.max else { throw RevisionOverflow() }
        dependencyRevision += 1
    }

    mutating func addRoot(_ id: UUID, _ root: ScopedRoot) throws {
        guard roots[id] == nil, messageRoots[id] == nil else { throw StrictCodingError.invalid("root 已存在") }
        roots[id] = root
        messageRoots[id] = id
        try bump()
    }

    /// Records `messageID` as a member of `root`; an existing member keeps its root.
    mutating func addMember(_ messageID: UUID, root: UUID) throws {
        guard roots[root] != nil else { throw StrictCodingError.invalid("未知 root") }
        if let existing = messageRoots[messageID] {
            guard existing == root else { throw StrictCodingError.invalid("消息已属于其他 root") }
            return
        }
        messageRoots[messageID] = root
        try bump()
    }

    mutating func updateRoot(_ id: UUID, _ change: (inout ScopedRoot) throws -> Void) throws {
        guard var root = roots[id] else { throw StrictCodingError.invalid("未知 root") }
        let before = root
        try change(&root)
        guard root != before else { return }
        roots[id] = root
        // Segment digests change with every event; only graph, scope and
        // eligibility changes are dependency changes.
        var comparable = root; comparable.segmentDigest = before.segmentDigest
        if comparable != before { try bump() }
    }

    mutating func mask(root id: UUID, by tombstone: UUID) throws {
        if maskedRoots[id, default: []].insert(tombstone).inserted { try bump() }
    }
    mutating func mask(message id: UUID, by tombstone: UUID) throws {
        if maskedMessages[id, default: []].insert(tombstone).inserted { try bump() }
    }

    /// Drops membership of messages that no longer exist anywhere. A root
    /// left without its prompt keeps its identity and read edges (as unknown,
    /// without content) while any root that still has history reads it,
    /// directly or transitively; otherwise it is removed. Masks are keyed by
    /// ID and always kept, so copies and later content stay covered.
    mutating func prune(existing messageIDs: Set<UUID>) throws {
        let gone = messageRoots.keys.filter { !messageIDs.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone { messageRoots[id] = nil }
        var referenced: Set<UUID> = []
        var stack = roots.filter { messageRoots[$0.key] != nil }.flatMap { $0.value.dependencies.rootReads }
        while let next = stack.popLast() {
            guard referenced.insert(next).inserted else { continue }
            stack += roots[next]?.dependencies.rootReads ?? []
        }
        for id in Array(roots.keys) where messageRoots[id] == nil {
            if referenced.contains(id) { roots[id]?.verified = false } else { roots[id] = nil }
        }
        try bump()
    }

    var allRootIDs: Dictionary<UUID, ScopedRoot>.Keys { roots.keys }
}

// MARK: Memory

nonisolated struct MemoryRecord: Identifiable, Hashable, Sendable, Codable {
    var id: UUID
    var target: AgentMemoryTarget
    var scope: MemoryScope
    var content: String
    var revision: UInt64
    var origin: MemoryOrigin
    var sourceRootPromptIDs: [UUID]
    var sourceMessageIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date
}

/// Forgotten entry: identity, provenance and a content digest, never content.
nonisolated struct MemoryTombstone: Identifiable, Hashable, Sendable, Codable {
    var id: UUID
    var entryID: UUID
    var throughRevision: UInt64
    var target: AgentMemoryTarget
    var scope: MemoryScope
    var contentDigest: String
    var sourceRootPromptIDs: [UUID]
    var sourceMessageIDs: [UUID]
    /// Ledger revision that recorded the forget.
    var revision: UInt64
    var forgottenAt: Date
}

nonisolated struct MemoryLedger: Hashable, Sendable, Codable {
    var revision: UInt64 = 0
    var forgetEpoch: UInt64 = 0
    var active: [MemoryRecord] = []
    var tombstones: [MemoryTombstone] = []
    init() {}
}

/// Host command receipt: identity and outcome only, never memory content.
nonisolated struct MemoryReceipt: Identifiable, Hashable, Sendable, Codable {
    static let retained = 64
    var id: UUID
    var entryIDs: [UUID]
    var action: String
    var scope: MemoryScope
    var createdAt: Date
    var result: String
}

// MARK: Compaction

nonisolated struct StoredCompaction: Identifiable, Hashable, Sendable, Codable {
    var id: UUID
    var record: AgentCompactionRecord
    var sessionID: UUID
    var scope: WorkScope
    var sourceRootPromptIDs: [UUID]
    var sourceMessageIDs: [UUID]
    var predecessorID: UUID?
    var predecessorDigest: String?
    var inputDigest: String
    var recordDigest: String
    var builderVersion: Int
    var summaryPromptVersion: Int
    /// Informational: forget epoch when generated. Validity follows coverage
    /// and digests, not global epoch equality.
    var forgetEpoch: UInt64
    var summaryModel: String

    private enum Keys: String, CodingKey {
        case id, record, sessionID, scope, sourceRootPromptIDs, sourceMessageIDs, predecessorID, predecessorDigest
        case inputDigest, recordDigest, builderVersion, summaryPromptVersion, forgetEpoch, summaryModel
    }
    init(id: UUID, record: AgentCompactionRecord, sessionID: UUID, scope: WorkScope, sourceRootPromptIDs: [UUID],
         sourceMessageIDs: [UUID], predecessorID: UUID?, predecessorDigest: String?, inputDigest: String,
         recordDigest: String, builderVersion: Int, summaryPromptVersion: Int, forgetEpoch: UInt64, summaryModel: String) {
        self.id = id; self.record = record; self.sessionID = sessionID; self.scope = scope
        self.sourceRootPromptIDs = sourceRootPromptIDs; self.sourceMessageIDs = sourceMessageIDs
        self.predecessorID = predecessorID; self.predecessorDigest = predecessorDigest
        self.inputDigest = inputDigest; self.recordDigest = recordDigest; self.builderVersion = builderVersion
        self.summaryPromptVersion = summaryPromptVersion; self.forgetEpoch = forgetEpoch; self.summaryModel = summaryModel
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        record = try c.decode(AgentCompactionRecord.self, forKey: .record)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        scope = try c.decode(WorkScope.self, forKey: .scope)
        sourceRootPromptIDs = try c.decode([UUID].self, forKey: .sourceRootPromptIDs)
        sourceMessageIDs = try c.decode([UUID].self, forKey: .sourceMessageIDs)
        predecessorID = try c.nullable(UUID.self, .predecessorID)
        predecessorDigest = try c.nullable(String.self, .predecessorDigest)
        inputDigest = try c.decode(String.self, forKey: .inputDigest)
        recordDigest = try c.decode(String.self, forKey: .recordDigest)
        builderVersion = try c.decode(Int.self, forKey: .builderVersion)
        summaryPromptVersion = try c.decode(Int.self, forKey: .summaryPromptVersion)
        forgetEpoch = try c.decode(UInt64.self, forKey: .forgetEpoch)
        summaryModel = try c.decode(String.self, forKey: .summaryModel)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id); try c.encode(record, forKey: .record); try c.encode(sessionID, forKey: .sessionID)
        try c.encode(scope, forKey: .scope); try c.encode(sourceRootPromptIDs, forKey: .sourceRootPromptIDs)
        try c.encode(sourceMessageIDs, forKey: .sourceMessageIDs); try c.encode(predecessorID, forKey: .predecessorID)
        try c.encode(predecessorDigest, forKey: .predecessorDigest); try c.encode(inputDigest, forKey: .inputDigest)
        try c.encode(recordDigest, forKey: .recordDigest); try c.encode(builderVersion, forKey: .builderVersion)
        try c.encode(summaryPromptVersion, forKey: .summaryPromptVersion); try c.encode(forgetEpoch, forKey: .forgetEpoch)
        try c.encode(summaryModel, forKey: .summaryModel)
    }
}

// MARK: Pending next request

/// Exact, user-selected safe window of earlier history: complete call/result
/// groups only, checked against its content digest before every read.
nonisolated struct HistoryReference: Hashable, Sendable, Codable {
    var sessionID: UUID
    var firstMessageID: UUID
    var lastMessageID: UUID
    var expectedContentDigest: String
}

nonisolated enum PendingPrompt: Hashable, Sendable, Codable {
    /// Not yet in history. The message has no image bytes, snapshot or
    /// provider items; attachments are file references only.
    case detached(message: AgentTranscriptMessage, attachments: [ChatAttachment])
    /// Original text is already in the session's messages; only the receipt remains.
    case promoted(promptID: UUID)

    private enum Keys: String, CodingKey { case kind, message, attachments, promptID }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "detached":
            self = .detached(message: try c.decode(AgentTranscriptMessage.self, forKey: .message),
                             attachments: try c.decode([ChatAttachment].self, forKey: .attachments))
        case "promoted": self = .promoted(promptID: try c.decode(UUID.self, forKey: .promptID))
        case let other: throw StrictCodingError.invalid("PendingPrompt \(other)")
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .detached(let message, let attachments):
            try c.encode("detached", forKey: .kind); try c.encode(message, forKey: .message)
            try c.encode(attachments, forKey: .attachments)
        case .promoted(let id): try c.encode("promoted", forKey: .kind); try c.encode(id, forKey: .promptID)
        }
    }
    var promptID: UUID {
        switch self {
        case .detached(let message, _): message.id
        case .promoted(let id): id
        }
    }
}

nonisolated enum PendingState: Hashable, Sendable, Codable {
    case queued
    case held(reason: String)
    case needsResume

    private enum Keys: String, CodingKey { case kind, reason }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "queued": self = .queued
        case "held": self = .held(reason: try c.decode(String.self, forKey: .reason))
        case "needsResume": self = .needsResume
        case let other: throw StrictCodingError.invalid("PendingState \(other)")
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .queued: try c.encode("queued", forKey: .kind)
        case .held(let reason): try c.encode("held", forKey: .kind); try c.encode(reason, forKey: .reason)
        case .needsResume: try c.encode("needsResume", forKey: .kind)
        }
    }
}

/// The single next request of the primary line. Disk holds only nonsecret
/// selection and original content; the resolved configuration and credential
/// live in memory with the accepted job and are re-resolved on explicit resume.
nonisolated struct PendingNext: Hashable, Sendable, Codable {
    var sessionID: UUID
    var prompt: PendingPrompt
    var selection: ModelSelection
    var workspaceID: UUID?
    var backend: PhoneBackendKind
    var clipboardAllowed: Bool
    var acceptedOrdinal: UInt64
    var state: PendingState
    var references: [HistoryReference]
    var acceptedAt: Date

    private enum Keys: String, CodingKey {
        case sessionID, prompt, selection, workspaceID, backend, clipboardAllowed, acceptedOrdinal, state, references, acceptedAt
    }
    init(sessionID: UUID, prompt: PendingPrompt, selection: ModelSelection, workspaceID: UUID?, backend: PhoneBackendKind,
         clipboardAllowed: Bool, acceptedOrdinal: UInt64, state: PendingState, references: [HistoryReference], acceptedAt: Date) {
        self.sessionID = sessionID; self.prompt = prompt; self.selection = selection; self.workspaceID = workspaceID
        self.backend = backend; self.clipboardAllowed = clipboardAllowed; self.acceptedOrdinal = acceptedOrdinal
        self.state = state; self.references = references; self.acceptedAt = acceptedAt
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        prompt = try c.decode(PendingPrompt.self, forKey: .prompt)
        selection = try c.decode(ModelSelection.self, forKey: .selection)
        workspaceID = try c.nullable(UUID.self, .workspaceID)
        backend = try c.decode(PhoneBackendKind.self, forKey: .backend)
        clipboardAllowed = try c.decode(Bool.self, forKey: .clipboardAllowed)
        acceptedOrdinal = try c.decode(UInt64.self, forKey: .acceptedOrdinal)
        state = try c.decode(PendingState.self, forKey: .state)
        references = try c.decode([HistoryReference].self, forKey: .references)
        acceptedAt = try c.decode(Date.self, forKey: .acceptedAt)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(sessionID, forKey: .sessionID); try c.encode(prompt, forKey: .prompt)
        try c.encode(selection, forKey: .selection); try c.encode(workspaceID, forKey: .workspaceID)
        try c.encode(backend, forKey: .backend); try c.encode(clipboardAllowed, forKey: .clipboardAllowed)
        try c.encode(acceptedOrdinal, forKey: .acceptedOrdinal); try c.encode(state, forKey: .state)
        try c.encode(references, forKey: .references); try c.encode(acceptedAt, forKey: .acceptedAt)
    }
}

// MARK: Assistant state

nonisolated struct AssistantState: Hashable, Sendable, Codable {
    var primarySessionID: UUID
    var primaryNotice: PrimaryNotice?
    var memory: MemoryLedger
    var compactions: [StoredCompaction]
    var pendingNext: PendingNext?
    var scopeIndex: ScopeIndex
    var memoryReceipts: [MemoryReceipt]

    init(primarySessionID: UUID) {
        self.primarySessionID = primarySessionID
        primaryNotice = nil; memory = MemoryLedger(); compactions = []; pendingNext = nil
        scopeIndex = ScopeIndex(); memoryReceipts = []
    }

    private enum Keys: String, CodingKey {
        case primarySessionID, primaryNotice, memory, compactions, pendingNext, scopeIndex, memoryReceipts
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        primarySessionID = try c.decode(UUID.self, forKey: .primarySessionID)
        primaryNotice = try c.nullable(PrimaryNotice.self, .primaryNotice)
        memory = try c.decode(MemoryLedger.self, forKey: .memory)
        compactions = try c.decode([StoredCompaction].self, forKey: .compactions)
        pendingNext = try c.nullable(PendingNext.self, .pendingNext)
        scopeIndex = try c.decode(ScopeIndex.self, forKey: .scopeIndex)
        memoryReceipts = try c.decode([MemoryReceipt].self, forKey: .memoryReceipts)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(primarySessionID, forKey: .primarySessionID); try c.encode(primaryNotice, forKey: .primaryNotice)
        try c.encode(memory, forKey: .memory); try c.encode(compactions, forKey: .compactions)
        try c.encode(pendingNext, forKey: .pendingNext); try c.encode(scopeIndex, forKey: .scopeIndex)
        try c.encode(memoryReceipts, forKey: .memoryReceipts)
    }
}
