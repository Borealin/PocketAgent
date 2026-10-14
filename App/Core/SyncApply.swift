import AgentKit
import Foundation

/// Applying a merged portable snapshot to the complete local file. Only
/// portable session fields change; primary identity, memory, scope,
/// compactions and the pending request stay local. The primary line is never
/// silently replaced: deletion, replacement or divergence becomes a notice.
nonisolated extension HistoryFile {
    mutating func applyPortable(merged: PortableSnapshot, base: PortableSnapshot, deferred: Set<UUID>,
                                now: Date = Date()) throws -> Int {
        let primaryID = assistant.primarySessionID
        let primaryBefore = primary
        let result = SyncApplication.sessions(sessions, tombstones: deletedSessions, merged: merged, base: base,
                                              deferred: deferred, now: now)
        sessions = result.sessions
        deletedSessions = result.tombstones
        if let id = selectedID, let replacement = result.replaced[id] { selectedID = replacement }

        if session(primaryID) == nil {
            if assistant.primaryNotice == nil || assistant.primaryNotice == .missing {
                assistant.primaryNotice = deletedSessions.contains(where: { $0.id == primaryID })
                    ? .remoteDeleted(localCopyID: result.replaced[primaryID]) : .missing
            }
        } else if let before = primaryBefore, let after = primary {
            let copies = sessions.filter { $0.conflictOf == primaryID }.map(\.id)
            let extendsStrictly = after.messages.count >= before.messages.count
                && Array(after.messages.prefix(before.messages.count)) == before.messages
            if !copies.isEmpty || !extendsStrictly {
                assistant.primaryNotice = .diverged(copyIDs: copies)
            }
        }
        if let id = selectedID, session(id) == nil { selectedID = primary?.id ?? sessions.first?.id }
        try reconcileScope(deferred: deferred)
        // Summaries of sessions that no longer exist are dropped; others are
        // revalidated by digest and coverage every time they are used.
        let live = Set(sessions.map(\.id))
        assistant.compactions.removeAll { !live.contains($0.sessionID) }
        return result.deferred
    }

    /// A root stays known only while its whole segment in its source session
    /// still has the recorded digest; same ID with different content, a
    /// missing source or a new remote segment becomes unknown. Masks are
    /// keyed by root/message ID and keep covering every copy.
    mutating func reconcileScope(deferred: Set<UUID>) throws {
        let existing = Set(sessions.flatMap { $0.messages.map(\.id) })
        try assistant.scopeIndex.prune(existing: existing)
        for rootID in Array(assistant.scopeIndex.allRootIDs) {
            guard let root = assistant.scopeIndex.scopedRoot(rootID), root.verified,
                  !deferred.contains(root.sourceSessionID) else { continue }
            let digest = try? Self.segmentDigest(segment(root: rootID, in: root.sourceSessionID))
            if session(root.sourceSessionID) == nil || digest != root.segmentDigest {
                try assistant.scopeIndex.updateRoot(rootID) { $0.verified = false }
            }
        }
    }

    /// Explicit recovery choice for a missing, deleted or diverged primary:
    /// an existing session becomes the primary line. Its roots must still
    /// match their digests to stay known; old summaries revalidate.
    mutating func choosePrimary(_ id: UUID) throws {
        guard session(id) != nil else { throw HistoryEditError.missingSession }
        guard assistant.pendingNext == nil || assistant.pendingNext?.sessionID == id else {
            throw HistoryEditError.invalid("请先处理待处理请求，再更换主线。")
        }
        assistant.primarySessionID = id
        assistant.primaryNotice = nil
        selectedID = id
        try editSession(id) { $0.conflictOf = nil; $0.metadataUpdatedAt = Date() }
        try reconcileScope(deferred: [])
    }

    /// Explicit recovery choice: a new empty primary line. Memory is kept; the
    /// old line stays in tasks/history and its summaries stop applying.
    mutating func startNewPrimary(selection: ModelSelection?) throws {
        guard assistant.pendingNext == nil else { throw HistoryEditError.invalid("请先处理待处理请求，再新建主线。") }
        let fresh = ChatSession(selection: selection, title: ChatSession.primaryTitle)
        sessions.insert(fresh, at: 0)
        assistant.compactions.removeAll { $0.sessionID == assistant.primarySessionID }
        assistant.primarySessionID = fresh.id
        assistant.primaryNotice = nil
        selectedID = fresh.id
    }
}
