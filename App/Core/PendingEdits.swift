import AgentKit
import Foundation

nonisolated enum PendingError: LocalizedError, Equatable {
    case alreadyPending
    case noPending
    case notDetached
    case notPromoted
    case alreadyAuthorized
    var errorDescription: String? {
        switch self {
        case .alreadyPending: "已有一个待处理请求；请先处理它，新输入保留在草稿中。"
        case .noPending: "没有待处理请求。"
        case .notDetached: "待处理请求已进入历史，不能移回草稿。"
        case .notPromoted: "该请求尚未进入历史。"
        case .alreadyAuthorized: "该请求可能已开始执行，不能以同一请求继续；请发送新消息。"
        }
    }
}

/// What restart may offer for the single pending request.
nonisolated enum PendingResumeOption: Equatable, Sendable {
    /// Not in history yet: continue with a freshly resolved configuration,
    /// move back to the empty draft, or delete.
    case detached
    /// In history and provably never authorized: continue with the same ID.
    case promotedUnstarted(promptID: UUID)
    /// No pending request.
    case none
}

/// Pure transitions of the primary line's one pending-next request. Each is a
/// single history write; promotion keeps the original message and ID.
nonisolated extension HistoryFile {
    /// Accepting "next" stores the original text detached from history.
    mutating func acceptPending(_ pending: PendingNext) throws {
        guard assistant.pendingNext == nil else { throw PendingError.alreadyPending }
        guard case .detached(let message, let attachments) = pending.prompt else { throw PendingError.notDetached }
        try HistoryCodec.validateDetached(message, attachments: attachments)
        guard session(pending.sessionID) != nil else { throw HistoryEditError.missingSession }
        assistant.pendingNext = pending
    }

    /// detached → promoted: the original prompt (same ID) enters history with
    /// its attachments and root, in this one write.
    mutating func activatePending(scope: WorkScope) throws -> (prompt: AgentTranscriptMessage, attachments: [ChatAttachment]) {
        guard var pending = assistant.pendingNext else { throw PendingError.noPending }
        guard case .detached(let message, let attachments) = pending.prompt else { throw PendingError.notDetached }
        try acceptRoot(message, attachments: attachments, in: pending.sessionID, scope: scope)
        try editSession(pending.sessionID) { $0.state = .queued; $0.detail = "" }
        pending.prompt = .promoted(promptID: message.id)
        pending.state = .queued
        assistant.pendingNext = pending
        return (message, attachments)
    }

    mutating func holdPending(_ reason: String) throws {
        guard assistant.pendingNext != nil else { throw PendingError.noPending }
        assistant.pendingNext?.state = .held(reason: reason)
    }

    /// A promoted request that never received its startup permit is given
    /// up: the original stays in history, marked unstarted and excluded from
    /// automatic context; the slot is released.
    mutating func abandonUnstarted(promptID: UUID, detail: String) throws {
        guard case .promoted(let id)? = assistant.pendingNext?.prompt, id == promptID,
              let pending = assistant.pendingNext else { throw PendingError.notPromoted }
        guard assistant.scopeIndex.scopedRoot(promptID)?.dispatchAuthorized == false else { throw PendingError.alreadyAuthorized }
        try assistant.scopeIndex.updateRoot(promptID) { $0.abandonedUnstarted = true }
        assistant.pendingNext = nil
        try editSession(pending.sessionID) { $0.state = .interrupted; $0.detail = detail }
    }

    /// Removes a detached request (cancel, move back to an empty draft or
    /// delete). Nothing executed belongs to it.
    mutating func removeDetachedPending() throws -> (message: AgentTranscriptMessage, attachments: [ChatAttachment]) {
        guard case .detached(let message, let attachments)? = assistant.pendingNext?.prompt else { throw PendingError.notDetached }
        assistant.pendingNext = nil
        return (message, attachments)
    }

    /// Explicit continue: the request goes back to the queue with the
    /// configuration and project confirmed now. A promoted one must still be
    /// unauthorized; its root moves to the confirmed scope in the same write
    /// (registered reads, original ID/text and masks unchanged), so the run and
    /// its results belong to the scope they actually use.
    mutating func requeuePending(selection: ModelSelection, workspaceID: UUID?, backend: PhoneBackendKind,
                                 clipboardAllowed: Bool, ordinal: UInt64) throws {
        guard var pending = assistant.pendingNext else { throw PendingError.noPending }
        if case .promoted(let id) = pending.prompt {
            guard assistant.scopeIndex.scopedRoot(id)?.dispatchAuthorized == false else { throw PendingError.alreadyAuthorized }
            try assistant.scopeIndex.updateRoot(id) { $0.scope = WorkScope(workspaceID: workspaceID) }
        }
        pending.selection = selection; pending.workspaceID = workspaceID; pending.backend = backend
        pending.clipboardAllowed = clipboardAllowed; pending.acceptedOrdinal = ordinal; pending.state = .queued
        assistant.pendingNext = pending
    }

    var pendingResumeOption: PendingResumeOption {
        switch assistant.pendingNext?.prompt {
        case nil: .none
        case .detached?: .detached
        case .promoted(let id)?:
            assistant.scopeIndex.scopedRoot(id)?.dispatchAuthorized == false ? .promotedUnstarted(promptID: id) : .none
        }
    }
}
