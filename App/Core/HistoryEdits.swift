import AgentKit
import Foundation

nonisolated enum HistoryEditError: LocalizedError, Equatable {
    case missingSession
    case missingRoot
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .missingSession: "会话已不存在。"
        case .missingRoot: "请求的任务段不存在。"
        case .invalid(let detail): detail
        }
    }
}

/// Pure edits of one candidate history, applied inside the owner's
/// transaction or record so that messages, scope membership and run state
/// change in the same write.
nonisolated extension HistoryFile {
    mutating func editSession(_ id: UUID, touch: Bool = true, _ change: (inout ChatSession) throws -> Void) throws {
        guard let index = sessionIndex(id) else { throw HistoryEditError.missingSession }
        try change(&sessions[index])
        if touch { sessions[index].updatedAt = Date() }
    }

    /// The primary line without a model takes the Settings default. An
    /// existing selection is never replaced, and the fill is not an explicit
    /// metadata edit (a synchronized explicit choice still wins). Returns
    /// whether the primary changed.
    @discardableResult
    mutating func adoptDefaultSelection(_ selection: ModelSelection?) throws -> Bool {
        guard let selection, let primary, primary.selection == nil else { return false }
        try editSession(primary.id, touch: false) { $0.selection = selection }
        return true
    }

    /// A new root prompt and its scope are recorded in the same write. The
    /// root is not dispatch-authorized until the startup permit commits.
    mutating func acceptRoot(_ prompt: AgentTranscriptMessage, attachments: [ChatAttachment], in sessionID: UUID,
                             scope: WorkScope) throws {
        let message = ChatSession.forHistory(prompt)
        guard message.role == .user else { throw HistoryEditError.invalid("根请求必须是用户消息。") }
        try editSession(sessionID) { session in
            guard !session.messages.contains(where: { $0.id == message.id }) else {
                throw HistoryEditError.invalid("请求已在历史中。")
            }
            session.messages.append(message)
            if !attachments.isEmpty { session.attachments[message.id.uuidString] = attachments }
        }
        try assistant.scopeIndex.addRoot(message.id, ScopedRoot(
            scope: scope, sourceSessionID: sessionID, segmentDigest: try Self.segmentDigest([message]),
            dependencies: RootDependencies(), abandonedUnstarted: false, dispatchAuthorized: false, verified: true))
    }

    /// A run event (assistant reply, tool result, delivered steering) belongs
    /// to its job's root. Event order is authoritative; an existing ID is
    /// replaced in place, a new one is inserted before undelivered steering.
    mutating func appendEvent(_ message: AgentTranscriptMessage, to sessionID: UUID, root: UUID?,
                              before pending: Set<UUID> = [], attribution: String? = nil) throws {
        let message = ChatSession.forHistory(message)
        try editSession(sessionID) { session in
            if let index = session.messages.firstIndex(where: { $0.id == message.id }) { session.messages[index] = message }
            else {
                let index = session.messages.firstIndex { pending.contains($0.id) } ?? session.messages.endIndex
                session.messages.insert(message, at: index)
            }
            if let attribution { session.attributions[message.id.uuidString] = attribution }
        }
        if let root, assistant.scopeIndex.scopedRoot(root) != nil {
            try assistant.scopeIndex.addMember(message.id, root: root)
            try refreshSegment(root)
        }
    }

    /// Moves a delivered steering message to its delivery position.
    mutating func deliverSteering(_ message: AgentTranscriptMessage, to sessionID: UUID, root: UUID?,
                                  before pending: Set<UUID>) throws {
        try editSession(sessionID, touch: false) { $0.messages.removeAll { $0.id == message.id } }
        try appendEvent(message, to: sessionID, root: root, before: pending)
    }

    mutating func refreshSegment(_ root: UUID) throws {
        guard let scoped = assistant.scopeIndex.scopedRoot(root) else { throw HistoryEditError.missingRoot }
        let digest = try Self.segmentDigest(segment(root: root, in: scoped.sourceSessionID))
        try assistant.scopeIndex.updateRoot(root) { $0.segmentDigest = digest }
    }

    /// Real messages of `root` in `sessionID`, in event order. Roots are
    /// searched from the end, where recent work lives.
    func segment(root: UUID, in sessionID: UUID) -> [AgentTranscriptMessage] {
        guard let session = session(sessionID),
              let start = session.messages.lastIndex(where: { $0.id == root }) else { return [] }
        let index = assistant.scopeIndex
        return session.messages[start...].filter { index.root(of: $0.id) == root }
    }

    static func segmentDigest(_ messages: [AgentTranscriptMessage]) throws -> String {
        try CanonicalDigest.digest(try messages.map { try MessageDigestDTO($0) }, domain: "segment")
    }

    /// The startup permit: from this commit on, the run may dispatch model
    /// and phone requests; restart treats it as possibly interrupted work.
    /// The run's frozen scope must be the root's recorded scope.
    mutating func commitDispatchPermit(root: UUID, sessionID: UUID, scope: WorkScope) throws {
        guard let scoped = assistant.scopeIndex.scopedRoot(root), scoped.sourceSessionID == sessionID else {
            throw HistoryEditError.missingRoot
        }
        guard !scoped.abandonedUnstarted else { throw HistoryEditError.invalid("该请求已放弃，不能启动。") }
        guard scoped.scope == scope else { throw HistoryEditError.invalid("请求记录的项目与本次执行的项目不一致，任务未开始。") }
        try assistant.scopeIndex.updateRoot(root) { $0.dispatchAuthorized = true }
        if case .promoted(let id)? = assistant.pendingNext?.prompt, id == root { assistant.pendingNext = nil }
        try editSession(sessionID) { $0.state = .running; $0.detail = "" }
    }

    /// Launch recovery: active work becomes interrupted and every pending
    /// request needs an explicit decision. Nothing is rescheduled.
    mutating func recoverAfterLaunch() {
        for index in sessions.indices where [.queued, .running, .cancelling].contains(sessions[index].state) {
            sessions[index].state = .interrupted
            sessions[index].detail = HistoryCodec.interruptedDetail
        }
        if assistant.pendingNext != nil { assistant.pendingNext?.state = .needsResume }
        if primary == nil, assistant.primaryNotice == nil { assistant.primaryNotice = .missing }
    }

    /// All attachment files the file still references.
    var referencedAttachmentIDs: Set<UUID> {
        var keep = Set(sessions.flatMap(\.referencedAttachmentIDs))
        if case .detached(_, let attachments)? = assistant.pendingNext?.prompt { keep.formUnion(attachments.map(\.id)) }
        return keep
    }

    /// The selected session, never an arbitrary first one for the primary line.
    var isPrimaryAvailable: Bool { primary != nil && assistant.primaryNotice == nil }
}
