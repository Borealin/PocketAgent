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

nonisolated struct ChatSession: Identifiable, Codable, Sendable {
    static let defaultTitle = "新会话"
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

    init(selection: ModelSelection? = nil) { self.selection = selection }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, draft, state, detail, updatedAt, selection, metadataUpdatedAt, attributions, conflictOf
    }
    // v1/v2 rows lack the newer fields; real IDs and messages are mandatory.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        messages = try c.decode([AgentTranscriptMessage].self, forKey: .messages)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? Self.defaultTitle
        draft = try c.decodeIfPresent(String.self, forKey: .draft) ?? ""
        state = try c.decodeIfPresent(ChatState.self, forKey: .state) ?? .idle
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        selection = try c.decodeIfPresent(ModelSelection.self, forKey: .selection)
        metadataUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .metadataUpdatedAt) ?? Date(timeIntervalSince1970: 0)
        attributions = try c.decodeIfPresent([String: String].self, forKey: .attributions) ?? [:]
        conflictOf = try c.decodeIfPresent(UUID.self, forKey: .conflictOf)
    }
}

nonisolated struct HistoryFile: Codable, Sendable {
    static let currentVersion = 3
    var version = HistoryFile.currentVersion
    var selectedID: UUID?
    var sessions: [ChatSession]
    var deletedSessions: [Tombstone] = []

    init(selectedID: UUID?, sessions: [ChatSession], deletedSessions: [Tombstone]) {
        self.selectedID = selectedID; self.sessions = sessions; self.deletedSessions = deletedSessions
    }
    private enum CodingKeys: String, CodingKey { case version, selectedID, sessions, deletedSessions }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        selectedID = try c.decodeIfPresent(UUID.self, forKey: .selectedID)
        sessions = try c.decode([ChatSession].self, forKey: .sessions)
        deletedSessions = try c.decodeIfPresent([Tombstone].self, forKey: .deletedSessions) ?? []
    }
}

nonisolated enum HistoryError: LocalizedError, Equatable {
    case unreadable
    case unsupportedVersion(Int)
    case duplicateSessionIDs
    var errorDescription: String? {
        switch self {
        case .unreadable: "无效的会话文件"
        case .unsupportedVersion(let version): "不支持的会话文件版本 \(version)"
        case .duplicateSessionIDs: "会话文件包含重复会话 ID"
        }
    }
}

nonisolated enum HistoryMigration {
    static let interruptedDetail = "App 上次退出时任务未完成；发送新消息继续，不会自动重放操作。"

    /// Decodes any supported history version into the current layout. Only the
    /// removed counter demo mode is discarded; real sessions keep their IDs and
    /// messages. Sessions from files older than v3 adopt `legacySelection` so
    /// they keep using the migrated provider. Unfinished work becomes
    /// interrupted and is never replayed.
    static func decode(_ data: Data, legacySelection: ModelSelection?) throws -> HistoryFile {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int else { throw HistoryError.unreadable }
        guard (1...HistoryFile.currentVersion).contains(version) else { throw HistoryError.unsupportedVersion(version) }
        var data = data
        if version == 1 {
            guard let rows = root["sessions"] as? [[String: Any]] else { throw HistoryError.unreadable }
            root["sessions"] = rows.filter { $0["mode"] as? String != "counter" }
            data = try JSONSerialization.data(withJSONObject: root)
        }
        var file = try JSONDecoder().decode(HistoryFile.self, from: data)
        guard Set(file.sessions.map(\.id)).count == file.sessions.count else { throw HistoryError.duplicateSessionIDs }
        for i in file.sessions.indices {
            file.sessions[i].messages = repairedToolOrder(file.sessions[i].messages)
            if version < HistoryFile.currentVersion, file.sessions[i].selection == nil {
                file.sessions[i].selection = legacySelection
            }
            if [.running, .queued, .cancelling].contains(file.sessions[i].state) {
                file.sessions[i].state = .interrupted
                file.sessions[i].detail = interruptedDetail
            }
        }
        file.version = HistoryFile.currentVersion
        return file
    }

    static func encode(_ file: HistoryFile) throws -> Data {
        var file = file
        file.version = HistoryFile.currentVersion
        return try JSONEncoder().encode(file)
    }

    /// Places each tool result directly after the assistant message that
    /// called it. Event order is otherwise authoritative; dates are not sorted.
    static func repairedToolOrder(_ messages: [AgentTranscriptMessage]) -> [AgentTranscriptMessage] {
        let calls = Set(messages.flatMap { $0.toolCalls.map(\.id) })
        let results = Dictionary(grouping: messages.filter { $0.role == .tool && $0.toolCallID != nil },
                                 by: { $0.toolCallID! })
        var ordered: [AgentTranscriptMessage] = []
        var emitted: Set<UUID> = []
        for message in messages {
            if message.role == .tool, let call = message.toolCallID, calls.contains(call) { continue }
            guard emitted.insert(message.id).inserted else { continue }
            ordered.append(message)
            for call in message.toolCalls {
                for result in results[call.id] ?? [] where emitted.insert(result.id).inserted { ordered.append(result) }
            }
        }
        return ordered
    }
}
