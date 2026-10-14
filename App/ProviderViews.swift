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
    @State private var preset: ProviderConnectionPreset
    @State private var baseURL = ""
    @State private var secret = ""
    @State private var removeKey = false
    @State private var newModel = ""
    @State private var newModelImages = false
    @State private var modelSearch = ""
    @State private var fetching = false
    @State private var catalogMessage = ""
    @State private var catalogFailed = false
    @State private var message = ""
    @State private var activeCatalogRequest: UUID?
    @State private var catalogTask: Task<Void, Never>?

    init(store: ProviderStore, original: ProviderRecord?) {
        self.store = store; self.original = original
        let record = original ?? ProviderRecord()
        let input = original.flatMap(ProviderEndpoints.standardInput)
        _draft = State(initialValue: record)
        _baseURL = State(initialValue: input ?? "")
        // Recognize a standard pair only by exact, reversible addresses.
        // Custom routes stay untouched; a gateway brand is never guessed.
        _preset = State(initialValue: original == nil ? .compatible
                        : (input == nil ? .custom : .matching(record.format)))
    }

    private var hasStoredKey: Bool { store.keyed.contains(draft.id) }
    private var visibleModels: [ProviderModelEntry] {
        let search = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.models.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) }
    }
    private var endpoints: ProviderEndpoints? {
        guard preset != .custom else { return nil }
        return try? ProviderEndpoints.resolve(baseURL: baseURL, format: draft.format)
    }
    private var canFetch: Bool {
        guard let record = try? preparedRecord() else { return false }
        return !record.modelsBaseURL.isEmpty
    }

    /// Keys participate in stale-response detection only in memory.
    private struct CatalogInput: Equatable {
        let preset: ProviderConnectionPreset
        let baseURL: String
        let format: ModelAPIFormat
        let inferenceURL: String
        let catalogBaseURL: String
        let secret: String
        let removeKey: Bool
    }
    private var catalogInput: CatalogInput {
        CatalogInput(preset: preset, baseURL: baseURL, format: draft.format,
                     inferenceURL: draft.inferenceURL, catalogBaseURL: draft.modelsBaseURL,
                     secret: secret.trimmingCharacters(in: .whitespacesAndNewlines), removeKey: removeKey)
    }

    var body: some View {
        Form {
            Section {
                Picker("接入类型", selection: Binding(get: { preset }, set: selectPreset)) {
                    ForEach(ProviderConnectionPreset.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("providerPreset")
                if preset != .custom {
                    TextField("Base URL，例如 https://example.com/v1", text: $baseURL, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("providerBaseURL")
                }
                Picker("API 协议", selection: $draft.format) {
                    ForEach(ModelAPIFormat.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("providerFormat")
                if preset == .custom {
                    TextField(draft.format.urlHint, text: $draft.inferenceURL, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("providerInferenceURL")
                    TextField("模型目录 Base URL（可选），如 https://…/v1", text: $draft.modelsBaseURL, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("providerCatalogURL")
                }
                SecureField(hasStoredKey ? "API Key（留空保留已保存的 Key）" : "API Key", text: $secret)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("providerSecret")
                if hasStoredKey {
                    Toggle("保存时删除已保存的 Key", isOn: $removeKey).disabled(!secret.isEmpty)
                }
                if let record = try? preparedRecord(), let problem = store.keyProblem(record), secret.isEmpty, !removeKey {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                Button { fetchModels() } label: {
                    Label(fetching ? "正在连接…" : "连接并加载模型", systemImage: "arrow.triangle.2.circlepath")
                }.disabled(fetching || !canFetch)
                    .accessibilityIdentifier("providerConnect")
                if fetching { ProgressView("正在获取模型列表…") }
                if !catalogMessage.isEmpty {
                    Label(catalogMessage, systemImage: catalogFailed ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(catalogFailed ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("providerConnectionStatus")
                }
            } header: { Text("连接模型服务") } footer: {
                Text(preset.detail + " Key 只保存在本机钥匙串。连接操作只读取模型目录，失败时可手动添加模型。")
            }
            Section {
                DisclosureGroup("高级设置与地址预览") {
                    TextField("名称（可选，默认使用主机名）", text: $draft.name)
                        .accessibilityIdentifier("providerName")
                    Toggle("启用", isOn: $draft.isEnabled)
                    if preset == .custom {
                        endpointPreview("推理地址", value: draft.inferenceURL)
                        if !draft.modelsBaseURL.isEmpty {
                            endpointPreview("模型目录", value: ModelProvider(name: "preview", baseURL: draft.modelsBaseURL).resolvedModelsURL ?? "")
                        }
                        Text("完整推理地址原样请求，可使用 {model}。模型目录填 Base URL，请求时追加 /models。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let endpoints {
                        endpointPreview("推理地址", value: endpoints.inferenceURL)
                        endpointPreview("模型目录", value: endpoints.modelsURL)
                        Button("改用自定义完整地址") { selectPreset(.custom) }
                    } else {
                        Text("填写有效的 HTTPS Base URL 后显示请求地址。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("仅支持 HTTPS。Base URL 不接受查询参数；非标准路由请使用自定义地址。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                if !draft.models.isEmpty {
                    TextField("搜索模型", text: $modelSearch)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("providerModelSearch")
                    ForEach(visibleModels) { model in
                        Toggle(isOn: imageCapability(for: model.id)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.id)
                                Text(model.supportsImages ? "支持图像输入" : "仅文字输入")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.onDelete { indexes in
                        let ids = Set(indexes.map { visibleModels[$0].id })
                        draft.models.removeAll { ids.contains($0.id) }
                    }
                    if visibleModels.isEmpty { Text("没有匹配的模型。可以手动添加模型 ID。").foregroundStyle(.secondary) }
                } else {
                    Text("连接后显示模型列表，也可以直接填写模型 ID。").foregroundStyle(.secondary)
                }
                HStack {
                    TextField("手动添加模型 ID", text: $newModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("providerNewModel")
                    Toggle("图像", isOn: $newModelImages).labelsHidden().accessibilityLabel("新模型支持图像输入")
                    Button("添加") { addModel() }.disabled(newModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("providerAddModel")
                }
            } header: { Text("模型 · \(draft.models.count)") } footer: {
                Text("图像开关可手动调整。刷新保留已有模型和开关；模型目录连接成功并不代表每个模型都支持当前 API 协议。保存后在会话中选择模型。")
            }
            if let original, !original.models.isEmpty {
                Section {
                    ForEach(original.models) { model in
                        NavigationLink {
                            ModelBudgetView(store: store, providerID: original.id, modelID: model.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.id)
                                Text(budgetLabel(original.id, model.id)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("本机上下文预算") } footer: {
                    Text("只保存在这台设备、不同步。“你的助理”按这里的窗口或上限整理较早的对话；未设置时只按软目标整理。")
                }
            }
            if !message.isEmpty { Section { Text(message).font(.caption).foregroundStyle(.orange) } }
        }.navigationTitle(original == nil ? "添加模型服务" : (draft.name.isEmpty ? "编辑模型服务" : draft.name))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.accessibilityIdentifier("providerSave") }
            }
            .onChange(of: catalogInput) { _, _ in invalidateCatalog() }
            .onDisappear { invalidateCatalog(showMessage: false) }
    }

    private func budgetLabel(_ provider: UUID, _ model: String) -> String {
        let override = store.budgetOverride(ModelSelection(providerID: provider, modelID: model))
        return ((try? ContextBudgetPolicy.resolve(override)) ?? .unknown).label
    }

    private func endpointPreview(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let safe = try? EndpointValidation.validate(value, field: title) {
                Text(safe).font(.caption.monospaced()).textSelection(.enabled)
            } else {
                Text("请填写有效的 HTTPS 地址，凭据请放在 Key 栏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func preparedRecord() throws -> ProviderRecord {
        try ProviderEndpoints.applying(baseURL: preset == .custom ? nil : baseURL, to: draft)
    }

    private func selectPreset(_ next: ProviderConnectionPreset) {
        guard next != preset else { return }
        if next == .custom {
            if let endpoints {
                draft.inferenceURL = endpoints.inferenceURL
                draft.modelsBaseURL = endpoints.modelsBaseURL
            }
        } else {
            // Selecting a preset explicitly opts into a shared catalog base.
            // Recognize only an exactly reversible inference route; never
            // retain an unrelated old base when the custom route is unknown.
            if preset == .custom {
                baseURL = ProviderEndpoints.standardInferenceInput(for: draft) ?? ""
            }
            draft.format = next.format
        }
        preset = next
    }

    private func imageCapability(for id: String) -> Binding<Bool> {
        Binding(get: { draft.model(id)?.supportsImages ?? false }, set: { enabled in
            if let index = draft.models.firstIndex(where: { $0.id == id }) { draft.models[index].supportsImages = enabled }
        })
    }

    private func addModel() {
        let id = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if draft.model(id) == nil { draft.models.append(ProviderModelEntry(id: id, supportsImages: newModelImages)) }
        newModel = ""
    }

    private func invalidateCatalog(showMessage: Bool = true) {
        let wasFetching = fetching
        activeCatalogRequest = nil
        catalogTask?.cancel(); catalogTask = nil
        fetching = false
        if showMessage, wasFetching {
            catalogFailed = false
            catalogMessage = "连接信息已修改，请重新连接加载模型。"
        } else if showMessage { catalogMessage = "" }
    }

    private func fetchModels() {
        do {
            let record = try preparedRecord(), snapshot = catalogInput, requestID = UUID()
            activeCatalogRequest = requestID
            fetching = true; catalogMessage = ""; message = ""; catalogFailed = false
            catalogTask = Task {
                do {
                    let fetched = try await store.fetchModels(for: record, typedSecret: snapshot.secret, removeStoredKey: snapshot.removeKey)
                    guard activeCatalogRequest == requestID, catalogInput == snapshot, !Task.isCancelled else { return }
                    let count = draft.models.count
                    draft.models = ProviderCatalogMerge.merge(fetched, into: draft.models)
                    catalogMessage = fetched.isEmpty ? "连接成功，但目录没有返回对话模型。请手动添加模型 ID。"
                        : "连接成功，获取 \(fetched.count) 个模型，新增 \(draft.models.count - count) 个。"
                } catch {
                    guard activeCatalogRequest == requestID, catalogInput == snapshot, !Task.isCancelled else { return }
                    catalogFailed = true
                    catalogMessage = "连接失败：\(error.localizedDescription) 可检查地址、Key 和协议，或手动添加模型。"
                }
                if activeCatalogRequest == requestID { activeCatalogRequest = nil; fetching = false; catalogTask = nil }
            }
        } catch { message = error.localizedDescription }
    }

    private func save() {
        do {
            try store.save(preparedRecord(), newSecret: secret, removeSecret: removeKey)
            invalidateCatalog(showMessage: false)
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
    @State private var search = ""
    private func matches(_ model: ProviderModelEntry, provider: ProviderRecord) -> Bool {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || model.id.localizedCaseInsensitiveContains(term) || provider.name.localizedCaseInsensitiveContains(term)
    }
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
                        ForEach(provider.models.filter { matches($0, provider: provider) }) { model in
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
                if !search.isEmpty, !providers.providers.filter(\.isEnabled).contains(where: { provider in
                    provider.models.contains { matches($0, provider: provider) }
                }) {
                    Text("没有匹配的模型。").foregroundStyle(.secondary)
                }
                if providers.providers.allSatisfy({ !$0.isEnabled }) {
                    Text("没有已启用的服务商。").foregroundStyle(.secondary)
                }
                if offersDefault {
                    Section { Toggle("同时设为新会话默认模型", isOn: $makeDefault) }
                }
                Section { NavigationLink("管理模型服务") { ProviderListView(store: providers) } }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "搜索模型或服务")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}
