import AgentKit
import Foundation

nonisolated enum ChatState: String, Codable, Sendable {
    case idle, queued, running, cancelling, completed, failed, interrupted
}

/// Which configured provider and model a conversation uses. Resolved against
/// the provider list only when a turn is enqueued; a missing provider is an
/// explicit unresolved state, never a fallback.
nonisolated struct ModelSelection: Hashable, Codable, Sendable {
    var providerID: UUID
    var modelID: String
}

nonisolated struct Tombstone: Hashable, Codable, Sendable {
    var id: UUID
    var deletedAt: Date
}

nonisolated struct ChatSession: Identifiable, Hashable, Codable, Sendable {
    static let defaultTitle = "新会话"
    static let primaryTitle = "你的助理"
    var id = UUID()
    var title = ChatSession.defaultTitle
    var messages: [AgentTranscriptMessage] = []
    var draft = ""
    var state = ChatState.idle
    var detail = ""
    var updatedAt = Date()
    var selection: ModelSelection?
    /// Last rename/model change; orders concurrent metadata edits during sync.
    var metadataUpdatedAt = Date(timeIntervalSince1970: 0)
    /// Message ID → "provider · model" that actually produced the message.
    var attributions: [String: String] = [:]
    /// Set when this conversation is a conflict copy split from another.
    var conflictOf: UUID?
    /// Message ID → user images sent with it. Metadata only; bytes live in
    /// local protected files named by attachment ID (see `AttachmentFiles`).
    var attachments: [String: [ChatAttachment]] = [:]
    /// Images picked for the unsent draft; local only, never synchronized.
    var draftAttachments: [ChatAttachment] = []
    /// Project directory used by this conversation's next turns. Local only:
    /// projects are not part of portable sync, so it is never synchronized.
    var workspaceID: UUID?

    init(id: UUID = UUID(), selection: ModelSelection? = nil, title: String = ChatSession.defaultTitle) {
        self.id = id; self.selection = selection; self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, draft, state, detail, updatedAt, selection, metadataUpdatedAt, attributions, conflictOf
        case attachments, draftAttachments, workspaceID
    }
    /// assistant-v1 only: every key is required and nullable values are explicit.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        messages = try c.decode([AgentTranscriptMessage].self, forKey: .messages)
        draft = try c.decode(String.self, forKey: .draft)
        state = try c.decode(ChatState.self, forKey: .state)
        detail = try c.decode(String.self, forKey: .detail)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        selection = try c.nullable(ModelSelection.self, .selection)
        metadataUpdatedAt = try c.decode(Date.self, forKey: .metadataUpdatedAt)
        attributions = try c.decode([String: String].self, forKey: .attributions)
        conflictOf = try c.nullable(UUID.self, .conflictOf)
        attachments = try c.decode([String: [ChatAttachment]].self, forKey: .attachments)
        draftAttachments = try c.decode([ChatAttachment].self, forKey: .draftAttachments)
        workspaceID = try c.nullable(UUID.self, .workspaceID)
    }
    func encode(to encoder: any Encoder) throws { try encode(to: encoder, messagesPlaceholder: nil) }

    /// Shared by the normal encoding and the incremental writer, which
    /// substitutes a sentinel string for `messages` (same keys, no drift).
    func encode(to encoder: any Encoder, messagesPlaceholder: String?) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title)
        if let messagesPlaceholder { try c.encode(messagesPlaceholder, forKey: .messages) }
        else { try c.encode(messages, forKey: .messages) }
        try c.encode(draft, forKey: .draft); try c.encode(state, forKey: .state); try c.encode(detail, forKey: .detail)
        try c.encode(updatedAt, forKey: .updatedAt); try c.encode(selection, forKey: .selection)
        try c.encode(metadataUpdatedAt, forKey: .metadataUpdatedAt); try c.encode(attributions, forKey: .attributions)
        try c.encode(conflictOf, forKey: .conflictOf); try c.encode(attachments, forKey: .attachments)
        try c.encode(draftAttachments, forKey: .draftAttachments); try c.encode(workspaceID, forKey: .workspaceID)
    }

    func attachments(of message: AgentTranscriptMessage) -> [ChatAttachment] {
        attachments[message.id.uuidString] ?? []
    }

    /// Every attachment file this conversation still needs on this device.
    var referencedAttachmentIDs: Set<UUID> {
        Set(attachments.values.joined().map(\.id) + draftAttachments.map(\.id))
    }

    /// History never stores image bytes delivered through run events: user
    /// photos are file-backed under `attachments`, and live phone screenshots
    /// belong only to the request that carried them. Replay snapshots are
    /// request-only state as well.
    static func forHistory(_ message: AgentTranscriptMessage) -> AgentTranscriptMessage {
        var message = message
        message.images = []
        message.contextSnapshot = nil
        return message
    }
}

/// The one atomic local history file of the assistant-v1 namespace.
nonisolated struct HistoryFile: Hashable, Codable, Sendable {
    static let generationTag = "assistant-v1"
    static let currentSchema = 1
    var generation: String
    var schemaVersion: Int
    /// Key required, value may be null.
    var selectedID: UUID?
    var sessions: [ChatSession]
    var deletedSessions: [Tombstone]
    var assistant: AssistantState

    /// A new namespace: one empty primary line and every required field, created in one write.
    static func initial(selection: ModelSelection?, now: Date = Date()) -> HistoryFile {
        var primary = ChatSession(selection: selection, title: ChatSession.primaryTitle)
        primary.updatedAt = now
        return HistoryFile(generation: generationTag, schemaVersion: currentSchema, selectedID: primary.id,
                           sessions: [primary], deletedSessions: [], assistant: AssistantState(primarySessionID: primary.id))
    }

    init(generation: String, schemaVersion: Int, selectedID: UUID?, sessions: [ChatSession],
         deletedSessions: [Tombstone], assistant: AssistantState) {
        self.generation = generation; self.schemaVersion = schemaVersion; self.selectedID = selectedID
        self.sessions = sessions; self.deletedSessions = deletedSessions; self.assistant = assistant
    }

    private enum CodingKeys: String, CodingKey { case generation, schemaVersion, selectedID, sessions, deletedSessions, assistant }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decode(String.self, forKey: .generation)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard generation == Self.generationTag else { throw HistoryError.unsupportedGeneration(generation) }
        guard schemaVersion == Self.currentSchema else { throw HistoryError.unsupportedSchema(schemaVersion) }
        selectedID = try c.nullable(UUID.self, .selectedID)
        sessions = try c.decode([ChatSession].self, forKey: .sessions)
        deletedSessions = try c.decode([Tombstone].self, forKey: .deletedSessions)
        assistant = try c.decode(AssistantState.self, forKey: .assistant)
    }
    func encode(to encoder: any Encoder) throws { try encode(to: encoder, sessionsPlaceholder: nil) }

    func encode(to encoder: any Encoder, sessionsPlaceholder: String?) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generation, forKey: .generation); try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(selectedID, forKey: .selectedID)
        if let sessionsPlaceholder { try c.encode(sessionsPlaceholder, forKey: .sessions) }
        else { try c.encode(sessions, forKey: .sessions) }
        try c.encode(deletedSessions, forKey: .deletedSessions); try c.encode(assistant, forKey: .assistant)
    }

    func session(_ id: UUID) -> ChatSession? { sessions.first { $0.id == id } }
    func sessionIndex(_ id: UUID) -> Int? { sessions.firstIndex { $0.id == id } }
    var primary: ChatSession? { session(assistant.primarySessionID) }
}

nonisolated enum HistoryError: LocalizedError, Equatable {
    case unreadable(String)
    case unsupportedGeneration(String)
    case unsupportedSchema(Int)
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): "历史文件无法读取：\(detail)"
        case .unsupportedGeneration(let generation): "不支持的历史格式 \(generation)；本版本只读取 assistant-v1。"
        case .unsupportedSchema(let version): "不支持的历史结构版本 \(version)"
        case .invalid(let detail): "历史文件内容无效：\(detail)"
        }
    }
}

/// Strict assistant-v1 codec: one generation and schema, no historical
/// decoder, no field backfill, no automatic repair or deduplication.
nonisolated enum HistoryCodec {
    static let interruptedDetail = "App 上次退出时任务未完成；发送新消息继续，不会自动重放操作。"

    /// Pure read: decoding never changes run state; the owner's recovery
    /// transaction does that and publishes only after it is saved.
    static func decode(_ data: Data) throws -> HistoryFile {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HistoryError.unreadable("不是 JSON 对象")
        }
        guard let generation = root["generation"] as? String else { throw HistoryError.unsupportedGeneration("缺少 generation") }
        guard generation == HistoryFile.generationTag else { throw HistoryError.unsupportedGeneration(generation) }
        guard let schema = root["schemaVersion"] as? Int else { throw HistoryError.unreadable("缺少 schemaVersion") }
        guard schema == HistoryFile.currentSchema else { throw HistoryError.unsupportedSchema(schema) }
        let file: HistoryFile
        do { file = try JSONDecoder().decode(HistoryFile.self, from: data) }
        catch let error as HistoryError { throw error }
        catch { throw HistoryError.unreadable(String(String(describing: error).prefix(240))) }
        try validate(file)
        return file
    }

    static func encode(_ file: HistoryFile) throws -> Data {
        try validate(file)
        return try JSONEncoder().encode(file)
    }

    /// Structural invariants of the current format. Different conflict copies
    /// may share message IDs; a duplicate inside one session may not.
    static func validate(_ file: HistoryFile) throws {
        guard file.generation == HistoryFile.generationTag else { throw HistoryError.unsupportedGeneration(file.generation) }
        guard file.schemaVersion == HistoryFile.currentSchema else { throw HistoryError.unsupportedSchema(file.schemaVersion) }
        var sessionIDs: Set<UUID> = []
        var allMessages: Set<UUID> = []
        for session in file.sessions {
            guard sessionIDs.insert(session.id).inserted else { throw HistoryError.invalid("重复会话 ID") }
            var ids: Set<UUID> = []
            for message in session.messages {
                guard ids.insert(message.id).inserted else { throw HistoryError.invalid("会话内重复消息 ID") }
            }
            allMessages.formUnion(ids)
        }
        guard Set(file.deletedSessions.map(\.id)).count == file.deletedSessions.count else {
            throw HistoryError.invalid("重复删除记录")
        }
        let assistant = file.assistant
        let ledger = assistant.memory
        guard Set(ledger.active.map(\.id)).count == ledger.active.count else { throw HistoryError.invalid("重复记忆 ID") }
        guard Set(ledger.tombstones.map(\.id)).count == ledger.tombstones.count else { throw HistoryError.invalid("重复遗忘记录") }
        guard Set(ledger.active.map(\.id)).isDisjoint(with: ledger.tombstones.map(\.entryID)) else {
            throw HistoryError.invalid("记忆同时处于有效和已遗忘状态")
        }
        guard Set(assistant.compactions.map(\.id)).count == assistant.compactions.count else { throw HistoryError.invalid("重复摘要 ID") }
        guard Set(assistant.memoryReceipts.map(\.id)).count == assistant.memoryReceipts.count,
              assistant.memoryReceipts.count <= MemoryReceipt.retained else { throw HistoryError.invalid("记忆回执无效") }
        if let pending = assistant.pendingNext {
            guard let session = file.session(pending.sessionID) else { throw HistoryError.invalid("待处理请求指向不存在的会话") }
            switch pending.prompt {
            case .detached(let message, let attachments):
                guard !allMessages.contains(message.id) else { throw HistoryError.invalid("待处理请求与历史消息重复所有权") }
                try validateDetached(message, attachments: attachments)
            case .promoted(let id):
                guard session.messages.contains(where: { $0.id == id }) else { throw HistoryError.invalid("已提升请求不在历史中") }
                guard assistant.scopeIndex.scopedRoot(id)?.dispatchAuthorized == false else {
                    throw HistoryError.invalid("已授权的请求仍保留提升回执")
                }
            }
        }
    }

    /// Detached prompts carry no request payloads: no image bytes, replay
    /// snapshot or provider items. Attachments are file references.
    static func validateDetached(_ message: AgentTranscriptMessage, attachments: [ChatAttachment]) throws {
        guard message.role == .user, message.images.isEmpty, message.contextSnapshot == nil, message.providerItems.isEmpty,
              message.contextAttachments.isEmpty, message.toolCalls.isEmpty,
              attachments.count <= ChatAttachment.maxPerMessage else {
            throw HistoryError.invalid("待处理请求包含不允许的载荷")
        }
    }
}
