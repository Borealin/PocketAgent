import AgentKit
import Foundation

extension ChatController {
    // MARK: Primary turn support

    func assistantSupport(for job: ChatJob) -> AssistantTurnSupport {
        AssistantTurnSupport(owner: owner, sessionID: job.sessionID, promptID: job.prompt.id, scope: job.scope,
                             references: job.references, config: job.config, epoch: job.epoch,
                             isActive: { [weak self, weak job] in
                                 guard let self, let job else { return false }
                                 return self.jobs[job.sessionID] === job && !job.cancelled && !job.revoked && !job.terminal
                             })
    }

    /// Memory scope the composer's commands and the panel default to: the
    /// primary line's project, else global.
    var defaultMemoryScope: MemoryScope {
        file.primary?.workspaceID.map(MemoryScope.workspace) ?? .global
    }

    // MARK: Explicit memory writes (host only)

    /// `记住：<原文>` / `/remember <原文>`: the exact remainder is saved in one
    /// write with its receipt; no run starts and nothing enters the
    /// conversation, a tool group or portable data. A failed write keeps the draft.
    func rememberCommand(_ command: MemoryCommand, sessionID: UUID) {
        var receipt: MemoryReceipt?
        let ok = transact { file in
            receipt = try file.applyMemoryEdit(.add(target: .memory, scope: self.defaultMemoryScope, content: command.content,
                                                    origin: .command, sourceRootPromptIDs: [], sourceMessageIDs: []))
            try file.editSession(sessionID) { $0.draft = "" }
        }
        if ok, let receipt { memoryNotice = receipt.result }
    }

    // MARK: Remember mode (host only)

    var canRemember: Bool {
        guard storageReady, let selected, isPrimary(selected.id) else { return false }
        return !selected.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Opens the prefilled editor for the primary composer's text. No run,
    /// background task, phone action or tool group; an exact `记住：` command
    /// still saves directly.
    func beginRemember() {
        guard canRemember, let session = selected else { return }
        notice = ""
        if let command = MemoryCommand.parse(session.draft) { rememberCommand(command, sessionID: session.id); return }
        rememberRequest = composerDraft(session)
    }

    private func composerDraft(_ session: ChatSession) -> ComposerDraft {
        ComposerDraft(sessionID: session.id, text: session.draft, draftRevision: draftRevisions[session.id, default: 0])
    }

    /// The editor's explicit save (see `HistoryFile.commitComposerMemory`).
    /// A failure keeps the draft, the editor and its target/scope choice.
    func saveRemember(_ edit: UserMemoryEdit, request: ComposerDraft) -> MemoryReceipt? {
        guard let receipt = commitComposerMemory(edit, from: request) else { return nil }
        rememberMode = false
        return receipt
    }

    private func commitComposerMemory(_ edit: UserMemoryEdit, from draft: ComposerDraft) -> MemoryReceipt? {
        var receipt: MemoryReceipt?
        let revision = draftRevisions[draft.sessionID, default: 0]
        guard transact({ receipt = try $0.commitComposerMemory(edit, from: draft, draftRevision: revision) }) else { return nil }
        memoryNotice = receipt?.result ?? ""
        return receipt
    }

    // MARK: Natural-language edit/forget (host only)

    /// The primary line's current scope, for candidate lookup.
    private var primaryWorkScope: WorkScope { file.primary?.workspaceID.map(WorkScope.workspace) ?? .general }

    /// Recognises an explicit edit/forget request in the primary composer and
    /// shows candidates instead of sending. Nil when the text is not one.
    func beginMemoryIntent() -> Bool {
        guard let session = selected, isPrimary(session.id), storageReady,
              let intent = MemoryIntent.parse(session.draft) else { return false }
        notice = ""
        memoryIntent = MemoryIntentRequest(intent: intent, draft: composerDraft(session))
        return true
    }

    /// Recomputed from the latest ledger and the current scope on every read,
    /// so a correction, a forget or a scope switch shows at once.
    var intentCandidates: [MemoryRecord] {
        memoryIntent.map { $0.intent.candidates(in: assistant.memory, scope: primaryWorkScope) } ?? []
    }

    /// The prefilled editor's save for a picked candidate (CAS by the
    /// revision it was opened with).
    func saveIntentEdit(_ edit: UserMemoryEdit, request: MemoryIntentRequest) -> MemoryReceipt? {
        guard let receipt = commitComposerMemory(edit, from: request.draft) else { return nil }
        memoryIntent = nil
        return receipt
    }

    /// After the forget panel committed: the request's draft, if unchanged, is emptied.
    func settleIntent(_ request: MemoryIntentRequest) {
        let revision = draftRevisions[request.draft.sessionID, default: 0]
        transact { try $0.settleComposerDraft(request.draft, draftRevision: revision) }
        memoryIntent = nil
    }

    /// The user's choice: the text was not a memory request after all.
    func sendIntentAsMessage() {
        memoryIntent = nil
        send(asMessage: true)
    }

    /// One explicit panel or chip edit, CAS-checked against the shown revision.
    @discardableResult
    func editMemory(_ edit: UserMemoryEdit) -> MemoryReceipt? {
        var receipt: MemoryReceipt?
        guard transact({ receipt = try $0.applyMemoryEdit(edit) }) else { return nil }
        memoryNotice = receipt?.result ?? ""
        return receipt
    }

    /// A request that has not started yet but may still start: queued or
    /// preparing, or the pending request kept for an explicit decision.
    func isAwaitingStart(_ root: UUID) -> Bool {
        if jobs.values.contains(where: { $0.prompt.id == root && !$0.terminal }) { return true }
        if case .promoted(let id)? = assistant.pendingNext?.prompt { return id == root }
        return false
    }

    /// The primary turn the engine is executing (preparing or running), if any.
    var activePrimaryRoot: UUID? {
        let job = runningJob.flatMap { jobs[$0.sessionID] === $0 ? $0 : nil }
        return ForgetStopPolicy.activeRoot(primaryID: primaryID, runningSessionID: job?.sessionID,
                                           runningRoot: job?.prompt.id, terminal: job?.terminal ?? true)
    }

    func forgetPreview(_ entryIDs: [UUID]) -> ForgetPreview? {
        do { return try file.forgetPreview(entryIDs, activeRoot: activePrimaryRoot) }
        catch { notice = error.localizedDescription; return nil }
    }

    /// Commits the confirmed panel. A changed closure refuses and the panel
    /// refreshes. A hit active root stops that run's further effects; its
    /// original and already-happened results stay; a pending request is held.
    func commitForget(_ preview: ForgetPreview) -> Bool {
        let active = activePrimaryRoot
        var receipt: MemoryReceipt?
        do { try owner.transact { receipt = try $0.commitForget(preview, activeRoot: active) } }
        catch { notice = error.localizedDescription; return false }
        memoryNotice = receipt?.result ?? ""
        // Only the primary run the engine is executing is stopped, never another task.
        if preview.stopsActiveRoot, let job = runningJob, job.primary, job.prompt.id == active {
            job.revoked = true
            if assistant.pendingNext != nil { transact { try $0.holdPending("当前任务因遗忘停止；确认后再继续。") } }
            engine.cancel()
        }
        return true
    }

    // MARK: Clear the conversation, keep memory

    /// Why "清空对话，保留记忆" cannot run now, or nil. Covers this device's
    /// accepted, queued or preparing primary job and steering being settled,
    /// in addition to the history checks repeated in the transaction.
    var clearPrimaryBlocker: String? {
        guard storageReady else { return owner.health.message ?? "历史存储不可用，暂不能清空。" }
        if jobs[primaryID] != nil || settlingSteers > 0 { return ClearPrimaryError.busy.localizedDescription }
        return file.clearPrimaryBlocker()?.localizedDescription
    }

    /// One transaction: the assistant line becomes empty (see
    /// `HistoryFile.clearPrimaryConversation`); a failed write changes nothing.
    /// Memory stays; files no longer referenced are removed afterwards.
    func clearPrimaryConversation() {
        if let blocker = clearPrimaryBlocker { notice = blocker; return }
        let old = primaryID
        guard transact({ try $0.clearPrimaryConversation() }) else { return }
        referenceDrafts[old] = nil; visibleLimit[old] = nil; draftRevisions[old] = nil
        if old != primaryID { statuses[old] = nil }
        cancelImports(for: old)
        cleanupAttachments()
        memoryNotice = "已清空“你的助理”的对话；记忆已保留（\(assistant.memory.active.count) 条）。"
    }

    // MARK: Primary recovery (explicit only)

    func choosePrimary(_ id: UUID) {
        if transact({ try $0.choosePrimary(id) }) { notice = "已将所选会话设为助理主线。" }
    }

    func startNewPrimary() {
        if transact({ try $0.startNewPrimary(selection: self.providers.defaultSelection) }) {
            notice = "已建立新的空主线；记忆保留，原主线在任务/历史中。"
        }
    }

    // MARK: Explicit history references for the next primary request

    /// The user picks a message; the reference expands to the complete safe
    /// call/result window around it and records its content digest.
    func referenceForAssistant(sessionID: UUID, messageID: UUID) {
        guard let session = file.session(sessionID), let index = session.messages.firstIndex(where: { $0.id == messageID }) else { return }
        let root = file.assistant.scopeIndex.root(of: messageID)
        var start = index, end = index
        if let root {
            start = session.messages.firstIndex { file.assistant.scopeIndex.root(of: $0.id) == root } ?? index
            end = session.messages.lastIndex { file.assistant.scopeIndex.root(of: $0.id) == root } ?? index
        } else {
            while start > 0, session.messages[start].role == .tool { start -= 1 }
            while end + 1 < session.messages.count, session.messages[end + 1].role == .tool { end += 1 }
        }
        let window = Array(session.messages[start...end])
        guard AssistantContext.isSafeWindow(window), !window.contains(where: { file.assistant.scopeIndex.isMasked(message: $0.id) }),
              let digest = try? AssistantContext.referenceDigest(window) else {
            notice = "这段记录包含未完成的工具调用或已被遗忘，不能引用。"; return
        }
        let reference = HistoryReference(sessionID: sessionID, firstMessageID: window.first!.id, lastMessageID: window.last!.id,
                                         expectedContentDigest: digest)
        var list = referenceDrafts[primaryID] ?? []
        if !list.contains(reference) { list.append(reference) }
        referenceDrafts[primaryID] = Array(list.suffix(3))
        notice = "已引用到“你的助理”的下一条消息；只读取这段记录。"
    }

    func removeReference(_ reference: HistoryReference) {
        referenceDrafts[primaryID]?.removeAll { $0 == reference }
    }

    func referenceTitle(_ reference: HistoryReference) -> String {
        let title = file.session(reference.sessionID)?.title ?? "已删除的会话"
        let text = file.session(reference.sessionID)?.messages.first { $0.id == reference.firstMessageID }?.text ?? ""
        return "\(title)：\(text.prefix(16))"
    }
}
