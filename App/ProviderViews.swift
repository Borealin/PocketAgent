import AgentKit
import SwiftUI

extension ModelAPIFormat {
    var title: String {
        switch self {
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses"
        case .messages: "Messages"
        case .generateContent: "Generate Content"
        }
    }
    var urlHint: String {
        switch self {
        case .chatCompletions: "https://…/v1/chat/completions"
        case .responses: "https://…/v1/responses"
        case .messages: "https://…/v1/messages"
        case .generateContent: "https://…/v1beta/models/{model}:generateContent"
        }
    }
}

/// Dedicated provider management page, reached from Settings or setup.
struct ProviderListView: View {
    @ObservedObject var store: ProviderStore
    @State private var pendingDelete: ProviderRecord?
    var body: some View {
        List {
            if store.providers.isEmpty {
                ContentUnavailableView("尚未添加服务商", systemImage: "server.rack",
                                       description: Text("点右上角 + 添加。不会自动使用任何内置服务。"))
            }
            ForEach(store.providers) { provider in
                NavigationLink { ProviderEditorView(store: store, original: provider) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(provider.name)
                            if !provider.isEnabled { Text("已停用").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text("\(provider.format.title) · \(provider.models.count) 个模型 · \(store.keyed.contains(provider.id) ? "Key 已保存" : "无 Key")")
                            .font(.caption).foregroundStyle(.secondary)
                        if store.keyProblem(provider) != nil {
                            Text("地址已变更，需重新输入 Key").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }.accessibilityIdentifier("provider-\(provider.id.uuidString)")
                    .swipeActions {
                        Button("删除", role: .destructive) { pendingDelete = provider }
                        Button(provider.isEnabled ? "停用" : "启用") { store.setEnabled(provider.id, !provider.isEnabled) }
                    }
            }
        }.navigationTitle("模型服务")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { ProviderEditorView(store: store, original: nil) } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("addProvider")
                }
            }
            .confirmationDialog("删除服务商？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { provider in
                Button("删除 \(provider.name) 及其本机 Key", role: .destructive) { store.delete(provider.id) }
            } message: { _ in
                Text("使用它的会话将显示为未选择模型，需要重新选择；已排队的任务不受影响。")
            }
    }
}

struct ProviderEditorView: View {
    @ObservedObject var store: ProviderStore
    let original: ProviderRecord?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProviderRecord
    @State private var secret = ""
    @State private var removeKey = false
    @State private var newModel = ""
    @State private var newModelImages = false
    @State private var fetching = false
    @State private var message = ""

    init(store: ProviderStore, original: ProviderRecord?) {
        self.store = store; self.original = original
        _draft = State(initialValue: original ?? ProviderRecord())
    }

    private var hasStoredKey: Bool { store.keyed.contains(draft.id) }

    var body: some View {
        Form {
            Section("服务商") {
                TextField("名称", text: $draft.name).accessibilityIdentifier("providerName")
                Picker("API 格式", selection: $draft.format) {
                    ForEach(ModelAPIFormat.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("providerFormat")
                Toggle("启用", isOn: $draft.isEnabled)
            }
            Section {
                TextField(draft.format.urlHint, text: $draft.inferenceURL, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("providerInferenceURL")
                TextField("模型目录 URL（可选），如 https://…/v1", text: $draft.modelsBaseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("providerCatalogURL")
            } header: { Text("地址") } footer: {
                Text("推理 URL 填完整地址，原样请求；可用 {model} 代替模型 ID。仅支持 HTTPS，不能在 URL 中包含用户名、密码或密钥参数。")
            }
            Section {
                SecureField(hasStoredKey ? "已保存；留空保持不变" : "API Key", text: $secret)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("providerSecret")
                if hasStoredKey {
                    Toggle("保存时删除已保存的 Key", isOn: $removeKey).disabled(!secret.isEmpty)
                }
                if let problem = store.provider(draft.id).flatMap(store.keyProblem) {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("API Key") } footer: { Text("只保存在本机钥匙串，不会同步、备份到其他设备或写入日志。") }
            Section {
                ForEach($draft.models) { $model in
                    Toggle(isOn: $model.supportsImages) {
                        VStack(alignment: .leading) {
                            Text(model.id)
                            Text(model.supportsImages ? "接收照片、截图和界面结构" : "仅接收文字和界面结构").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.onDelete { draft.models.remove(atOffsets: $0) }
                HStack {
                    TextField("添加模型 ID", text: $newModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("providerNewModel")
                    Toggle("图像", isOn: $newModelImages).labelsHidden()
                    Button("添加") { addModel() }.disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("providerAddModel")
                }
                Button(fetching ? "正在获取…" : "从模型目录获取") { fetchModels() }
                    .disabled(fetching || draft.modelsBaseURL.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: { Text("模型") } footer: { Text("开关表示模型是否接受图像输入。获取模型列表是可选的，可直接手动填写模型 ID。") }
            if !message.isEmpty { Section { Text(message).font(.caption) } }
        }.navigationTitle(original == nil ? "添加服务商" : draft.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.accessibilityIdentifier("providerSave") }
            }
    }

    private func addModel() {
        let id = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if draft.model(id) == nil { draft.models.append(ProviderModelEntry(id: id, supportsImages: newModelImages)) }
        newModel = ""
    }

    private func fetchModels() {
        fetching = true; message = ""
        Task {
            defer { fetching = false }
            do {
                let fetched = try await store.fetchModels(for: draft, typedSecret: secret)
                let known = Set(draft.models.map(\.id))
                draft.models += fetched.filter { !known.contains($0.id) }
                message = "获取到 \(fetched.count) 个对话模型。"
            } catch { message = "获取失败：\(error.localizedDescription)" }
        }
    }

    private func save() {
        do {
            try store.save(draft, newSecret: secret, removeSecret: removeKey)
            secret = ""
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

/// Native model selection for a conversation (or the new-session default).
struct ModelPickerSheet: View {
    @ObservedObject var providers: ProviderStore
    let current: ModelSelection?
    let title: String
    var offersDefault = true
    let onSelect: (ModelSelection, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var makeDefault = false
    var body: some View {
        NavigationStack {
            List {
                if let problem = providers.describe(current).problem, current != nil {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                // Model name is the row; provider and API format are its caption.
                Section {
                    ForEach(providers.providers.filter(\.isEnabled)) { provider in
                        if provider.models.isEmpty {
                            Text("\(provider.name) 尚未添加模型").font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(provider.models) { model in
                            let selection = ModelSelection(providerID: provider.id, modelID: model.id)
                            Button { onSelect(selection, makeDefault) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(model.id).foregroundStyle(.primary)
                                            if model.supportsImages {
                                                Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
                                                    .accessibilityLabel("支持图片")
                                            }
                                        }
                                        Text("\(provider.name) · \(provider.format.title)")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if current == selection { Image(systemName: "checkmark") }
                                }
                            }.accessibilityIdentifier("model-\(provider.id.uuidString)-\(model.id)")
                        }
                    }
                }
                if providers.providers.allSatisfy({ !$0.isEnabled }) {
                    Text("没有已启用的服务商。").foregroundStyle(.secondary)
                }
                if offersDefault {
                    Section { Toggle("同时设为新会话默认模型", isOn: $makeDefault) }
                }
                Section { NavigationLink("管理模型服务") { ProviderListView(store: providers) } }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}
