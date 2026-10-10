import AgentKit
import Foundation
import SwiftUI

extension ChatState {
    var label: String {
        switch self {
        case .idle: "就绪"
        case .queued: "等待手机空闲；回到 App 后继续"
        case .running: "正在运行"
        case .cancelling: "正在取消"
        case .completed: "已完成"
        case .failed: "失败"
        case .interrupted: "已中断"
        }
    }
}

@MainActor
private final class ChatJob {
    let sessionID: UUID
    let prompt: AgentTranscriptMessage
    let prior: [AgentTranscriptMessage]
    /// Frozen at enqueue; later provider or selection edits do not reach it.
    let config: RunConfiguration
    var partial: AgentTranscriptMessage?
    var pendingSteering: Set<UUID> = []
    var ready = false
    var steeringInFlight = false
    var cancelled = false
    var terminal = false
    init(session: ChatSession, prompt: AgentTranscriptMessage, config: RunConfiguration) {
        sessionID = session.id; self.prompt = prompt; prior = session.messages; self.config = config
    }
}

@MainActor
final class ChatController: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var selectedID: UUID?
    @Published var storageError = ""
    @Published private(set) var deletedSessions: [Tombstone] = []
    @Published private var live: [UUID: AgentTranscriptMessage] = [:]
    @Published private var jobs: [UUID: ChatJob] = [:]
    let engine: Model
    let providers: ProviderStore
    /// Called once when the last active job finishes (deferred sync rounds).
    var onIdle: (() -> Void)?
    private let file = documents.appendingPathComponent("chat-sessions.json")
    private var queuedPhone: [ChatJob] = []
    private var phoneSessionID: UUID?
    private var foreground = false
    private var draftWrite: Task<Void, Never>?
    init(engine: Model, providers: ProviderStore) {
        self.engine = engine
        self.providers = providers
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
        } catch { storageError = "历史读取失败，原文件已保留：\(error.localizedDescription)" }
    }
    var selected: ChatSession? { sessions.first { $0.id == selectedID } }
    var active: Bool { selectedID.map { jobs[$0] != nil } ?? false }
    var activeSessionIDs: Set<UUID> { Set(jobs.keys) }
    var canSend: Bool {
        guard storageError.isEmpty, let selected, !selected.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
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
        sessions.insert(session, at: 0); selectedID = session.id; persist()
    }
    func select(_ id: UUID) { selectedID = id; persist() }
    func rename(_ title: String) {
        guard let id = selectedID else { return }
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
    func delete(_ id: UUID) {
        guard jobs[id] == nil, storageError.isEmpty else { return }
        sessions.removeAll { $0.id == id }
        deletedSessions.removeAll { $0.id == id }
        deletedSessions.append(Tombstone(id: id, deletedAt: Date()))
        if sessions.isEmpty { sessions = [ChatSession(selection: providers.defaultSelection)] }
        if selectedID == id { selectedID = sessions.first?.id }
        persist()
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
        return result.deferred
    }
    // Event order is authoritative. A tool event is consumed after a later
    // assistant may already have its timestamp; sorting dates breaks call/result adjacency.
    private func append(_ message: AgentTranscriptMessage, to id: UUID, before pending: Set<UUID> = [], attribution: String? = nil) {
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
    func send() {
        guard canSend, let session = selected else { return }
        let text = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = AgentTranscriptMessage(role: .user, text: text)
        if let job = jobs[session.id] {
            guard let runtime = engine.activeAgentRuntime else { return }
            job.steeringInFlight = true
            edit(session.id) { $0.detail = "正在追加指令。" }
            Task {
                defer { job.steeringInFlight = false; objectWillChange.send() }
                if await runtime.steer(message) {
                    // A delivered event may arrive before steer returns. Keep its delivery timestamp.
                    if !sessions.contains(where: { $0.id == session.id && $0.messages.contains(where: { $0.id == message.id }) }) {
                        job.pendingSteering.insert(message.id)
                        append(message, to: session.id)
                    }
                    edit(session.id) {
                        if $0.draft == session.draft { $0.draft = "" }
                        $0.detail = "追加指令将在下一轮进入模型上下文。"
                    }
                    persist()
                } else {
                    // The run crossed its final boundary; keep the draft for a new turn.
                    edit(session.id) { $0.detail = "本轮已结束，请再次发送以开始下一轮。" }; persist()
                }
            }
            return
        }
        // Capture provider, endpoint, format, model, capability and key now.
        let config: RunConfiguration
        do { config = try providers.configuration(for: session.selection) }
        catch { edit(session.id) { $0.detail = error.localizedDescription }; persist(); return }
        let job = ChatJob(session: session, prompt: message, config: config)
        jobs[session.id] = job
        append(message, to: session.id)
        edit(session.id) {
            $0.draft = ""; $0.detail = ""; $0.state = .queued
            if $0.title == ChatSession.defaultTitle { $0.title = String(text.prefix(20)) }
        }
        persist()
        queuedPhone.append(job); drainPhone()
    }
    func cancel(_ id: UUID) {
        guard let job = jobs[id] else { return }
        job.cancelled = true; job.ready = false
        edit(id) { $0.state = .cancelling }; persist()
        if queuedPhone.contains(where: { $0 === job }) {
            queuedPhone.removeAll { $0 === job }; finish(job, state: .interrupted, detail: "已取消排队任务。")
        } else { engine.cancel() }
    }
    private func drainPhone() {
        guard foreground, !engine.busy, phoneSessionID == nil, !queuedPhone.isEmpty else { return }
        let job = queuedPhone.removeFirst()
        guard !job.cancelled else { drainPhone(); return }
        phoneSessionID = job.sessionID
        edit(job.sessionID) { $0.state = .running; $0.detail = "正在连接模型。" }; persist()
        engine.beginAgent(goal: job.prompt.text, config: job.config, conversationID: job.sessionID,
            promptID: job.prompt.id, priorMessages: job.prior,
            onEvent: { [weak self, weak job] event in
                guard let self, let job else { return }; handle(event, job: job)
            }, onFinished: { [weak self, weak job] successful, cleanupWarning in
                guard let self, let job else { return }
                phoneSessionID = nil
                finish(job, state: successful ? .completed : (job.cancelled ? .interrupted : .failed),
                    detail: ([successful ? "" : (job.cancelled ? "已取消。" : "本轮未完成，请重试。"),
                              cleanupWarning].filter { !$0.isEmpty }).joined(separator: " "))
                // The previous runner and BG task have completed before draining.
                Task { @MainActor [weak self] in self?.drainPhone() }
            })
    }
    private func handle(_ event: AgentEvent, job: ChatJob) {
        guard jobs[job.sessionID] === job else { return }
        switch event {
        case .runStarted: job.ready = true
        case .messageStarted(let message): job.partial = message; live[job.sessionID] = message
        case .messageDelta(let id, let text):
            if job.partial?.id == id { job.partial?.text += text; live[job.sessionID] = job.partial }
        case .messageFinished(let message):
            append(message, to: job.sessionID, before: job.pendingSteering,
                   attribution: message.role == .assistant ? job.config.label : nil)
            job.partial = nil; live[job.sessionID] = nil
        case .steeringDelivered(let message):
            job.pendingSteering.remove(message.id)
            edit(job.sessionID) { $0.messages.removeAll { $0.id == message.id } }
            append(message, to: job.sessionID, before: job.pendingSteering)
        case .modelRetryScheduled:
            job.partial = nil; live[job.sessionID] = nil
            edit(job.sessionID) { $0.detail = "连接中断，正在重试；不会重放已完成的工具。" }; persist()
        case .toolStarted(let invocation):
            edit(job.sessionID) { $0.detail = "执行工具：\(invocation.call.name)" }
        case .toolFinished(let invocation, let result):
            if !result.isProviderNative {
                append(AgentTranscriptMessage(id: AgentTranscriptMessage.toolResultID(runID: invocation.runID, callID: result.callID),
                    role: .tool, text: result.content, toolCallID: result.callID,
                    toolName: invocation.call.name, isError: result.isError, modelText: result.modelContent),
                    to: job.sessionID, before: job.pendingSteering)
            }
        case .runFinished:
            job.terminal = true; job.ready = false
            edit(job.sessionID) { $0.detail = "正在返回 App 并结束自动化。" }; persist()
        case .failed: edit(job.sessionID) { $0.detail = "模型请求失败，正在结束本轮。" }
        default: break
        }
    }
    private func finish(_ job: ChatJob, state: ChatState, detail: String) {
        guard jobs[job.sessionID] === job else { return }
        jobs[job.sessionID] = nil; live[job.sessionID] = nil
        edit(job.sessionID) { $0.state = state; $0.detail = String(detail.prefix(600)) }; persist()
        if jobs.isEmpty, let onIdle { self.onIdle = nil; onIdle() }
    }
}

struct ChatRootView: View {
    @ObservedObject var engine: Model
    @ObservedObject var chat: ChatController
    @ObservedObject var providers: ProviderStore
    @ObservedObject var sync: SyncCoordinator
    @ObservedObject var device: DeviceSettingsModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSessions = false
    @State private var showSettings = false
    @State private var showModels = false
    @State private var showProviders = false
    @State private var renameDialog = false
    @State private var newTitle = ""
    @FocusState private var inputFocused: Bool
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                if !chat.storageError.isEmpty { Text(chat.storageError).foregroundStyle(.red).padding() }
                if !providers.storageError.isEmpty { Text(providers.storageError).foregroundStyle(.red).padding() }
                if !providers.notice.isEmpty { Text(providers.notice).font(.caption).foregroundStyle(.orange) }
                if providers.isConfigured { transcript } else { setup }
                if let selected = chat.selected {
                    modelBar(selected)
                    HStack {
                        Text(selected.state.label).accessibilityIdentifier("chatStatus")
                        Spacer()
                        if chat.active { Button("取消") { chat.cancel(selected.id) }.accessibilityIdentifier("chatCancel") }
                    }.font(.caption)
                    if !selected.detail.isEmpty { Text(selected.detail).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                    composer(selected)
                }
            }.padding(.horizontal)
                .navigationTitle(chat.selected?.title ?? "手机助手").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("会话 \(chat.sessions.count)") { inputFocused = false; showSessions = true }.accessibilityIdentifier("sessions")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { inputFocused = false; chat.newSession() } label: { Image(systemName: "plus.bubble") }.accessibilityIdentifier("newSession")
                        Button { newTitle = chat.selected?.title ?? ""; renameDialog = true } label: { Image(systemName: "pencil") }.accessibilityIdentifier("renameSession")
                        Button { inputFocused = false; showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityIdentifier("settings")
                    }
                }
                .alert("重命名会话", isPresented: $renameDialog) {
                    TextField("会话标题", text: $newTitle)
                    Button("保存") { chat.rename(newTitle) }.accessibilityIdentifier("renameSave")
                    Button("取消", role: .cancel) {}
                }
                .sheet(isPresented: $showSessions) { sessionList }
                .sheet(isPresented: $showSettings) {
                    SettingsView(providers: providers, sync: sync, device: device) { showSettings = false }
                }
                .sheet(isPresented: $showModels) {
                    if let selected = chat.selected {
                        ModelPickerSheet(providers: providers, current: selected.selection, title: "本会话模型") { selection, makeDefault in
                            chat.setSelection(selection, for: selected.id)
                            if makeDefault { providers.setDefault(selection) }
                            showModels = false
                        }
                    }
                }
                .sheet(isPresented: $showProviders) {
                    NavigationStack {
                        ProviderListView(store: providers).toolbar {
                            ToolbarItem(placement: .topBarTrailing) { Button("完成") { showProviders = false } }
                        }
                    }
                }
                .onAppear { chat.foregroundChanged(scenePhase == .active); if scenePhase == .active { sync.foreground() } }
                .onChange(of: scenePhase) { _, phase in
                    chat.foregroundChanged(phase == .active)
                    if phase == .active { sync.foreground() } else { chat.persist() }
                }
                .onChange(of: engine.busy) { _, _ in chat.foregroundChanged(scenePhase == .active) }
        }
    }
    private var setup: some View {
        ContentUnavailableView {
            Label("尚未配置模型服务", systemImage: "server.rack")
        } description: {
            Text("添加服务商、填写 HTTPS 推理地址和模型后即可开始对话。API Key 只保存在本机钥匙串。")
        } actions: {
            Button("添加模型服务") { showProviders = true }.buttonStyle(.borderedProminent).accessibilityIdentifier("setupProviders")
        }.frame(maxHeight: .infinity)
    }
    private func modelBar(_ selected: ChatSession) -> some View {
        let state = providers.describe(selected.selection)
        return Button { inputFocused = false; showModels = true } label: {
            HStack(spacing: 6) {
                Image(systemName: state.problem == nil ? "cpu" : "exclamationmark.triangle")
                Text(state.label).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
                Spacer()
            }.font(.caption).foregroundStyle(state.problem == nil ? Color.secondary : Color.orange)
        }.accessibilityIdentifier("modelSelection")
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.displayedMessages.isEmpty {
                        Text("开始一个新话题，也可以让助手打开 App、查找内容或操作手机。")
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    ForEach(chat.displayedMessages) { message in
                        ChatMessageView(message: message, author: chat.author(of: message),
                                        streaming: chat.isStreaming(message.id)).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.vertical, 8)
            }.accessibilityIdentifier("chatTranscript")
                .onChange(of: chat.displayedMessages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.selectedID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
    private func composer(_ selected: ChatSession) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom) {
                TextEditor(text: Binding(get: { chat.selected?.draft ?? "" }, set: chat.setDraft))
                    .frame(height: 66).scrollContentBackground(.hidden).padding(4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .focused($inputFocused).accessibilityIdentifier("chatInput")
                Button(chat.active ? "追加" : "发送") { inputFocused = false; chat.send() }
                    .buttonStyle(.borderedProminent).disabled(!chat.canSend).accessibilityIdentifier("sendMessage")
            }
        }.padding(.bottom, 8)
    }
    private var sessionList: some View {
        NavigationStack {
            List {
                ForEach(chat.sessions.sorted { $0.updatedAt > $1.updatedAt }) { session in
                    Button { chat.select(session.id); showSessions = false } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title).foregroundStyle(.primary)
                            Text("\(session.state.label) · \(session.messages.count) 条消息 · \(providers.describe(session.selection).label)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.accessibilityIdentifier("session-\(session.id.uuidString)")
                        .swipeActions { if !chat.isRunning(session.id) { Button("删除", role: .destructive) { chat.delete(session.id) } } }
                }
            }.navigationTitle("会话")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("关闭") { showSessions = false }.accessibilityIdentifier("closeSessions") }
                    ToolbarItem(placement: .topBarTrailing) { Button("新建") { chat.newSession(); showSessions = false }.accessibilityIdentifier("createSession") }
                }
        }
    }
}

private struct ChatMessageView: View {
    let message: AgentTranscriptMessage
    let author: String
    let streaming: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(author).font(.caption).foregroundStyle(.secondary)
            if !message.text.isEmpty {
                if message.role == .tool {
                    DisclosureGroup(message.isError ? "执行失败" : "执行结果") {
                        Text(message.text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } else { Text(.init(message.text)).textSelection(.enabled) }
            } else if message.toolCalls.isEmpty {
                if streaming { ProgressView().controlSize(.small) }
                else { Text("本轮没有文本回复。").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(message.toolCalls, id: \.id) { call in
                Text("调用 \(call.name)").font(.caption.monospaced())
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(message.role == .user ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("message-\(message.id.uuidString)")
    }
}

extension ChatController {
    func isRunning(_ id: UUID) -> Bool { jobs[id] != nil }
    func isStreaming(_ id: UUID) -> Bool { live.values.contains { $0.id == id } }
}
