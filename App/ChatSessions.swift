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

/// The assistant-v1 namespace. Earlier history, provider and attachment
/// locations are not read, converted or cleaned.
let assistantNamespace = AssistantNamespace(applicationSupport: applicationSupport)
/// Local protected image files; excluded from backup and portable sync.
let attachmentFiles = AttachmentFiles(directory: assistantNamespace.attachments)

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

/// MainActor owner of the single assistant-v1 history file. Every change goes
/// through `HistoryOwner`; views read its published state.
@MainActor
final class ChatController: ObservableObject {
    /// Bumped after every owner change so SwiftUI re-reads derived state.
    @Published private(set) var revision = 0
    /// Local, transient problem (image import, steering refusal) shown by the composer.
    @Published var notice = ""
    /// Local receipt of the last explicit memory operation (no content).
    @Published var memoryNotice = ""
    /// Primary composer's remember mode: plain text opens the prefilled memory editor.
    @Published var rememberMode = false
    /// The editor opened from remember mode, if any.
    @Published var rememberRequest: ComposerDraft?
    /// A recognised natural-language edit/forget waiting for the user's pick.
    @Published var memoryIntent: MemoryIntentRequest?
    @Published var imageWarning: ImageWarning?
    /// Outstanding image imports by ticket ID; reads and preparation both count.
    @Published var imports: [UUID: ImportTicket] = [:]
    @Published var live: [UUID: AgentTranscriptMessage] = [:]
    @Published var jobs: [UUID: ChatJob] = [:]
    /// Semantic status per session from the engine's single reducer; kept
    /// after a turn ends so the final result stays visible this launch.
    @Published var statuses: [UUID: ExecutionStatus] = [:]
    @Published var queuedPhone: [ChatJob] = []
    @Published var foreground = false
    /// Primary-line input target while a turn is active: next request (default) or steer.
    @Published var steerPrimary = false
    /// Messages shown per transcript page; grows with "显示更早".
    @Published var visibleLimit: [UUID: Int] = [:]
    let engine: Model
    let providers: ProviderStore
    let workspaces: WorkspaceStore
    let owner: HistoryOwner
    let storage: HistoryStorage
    /// The production writer (nil in the read-only viewer); held only for
    /// the local acceptance fault injection.
    private var historyWriter: PatchingHistoryWriter?
    /// Called once when the last active job finishes (deferred sync rounds).
    var onIdle: (() -> Void)?
    var phoneSessionID: UUID?
    /// The job the engine is executing; late callbacks from any other job are ignored.
    var runningJob: ChatJob?
    /// Transient per-session count of user edits to the composer (text,
    /// image removal, chosen images). Not persisted; programmatic clearing on
    /// enqueue does not count. Decides whether a never-started turn may
    /// restore its draft.
    var draftRevisions: [UUID: Int] = [:]
    func noteDraftEdit(_ id: UUID) { draftRevisions[id, default: 0] += 1 }
    /// The acceptance forget during a run has been attempted (one-shot).
    var diagnosticForgetConsumed = false
    private var draftWrite: Task<Void, Never>?
    /// Draft text changed in memory but not yet written.
    private var draftDirty = false
    /// Attachment files written but not yet recorded; cleanup never removes them.
    var pendingAttachmentIDs: Set<UUID> = []
    /// Process-wide fair order of accepted jobs and the pending request.
    var nextOrdinal: UInt64 = 0
    var nextEpoch: UInt64 = 0
    /// Stop increments this before cancelling; a pending request only advances
    /// automatically when it is unchanged since the finishing turn started.
    var stopEpoch: UInt64 = 0
    /// In-memory frozen configuration of the pending request (never persisted).
    var pendingFrozen: FrozenTurn?
    /// Stop epoch when the pending request was accepted or resumed.
    var pendingStopEpoch: UInt64 = 0
    /// Steering calls not yet answered by the runtime; activation waits for them.
    var settlingSteers = 0
    /// Explicit history references chosen for the next send, per session (UI only).
    @Published var referenceDrafts: [UUID: [HistoryReference]] = [:]
    /// Launch recovery that could not be saved yet.
    private var unsavedRecovery: HistoryFile?
    /// Storage reset is offered only after a load failure.
    var canResetStorage: Bool { if case .loadBlocked = owner.health { true } else { false } }

    init(engine: Model, providers: ProviderStore, workspaces: WorkspaceStore) {
        self.engine = engine
        self.providers = providers
        self.workspaces = workspaces
        let storage = HistoryStorage(url: assistantNamespace.history)
        self.storage = storage
        // One writer for the process: it alone knows the file it last published.
        let store = PatchingHistoryWriter(storage: storage)
        historyWriter = store
        var recovery: HistoryFile?
        var launchSource: HistoryLoadSource?
        let created: HistoryOwner
        do {
            let (loadedState, source) = try storage.loadForAdoption()
            switch loadedState {
            case .absent:
                // One atomic initialization of the empty primary line.
                let initial = HistoryFile.initial(selection: providers.defaultSelection)
                let fresh = HistoryOwner(file: initial, store: store)
                do { try fresh.reset(to: initial); created = fresh } catch {
                    created = HistoryOwner(file: initial, health: .saveDirty(error.localizedDescription), store: store)
                }
            case .loaded(let file):
                var recovered = file
                recovered.recoverAfterLaunch()
                let loaded = HistoryOwner(file: file, store: store)
                if recovered == file { created = loaded; launchSource = source } else {
                    // Interrupted/needsResume states are published only once saved.
                    do { try loaded.transact { $0 = recovered }; created = loaded } catch {
                        recovery = recovered
                        created = HistoryOwner(file: file, health: .saveDirty("启动恢复状态未保存：\(error.localizedDescription)"),
                                               store: store)
                    }
                }
            }
        } catch {
            created = HistoryOwner(file: .initial(selection: nil), health: .loadBlocked(error.localizedDescription), store: store)
        }
        owner = created
        unsavedRecovery = recovery
        if let launchSource {
            // Off the main actor: prove the launched file is this writer's
            // image of what was loaded, so the first write can patch it.
            Task { @MainActor in
                let hydration = await Task.detached(priority: .utility) { HistoryHydration.make(launchSource) }.value
                if let hydration { created.adopt(hydration) }
            }
        }
        owner.onChange = { [weak self] in self?.revision &+= 1 }
        owner.onStorageFailure = { [weak self] error in self?.storageFailed(error) }
        if DeviceSettings.dirtyAfterFirstScriptCall {
            // Local acceptance only: one failing write of an unchanged run event,
            // through the real owner (dirty, every gate fails, jobs stop).
            NotificationCenter.default.addObserver(forName: DeviceSettings.diagnosticDirty, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let job = self.runningJob else { return }
                    self.historyWriter?.failNextWrite = CocoaError(.fileWriteOutOfSpace)
                    self.owner.record { try $0.editSession(job.sessionID, touch: false) { _ in } }
                }
            }
        }
        if DeviceSettings.stopAtFirstSummaryText {
            // Local acceptance only: the Stop button's own path for the primary line.
            NotificationCenter.default.addObserver(forName: DeviceSettings.diagnosticStop, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; self.cancel(self.owner.file.assistant.primarySessionID) }
            }
        }
        workspaces.inUse = { [weak self] id in self?.workspaceInUse(id) ?? false }
        providers.onDefaultSelection = { [weak self] in self?.adoptDefaultSelection() }
        if owner.health.isReady { cleanupAttachments() }
        adoptDefaultSelection()
    }

    /// Read-only viewer over a synthetic history, for the local viewport
    /// benchmark only (`-PocketAgentViewportBenchmark`): the file lives in this
    /// owner's memory with storage load-blocked, so transactions, run-event
    /// records and drafts are refused before any change (and the writer, which
    /// would fail, counts any call); no attachment cleanup,
    /// default-model adoption or provider/workspace callbacks; the storage path
    /// is an unused temporary file. The app's own controller, history and sync
    /// are not involved.
    init(viewing file: HistoryFile, engine: Model, providers: ProviderStore, workspaces: WorkspaceStore,
         writerCalls: @escaping () -> Void) {
        self.engine = engine
        self.providers = providers
        self.workspaces = workspaces
        storage = HistoryStorage(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketagent-viewport-\(UUID().uuidString).json"))
        owner = HistoryOwner(file: file, health: .loadBlocked("只读量测视图，不写入"),
                             writer: { _ in writerCalls(); throw CocoaError(.featureUnsupported) })
        unsavedRecovery = nil
        owner.onChange = { [weak self] in self?.revision &+= 1 }
    }

    /// The primary line without a model uses the Settings default model;
    /// an existing selection is kept.
    func adoptDefaultSelection() {
        guard owner.health.isReady, owner.file.primary?.selection == nil, providers.defaultSelection != nil else { return }
        transact { try $0.adoptDefaultSelection(self.providers.defaultSelection) }
    }

    // MARK: Derived state

    var file: HistoryFile { owner.file }
    var sessions: [ChatSession] { owner.file.sessions }
    var selectedID: UUID? { owner.file.selectedID }
    var deletedSessions: [Tombstone] { owner.file.deletedSessions }
    var assistant: AssistantState { owner.file.assistant }
    var primaryID: UUID { owner.file.assistant.primarySessionID }
    var storageError: String { owner.health.message ?? "" }
    var storageReady: Bool { owner.health.isReady }
    func isPrimary(_ id: UUID?) -> Bool { id != nil && id == primaryID && owner.file.primary != nil }
    var selected: ChatSession? { selectedID.flatMap { id in sessions.first { $0.id == id } } }
    var active: Bool { selectedID.map { jobs[$0] != nil } ?? false }
    var activeSessionIDs: Set<UUID> { Set(jobs.keys) }
    var taskSessions: [ChatSession] { sessions.filter { $0.id != primaryID }.sorted { $0.updatedAt > $1.updatedAt } }

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
                                                  waitingForForeground: !foreground && phoneSessionID == nil && index == 0),
                                   budget: job.statusBudget)
        }
        if let job = jobs[id], statuses[id] == nil || statuses[id]?.phase.isTerminal == true {
            return ExecutionStatus(modelLabel: job.config.label, budget: job.statusBudget)
        }
        return statuses[id]
    }

    /// Image capability that applies to the next send from this session: the
    /// running turn's frozen model, else the current selection.
    func acceptsImages(_ id: UUID) -> Bool? {
        if let job = jobs[id], !(isPrimary(id) && !steerPrimary) { return job.config.supportsImages }
        guard let selection = sessions.first(where: { $0.id == id })?.selection else { return nil }
        return providers.provider(selection.providerID)?.model(selection.modelID)?.supportsImages
    }

    func foregroundChanged(_ active: Bool) {
        foreground = active
        if active { drainPhone(); advancePendingIfReady() }
    }

    // MARK: Storage

    /// Writes staged draft text. A failure keeps the text and reports it.
    func persist() {
        draftWrite?.cancel(); draftWrite = nil
        guard draftDirty, storageReady else { return }
        draftDirty = false
        owner.record { _ in }
    }

    /// Explicit retry after a save failure; storage only, never the stopped run.
    func retryStorage() {
        do {
            if let recovered = unsavedRecovery {
                try owner.flushReplacing(recovered)
                unsavedRecovery = nil
            } else {
                try owner.flush()
            }
            notice = ""
            cleanupAttachments()
        } catch { notice = "仍无法保存：\(error.localizedDescription)" }
    }

    /// Explicit reset of an unreadable assistant-v1 file: the file is moved
    /// aside (kept) and a fresh empty primary line starts. Other namespaces
    /// and device settings are untouched.
    func resetUnreadableStorage() {
        guard canResetStorage else { return }
        do {
            _ = try storage.quarantine()
            try owner.reset(to: .initial(selection: providers.defaultSelection))
            notice = "无法读取的历史文件已移到同一目录保留；已开始新的助理数据。"
        } catch { notice = "重置失败：\(error.localizedDescription)" }
    }

    /// Storage became dirty: stop every active turn at its next boundary.
    /// Already issued effects keep their real or unknown results; nothing resumes on its own.
    private func storageFailed(_ error: StorageCommitError) {
        for job in jobs.values where !job.cancelled {
            job.cancelled = true; job.ready = false
        }
        if engine.busy { engine.cancel() }
        notice = error.localizedDescription
    }

    /// One transactional user edit; reports a failure instead of publishing.
    @discardableResult
    func transact(_ edit: (inout HistoryFile) throws -> Void) -> Bool {
        do { try owner.transact(edit); return true }
        catch { notice = error.localizedDescription; return false }
    }

    // MARK: Sessions

    func setDraft(_ text: String) {
        guard let id = selectedID, storageReady else { return }
        if sessions.first(where: { $0.id == id })?.draft != text { noteDraftEdit(id) }
        owner.stage { try? $0.editSession(id) { $0.draft = text } }
        draftDirty = true
        draftWrite?.cancel()
        draftWrite = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.persist()
        }
    }

    /// A new independent task conversation.
    func newSession() {
        let session = ChatSession(selection: providers.defaultSelection)
        if transact({ $0.sessions.insert(session, at: 0); $0.selectedID = session.id }) { notice = "" }
    }

    func selectPrimary() { if let primary = owner.file.primary { select(primary.id) } }

    func select(_ id: UUID) {
        persist()
        if transact({ $0.selectedID = id }) { notice = "" }
    }

    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        transact { try $0.editSession(id) { $0.title = String(title.prefix(60)); $0.metadataUpdatedAt = Date() } }
    }

    /// Affects only turns enqueued afterwards.
    func setSelection(_ selection: ModelSelection, for id: UUID) {
        transact {
            try $0.editSession(id) {
                $0.selection = selection; $0.metadataUpdatedAt = Date()
                if $0.state == .failed { $0.detail = "" }
            }
        }
    }

    /// Affects only turns enqueued afterwards.
    func setWorkspace(_ workspace: UUID?, for id: UUID) {
        transact { try $0.editSession(id) { $0.workspaceID = workspace; if $0.state == .failed { $0.detail = "" } } }
    }

    /// Whether a queued or running turn, or the pending request, froze this project.
    func workspaceInUse(_ id: UUID) -> Bool {
        jobs.values.contains { $0.workspace?.id == id } || pendingFrozen?.workspace?.id == id
            || owner.file.assistant.pendingNext?.workspaceID == id
    }

    /// The primary line and sessions with jobs or the pending request cannot be deleted.
    func canDelete(_ id: UUID) -> Bool {
        id != primaryID && jobs[id] == nil && owner.file.assistant.pendingNext?.sessionID != id
    }

    func delete(_ id: UUID) {
        guard canDelete(id), storageReady else { return }
        let ok = transact { file in
            file.sessions.removeAll { $0.id == id }
            file.deletedSessions.removeAll { $0.id == id }
            file.deletedSessions.append(Tombstone(id: id, deletedAt: Date()))
            if file.selectedID == id { file.selectedID = file.primary?.id ?? file.sessions.first?.id }
            let existing = Set(file.sessions.flatMap { $0.messages.map(\.id) })
            try file.assistant.scopeIndex.prune(existing: existing)
            file.assistant.compactions.removeAll { $0.sessionID == id }
        }
        guard ok else { return }
        statuses[id] = nil
        imports = imports.filter { $0.value.sessionID != id }
        cleanupAttachments()
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
        guard storageReady, requested > 0, sessions.contains(where: { $0.id == id }) else { return nil }
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
        if active, let session = sessions.first(where: { $0.id == ticket.sessionID }) {
            let keep = AttachmentCapacity.accepted(incoming: stored.count, committed: session.draftAttachments.count)
            transact { try $0.editSession(ticket.sessionID) { $0.draftAttachments += stored.prefix(keep) } }
            if keep < stored.count { notice = AttachmentError.tooMany.localizedDescription }
        }
        pendingAttachmentIDs.subtract(ids)
        if active, let first = errors.first { notice = errors.count > 1 ? "\(errors.count) 张图片未添加：\(first)" : first }
        cleanupAttachments() // removes files of cancelled, overflowing or orphaned imports
    }

    func reportImportFailure(_ message: String) { notice = message }

    func removeDraftAttachment(_ attachmentID: UUID) {
        guard let id = selectedID else { return }
        noteDraftEdit(id)
        transact { try $0.editSession(id) { $0.draftAttachments.removeAll { $0.id == attachmentID } } }
        cleanupAttachments()
    }

    /// Deletes files nothing references now: no message, draft, pending
    /// request, accepted turn, steering lease or in-progress import. Always
    /// recomputed from current state, never from an older snapshot.
    func cleanupAttachments() {
        guard storageReady else { return }
        var keep = pendingAttachmentIDs.union(owner.file.referencedAttachmentIDs)
        for job in jobs.values { keep.formUnion(job.referencedAttachmentIDs) }
        attachmentFiles.removeUnreferenced(keeping: keep)
    }

    // MARK: Sync

    /// Sessions that must not be overwritten by a sync round right now.
    var syncDeferred: Set<UUID> {
        var ids = Set(jobs.keys)
        if let pending = owner.file.assistant.pendingNext { ids.insert(pending.sessionID) }
        return ids
    }

    /// Applies a merged sync snapshot from the latest complete local file;
    /// returns how many sessions were deferred. The deferred set is checked
    /// again here, so work accepted while the round was in flight is kept.
    func applySync(merged: PortableSnapshot, base: PortableSnapshot, deferred: Set<UUID>) -> Int {
        guard storageReady else { return 0 }
        let deferred = deferred.union(syncDeferred)
        var skipped = 0
        let ok = transact { file in
            skipped = try file.applyPortable(merged: merged, base: base, deferred: deferred)
        }
        guard ok else { return 0 }
        cleanupAttachments()
        return skipped
    }
}

extension HistoryOwner {
    /// Draft keystrokes: applied in memory and written by the next record or
    /// transaction (debounced). Not used for run events or user operations.
    func stage(_ edit: (inout HistoryFile) -> Void) {
        replaceInMemory { edit(&$0) }
    }
}
