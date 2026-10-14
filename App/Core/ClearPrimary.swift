import Foundation

nonisolated enum ClearPrimaryError: LocalizedError, Equatable {
    case missing, notice, busy, pending
    var errorDescription: String? {
        switch self {
        case .missing: "没有可清空的助理主线。"
        case .notice: "请先处理主线的恢复提示，再清空对话。"
        case .busy: "助理正在准备、排队或执行，请先停止本轮再清空对话。"
        case .pending: "还有待处理请求，请先继续、移回草稿或放弃，再清空对话。"
        }
    }
}

/// "清空对话，保留记忆": the assistant's conversation is removed in one write,
/// its memory is kept.
nonisolated extension HistoryFile {
    /// Refusals before anything changes: a recovery notice, queued/running work
    /// on the primary line or a pending request.
    func clearPrimaryBlocker() -> ClearPrimaryError? {
        guard let primary else { return .missing }
        if assistant.primaryNotice != nil { return .notice }
        if [.queued, .running, .cancelling].contains(primary.state) { return .busy }
        if assistant.pendingNext != nil { return .pending }
        return nil
    }

    /// A primary line with history is replaced by an empty one (new ID, same
    /// title, model and project) and the old line gets a deletion tombstone,
    /// so stale or synchronized copies of it can never be merged back. Its
    /// summaries go with it, scope membership of its messages is pruned (a
    /// root still read by remaining history keeps its identity) and roots of
    /// the old line still present in a conflict copy become unknown. Memory
    /// entries, revisions, sources, tombstones and forget masks, other
    /// conversations and the deletion records of others are unchanged. An
    /// empty line is replaced the same way: an empty local session is not
    /// exported, so a remote or in-flight copy with the same ID and history
    /// would otherwise be adopted into it. Repeating the clear changes no
    /// content. Returns the new primary ID.
    @discardableResult
    mutating func clearPrimaryConversation(now: Date = Date()) throws -> UUID {
        if let blocker = clearPrimaryBlocker() { throw blocker }
        guard let old = primary else { throw ClearPrimaryError.missing }
        var fresh = ChatSession(selection: old.selection, title: ChatSession.primaryTitle)
        fresh.workspaceID = old.workspaceID
        fresh.metadataUpdatedAt = now
        fresh.updatedAt = now
        sessions.removeAll { $0.id == old.id }
        sessions.insert(fresh, at: 0)
        deletedSessions.removeAll { $0.id == old.id }
        deletedSessions.append(Tombstone(id: old.id, deletedAt: now))
        assistant.primarySessionID = fresh.id
        if selectedID == old.id || selectedID.flatMap({ session($0) }) == nil { selectedID = fresh.id }
        assistant.compactions.removeAll { $0.sessionID == old.id }
        // Source check, as after sync: roots whose source line is gone become
        // unknown even where a conflict copy still holds the same message IDs,
        // so neither automatic context nor history search reads them; their
        // identity and read edges stay for forgetting. Lines being written are skipped.
        try reconcileScope(deferred: Set(sessions.filter { [.queued, .running, .cancelling].contains($0.state) }.map(\.id)))
        return fresh.id
    }
}
