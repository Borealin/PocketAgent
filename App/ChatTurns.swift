import AgentKit
import Foundation

/// Everything a turn needs, captured when it is accepted. Not persisted: the
/// credential lives only in memory; a restarted pending request resolves again.
struct FrozenTurn {
    let config: RunConfiguration
    let workspace: WorkspaceSnapshot?
    let backend: PhoneBackendKind
    let clipboardAllowed: Bool
    let references: [HistoryReference]
}

enum JobOrigin {
    /// Ordinary send: a never-started turn may give its draft back.
    case send(DraftSnapshot)
    /// Activated pending-next request: failure before the permit holds it.
    case pending
    /// Explicit same-ID continuation of an unauthorized promoted request.
    case resume
}

/// Where composer input goes for the selected conversation.
enum InputTarget { case send, steer, next }

@MainActor
final class ChatJob {
    let sessionID: UUID
    let epoch: UInt64
    let ordinal: UInt64
    /// History form of the prompt (no image bytes).
    let prompt: AgentTranscriptMessage
    let promptAttachments: [ChatAttachment]
    let origin: JobOrigin
    /// Frozen at acceptance; later provider or selection edits do not reach it.
    let config: RunConfiguration
    let phoneBackend: PhoneBackendKind
    let clipboardAllowed: Bool
    /// Project directory frozen at acceptance, like the model configuration.
    let workspace: WorkspaceSnapshot?
    let scope: WorkScope
    let references: [HistoryReference]
    let primary: Bool
    /// The startup permit committed; from here on nothing is restored or resumed.
    var permitted = false
    /// AgentKit emitted runStarted.
    var started = false
    var runID: UUID?
    var partial: AgentTranscriptMessage?
    var pendingSteering: Set<UUID> = []
    /// Accepted steering not yet settled, with its attachment references (kept from GC).
    var steerLeases: [UUID: [ChatAttachment]] = [:]
    var steerCalls = 0
    var ready = false
    var cancelled = false
    var terminal = false
    /// An explicit forget masked this run's own root: no further effects.
    var revoked = false

    init(sessionID: UUID, epoch: UInt64, ordinal: UInt64, prompt: AgentTranscriptMessage, attachments: [ChatAttachment],
         origin: JobOrigin, frozen: FrozenTurn, primary: Bool) {
        self.sessionID = sessionID; self.epoch = epoch; self.ordinal = ordinal
        self.prompt = ChatSession.forHistory(prompt); promptAttachments = attachments; self.origin = origin
        config = frozen.config; phoneBackend = frozen.backend; clipboardAllowed = frozen.clipboardAllowed
        workspace = frozen.workspace; scope = WorkScope(workspaceID: frozen.workspace?.id)
        references = frozen.references; self.primary = primary
    }

    var referencedAttachmentIDs: Set<UUID> {
        Set(promptAttachments.map(\.id) + steerLeases.values.joined().map(\.id))
    }
    var isPendingOrigin: Bool { if case .send = origin { false } else { true } }
}

extension ChatController {
    // MARK: Input

    func inputTarget(_ id: UUID) -> InputTarget {
        guard jobs[id] != nil else { return .send }
        return isPrimary(id) && !steerPrimary ? .next : .steer
    }

    var canSend: Bool {
        guard storageReady, let selected, !isImporting(selected.id),
              !selected.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selected.draftAttachments.isEmpty
        else { return false }
        if isPrimary(selected.id) {
            // An exact memory command never starts a run, so it is always allowed.
            if MemoryCommand.parse(selected.draft) != nil { return true }
            guard assistant.primaryNotice == nil else { return false }
            // One pending request occupies the slot; new input stays in the draft.
            switch inputTarget(selected.id) {
            case .send, .next: return assistant.pendingNext == nil
            case .steer: break
            }
        }
        return jobs[selected.id].map { $0.ready && $0.steerCalls == 0 && !$0.cancelled && !$0.terminal } ?? true
    }

    /// `textOnly` is the user's explicit choice after a text-only model
    /// warning: the text is sent and the images stay in the draft.
    func send(textOnly: Bool = false) {
        guard canSend, let session = selected else { return }
        let text = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = textOnly ? [] : session.draftAttachments
        if textOnly, text.isEmpty { return }
        notice = ""
        if let command = MemoryCommand.parse(session.draft), isPrimary(session.id) {
            rememberCommand(command, sessionID: session.id); return
        }
        switch inputTarget(session.id) {
        case .steer: if let job = jobs[session.id] { steer(job, session: session, text: text, images: images) }
        case .next: acceptNext(session: session, text: text, images: images, textOnly: textOnly)
        case .send: acceptSend(session: session, text: text, images: images, textOnly: textOnly)
        }
    }

    /// Captures provider, endpoint, format, model, capability, key, budget,
    /// project, backend and clipboard policy now. Nil after reporting why not.
    func freeze(selection: ModelSelection?, workspaceID: UUID?, sessionID: UUID, text: String,
                images: [ChatAttachment], references: [HistoryReference] = []) -> FrozenTurn? {
        let config: RunConfiguration
        do { config = try providers.configuration(for: selection) }
        catch { notice = error.localizedDescription; return nil }
        switch ImageCapability.check(supportsImages: config.supportsImages, hasText: !text.isEmpty, imageCount: images.count) {
        case .ok: break
        case .warnDropImages, .blockImageOnly:
            imageWarning = ImageWarning(sessionID: sessionID, modelLabel: config.label,
                                        verdict: ImageCapability.check(supportsImages: false, hasText: !text.isEmpty,
                                                                       imageCount: images.count))
            return nil
        }
        guard images.allSatisfy(attachmentFiles.exists) else { notice = AttachmentError.missingFile.localizedDescription; return nil }
        // A selected project that no longer exists is an explicit problem, never a silent fallback.
        var workspace: WorkspaceSnapshot?
        if let id = workspaceID {
            guard let snapshot = workspaces.snapshot(id) else {
                notice = "本会话选择的项目已不存在；请重新选择项目或选择“不使用项目”。"; return nil
            }
            workspace = snapshot
        }
        return FrozenTurn(config: config, workspace: workspace, backend: DeviceSettings.phoneBackend,
                          clipboardAllowed: DeviceSettings.clipboardAllowed, references: references)
    }

    func takeOrdinal() -> UInt64 { nextOrdinal += 1; return nextOrdinal }

    private func makeJob(session: UUID, prompt: AgentTranscriptMessage, attachments: [ChatAttachment], origin: JobOrigin,
                         frozen: FrozenTurn, ordinal: UInt64) -> ChatJob? {
        nextEpoch += 1
        let job = ChatJob(sessionID: session, epoch: nextEpoch, ordinal: ordinal, prompt: prompt, attachments: attachments,
                          origin: origin, frozen: frozen, primary: isPrimary(session))
        do { owner.barrier.open(epoch: job.epoch, seed: [job.prompt.id: try CommittedMessage(job.prompt, imageIDs: attachments.map(\.id))]) }
        catch { notice = error.localizedDescription; return nil }
        return job
    }

    private func enqueue(_ job: ChatJob) {
        jobs[job.sessionID] = job
        statuses[job.sessionID] = nil
        queuedPhone.append(job)
        queuedPhone.sort { $0.ordinal < $1.ordinal }
        drainPhone()
    }

    private func acceptSend(session: ChatSession, text: String, images: [ChatAttachment], textOnly: Bool) {
        if isPrimary(session.id), assistant.pendingNext != nil { notice = PendingError.alreadyPending.localizedDescription; return }
        guard let frozen = freeze(selection: session.selection, workspaceID: session.workspaceID, sessionID: session.id,
                                  text: text, images: images, references: referenceDrafts[session.id] ?? []) else { return }
        let message = AgentTranscriptMessage(role: .user, text: text)
        let draft = DraftSnapshot(text: session.draft, attachments: session.draftAttachments,
                                  revision: draftRevisions[session.id, default: 0])
        persist()
        // History, membership and queued state are one write; the job is
        // published only after it succeeds. A failed write keeps the draft.
        let ok = transact { file in
            try file.acceptRoot(message, attachments: images, in: session.id, scope: WorkScope(workspaceID: frozen.workspace?.id))
            try file.editSession(session.id) {
                $0.draft = ""; $0.detail = ""; $0.state = .queued
                if !textOnly { $0.draftAttachments = [] }
                if $0.title == ChatSession.defaultTitle { $0.title = text.isEmpty ? "图片" : String(text.prefix(20)) }
            }
        }
        guard ok, let job = makeJob(session: session.id, prompt: message, attachments: images, origin: .send(draft),
                                    frozen: frozen, ordinal: takeOrdinal()) else { return }
        referenceDrafts[session.id] = nil
        enqueue(job)
    }

    // MARK: Pending next (primary line)

    /// While the primary line works, a new request waits as the single
    /// pending next. Its original text is stored detached from history.
    private func acceptNext(session: ChatSession, text: String, images: [ChatAttachment], textOnly: Bool) {
        guard assistant.pendingNext == nil else { notice = PendingError.alreadyPending.localizedDescription; return }
        guard let selection = session.selection else { notice = ProviderError.noSelection.localizedDescription; return }
        guard let frozen = freeze(selection: selection, workspaceID: session.workspaceID, sessionID: session.id,
                                  text: text, images: images, references: referenceDrafts[session.id] ?? []) else { return }
        let message = AgentTranscriptMessage(role: .user, text: text)
        let pending = PendingNext(sessionID: session.id, prompt: .detached(message: message, attachments: images),
                                  selection: selection, workspaceID: frozen.workspace?.id, backend: frozen.backend,
                                  clipboardAllowed: frozen.clipboardAllowed, acceptedOrdinal: takeOrdinal(),
                                  state: .queued, references: frozen.references, acceptedAt: Date())
        persist()
        let ok = transact { file in
            try file.acceptPending(pending)
            try file.editSession(session.id) { $0.draft = ""; if !textOnly { $0.draftAttachments = [] } }
        }
        guard ok else { return }
        referenceDrafts[session.id] = nil
        pendingFrozen = frozen
        pendingStopEpoch = stopEpoch
        advancePendingIfReady()
    }

    /// Activates the pending request when the primary line is free and the
    /// previous turn finished normally; otherwise it stays queued/held.
    func advancePendingIfReady() {
        guard storageReady, let pending = assistant.pendingNext, pending.state == .queued,
              case .detached = pending.prompt, jobs[pending.sessionID] == nil, settlingSteers == 0,
              assistant.primaryNotice == nil else { return }
        guard foreground else { return }
        guard let frozen = pendingFrozen, stopEpoch == pendingStopEpoch else {
            transact { try $0.holdPending(pendingFrozen == nil ? "需要重新确认模型与项目后继续" : "已停止；确认后再继续") }
            return
        }
        if let workspace = frozen.workspace, workspaces.snapshot(workspace.id)?.root != workspace.root {
            transact { try $0.holdPending("请求冻结的项目已不存在，未开始。") }
            return
        }
        var activated: (prompt: AgentTranscriptMessage, attachments: [ChatAttachment])?
        guard transact({ activated = try $0.activatePending(scope: WorkScope(workspaceID: frozen.workspace?.id)) }),
              let activated,
              let job = makeJob(session: pending.sessionID, prompt: activated.prompt, attachments: activated.attachments,
                                origin: .pending, frozen: frozen, ordinal: pending.acceptedOrdinal) else { return }
        pendingFrozen = nil
        enqueue(job)
    }

    /// Explicit continuation of a held or restarted pending request with the
    /// conversation's current selection, project and freshly resolved key.
    func resumePending() {
        guard storageReady, let pending = assistant.pendingNext, jobs[pending.sessionID] == nil,
              assistant.primaryNotice == nil, let session = file.session(pending.sessionID) else { return }
        let text: String, attachments: [ChatAttachment]
        switch pending.prompt {
        case .detached(let message, let files): text = message.text; attachments = files
        case .promoted(let id):
            guard file.pendingResumeOption == .promotedUnstarted(promptID: id),
                  let message = session.messages.first(where: { $0.id == id }) else {
                notice = PendingError.alreadyAuthorized.localizedDescription; return
            }
            text = message.text; attachments = session.attachments(of: message)
        }
        guard let selection = session.selection,
              let frozen = freeze(selection: selection, workspaceID: session.workspaceID, sessionID: session.id,
                                  text: text, images: attachments, references: pending.references) else { return }
        let ordinal = takeOrdinal()
        guard transact({ try $0.requeuePending(selection: selection, workspaceID: frozen.workspace?.id, backend: frozen.backend,
                                              clipboardAllowed: frozen.clipboardAllowed, ordinal: ordinal) }) else { return }
        switch pending.prompt {
        case .detached:
            pendingFrozen = frozen; pendingStopEpoch = stopEpoch
            advancePendingIfReady()
        case .promoted(let id):
            // Same ID, no second append; prior is everything before it.
            guard let message = session.messages.first(where: { $0.id == id }),
                  let job = makeJob(session: session.id, prompt: message, attachments: attachments, origin: .resume,
                                    frozen: frozen, ordinal: ordinal) else { return }
            enqueue(job)
        }
    }

    /// Gives up the pending request: a detached one is deleted; a promoted,
    /// unauthorized one keeps its original text marked as not started.
    func discardPending() {
        guard let pending = assistant.pendingNext, jobs[pending.sessionID] == nil else { return }
        switch pending.prompt {
        case .detached: if transact({ _ = try $0.removeDetachedPending() }) { pendingFrozen = nil }
        case .promoted(let id): transact { try $0.abandonUnstarted(promptID: id, detail: "已放弃未开始的请求。") }
        }
        cleanupAttachments()
        // After the caller's settlement: drain, decide pending advancement,
        // and only then let idle observers (deferred sync) run.
        Task { @MainActor [weak self] in
            guard let self else { return }
            drainPhone(); advancePendingIfReady(); notifyIdleIfNeeded()
        }
    }

    /// Moves a detached pending request back into an empty draft.
    func movePendingToDraft() {
        guard let pending = assistant.pendingNext, case .detached = pending.prompt,
              let session = file.session(pending.sessionID), session.draft.isEmpty, session.draftAttachments.isEmpty else {
            notice = "只能把尚未进入历史的请求移回空草稿。"; return
        }
        if transact({ file in
            let removed = try file.removeDetachedPending()
            try file.editSession(pending.sessionID) { $0.draft = removed.message.text; $0.draftAttachments = removed.attachments }
        }) {
            pendingFrozen = nil
            noteDraftEdit(pending.sessionID)
        }
    }

    // MARK: Steering

    private func steer(_ job: ChatJob, session: ChatSession, text: String, images: [ChatAttachment]) {
        guard let runtime = engine.activeAgentRuntime, phoneSessionID == job.sessionID, job.permitted else {
            notice = "本轮尚未开始执行，暂不能追加指令。"; return
        }
        if !images.isEmpty, !job.config.supportsImages {
            notice = "本轮模型 \(job.config.label) 不接收图片；图片保留在草稿中，可移除后追加文字，或在本轮结束后换用支持图片的模型。"
            return
        }
        let hydrated: [AgentImageAttachment]
        do { hydrated = try AttachmentHydration.images(images, load: attachmentFiles.data) }
        catch { notice = error.localizedDescription; return }
        let message = AgentTranscriptMessage(role: .user, text: text, images: hydrated)
        // Lease before the await: attachment references and root ownership
        // exist even if delivery arrives before steer returns.
        job.steerLeases[message.id] = images
        job.steerCalls += 1
        settlingSteers += 1
        let draftBefore = session.draft
        Task {
            let accepted = await runtime.steer(message)
            job.steerCalls -= 1
            settlingSteers -= 1
            defer { objectWillChange.send(); advancePendingIfReady() }
            guard accepted else {
                job.steerLeases[message.id] = nil
                if jobs[job.sessionID] === job { owner.stage { try? $0.editSession(job.sessionID) { $0.detail = "本轮已结束，请再次发送以开始下一轮。" } } }
                return
            }
            // Whichever of this return or steeringDelivered records first creates the entry.
            let recorded = file.session(job.sessionID)?.messages.contains { $0.id == message.id } ?? true
            if !recorded {
                job.pendingSteering.insert(message.id)
                recordSteering(job, message, delivered: false)
            }
            let sent = Set(images.map(\.id))
            transact { file in
                try file.editSession(job.sessionID) {
                    if $0.draft == draftBefore { $0.draft = "" }
                    $0.draftAttachments.removeAll { sent.contains($0.id) }
                    $0.detail = "追加指令将在下一轮进入模型上下文。"
                }
            }
        }
    }

    /// Records accepted or delivered steering under the job's root, with its
    /// attachment metadata, in one write; idempotent by message ID.
    private func recordSteering(_ job: ChatJob, _ message: AgentTranscriptMessage, delivered: Bool) {
        let stored = ChatSession.forHistory(message)
        let attachments = job.steerLeases[message.id] ?? []
        let commit = try? CommittedMessage(stored, imageIDs: attachments.map(\.id))
        owner.record(commit: commit.map { .init(epoch: job.epoch, messages: [stored.id: $0]) }) { file in
            if delivered {
                try file.deliverSteering(stored, to: job.sessionID, root: job.prompt.id, before: job.pendingSteering)
            } else if !(file.session(job.sessionID)?.messages.contains { $0.id == stored.id } ?? false) {
                try file.appendEvent(stored, to: job.sessionID, root: job.prompt.id, before: job.pendingSteering)
            }
            if !attachments.isEmpty {
                try file.editSession(job.sessionID, touch: false) { $0.attachments[stored.id.uuidString] = attachments }
            }
        }
        if delivered { job.steerLeases[message.id] = nil }
    }

    // MARK: Queue and start

    func drainPhone() {
        guard foreground, !engine.busy, phoneSessionID == nil, !queuedPhone.isEmpty else { return }
        let job = queuedPhone.removeFirst()
        guard !job.cancelled, jobs[job.sessionID] === job else { drainPhone(); return }
        start(job)
    }

    private func start(_ job: ChatJob) {
        // The frozen project must still exist; it is never swapped for another.
        if let workspace = job.workspace, workspaces.snapshot(workspace.id)?.root != workspace.root {
            notStarted(job, "本轮选择的项目已不存在，任务未开始。", cancelled: false); return
        }
        // Image bytes are read only now, from the frozen references.
        let promptImages: [AgentImageAttachment]
        do { promptImages = try AttachmentHydration.images(job.promptAttachments, load: attachmentFiles.data) }
        catch { notStarted(job, error.localizedDescription, cancelled: false); return }
        guard let session = file.session(job.sessionID),
              let promptIndex = session.messages.firstIndex(where: { $0.id == job.prompt.id }) else {
            notStarted(job, "请求已不在历史中，任务未开始。", cancelled: false); return
        }
        let before = Array(session.messages[..<promptIndex])
        let prior = AttachmentHydration.context(before, attachments: session.attachments,
                                                supportsImages: job.config.supportsImages, load: attachmentFiles.data)
        phoneSessionID = job.sessionID
        runningJob = job
        statuses[job.sessionID] = ExecutionStatus(modelLabel: job.config.label)
        let gates = TurnGates(epoch: job.epoch, barrier: owner.barrier, promptID: job.prompt.id,
                              permit: { [weak self, weak job] in
                                  guard let self, let job else { throw CancellationError() }
                                  try self.commitPermit(job)
                              },
                              effectsBlocked: { [weak self, weak job] in
                                  guard let self, let job else { return "本轮已结束。" }
                                  return TurnEffectPolicy.blocked(storage: self.owner.health, isCurrent: self.jobs[job.sessionID] === job,
                                                                  isRunning: self.runningJob === job, cancelled: job.cancelled || job.revoked,
                                                                  terminal: job.terminal)
                              },
                              assistant: job.primary ? assistantSupport(for: job) : nil)
        engine.beginAgent(goal: job.prompt.text, images: promptImages, config: job.config, workspace: job.workspace,
            backend: job.phoneBackend, clipboardAllowed: job.clipboardAllowed,
            conversationID: job.sessionID, promptID: job.prompt.id, priorMessages: prior, gates: gates,
            onEvent: { [weak self, weak job] event, status in
                guard let self, let job else { return }; handle(event, status: status, job: job)
            }, onStatus: { [weak self, weak job] status in
                // Script phone actions update progress only; they add no transcript message.
                guard let self, let job, jobs[job.sessionID] === job else { return }
                statuses[job.sessionID] = status
            }, onFinished: { [weak self, weak job] successful, cleanupWarning, status in
                guard let self, let job else { return }
                finished(job, successful: successful, cleanupWarning: cleanupWarning, status: status)
            })
    }

    /// The startup permit, before `runtime.start` and any main model or phone
    /// request: clears a promoted receipt, authorizes the root and marks the
    /// session running in one write. Failure means the turn never starts.
    func commitPermit(_ job: ChatJob) throws {
        guard jobs[job.sessionID] === job, runningJob === job, !job.cancelled, !job.terminal else { throw CancellationError() }
        try owner.transact { try $0.commitDispatchPermit(root: job.prompt.id, sessionID: job.sessionID) }
        job.permitted = true
    }

    private func finished(_ job: ChatJob, successful: Bool, cleanupWarning: String, status: ExecutionStatus) {
        // A late completion of a job that is no longer current changes nothing.
        guard jobs[job.sessionID] === job else {
            if runningJob === job { runningJob = nil; phoneSessionID = nil }
            return
        }
        if runningJob === job { runningJob = nil; phoneSessionID = nil }
        statuses[job.sessionID] = status
        if !job.permitted {
            // Nothing was dispatched for this request.
            let reason = job.revoked ? ContextSourceRevoked().errorDescription : status.failure
            notStarted(job, reason ?? "本轮未开始。", cancelled: job.cancelled, warning: cleanupWarning)
        } else {
            let reason = (status.failure.map { "原因：\($0)" } ?? "").trimmingCharacters(in: .whitespaces)
            let state: ChatState = successful ? .completed : (job.cancelled ? .interrupted : .failed)
            finish(job, state: state, detail: ([successful ? "" : (job.cancelled ? "已取消。" : "本轮未完成，请发送新消息继续；已执行的动作不会重放。"),
                                               successful || job.cancelled ? "" : reason, cleanupWarning]
                .filter { !$0.isEmpty }).joined(separator: " "))
            if job.primary { settlePendingAfterPrimaryTurn(successful: successful, stopEpochAtFinish: stopEpoch) }
        }
    }

    /// A primary turn ended: the pending request may advance only after a
    /// completed turn in the foreground with no Stop since it was accepted.
    private func settlePendingAfterPrimaryTurn(successful: Bool, stopEpochAtFinish: UInt64) {
        guard let pending = assistant.pendingNext, pending.state == .queued, case .detached = pending.prompt else { return }
        switch PendingAdvancePolicy.afterPrimaryTurn(successful: successful, foreground: foreground,
                                                      stopEpochAtAccept: pendingStopEpoch, stopEpochNow: stopEpochAtFinish) {
        case .advance: break
        case .hold(let reason): transact { try $0.holdPending(reason) }
        }
    }

    /// Idle observers (deferred sync) run only once no job remains, after
    /// pending advancement had its chance to queue the next job.
    func notifyIdleIfNeeded() {
        guard jobs.isEmpty, let onIdle else { return }
        self.onIdle = nil
        onIdle()
    }

    /// A request that never received its startup permit.
    private func notStarted(_ job: ChatJob, _ message: String, cancelled: Bool, warning: String = "") {
        var status = statuses[job.sessionID] ?? ExecutionStatus(modelLabel: job.config.label)
        if !status.phase.isTerminal { status.failure = message; status.finish(successful: false, cancelled: cancelled) }
        if jobs[job.sessionID] === job { statuses[job.sessionID] = status }
        switch NotStartedRoute.route(pendingOrigin: job.isPendingOrigin, cancelled: cancelled) {
        case .restoreDraft:
            let restored = restoreDraft(job)
            finish(job, state: cancelled ? .interrupted : .failed,
                   detail: (cancelled ? "已取消排队任务。" : message + " 未开始执行。") + DraftRestore.note(restored: restored)
                       + (warning.isEmpty ? "" : " " + warning))
        case .abandon:
            // Pending-origin cancellation and the abandon are one write; if it
            // fails the receipt stays and restart asks again.
            transact { try $0.abandonUnstarted(promptID: job.prompt.id, detail: "已取消，未开始执行。") }
            finish(job, state: .interrupted, detail: "已取消，未开始执行。")
        case .hold:
            transact { try $0.holdPending(message) }
            finish(job, state: .failed, detail: message)
        }
    }

    // MARK: Events

    private func handle(_ event: AgentEvent, status: ExecutionStatus, job: ChatJob) {
        guard jobs[job.sessionID] === job else { return }
        statuses[job.sessionID] = status
        switch event {
        case .runStarted(let run): job.ready = true; job.started = true; job.runID = run.id
        case .messageStarted(let message): job.partial = message; live[job.sessionID] = message
        case .messageDelta(let id, let text):
            if job.partial?.id == id { job.partial?.text += text; live[job.sessionID] = job.partial }
        case .reasoningDelta(let id, let text):
            // Provider-supplied reasoning only; nothing is synthesized locally.
            if var partial = job.partial, partial.id == id {
                if partial.reasoning.isEmpty { partial.reasoning = [AgentReasoningBlock(text: "")] }
                partial.reasoning[partial.reasoning.count - 1].text += text
                job.partial = partial; live[job.sessionID] = partial
            }
        case .messageFinished(let message):
            recordEvent(job, message, attribution: message.role == .assistant ? job.config.label : nil)
            job.partial = nil; live[job.sessionID] = nil
        case .steeringDelivered(let message):
            job.pendingSteering.remove(message.id)
            recordSteering(job, message, delivered: true)
        case .modelRetryScheduled:
            // Discard the abandoned attempt's transient text and reasoning.
            job.partial = nil; live[job.sessionID] = nil
        case .toolFinished(let invocation, let result):
            let key = TranscriptCommitBarrier.ResultKey(runID: invocation.runID, callID: invocation.call.id)
            if !result.isProviderNative {
                recordEvent(job, AgentTranscriptMessage(id: AgentTranscriptMessage.toolResultID(runID: invocation.runID,
                                                                                                 callID: result.callID),
                    role: .tool, text: result.content, toolCallID: result.callID,
                    toolName: invocation.call.name, isError: result.isError, modelText: result.modelContent), result: key)
            } else if storageReady {
                // Answered by the provider: its payload is part of the saved
                // assistant message; no local result message exists.
                owner.barrier.commit(epoch: job.epoch, [:], results: [key])
            }
        case .runFinished:
            job.terminal = true; job.ready = false
        default: break
        }
    }

    /// Event order is authoritative. A tool event is consumed after a later
    /// assistant may already have its timestamp; dates are never sorted.
    /// Each successful write acknowledges the message to the turn's gates.
    private func recordEvent(_ job: ChatJob, _ message: AgentTranscriptMessage, attribution: String? = nil,
                             result: TranscriptCommitBarrier.ResultKey? = nil) {
        let stored = ChatSession.forHistory(message)
        let commit = try? CommittedMessage(stored)
        owner.record(commit: commit.map { .init(epoch: job.epoch, messages: [stored.id: $0],
                                                results: result.map { [$0] } ?? []) }) {
            try $0.appendEvent(stored, to: job.sessionID, root: job.prompt.id, before: job.pendingSteering,
                               attribution: attribution)
        }
    }

    // MARK: Stop and finish

    func cancel(_ id: UUID) {
        guard let job = jobs[id] else { return }
        // Stop first invalidates automatic advancement, then cancels.
        stopEpoch &+= 1
        job.cancelled = true; job.ready = false
        if queuedPhone.contains(where: { $0 === job }) {
            queuedPhone.removeAll { $0 === job }
            var status = ExecutionStatus(modelLabel: job.config.label)
            status.finish(successful: false, cancelled: true)
            statuses[id] = status
            notStarted(job, "已取消排队任务。", cancelled: true)
        } else if !job.permitted {
            engine.cancel() // preparation stops; `finished` routes the never-started request
        } else {
            owner.record { try $0.editSession(id) { $0.state = .cancelling } }
            engine.cancel()
        }
    }

    /// True only when the untouched composer actually got its draft back.
    private func restoreDraft(_ job: ChatJob) -> Bool {
        guard case .send(let saved) = job.origin, var session = file.session(job.sessionID),
              DraftRestore.apply(saved, to: &session, started: job.permitted,
                                 currentRevision: draftRevisions[job.sessionID, default: 0]) else { return false }
        return transact { try $0.editSession(job.sessionID) { $0.draft = session.draft; $0.draftAttachments = session.draftAttachments } }
    }

    private func finish(_ job: ChatJob, state: ChatState, detail: String) {
        guard jobs[job.sessionID] === job else { return }
        jobs[job.sessionID] = nil; live[job.sessionID] = nil
        owner.barrier.close(epoch: job.epoch)
        owner.record { try $0.editSession(job.sessionID) { $0.state = state; $0.detail = String(detail.prefix(600)) } }
        cleanupAttachments()
        // After the caller's settlement: drain, decide pending advancement,
        // and only then let idle observers (deferred sync) run.
        Task { @MainActor [weak self] in
            guard let self else { return }
            drainPhone(); advancePendingIfReady(); notifyIdleIfNeeded()
        }
    }
}
