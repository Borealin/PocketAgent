import AgentKit
import Foundation

nonisolated struct ProviderModelEntry: Hashable, Codable, Sendable, Identifiable {
    var id: String
    var supportsImages: Bool
    var fetched = false
}

/// Nonsecret provider configuration. The API key is filed in the local
/// Keychain under the provider ID and has no field here, so it cannot reach
/// history, provider files, sync snapshots or logs through this type.
nonisolated struct ProviderRecord: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name = ""
    var format = ModelAPIFormat.chatCompletions
    var isEnabled = true
    /// Complete inference address; `{model}` is substituted when present.
    var inferenceURL = ""
    /// Optional model catalog base; blank disables model fetching.
    var modelsBaseURL = ""
    var models: [ProviderModelEntry] = []
    var updatedAt = Date()

    func model(_ id: String) -> ProviderModelEntry? { models.first { $0.id == id } }

    /// Origins (scheme://host[:port]) the provider's key is sent to.
    var credentialOrigins: Set<String> {
        Set([inferenceURL, modelsBaseURL].compactMap(EndpointValidation.origin))
    }

    /// Trims and validates every field; returns the normalized record.
    func validated() throws -> ProviderRecord {
        var record = self
        record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !record.name.isEmpty else { throw ProviderError.missingName }
        record.inferenceURL = try EndpointValidation.validate(inferenceURL, field: "推理 URL")
        let base = modelsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        record.modelsBaseURL = base.isEmpty ? "" : try EndpointValidation.validate(base, field: "模型目录 URL")
        var seen: Set<String> = []
        record.models = []
        for var entry in models {
            entry.id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.id.isEmpty else { throw ProviderError.emptyModelID }
            guard seen.insert(entry.id).inserted else { throw ProviderError.duplicateModel(entry.id) }
            record.models.append(entry)
        }
        return record
    }
}

/// assistant-v1 provider file: strict keys, explicit nulls, no legacy
/// endpoint/model/Keychain-ID migration. Budget overrides are local only.
nonisolated struct ProviderFile: Codable, Sendable {
    static let generationTag = HistoryFile.generationTag
    static let currentSchema = 1
    var generation = ProviderFile.generationTag
    var schemaVersion = ProviderFile.currentSchema
    var providers: [ProviderRecord] = []
    /// Local only: selection given to new conversations. Key required, may be null.
    var defaultSelection: ModelSelection?
    var deletedProviders: [Tombstone] = []
    /// Provider ID → origins its local key was entered for. A key is never
    /// sent to an origin outside this set (e.g. after a synced URL change).
    var keyOrigins: [String: [String]] = [:]
    /// Local context budget settings per provider/model; never synchronized.
    var budgetOverrides: [ContextBudgetOverride] = []

    init(providers: [ProviderRecord] = [], defaultSelection: ModelSelection? = nil, deletedProviders: [Tombstone] = [],
         keyOrigins: [String: [String]] = [:], budgetOverrides: [ContextBudgetOverride] = []) {
        self.providers = providers; self.defaultSelection = defaultSelection; self.deletedProviders = deletedProviders
        self.keyOrigins = keyOrigins; self.budgetOverrides = budgetOverrides
    }
    private enum CodingKeys: String, CodingKey {
        case generation, schemaVersion, providers, defaultSelection, deletedProviders, keyOrigins, budgetOverrides
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decode(String.self, forKey: .generation)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        guard generation == Self.generationTag else { throw ProviderError.unsupportedFormat(generation) }
        guard schemaVersion == Self.currentSchema else { throw ProviderError.unsupportedVersion(schemaVersion) }
        providers = try c.decode([ProviderRecord].self, forKey: .providers)
        defaultSelection = try c.nullable(ModelSelection.self, .defaultSelection)
        deletedProviders = try c.decode([Tombstone].self, forKey: .deletedProviders)
        keyOrigins = try c.decode([String: [String]].self, forKey: .keyOrigins)
        budgetOverrides = try c.decode([ContextBudgetOverride].self, forKey: .budgetOverrides)
        guard Set(providers.map(\.id)).count == providers.count else { throw ProviderError.invalidFile("重复服务商 ID") }
        guard Set(budgetOverrides.map { "\($0.providerID.uuidString)/\($0.modelID)" }).count == budgetOverrides.count else {
            throw ProviderError.invalidFile("重复上下文预算设置")
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generation, forKey: .generation); try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(providers, forKey: .providers); try c.encode(defaultSelection, forKey: .defaultSelection)
        try c.encode(deletedProviders, forKey: .deletedProviders); try c.encode(keyOrigins, forKey: .keyOrigins)
        try c.encode(budgetOverrides, forKey: .budgetOverrides)
    }

    func budgetOverride(_ selection: ModelSelection) -> ContextBudgetOverride? {
        budgetOverrides.first { $0.providerID == selection.providerID && $0.modelID == selection.modelID }
    }
}

nonisolated enum ProviderError: LocalizedError, Equatable {
    case missingName, emptyModelID, duplicateModel(String)
    case invalidURL(String), insecureURL(String), credentialInURL(String)
    case noSelection, providerDeleted, providerDisabled(String), modelMissing(String, String)
    case keyOriginChanged(String)
    case unsupportedVersion(Int)
    case unsupportedFormat(String)
    case invalidFile(String)
    var errorDescription: String? {
        switch self {
        case .missingName: "请填写服务商名称。"
        case .emptyModelID: "模型 ID 不能为空。"
        case .duplicateModel(let id): "模型 \(id) 重复。"
        case .invalidURL(let field): "\(field)无效。"
        case .insecureURL(let field): "\(field)必须使用 HTTPS。"
        case .credentialInURL(let field): "\(field)不能包含用户名、密码或凭据参数；API Key 请填在密钥栏。"
        case .noSelection: "本会话尚未选择模型，请先选择服务商和模型。"
        case .providerDeleted: "该服务商已删除：会话请重新选择模型；编辑中的配置无法保存，请作为新服务商添加。"
        case .providerDisabled(let name): "服务商 \(name) 已停用，请启用或重新选择模型。"
        case .modelMissing(let name, let model): "服务商 \(name) 中没有模型 \(model)，请重新选择。"
        case .unsupportedVersion(let version): "不支持的服务商文件版本 \(version)"
        case .unsupportedFormat(let generation): "不支持的服务商文件格式 \(generation)；本版本只读取 assistant-v1。"
        case .invalidFile(let detail): "服务商文件内容无效：\(detail)"
        case .keyOriginChanged(let name):
            "服务商 \(name) 的地址已改为本机 Key 未确认的主机；为避免把 API Key 发往该地址，请在模型服务中重新输入 Key 或删除 Key。"
        }
    }
}

nonisolated enum EndpointValidation {
    private static let credentialNames = ["key", "token", "secret", "auth", "sig", "password", "passwd", "credential", "session"]

    /// HTTPS only, with a host, no user/password and no credential-bearing
    /// query parameters. `{model}` may appear anywhere in the address.
    static func validate(_ raw: String, field: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = value.replacingOccurrences(of: ModelProvider.modelToken, with: "model")
        guard !value.isEmpty, let components = URLComponents(string: probe),
              let scheme = components.scheme?.lowercased() else { throw ProviderError.invalidURL(field) }
        guard scheme == "https" else { throw ProviderError.insecureURL(field) }
        guard let host = components.host, !host.isEmpty else { throw ProviderError.invalidURL(field) }
        guard components.user == nil, components.password == nil else { throw ProviderError.credentialInURL(field) }
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            if credentialNames.contains(where: { name.contains($0) }) { throw ProviderError.credentialInURL(field) }
        }
        guard components.fragment == nil else { throw ProviderError.invalidURL(field) }
        return value
    }

    static func origin(of raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let components = URLComponents(string: value.replacingOccurrences(of: ModelProvider.modelToken, with: "model")),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let port = components.port.flatMap { $0 == 443 && scheme == "https" ? nil : ":\($0)" } ?? ""
        return scheme + "://" + host + port
    }
}

/// Everything a queued turn needs, captured at enqueue. Later provider edits,
/// selection changes or deletion do not affect accepted work. Not Codable:
/// the secret lives only in memory for the lifetime of the job.
nonisolated struct RunConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let providerID: UUID
    let providerName: String
    let format: ModelAPIFormat
    let inferenceURL: String
    let modelID: String
    let supportsImages: Bool
    let secret: String
    /// Context budget frozen with the turn; local override or unknown-window soft target.
    var budget: ContextBudgetPolicy = .unknown

    /// Model first, then the provider. Recorded as attribution for new
    /// replies; attributions already in history are shown verbatim.
    var label: String { "\(modelID) · \(providerName)" }
    var description: String { label }
    var debugDescription: String { label }

    var agentProvider: ModelProvider {
        ModelProvider(id: providerID, name: providerName, apiFormat: format, inferenceURL: inferenceURL)
    }
    var agentModel: AIModel {
        AIModel(id: modelID, input: supportsImages ? [.text, .image] : [.text], maxOutputTokens: 4096)
    }

    /// Strict resolution: no fallback to another provider or model.
    /// `boundOrigins` returns the origins the stored key was entered for; a
    /// stored key is refused for any other origin.
    static func resolve(_ selection: ModelSelection?, providers: [ProviderRecord],
                        secret: (UUID) throws -> String?,
                        boundOrigins: (UUID) -> Set<String>?,
                        budgetOverride: ContextBudgetOverride? = nil) throws -> RunConfiguration {
        guard let selection else { throw ProviderError.noSelection }
        guard let provider = providers.first(where: { $0.id == selection.providerID }) else { throw ProviderError.providerDeleted }
        guard provider.isEnabled else { throw ProviderError.providerDisabled(provider.name) }
        guard let model = provider.model(selection.modelID) else {
            throw ProviderError.modelMissing(provider.name, selection.modelID)
        }
        let valid = try provider.validated()
        let key = try secret(valid.id) ?? ""
        if !key.isEmpty, !(boundOrigins(valid.id).map { valid.credentialOrigins.isSubset(of: $0) } ?? false) {
            throw ProviderError.keyOriginChanged(valid.name)
        }
        return RunConfiguration(providerID: valid.id, providerName: valid.name, format: valid.format,
                                inferenceURL: valid.inferenceURL, modelID: model.id,
                                supportsImages: model.supportsImages, secret: key,
                                budget: try ContextBudgetPolicy.resolve(budgetOverride))
    }
}

/// Which origins a provider's local key may be sent to after an edit.
nonisolated enum KeyBinding {
    /// Returns the new bound origins (nil = no key). A new key binds to the
    /// saved addresses; editing the address on this device is explicit intent
    /// and rebinds the kept key; saving an address that changed elsewhere
    /// (sync) without re-entering the key is refused.
    static func afterSave(stored: ProviderRecord?, saved: ProviderRecord, bound: Set<String>?,
                          hasStoredKey: Bool, enteredNewKey: Bool, removeKey: Bool) throws -> Set<String>? {
        if enteredNewKey { return saved.credentialOrigins }
        if removeKey || !hasStoredKey { return nil }
        if let bound, saved.credentialOrigins.isSubset(of: bound) { return bound }
        if let stored, stored.credentialOrigins != saved.credentialOrigins { return saved.credentialOrigins }
        throw ProviderError.keyOriginChanged(saved.name)
    }
}
