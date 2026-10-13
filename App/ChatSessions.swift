import AgentKit
import Foundation
import SwiftUI

extension ChatState {
    var label: String {
        switch self {
        case .idle: "就绪"
        case .queued: "排队中"
        case .running: "正在运行"
        case .cancelling: "正在取消"
        case .completed: "已完成"
        case .failed: "失败"
        case .interrupted: "已中断"
        }
    }
}

/// Local protected image files; excluded from backup and portable sync.
let attachmentFiles = AttachmentFiles(directory: applicationSupport.appendingPathComponent("Attachments", isDirectory: true))

@MainActor
private final class ChatJob {
    let sessionID: UUID
    let prompt: AgentTranscriptMessage
    let promptAttachments: [ChatAttachment]
    /// History and its attachment metadata frozen at enqueue; later messages
    /// (including this prompt) are never part of the prior context.
    let prior: [AgentTranscriptMessage]
    let priorAttachments: [String: [ChatAttachment]]
    /// Frozen at enqueue; later provider or selection edits do not reach it.
    let config: RunConfiguration
    let phoneBackend = DeviceSettings.phoneBackend
    let clipboardAllowed = DeviceSettings.clipboardAllowed
    /// Project directory frozen at enqueue, like the model configuration.
    let workspace: WorkspaceSnapshot?
    /// Composer content this turn consumed; returned only if it never starts.
    let draft: DraftSnapshot
    /// AgentKit emitted runStarted; from then on nothing is restored or replayed.
    var started = false
    var partial: AgentTranscriptMessage?
    var pendingSteering: Set<UUID> = []
    var ready = false
    var steeringInFlight = false
    var cancelled = false
    var terminal = false
    init(session: ChatSession, prompt: AgentTranscriptMessage, attachments: [ChatAttachment], config: RunConfiguration,
         workspace: WorkspaceSnapshot?, revision: Int) {
        sessionID = session.id; self.prompt = prompt; promptAttachments = attachments
        prior = session.messages; priorAttachments = session.attachments; self.config = config; self.workspace = workspace
        draft = DraftSnapshot(text: session.draft, attachments: session.draftAttachments, revision: revision)
    }
    var referencedAttachmentIDs: Set<UUID> {
        Set(promptAttachments.map(\.id) + priorAttachments.values.joined().map(\.id))
    }
}

/// Draft capacity held for images being read or prepared for one session.
struct ImportTicket: Hashable {
    let id = UUID()
    let sessionID: UUID
    let slots: Int
}

/// A send that needs the user's decision because the frozen model is text-only.
struct ImageWarning: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let modelLabel: String
    let verdict: ImageCapability.Verdict
}

@MainActor
final class ChatController: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var selectedID: UUID?
    @Published var storageError = ""
    /// Local, transient problem (image import, steering refusal) shown by the composer.
    @Published var notice = ""
    @Published var imageWarning: ImageWarning?
    @Published private(set) var deletedSessions: [Tombstone] = []
    /// Outstanding image imports by ticket ID; reads and preparation both count.
    @Published private var imports: [UUID: ImportTicket] = [:]
    @Published private var live: [UUID: AgentTranscriptMessage] = [:]
    @Published private var jobs: [UUID: ChatJob] = [:]
    /// Semantic status per session from the engine's single reducer; kept
    /// after a turn ends so the final result stays visible this launch.
    @Published private var statuses: [UUID: ExecutionStatus] = [:]
    @Published private var queuedPhone: [ChatJob] = []
    @Published private var foreground = false
    let engine: Model
    let providers: ProviderStore
    let workspaces: WorkspaceStore
    /// Called once when the last active job finishes (deferred sync rounds).
    var onIdle: (() -> Void)?
    private let file = documents.appendingPathComponent("chat-sessions.json")
    private var phoneSessionID: UUID?
    /// Transient per-session count of user edits to the composer (text,
    /// image removal, chosen images). Not persisted; programmatic clearing on
    /// enqueue does not count. Decides whether a never-started turn may
    /// restore its draft.
    private var draftRevisions: [UUID: Int] = [:]
    private func noteDraftEdit(_ id: UUID) { draftRevisions[id, default: 0] += 1 }
    private var draftWrite: Task<Void, Never>?
    /// Attachment files written but not yet recorded; cleanup never removes them.
    private var pendingAttachmentIDs: Set<UUID> = []
    init(engine: Model, providers: ProviderStore, workspaces: WorkspaceStore) {
        self.engine = engine
        self.providers = providers
        self.workspaces = workspaces
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let stored = try HistoryMigration.decode(Data(contentsOf: file), legacySelection: providers.legacySelection)
                sessions = stored.sessions
                selectedID = stored.selectedID
                deletedSessions = stored.deletedSessions
            }
            if sessions.isEmpty { sessions = [ChatSession(selection: providers.defaultSelection)] }
            if !sessions.contains(where: { $0.id == selectedID }) { selectedID = sessions.first?.id }
            persist()
            cleanupAttachments()
        } catch { storageError = "历史读取失败，原文件已保留：\(error.localizedDescription)" }
        workspaces.inUse = { [weak self] id in self?.workspaceInUse(id) ?? false }
    }
    var selected: ChatSession? { sessions.first { $0.id == selectedID } }
    var active: Bool { selectedID.map { jobs[$0] != nil } ?? false }
    var activeSessionIDs: Set<UUID> { Set(jobs.keys) }
    var canSend: Bool {
        guard storageError.isEmpty, let selected, !isImporting(selected.id),
              !selected.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selected.draftAttachments.isEmpty
        else { return false }
        return jobs[selected.id].map { $0.ready && !$0.steeringInFlight && !$0.cancelled && !$0.terminal } ?? true
    }
    var displayedMessages: [AgentTranscriptMessage] {
        guard let selected else { return [] }
        var messages = selected.messages
        if let partial = live[selected.id], !messages.contains(where: { $0.id == partial.id }) {
            let pending = jobs[selected.id]?.pendingSteering ?? []
            let index = messages.firstIndex { pending.contains($0.id) } ?? messages.endIndex
            messages.insert(partial, at: index)
        }
        return messages
    }
    /// The provider and model that actually produced a message.
    func author(of message: AgentTranscriptMessage) -> String {
        switch message.role {
        case .user: return "你"
        case .tool: return "工具 · \(message.toolName ?? "")"
        case .assistant:
            if let selected, let label = selected.attributions[message.id.uuidString] { return label }
            if let selectedID, live[selectedID]?.id == message.id, let job = jobs[selectedID] { return job.config.label }
            return "助手"
        }
    }
    func isRunning(_ id: UUID) -> Bool { jobs[id] != nil }
    func isStreaming(_ id: UUID) -> Bool { live.values.contains { $0.id == id } }

    /// Queued turns show their position among waiting turns (1 = next, even
    /// while another turn is running); running and finished turns show the
    /// engine's status.
    func status(for id: UUID) -> ExecutionStatus? {
        if let job = jobs[id], let index = queuedPhone.firstIndex(where: { $0 === job }) {
            return ExecutionStatus(modelLabel: job.config.label,
                                   phase: .queued(rank: index + 1,
                                                  waitingForForeground: !foreground && phoneSessionID == nil && index == 0))
        }
        if let job = jobs[id], statuses[id] == nil || statuses[id]?.phase.isTerminal == true {
            return ExecutionStatus(modelLabel: job.config.label)
        }
        return statuses[id]
    }

    /// Image capability that applies to the next send from this session: the
    /// running turn's frozen model, else the current selection.
    func acceptsImages(_ id: UUID) -> Bool? {
        if let job = jobs[id] { return job.config.supportsImages }
        guard let selection = sessions.first(where: { $0.id == id })?.selection else { return nil }
        return providers.provider(selection.providerID)?.model(selection.modelID)?.supportsImages
    }

    func foregroundChanged(_ active: Bool) { foreground = active; if active { drainPhone() } }
    func persist() {
        guard storageError.isEmpty else { return }
        do {
            let data = try HistoryMigration.encode(HistoryFile(selectedID: selectedID, sessions: sessions, deletedSessions: deletedSessions))
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { storageError = "历史保存失败：\(error.localizedDescription)" }
    }
    func edit(_ id: UUID, _ change: (inout ChatSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index]); sessions[index].updatedAt = Date()
    }
    func setDraft(_ text: String) {
        guard let id = selectedID else { return }
        if sessions.first(where: { $0.id == id })?.draft != text { noteDraftEdit(id) }
        edit(id) { $0.draft = text }
        draftWrite?.cancel()
        draftWrite = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.persist()
        }
    }
    func newSession() {
        guard storageError.isEmpty else { return }
        let session = ChatSession(selection: providers.defaultSelection)
        sessions.insert(session, at: 0); selectedID = session.id; notice = ""; persist()
    }
    func select(_ id: UUID) { selectedID = id; notice = ""; persist() }
    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        edit(id) { $0.title = String(title.prefix(60)); $0.metadataUpdatedAt = Date() }; persist()
    }
    /// Affects only turns enqueued afterwards.
    func setSelection(_ selection: ModelSelection, for id: UUID) {
        edit(id) {
            $0.selection = selection; $0.metadataUpdatedAt = Date()
            if $0.state == .failed { $0.detail = "" }
        }
        persist()
    }
    /// Affects only turns enqueued afterwards.
    func setWorkspace(_ workspace: UUID?, for id: UUID) {
        edit(id) { $0.workspaceID = workspace; if $0.state == .failed { $0.detail = "" } }
        persist()
    }
    /// Whether a queued or running turn froze this project.
    func workspaceInUse(_ id: UUID) -> Bool { jobs.values.contains { $0.workspace?.id == id } }

    func delete(_ id: UUID) {
        guard jobs[id] == nil, storageError.isEmpty else { return }
        sessions.removeAll { $0.id == id }
        deletedSessions.removeAll { $0.id == id }
        deletedSessions.append(Tombstone(id: id, deletedAt: Date()))
        statuses[id] = nil
        imports = imports.filter { $0.value.sessionID != id }
        if sessions.isEmpty { sessions = [ChatSession(selection: providers.defaultSelection)] }
        if selectedID == id { selectedID = sessions.first?.id }
        persist()
        cleanupAttachments()
    }
    /// Applies a merged sync snapshot; returns how many sessions were deferred.
    func applySync(merged: PortableSnapshot, base: PortableSnapshot, deferred: Set<UUID>) -> Int {
        guard storageError.isEmpty else { return 0 }
        let result = SyncApplication.sessions(sessions, tombstones: deletedSessions, merged: merged, base: base, deferred: deferred)
        sessions = result.sessions
        deletedSessions = result.tombstones
        if let id = selectedID, let replacement = result.replaced[id] { selectedID = replacement }
        if sessions.isEmpty { sessions = [ChatSession(selection: providers.defaultSelection)] }
        if !sessions.contains(where: { $0.id == selectedID }) { selectedID = sessions.first?.id }
        persist()
        cleanupAttachments()
        return result.deferred
    }

    // MARK: Attachments

    func isImporting(_ id: UUID) -> Bool { imports.values.contains { $0.sessionID == id } }
    func importingCount(_ id: UUID) -> Int { imports.values.filter { $0.sessionID == id }.reduce(0) { $0 + $1.slots } }
    func importRoom(_ id: UUID) -> Int {
        AttachmentCapacity.room(committed: sessions.first { $0.id == id }?.draftAttachments.count ?? 0,
                                reserved: importingCount(id))
    }

    /// Reserves draft capacity before any image is read, so send stays
    /// disabled and concurrent imports cannot exceed the per-message limit.
    func reserveImport(_ requested: Int, into id: UUID) -> ImportTicket? {
        guard storageError.isEmpty, requested > 0, sessions.contains(where: { $0.id == id }) else { return nil }
        let room = importRoom(id)
        guard room > 0 else { notice = AttachmentError.tooMany.localizedDescription; return nil }
        notice = requested > room ? AttachmentError.tooMany.localizedDescription : ""
        let ticket = ImportTicket(sessionID: id, slots: min(requested, room))
        imports[ticket.id] = ticket
        noteDraftEdit(id) // choosing images is an edit, before any read
        return ticket
    }

    /// Releases a reservation whose reads failed or were cancelled; the
    /// draft's text and images are unchanged.
    func cancelImport(_ ticket: ImportTicket, message: String? = nil) {
        imports[ticket.id] = nil
        if let message { notice = message }
    }
    func cancelImports(for id: UUID) { imports = imports.filter { $0.value.sessionID != id } }

    /// Camera capture: reserve, then prepare.
    func importImages(_ inputs: [Data], into id: UUID) {
        guard let ticket = reserveImport(inputs.count, into: id) else { return }
        completeImport(ticket, inputs: inputs)
    }

    /// Normalizes and stores read images for a reserved import. The file is
    /// durable before its metadata is recorded; a cancelled or overflowing
    /// import records nothing and its files are removed.
    func completeImport(_ ticket: ImportTicket, inputs: [Data], failures: [String] = []) {
        guard imports[ticket.id] != nil else { return }
        let accepted = Array(inputs.prefix(ticket.slots))
        guard !accepted.isEmpty else {
            cancelImport(ticket, message: failures.first ?? "没有可添加的图片。"); return
        }
        let ids = accepted.map { _ in UUID() }
        pendingAttachmentIDs.formUnion(ids)
        Task.detached(priority: .userInitiated) {
            var stored: [ChatAttachment] = []
            var errors = failures
            for (data, id) in zip(accepted, ids) {
                do { stored.append(try attachmentFiles.store(ImageNormalizer.normalize(data), id: id)) }
                catch { errors.append(error.localizedDescription) }
            }
            await MainActor.run { [stored, errors] in self.finishImport(ticket, stored: stored, errors: errors, ids: ids) }
        }
    }

    private func finishImport(_ ticket: ImportTicket, stored: [ChatAttachment], errors: [String], ids: [UUID]) {
        let active = imports.removeValue(forKey: ticket.id) != nil
        pendingAttachmentIDs.subtract(ids)
        if active, let session = sessions.first(where: { $0.id == ticket.sessionID }) {
            let keep = AttachmentCapacity.accepted(incoming: stored.count, committed: session.draftAttachments.count)
            edit(ticket.sessionID) { $0.draftAttachments += stored.prefix(keep) }
            persist()
            if keep < stored.count { notice = AttachmentError.tooMany.localizedDescription }
        }
        if active, let first = errors.first { notice = errors.count > 1 ? "\(errors.count) 张图片未添加：\(first)" : first }
        cleanupAttachments() // removes files of cancelled, overflowing or orphaned imports
    }

    func reportImportFailure(_ message: String) { notice = message }

    func removeDraftAttachment(_ attachmentID: UUID) {
        guard let id = selectedID else { return }
        noteDraftEdit(id)
        edit(id) { $0.draftAttachments.removeAll { $0.id == attachmentID } }
        persist()
        cleanupAttachments()
    }

    /// Deletes files nothing references: no message, draft, accepted turn or
    /// in-progress import. Conflict copies share IDs, so their images stay.
    func cleanupAttachments() {
        guard storageError.isEmpty else { return }
        var keep = pendingAttachmentIDs
        for session in sessions { keep.formUnion(session.referencedAttachmentIDs) }
        for job in jobs.values { keep.formUnion(job.referencedAttachmentIDs) }
        attachmentFiles.removeUnreferenced(keeping: keep)
    }

    // MARK: Turns

    // Event order is authoritative. A tool event is consumed after a later
    // assistant may already have its timestamp; sorting dates breaks call/result adjacency.
    private func append(_ message: AgentTranscriptMessage, to id: UUID, before pending: Set<UUID> = [], attribution: String? = nil) {
        let message = ChatSession.forHistory(message)
        edit(id) { session in
            if let index = session.messages.firstIndex(where: { $0.id == message.id }) { session.messages[index] = message }
            else {
                let index = session.messages.firstIndex { pending.contains($0.id) } ?? session.messages.endIndex
                session.messages.insert(message, at: index)
            }
            if let attribution { session.attributions[message.id.uuidString] = attribution }
        }
        persist()
    }

    /// `textOnly` is the user's explicit choice after a text-only model
    /// warning: the text is sent and the images stay in the draft.
    func send(textOnly: Bool = false) {
        guard canSend, let session = selected else { return }
        let text = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = textOnly ? [] : session.draftAttachments
        if textOnly, text.isEmpty { return }
        notice = ""
        if let job = jobs[session.id] { steer(job, session: session, text: text, images: images); return }
        // Capture provider, endpoint, format, model, capability and key now.
        let config: RunConfiguration
        do { config = try providers.configuration(for: session.selection) }
        catch { edit(session.id) { $0.detail = error.localizedDescription }; persist(); return }
        switch ImageCapability.check(supportsImages: config.supportsImages, hasText: !text.isEmpty, imageCount: images.count) {
        case .ok: break
        case .warnDropImages, .blockImageOnly:
            imageWarning = ImageWarning(sessionID: session.id, modelLabel: config.label,
                                        verdict: ImageCapability.check(supportsImages: false, hasText: !text.isEmpty,
                                                                       imageCount: images.count))
            return
        }
        guard images.allSatisfy(attachmentFiles.exists) else { notice = AttachmentError.missingFile.localizedDescription; return }
        // A selected project that no longer exists is an explicit problem, never a silent fallback.
        var workspace: WorkspaceSnapshot?
        if let id = session.workspaceID {
            guard let snapshot = workspaces.snapshot(id) else {
                notice = "本会话选择的项目已不存在；请重新选择项目或选择“不使用项目”。"; return
            }
            workspace = snapshot
        }
        let message = AgentTranscriptMessage(role: .user, text: text)
        let job = ChatJob(session: session, prompt: message, attachments: images, config: config, workspace: workspace,
                          revision: draftRevisions[session.id, default: 0])
        // `session.draft` is the raw text, restored verbatim if the turn never starts.
        jobs[session.id] = job
        statuses[session.id] = nil
        if !images.isEmpty { edit(session.id) { $0.attachments[message.id.uuidString] = images } }
        append(message, to: session.id)
        edit(session.id) {
            $0.draft = ""; $0.detail = ""; $0.state = .queued
            if !textOnly { $0.draftAttachments = [] }
            if $0.title == ChatSession.defaultTitle { $0.title = text.isEmpty ? "图片" : String(text.prefix(20)) }
        }
        persist()
        queuedPhone.append(job); drainPhone()
    }

    private func steer(_ job: ChatJob, session: ChatSession, text: String, images: [ChatAttachment]) {
        guard let runtime = engine.activeAgentRuntime else { return }
        if !images.isEmpty, !job.config.supportsImages {
            notice = "本轮模型 \(job.config.label) 不接收图片；图片保留在草稿中，可移除后追加文字，或在本轮结束后换用支持图片的模型。"
            return
        }
        let hydrated: [AgentImageAttachment]
        do { hydrated = try AttachmentHydration.images(images, load: attachmentFiles.data) }
        catch { notice = error.localizedDescription; return }
        let message = AgentTranscriptMessage(role: .user, text: text, images: hydrated)
        job.steeringInFlight = true
        edit(session.id) { $0.detail = "正在追加指令。" }
        Task {
            defer { job.steeringInFlight = false; objectWillChange.send() }
            if await runtime.steer(message) {
                if !images.isEmpty { edit(session.id) { $0.attachments[message.id.uuidString] = images } }
                // A delivered event may arrive before steer returns. Keep its delivery timestamp.
                if !sessions.contains(where: { $0.id == session.id && $0.messages.contains(where: { $0.id == message.id }) }) {
                    job.pendingSteering.insert(message.id)
                    append(message, to: session.id)
                }
                let sent = Set(images.map(\.id))
                edit(session.id) {
                    if $0.draft == session.draft { $0.draft = "" }
                    $0.draftAttachments.removeAll { sent.contains($0.id) }
                    $0.detail = "追加指令将在下一轮进入模型上下文。"
                }
                persist()
            } else {
                // The run crossed its final boundary; keep the draft for a new turn.
                edit(session.id) { $0.detail = "本轮已结束，请再次发送以开始下一轮。" }; persist()
            }
        }
    }

    func cancel(_ id: UUID) {
        guard let job = jobs[id] else { return }
        job.cancelled = true; job.ready = false
        edit(id) { $0.state = .cancelling }; persist()
        if queuedPhone.contains(where: { $0 === job }) {
            queuedPhone.removeAll { $0 === job }
            let restored = restoreDraft(job)
            var status = ExecutionStatus(modelLabel: job.config.label)
            status.finish(successful: false, cancelled: true)
            statuses[id] = status
            finish(job, state: .interrupted, detail: "已取消排队任务。" + DraftRestore.note(restored: restored))
        } else { engine.cancel() }
    }
    private func drainPhone() {
        guard foreground, !engine.busy, phoneSessionID == nil, !queuedPhone.isEmpty else { return }
        let job = queuedPhone.removeFirst()
        guard !job.cancelled else { drainPhone(); return }
        func fail(_ message: String) {
            var status = ExecutionStatus(modelLabel: job.config.label)
            status.finish(successful: false, cancelled: false)
            statuses[job.sessionID] = status
            let restored = restoreDraft(job)
            finish(job, state: .failed, detail: message + DraftRestore.note(restored: restored))
            drainPhone()
        }
        // The frozen project must still exist; it is never swapped for another.
        if let workspace = job.workspace, workspaces.snapshot(workspace.id)?.root != workspace.root {
            fail("本轮选择的项目已不存在，任务未开始。"); return
        }
        // Image bytes are read only now, from the frozen references.
        let promptImages: [AgentImageAttachment]
        do { promptImages = try AttachmentHydration.images(job.promptAttachments, load: attachmentFiles.data) }
        catch { fail(error.localizedDescription); return }
        let prior = AttachmentHydration.context(job.prior, attachments: job.priorAttachments,
                                                supportsImages: job.config.supportsImages, load: attachmentFiles.data)
        phoneSessionID = job.sessionID
        statuses[job.sessionID] = ExecutionStatus(modelLabel: job.config.label)
        edit(job.sessionID) { $0.state = .running; $0.detail = "" }; persist()
        engine.beginAgent(goal: job.prompt.text, images: promptImages, config: job.config, workspace: job.workspace, backend: job.phoneBackend,
            clipboardAllowed: job.clipboardAllowed,
            conversationID: job.sessionID, promptID: job.prompt.id, priorMessages: prior,
            onEvent: { [weak self, weak job] event, status in
                guard let self, let job else { return }; handle(event, status: status, job: job)
            }, onStatus: { [weak self, weak job] status in
                // Script phone actions update progress only; they add no transcript message.
                guard let self, let job, jobs[job.sessionID] === job else { return }
                statuses[job.sessionID] = status
            }, onFinished: { [weak self, weak job] successful, cleanupWarning, status in
                guard let self, let job else { return }
                phoneSessionID = nil
                if jobs[job.sessionID] === job { statuses[job.sessionID] = status }
                // A turn that failed before AgentKit started gets its draft back.
                let restored = !successful && jobs[job.sessionID] === job && restoreDraft(job)
                let reason = ((status.failure.map { "原因：\($0)" } ?? "") + DraftRestore.note(restored: restored))
                    .trimmingCharacters(in: .whitespaces)
                finish(job, state: successful ? .completed : (job.cancelled ? .interrupted : .failed),
                    detail: ([successful ? "" : (job.cancelled ? "已取消。" : "本轮未完成，请重试。"),
                              successful || job.cancelled ? "" : reason, cleanupWarning].filter { !$0.isEmpty }).joined(separator: " "))
                // The previous runner and BG task have completed before draining.
                Task { @MainActor [weak self] in self?.drainPhone() }
            })
    }
    private func handle(_ event: AgentEvent, status: ExecutionStatus, job: ChatJob) {
        guard jobs[job.sessionID] === job else { return }
        statuses[job.sessionID] = status
        switch event {
        case .runStarted: job.ready = true; job.started = true
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
            append(message, to: job.sessionID, before: job.pendingSteering,
                   attribution: message.role == .assistant ? job.config.label : nil)
            job.partial = nil; live[job.sessionID] = nil
        case .steeringDelivered(let message):
            job.pendingSteering.remove(message.id)
            edit(job.sessionID) { $0.messages.removeAll { $0.id == message.id } }
            append(message, to: job.sessionID, before: job.pendingSteering)
        case .modelRetryScheduled:
            // Discard the abandoned attempt's transient text and reasoning.
            job.partial = nil; live[job.sessionID] = nil
        case .toolFinished(let invocation, let result):
            if !result.isProviderNative {
                append(AgentTranscriptMessage(id: AgentTranscriptMessage.toolResultID(runID: invocation.runID, callID: result.callID),
                    role: .tool, text: result.content, toolCallID: result.callID,
                    toolName: invocation.call.name, isError: result.isError, modelText: result.modelContent),
                    to: job.sessionID, before: job.pendingSteering)
            }
        case .runFinished:
            job.terminal = true; job.ready = false
        default: break
        }
    }
    /// True only when the untouched composer actually got its draft back.
    private func restoreDraft(_ job: ChatJob) -> Bool {
        guard var session = sessions.first(where: { $0.id == job.sessionID }),
              DraftRestore.apply(job.draft, to: &session, started: job.started,
                                 currentRevision: draftRevisions[job.sessionID, default: 0]) else { return false }
        edit(job.sessionID) { $0.draft = session.draft; $0.draftAttachments = session.draftAttachments }
        persist()
        return true
    }

    private func finish(_ job: ChatJob, state: ChatState, detail: String) {
        guard jobs[job.sessionID] === job else { return }
        jobs[job.sessionID] = nil; live[job.sessionID] = nil
        edit(job.sessionID) { $0.state = state; $0.detail = String(detail.prefix(600)) }; persist()
        cleanupAttachments()
        if jobs.isEmpty, let onIdle { self.onIdle = nil; onIdle() }
    }
}
