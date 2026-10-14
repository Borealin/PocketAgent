import SwiftUI
import UIKit

/// Chat screen: header with only the session-list icon, the renamable title
/// and a new-conversation icon. Sessions and Settings live in a slide-over
/// drawer opened by the icon or a leading-edge swipe.
struct ChatRootView: View {
    @ObservedObject var engine: Model
    @ObservedObject var chat: ChatController
    @ObservedObject var providers: ProviderStore
    @ObservedObject var sync: SyncCoordinator
    @ObservedObject var device: DeviceSettingsModel
    @ObservedObject var workspaces: WorkspaceStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var drawerOpen = false
    @State private var drag: CGFloat = 0
    @State private var showSettings = false
    @State private var showModels = false
    @State private var showWorkspaces = false
    @State private var showProviders = false
    @State private var renaming: UUID?
    @State private var newTitle = ""
    @State private var showMemory = false
    @State private var memoryPrefill: MemoryDraft?
    @FocusState private var inputFocused: Bool
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

    var body: some View {
        GeometryReader { geometry in
            let width = min(320, geometry.size.width * 0.84)
            let offset = drawerOffset(width: width)
            let progress = (offset + width) / width
            ZStack(alignment: .leading) {
                NavigationStack { main }
                if progress > 0 {
                    Color.black.opacity(0.28 * progress).ignoresSafeArea()
                        .onTapGesture { closeDrawer() }
                        .gesture(closeGesture(width: width))
                        .accessibilityLabel("关闭会话列表").accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("closeSessions")
                }
                SessionDrawer(chat: chat, providers: providers, close: closeDrawer,
                              rename: startRename, openSettings: { closeDrawer(); showSettings = true },
                              openMemory: { closeDrawer(); memoryPrefill = nil; showMemory = true })
                    .frame(width: width)
                    .offset(x: offset)
                    .gesture(closeGesture(width: width))
                    .accessibilityHidden(!drawerOpen)
                if !drawerOpen {
                    // Leading-edge swipe opens the drawer.
                    // Below the header so the list button stays fully tappable.
                    Color.clear.frame(width: 16).contentShape(Rectangle())
                        .gesture(openGesture(width: width)).padding(.top, 56)
                }
            }
            .animation(.snappy(duration: 0.25), value: drawerOpen)
        }
        .alert("重命名会话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("会话标题", text: $newTitle)
            Button("保存") { if let renaming { chat.rename(renaming, to: newTitle) } }.accessibilityIdentifier("renameSave")
            Button("取消", role: .cancel) {}
        }
        .alert(item: $chat.imageWarning) { warning in imageAlert(warning) }
        .sheet(isPresented: $showMemory) {
            MemoryPanelView(chat: chat, workspaces: workspaces, prefill: memoryPrefill)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine, providers: providers, sync: sync, device: device, workspaces: workspaces) { showSettings = false }
        }
        .sheet(isPresented: $showWorkspaces) {
            if let selected = chat.selected {
                WorkspacePickerSheet(store: workspaces, current: selected.workspaceID) { id in
                    chat.setWorkspace(id, for: selected.id); showWorkspaces = false
                }
            }
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
        .task { try? await ScriptRuntime.shared.checkTools() }
        // Applied to the hosting window only. Open sheets (Settings, model
        // picker, providers) are presented in that window and inherit it.
        .background(WindowAppearance(style: appearance.interfaceStyle))
    }

    private var main: some View {
        VStack(spacing: 0) {
            StorageBanner(chat: chat)
            if !providers.storageError.isEmpty { banner(providers.storageError, color: .red) }
            if !providers.notice.isEmpty { banner(providers.notice, color: .orange) }
            if providers.isConfigured {
                // One transcript identity per conversation: switching recreates
                // its scroll position and lazy layout state, starting at the bottom.
                if chat.isPrimary(chat.selectedID) || chat.assistant.primaryNotice != nil { PrimaryNoticeCard(chat: chat) }
                ChatTranscriptView(chat: chat, dismissKeyboard: { inputFocused = false },
                                   saveAsMemory: { draft in memoryPrefill = draft; showMemory = true })
                    .id(chat.selectedID)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let selected = chat.selected {
                            VStack(spacing: 0) {
                                ExecutionStrip(chat: chat, session: selected)
                                ChatComposer(chat: chat, providers: providers, workspaces: workspaces, session: selected,
                                             inputFocused: $inputFocused, chooseModel: { inputFocused = false; showModels = true },
                                             chooseWorkspace: { inputFocused = false; showWorkspaces = true })
                            }
                            .background(.bar)
                        }
                    }
            } else { setup }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { openDrawer() } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("会话列表").accessibilityIdentifier("sessions")
            }
            ToolbarItem(placement: .principal) {
                Text(chat.isPrimary(chat.selectedID) ? ChatSession.primaryTitle : (chat.selected?.title ?? "手机助手"))
                    .font(.headline).lineLimit(1)
                    .padding(.horizontal, 8).contentShape(Rectangle())
                    .onTapGesture { if let id = chat.selectedID, !chat.isPrimary(id) { startRename(id) } }
                    .onLongPressGesture { if let id = chat.selectedID, !chat.isPrimary(id) { startRename(id) } }
                    .accessibilityAddTraits(.isButton).accessibilityHint("轻点以重命名")
                    .accessibilityIdentifier("renameSession")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if chat.isPrimary(chat.selectedID) {
                    Button { inputFocused = false; memoryPrefill = nil; showMemory = true } label: { Image(systemName: "brain") }
                        .accessibilityLabel("记忆").accessibilityIdentifier("openMemory")
                } else {
                    Button { inputFocused = false; chat.selectPrimary() } label: { Image(systemName: "person.crop.circle") }
                        .accessibilityLabel("回到你的助理").accessibilityIdentifier("backToAssistant")
                }
            }
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text).font(.footnote).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.vertical, 6).textSelection(.enabled)
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

    private func imageAlert(_ warning: ImageWarning) -> Alert {
        let change = Alert.Button.default(Text("更换模型")) { showModels = true }
        if warning.verdict == .warnDropImages {
            return Alert(title: Text("当前模型不接收图片"),
                         message: Text("\(warning.modelLabel) 只接收文字，图片不会发送给模型。可以只发送文字（图片保留在草稿中），或换用支持图片的模型。"),
                         primaryButton: .default(Text("仅发送文字")) {
                             // After the alert's own binding reset.
                             Task { @MainActor in chat.send(textOnly: true) }
                         },
                         secondaryButton: change)
        }
        return Alert(title: Text("当前模型不接收图片"),
                     message: Text("\(warning.modelLabel) 只接收文字，无法发送仅含图片的消息。请换用支持图片的模型，或输入文字。"),
                     primaryButton: change, secondaryButton: .cancel(Text("取消")))
    }

    // MARK: Drawer

    private func drawerOffset(width: CGFloat) -> CGFloat {
        let base: CGFloat = drawerOpen ? 0 : -width
        return min(0, max(-width, base + drag))
    }
    private func openDrawer() { inputFocused = false; drag = 0; drawerOpen = true }
    private func closeDrawer() { drag = 0; drawerOpen = false }
    private func startRename(_ id: UUID) {
        newTitle = chat.sessions.first { $0.id == id }?.title ?? ""
        renaming = id
    }
    private func openGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in inputFocused = false; drag = max(0, min(width, value.translation.width)) }
            .onEnded { value in
                let open = value.predictedEndTranslation.width > width / 2 || value.translation.width > width / 3
                withAnimation(.snappy(duration: 0.25)) { drag = 0; drawerOpen = open }
            }
    }
    private func closeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in if drawerOpen { drag = min(0, value.translation.width) } }
            .onEnded { value in
                let close = value.predictedEndTranslation.width < -width / 2 || value.translation.width < -width / 3
                withAnimation(.snappy(duration: 0.25)) { drag = 0; if close { drawerOpen = false } }
            }
    }
}

/// Slide-over list: the assistant entry, memory, independent tasks/history
/// (select, rename, delete, new task) and Settings.
private struct SessionDrawer: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var providers: ProviderStore
    let close: () -> Void
    let rename: (UUID) -> Void
    let openSettings: () -> Void
    let openMemory: () -> Void
    @State private var pendingDelete: ChatSession?
    @State private var confirmClear = false
    @State private var clearBlocked: String?

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Button { chat.selectPrimary(); close() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ChatSession.primaryTitle).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Text(primarySubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .listRowBackground(chat.isPrimary(chat.selectedID) ? Color.accentColor.opacity(0.14) : Color.clear)
                    .accessibilityIdentifier("assistantEntry")
                    .swipeActions(allowsFullSwipe: false) {
                        Button("清空", systemImage: "eraser") { requestClear() }.tint(.orange)
                    }
                    .contextMenu {
                        Button("清空对话，保留记忆…", systemImage: "eraser", role: .destructive) { requestClear() }
                            .accessibilityIdentifier("clearAssistantConversation")
                    }
                    Button(action: openMemory) { Label("记忆 · \(chat.assistant.memory.active.count)", systemImage: "brain") }
                        .accessibilityIdentifier("drawerMemory")
                }
                Section {
                    ForEach(chat.taskSessions) { session in
                        Button { chat.select(session.id); close() } label: { row(session) }
                            .listRowBackground(session.id == chat.selectedID ? Color.accentColor.opacity(0.14) : Color.clear)
                            .accessibilityIdentifier("session-\(session.id.uuidString)")
                            .swipeActions(allowsFullSwipe: false) {
                                if chat.canDelete(session.id) {
                                    // This only requests confirmation. A destructive
                                    // swipe role animates removal before confirmation.
                                    Button("删除", systemImage: "trash") { pendingDelete = session }
                                        .tint(.red)
                                }
                                Button("重命名") { rename(session.id) }.tint(.indigo)
                            }
                            .contextMenu {
                                Button("重命名", systemImage: "pencil") { rename(session.id) }
                                if chat.canDelete(session.id) {
                                    Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = session }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("任务 / 历史")
                        Spacer()
                        Button { chat.newSession(); close() } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("新任务").accessibilityIdentifier("createSession")
                    }
                }
            }.listStyle(.insetGrouped)
            Divider()
            Button(action: openSettings) {
                Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
            }.padding().accessibilityIdentifier("settings")
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .confirmationDialog("删除会话？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { session in
            Button("删除「\(session.title)」", role: .destructive) {
                withAnimation { chat.delete(session.id) }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { _ in Text("会话及其本机图片将从这台设备删除；已开启同步时其他设备也会删除。") }
        .confirmationDialog("清空“你的助理”的对话？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空对话，保留记忆", role: .destructive) { withAnimation { chat.clearPrimaryConversation() } }
                .accessibilityIdentifier("confirmClearAssistant")
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除助理主线的全部对话、草稿、引用、对话摘要和只属于这些对话的图片，不能撤销；已开启同步时其他设备也会删除。"
                 + "已保存的记忆、遗忘记录、当前模型与项目、模型服务和其他任务都会保留。")
        }
        .alert("暂时不能清空", isPresented: Binding(get: { clearBlocked != nil }, set: { if !$0 { clearBlocked = nil } })) {
            Button("好", role: .cancel) { clearBlocked = nil }
        } message: { Text(clearBlocked ?? "") }
    }

    /// Asks for confirmation, or explains what has to be stopped or handled first.
    private func requestClear() {
        if let blocker = chat.clearPrimaryBlocker { clearBlocked = blocker } else { confirmClear = true }
    }

    private var primarySubtitle: String {
        guard let primary = chat.file.primary else { return "需要恢复主线" }
        let state = chat.status(for: primary.id).map(\.phaseLabel) ?? primary.state.label
        return "\(state) · \(providers.describe(primary.selection).label)"
    }

    private func row(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(session.title).font(.body).foregroundStyle(.primary).lineLimit(1)
                if chat.isRunning(session.id) { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.orange) }
            }
            Text(subtitle(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.vertical, 2)
    }

    private func subtitle(_ session: ChatSession) -> String {
        let state = chat.status(for: session.id).map(\.phaseLabel) ?? session.state.label
        return "\(state) · \(session.messages.count) 条 · \(providers.describe(session.selection).label)"
    }
}

/// Sets the hosting window's `overrideUserInterfaceStyle`. A presentation-level
/// `preferredColorScheme` override could stay light on an open sheet after
/// switching back to the system setting; clearing the window to
/// `.unspecified` returns every presentation in it to the system appearance.
private struct WindowAppearance: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    final class Probe: UIView {
        var style = UIUserInterfaceStyle.unspecified { didSet { apply() } }
        override func didMoveToWindow() { super.didMoveToWindow(); apply() }
        private func apply() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { view.style = style }
}
