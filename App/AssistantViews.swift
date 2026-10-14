import AgentKit
import SwiftUI

// MARK: Storage

/// Save/load failures: retry restores storage only; reset is offered only for
/// an unreadable current file and moves it aside.
struct StorageBanner: View {
    @ObservedObject var chat: ChatController
    @State private var confirmReset = false

    var body: some View {
        if !chat.storageError.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(chat.storageError).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                HStack {
                    if chat.canResetStorage {
                        Button("重置助理数据…", role: .destructive) { confirmReset = true }
                            .accessibilityIdentifier("storageReset")
                    } else {
                        Button("重试保存") { chat.retryStorage() }.accessibilityIdentifier("storageRetry")
                    }
                }.font(.footnote).buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .confirmationDialog("重置助理数据？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("移开无法读取的文件并重新开始", role: .destructive) { chat.resetUnreadableStorage() }
            } message: {
                Text("无法读取的历史文件会被移到同一目录保留，不会删除；配对、钥匙串和设备设置不变。")
            }
        }
    }
}

// MARK: Primary recovery

/// The primary line was deleted, replaced or diverged elsewhere. Nothing is
/// chosen automatically; the user keeps a copy, picks a session or starts empty.
struct PrimaryNoticeCard: View {
    @ObservedObject var chat: ChatController

    var body: some View {
        if let notice = chat.assistant.primaryNotice {
            VStack(alignment: .leading, spacing: 8) {
                Label(title(notice), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                Text("在你选择之前，主线不会自动开始新的执行或待处理请求。").font(.caption).foregroundStyle(.secondary)
                ForEach(options(notice), id: \.self) { id in
                    Button("使用「\(chat.file.session(id)?.title ?? "会话")」作为主线") { chat.choosePrimary(id) }
                        .font(.caption)
                }
                Button("新建空主线（保留记忆）") { chat.startNewPrimary() }.font(.caption)
                    .accessibilityIdentifier("startNewPrimary")
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12).padding(.top, 6)
            .accessibilityIdentifier("primaryNotice")
        }
    }

    private func title(_ notice: PrimaryNotice) -> String {
        switch notice {
        case .missing: "找不到助理主线"
        case .remoteDeleted: "助理主线已在另一台设备删除"
        case .diverged: "助理主线出现了分叉"
        }
    }

    private func options(_ notice: PrimaryNotice) -> [UUID] {
        var ids: [UUID] = []
        switch notice {
        case .missing: break
        case .remoteDeleted(let copy): if let copy { ids.append(copy) }
        case .diverged(let copies): ids.append(chat.primaryID); ids += copies
        }
        return ids.filter { chat.file.session($0) != nil }
    }
}

// MARK: Pending next

struct PendingCard: View {
    @ObservedObject var chat: ChatController

    var body: some View {
        if let pending = chat.assistant.pendingNext, pending.sessionID == chat.selectedID {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stateTitle(pending)).font(.caption.weight(.semibold))
                        Text(text(pending)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                if chat.jobs[pending.sessionID] == nil {
                    HStack(spacing: 10) {
                        Button("继续") { chat.resumePending() }.accessibilityIdentifier("pendingResume")
                        if case .detached = pending.prompt {
                            Button("移回草稿") { chat.movePendingToDraft() }.accessibilityIdentifier("pendingToDraft")
                        }
                        Button("放弃", role: .destructive) { chat.discardPending() }.accessibilityIdentifier("pendingDiscard")
                    }
                    .font(.caption).buttonStyle(.bordered).controlSize(.small)
                    if case .promoted = pending.prompt {
                        Text("这条请求已在历史中但从未开始执行；继续会使用当前模型与项目设置，以同一请求开始。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("pendingCard")
        }
    }

    private func stateTitle(_ pending: PendingNext) -> String {
        switch pending.state {
        case .queued: chat.jobs[pending.sessionID] != nil ? "下一件事（当前任务完成后开始）" : "下一件事"
        case .held(let reason): "待处理：\(reason)"
        case .needsResume: "App 重启前留下的待处理请求；请确认是否继续"
        }
    }

    private func text(_ pending: PendingNext) -> String {
        switch pending.prompt {
        case .detached(let message, let attachments):
            message.text.isEmpty ? "图片 \(attachments.count) 张" : message.text
        case .promoted(let id):
            chat.file.session(pending.sessionID)?.messages.first { $0.id == id }?.text ?? "（原文在历史中）"
        }
    }
}

// MARK: References

struct ReferenceChips: View {
    @ObservedObject var chat: ChatController

    var body: some View {
        let references = chat.referenceDrafts[chat.primaryID] ?? []
        if chat.isPrimary(chat.selectedID), !references.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(references, id: \.self) { reference in
                        HStack(spacing: 4) {
                            Image(systemName: "quote.opening").font(.caption2)
                            Text(chat.referenceTitle(reference)).lineLimit(1)
                            Button { chat.removeReference(reference) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).accessibilityLabel("移除引用")
                        }
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
            }.accessibilityIdentifier("referenceChips")
        }
    }
}

// MARK: Memory panel

struct MemoryPanelView: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var workspaces: WorkspaceStore
    var prefill: MemoryDraft?
    @Environment(\.dismiss) private var dismiss
    @State private var editing: MemoryDraft?
    @State private var preview: ForgetPreview?
    @State private var previewEntry: MemoryRecord?

    var body: some View {
        NavigationStack {
            List {
                if !chat.memoryNotice.isEmpty {
                    Section { Text(chat.memoryNotice).font(.footnote).accessibilityIdentifier("memoryReceipt") }
                }
                Section {
                    let entries = chat.assistant.memory.active.sorted { $0.updatedAt > $1.updatedAt }
                    if entries.isEmpty {
                        Text("还没有记忆。用“记住：…”或右上角添加。记忆只保存你明确确认的内容。").foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.content).textSelection(.enabled)
                            Text(caption(entry)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("memory-\(entry.id.uuidString)")
                        .swipeActions(allowsFullSwipe: false) {
                            Button("遗忘") { startForget(entry) }.tint(.red)
                            Button("更正") { editing = MemoryDraft(editing: entry) }.tint(.indigo)
                        }
                        .contextMenu {
                            Button("更正", systemImage: "pencil") { editing = MemoryDraft(editing: entry) }
                            Button("遗忘…", systemImage: "eye.slash", role: .destructive) { startForget(entry) }
                        }
                    }
                } header: { Text("记忆 · \(chat.assistant.memory.active.count)/\(MemoryLimits.activeEntries)") } footer: {
                    Text("更正会在下一次请求生效，不撤销已有任务；遗忘会把用到这条记忆的已知对话排除出助理上下文（原文仍保留）。")
                }
                let receipts = chat.assistant.memoryReceipts.reversed()
                if !receipts.isEmpty {
                    Section("最近操作") {
                        ForEach(Array(receipts.prefix(12))) { receipt in
                            Text("\(receipt.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(receipt.action) · \(receipt.result)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("记忆")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = MemoryDraft(scope: chat.defaultMemoryScope) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加记忆").accessibilityIdentifier("addMemory")
                }
            }
            .sheet(item: $editing) { draft in
                MemoryEditorView(chat: chat, workspaces: workspaces, draft: draft) { editing = nil }
            }
            .sheet(item: Binding(get: { previewEntry }, set: { if $0 == nil { previewEntry = nil; preview = nil } })) { entry in
                ForgetPreviewView(chat: chat, entry: entry, preview: $preview) { previewEntry = nil; preview = nil }
            }
            .onAppear { if let prefill { editing = prefill } }
        }
    }

    private func caption(_ entry: MemoryRecord) -> String {
        let scope: String
        switch entry.scope {
        case .global: scope = "全局"
        case .workspace(let id): scope = "项目「\(workspaces.record(id)?.name ?? "已删除")」"
        }
        let origin = switch entry.origin { case .panel: "面板"; case .command: "命令"; case .chatChip: "对话" }
        return "\(entry.target == .user ? "个人资料" : "记忆") · \(scope) · 版本 \(entry.revision) · 来自\(origin) · \(entry.updatedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func startForget(_ entry: MemoryRecord) {
        guard let computed = chat.forgetPreview([entry.id]) else { return }
        preview = computed
        previewEntry = entry
    }
}

/// Add or correct one entry. A correction carries the revision it was shown
/// with; a stale revision is refused and the panel refreshes.
struct MemoryDraft: Identifiable {
    let id = UUID()
    var entryID: UUID?
    var expectedRevision: UInt64 = 0
    var content = ""
    var target = AgentMemoryTarget.memory
    var scope = MemoryScope.global
    var origin = MemoryOrigin.panel
    var sourceRoots: [UUID] = []
    var sourceMessages: [UUID] = []

    init(scope: MemoryScope, content: String = "", origin: MemoryOrigin = .panel, roots: [UUID] = [], messages: [UUID] = []) {
        self.scope = scope; self.content = content; self.origin = origin; sourceRoots = roots; sourceMessages = messages
    }
    init(editing entry: MemoryRecord) {
        entryID = entry.id; expectedRevision = entry.revision; content = entry.content
        target = entry.target; scope = entry.scope; origin = entry.origin
    }
}

struct MemoryEditorView: View {
    @ObservedObject var chat: ChatController
    @ObservedObject var workspaces: WorkspaceStore
    @State var draft: MemoryDraft
    let done: () -> Void
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("要记住的内容", text: $draft.content, axis: .vertical).lineLimit(2...8)
                        .accessibilityIdentifier("memoryContent")
                } footer: { Text("按原文保存，最多 \(MemoryLimits.entryScalars) 字；不要保存密码、密钥或临时信息。") }
                if draft.entryID == nil {
                    Section("类型与范围") {
                        Picker("类型", selection: $draft.target) {
                            Text("记忆").tag(AgentMemoryTarget.memory)
                            Text("个人资料（全局）").tag(AgentMemoryTarget.user)
                        }
                        Picker("范围", selection: $draft.scope) {
                            Text("全局").tag(MemoryScope.global)
                            ForEach(workspaces.workspaces) { record in
                                Text("项目：\(record.name)").tag(MemoryScope.workspace(record.id))
                            }
                        }.disabled(draft.target == .user)
                    }
                }
                if !error.isEmpty { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle(draft.entryID == nil ? "保存记忆" : "更正记忆")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { done() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.accessibilityIdentifier("memorySave")
                        .disabled(draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: draft.target) { _, target in if target == .user { draft.scope = .global } }
        }
    }

    private func save() {
        let edit: UserMemoryEdit = draft.entryID.map {
            .replace(entryID: $0, expectedRevision: draft.expectedRevision, content: draft.content)
        } ?? .add(target: draft.target, scope: draft.scope, content: draft.content, origin: draft.origin,
                  sourceRootPromptIDs: draft.sourceRoots, sourceMessageIDs: draft.sourceMessages)
        if chat.editMemory(edit) != nil { done() } else { error = chat.notice }
    }
}

/// The final forget panel: the selected entry and revision, the known
/// closure size, whether the current task stops, and that originals stay.
/// Confirm recomputes; any change refuses and refreshes here.
struct ForgetPreviewView: View {
    @ObservedObject var chat: ChatController
    let entry: MemoryRecord
    @Binding var preview: ForgetPreview?
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("将遗忘") {
                    Text(entry.content)
                    Text("版本 \(entry.revision)，包括此前所有版本的已知读取").font(.caption).foregroundStyle(.secondary)
                }
                if let preview {
                    Section("连带影响") {
                        Text("\(preview.affectedRootCount) 段已知相关对话将排除出助理上下文、摘要与历史检索")
                            .accessibilityIdentifier("forgetImpact")
                        if preview.affectedSummaries > 0 { Text("\(preview.affectedSummaries) 个摘要将失效") }
                        if preview.stopsActiveRoot { Text("当前正在进行的任务使用了它，将被停止").foregroundStyle(.red) }
                        Text("链式依赖可能覆盖之后同一范围的大部分历史。原文仍可在会话中查看；只作用于这台设备，不能撤回已发给模型服务的内容。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("确认遗忘")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { done() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("遗忘", role: .destructive) { confirm() }.accessibilityIdentifier("forgetConfirm")
                }
            }
        }
    }

    private func confirm() {
        guard let current = preview else { return }
        if chat.commitForget(current) { done() }
        else { preview = chat.forgetPreview([entry.id]) } // changed: refreshed numbers, confirm again
    }
}

// MARK: Budget

/// Local context budget for one provider/model. A confirmed window or an
/// explicit ceiling is a hard guard; empty keeps the unknown-window soft target.
struct ModelBudgetView: View {
    @ObservedObject var store: ProviderStore
    let providerID: UUID
    let modelID: String
    @State private var window = ""
    @State private var ceiling = ""
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                TextField("已确认的上下文窗口（token）", text: $window).keyboardType(.numberPad)
                TextField("本机输入上限（token，可选）", text: $ceiling).keyboardType(.numberPad)
            } footer: {
                Text("留空时按约 \(ContextBudgetPolicy.unknownSoftTarget) token 的软目标整理，不作为硬限制。填写窗口后输入上限为窗口减去输出与余量；明确上限优先使用较小值。只保存在这台设备。")
            }
            if !message.isEmpty { Section { Text(message).font(.footnote) } }
        }
        .navigationTitle(modelID)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } } }
        .onAppear {
            let current = store.budgetOverride(ModelSelection(providerID: providerID, modelID: modelID))
            window = current?.contextWindow.map(String.init) ?? ""
            ceiling = current?.inputCeiling.map(String.init) ?? ""
        }
    }

    private func save() {
        func value(_ text: String) -> Int?? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .some(nil) }
            return Int(trimmed).map { .some($0) } ?? nil
        }
        guard let window = value(window), let ceiling = value(ceiling) else { message = "请输入整数。"; return }
        let override = ContextBudgetOverride(providerID: providerID, modelID: modelID, contextWindow: window, inputCeiling: ceiling)
        do {
            try store.setBudget(override)
            message = override.isEmpty ? "已恢复为窗口未知（软目标）。" : (try? ContextBudgetPolicy.resolve(override).label) ?? "已保存。"
        } catch { message = error.localizedDescription }
    }
}
