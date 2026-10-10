import AgentKit
import Foundation
import Security

/// Provider API keys live only in this device's Keychain, one item per
/// provider ID, and are never synchronized or backed up to another device.
enum ProviderKeychain {
    static let service = "PocketAgent.ProviderKey"

    static func read(service: String, account: String) throws -> String? {
        var query = base(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw failure("Keychain 读取失败：\(status)") }
        return String(data: data, encoding: .utf8)
    }
    static func secret(for id: UUID) throws -> String? { try read(service: service, account: id.uuidString) }

    static func setSecret(_ secret: String, for id: UUID) throws {
        let query = base(service, id.uuidString), data = Data(secret.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw failure("Keychain 更新失败：\(update)") }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure("Keychain 保存失败：\(status)") }
    }

    static func removeSecret(for id: UUID) throws {
        let status = SecItemDelete(base(service, id.uuidString) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure("Keychain 删除失败：\(status)") }
    }

    private static func base(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

@MainActor
final class ProviderStore: ObservableObject {
    @Published private(set) var providers: [ProviderRecord] = []
    @Published private(set) var defaultSelection: ModelSelection?
    @Published private(set) var keyed: Set<UUID> = []
    @Published var storageError = ""
    @Published var notice = ""
    private(set) var deletedProviders: [Tombstone] = []
    private var legacySecretPending = false
    private var keyOrigins: [String: [String]] = [:]
    private let file = applicationSupport.appendingPathComponent("providers.json")

    init() {
        load()
        importProvisioningFile()
    }

    /// Selection for conversations stored before per-session selection existed.
    /// Deterministic, so it holds even if the provider file is unreadable.
    var legacySelection: ModelSelection? {
        let defaults = UserDefaults.standard
        let legacy = providers.first { $0.id == LegacyProviderMigration.providerID }
            ?? LegacyProviderMigration.provider(endpoint: defaults.string(forKey: "agentEndpoint"),
                                                model: defaults.string(forKey: "agentModel"))
        return legacy.flatMap(LegacyProviderMigration.selection)
    }
    var isConfigured: Bool { !providers.isEmpty }
    func provider(_ id: UUID) -> ProviderRecord? { providers.first { $0.id == id } }

    func configuration(for selection: ModelSelection?) throws -> RunConfiguration {
        try RunConfiguration.resolve(selection, providers: providers, secret: { try ProviderKeychain.secret(for: $0) },
                                     boundOrigins: boundOrigins)
    }

    func boundOrigins(_ id: UUID) -> Set<String>? { keyOrigins[id.uuidString].map(Set.init) }

    /// Non-nil when the stored key may not be sent to the provider's current address.
    func keyProblem(_ provider: ProviderRecord) -> String? {
        guard keyed.contains(provider.id),
              !(boundOrigins(provider.id).map { provider.credentialOrigins.isSubset(of: $0) } ?? false) else { return nil }
        return ProviderError.keyOriginChanged(provider.name).localizedDescription
    }

    /// Display state for a selection; `problem` is non-nil when unresolved.
    func describe(_ selection: ModelSelection?) -> (label: String, problem: String?) {
        guard let selection else { return ("选择模型", ProviderError.noSelection.localizedDescription) }
        guard let provider = provider(selection.providerID) else {
            return ("\(selection.modelID)（服务商已删除）", ProviderError.providerDeleted.localizedDescription)
        }
        let label = "\(selection.modelID) · \(provider.name)"
        if !provider.isEnabled { return (label, ProviderError.providerDisabled(provider.name).localizedDescription) }
        if provider.model(selection.modelID) == nil {
            return (label, ProviderError.modelMissing(provider.name, selection.modelID).localizedDescription)
        }
        return (label, keyProblem(provider))
    }

    // MARK: CRUD

    /// Blank `newSecret` keeps the stored key; `removeSecret` deletes it.
    func save(_ record: ProviderRecord, newSecret: String, removeSecret: Bool) throws {
        guard storageError.isEmpty else { throw failure(storageError) }
        // An editor left open while sync deleted this provider must not revive it.
        guard !deletedProviders.contains(where: { $0.id == record.id }) else { throw ProviderError.providerDeleted }
        var record = try record.validated()
        record.updatedAt = Date()
        let secret = newSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let bound = try KeyBinding.afterSave(stored: provider(record.id), saved: record, bound: boundOrigins(record.id),
                                             hasStoredKey: (try ProviderKeychain.secret(for: record.id)) != nil,
                                             enteredNewKey: !secret.isEmpty, removeKey: removeSecret)
        if !secret.isEmpty { try ProviderKeychain.setSecret(secret, for: record.id) }
        else if removeSecret { try ProviderKeychain.removeSecret(for: record.id) }
        keyOrigins[record.id.uuidString] = bound.map { $0.sorted() }
        if let index = providers.firstIndex(where: { $0.id == record.id }) { providers[index] = record }
        else { providers.append(record) }
        if defaultSelection == nil { defaultSelection = LegacyProviderMigration.selection(for: record) }
        refreshKeys()
        try persist()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[index].isEnabled = enabled
        providers[index].updatedAt = Date()
        persistReporting()
    }

    /// Accepted turns keep their captured configuration; conversations that
    /// referenced this provider become explicitly unresolved.
    func delete(_ id: UUID) {
        providers.removeAll { $0.id == id }
        deletedProviders.removeAll { $0.id == id }
        deletedProviders.append(Tombstone(id: id, deletedAt: Date()))
        try? ProviderKeychain.removeSecret(for: id)
        keyOrigins[id.uuidString] = nil
        refreshKeys()
        persistReporting()
    }

    func setDefault(_ selection: ModelSelection?) {
        defaultSelection = selection
        persistReporting()
    }

    func fetchModels(for record: ProviderRecord, typedSecret: String) async throws -> [ProviderModelEntry] {
        let valid = try record.validated()
        guard !valid.modelsBaseURL.isEmpty else { throw failure("未填写模型目录 URL。") }
        let typed = typedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        var secret = typed
        if typed.isEmpty, let stored = try ProviderKeychain.secret(for: valid.id), !stored.isEmpty {
            // A stored key only goes to the catalog origin it was entered for.
            guard let origin = EndpointValidation.origin(of: valid.modelsBaseURL),
                  boundOrigins(valid.id)?.contains(origin) == true else { throw ProviderError.keyOriginChanged(valid.name) }
            secret = stored
        }
        let provider = ModelProvider(id: valid.id, name: valid.name, apiFormat: valid.format,
                                     inferenceURL: valid.inferenceURL, baseURL: valid.modelsBaseURL)
        let models = try await ModelCatalogClient().models(for: provider, secret: secret)
        return models.filter { $0.kind == .chat }
            .map { ProviderModelEntry(id: $0.id, supportsImages: $0.isVision, fetched: true) }
    }

    // MARK: Sync

    func applySync(merged: PortableSnapshot, base: PortableSnapshot) {
        let result = SyncApplication.providers(providers, tombstones: deletedProviders, merged: merged, base: base)
        for id in result.removed { try? ProviderKeychain.removeSecret(for: id); keyOrigins[id.uuidString] = nil }
        providers = result.providers
        deletedProviders = result.tombstones
        refreshKeys()
        persistReporting()
    }

    // MARK: Storage

    private func load() {
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = root["version"] as? Int else { throw failure("无效的服务商文件") }
                guard version == ProviderFile.currentVersion else { throw ProviderError.unsupportedVersion(version) }
                let stored = try JSONDecoder().decode(ProviderFile.self, from: data)
                providers = stored.providers
                defaultSelection = stored.defaultSelection
                deletedProviders = stored.deletedProviders
                legacySecretPending = stored.legacySecretPending
                keyOrigins = stored.keyOrigins
                if legacySecretPending { legacySecretPending = !copyLegacySecret(); try persist() }
            } else {
                migrateLegacySettings()
                try persist()
            }
        } catch { storageError = "服务商配置读取失败，原文件已保留：\(error.localizedDescription)" }
        refreshKeys()
    }

    /// One time: earlier builds kept one endpoint/model in UserDefaults and
    /// one key in a fixed Keychain item. Without them, setup UI is shown.
    private func migrateLegacySettings() {
        let defaults = UserDefaults.standard
        guard let provider = LegacyProviderMigration.provider(endpoint: defaults.string(forKey: "agentEndpoint"),
                                                              model: defaults.string(forKey: "agentModel")) else { return }
        providers = [provider]
        defaultSelection = LegacyProviderMigration.selection(for: provider)
        legacySecretPending = !copyLegacySecret()
    }

    /// Copies, never moves, the legacy key into the provider-scoped item.
    private func copyLegacySecret() -> Bool {
        let service = LegacyProviderMigration.keychainService(
            info: Bundle.main.object(forInfoDictionaryKey: "PocketAgentLegacyKeychainService") as? String)
        do {
            guard let secret = try ProviderKeychain.read(service: service, account: LegacyProviderMigration.keychainAccount),
                  !secret.isEmpty else { return true }
            try ProviderKeychain.setSecret(secret, for: LegacyProviderMigration.providerID)
            // The legacy key was used with the migrated endpoint.
            if let legacy = provider(LegacyProviderMigration.providerID) {
                keyOrigins[legacy.id.uuidString] = legacy.credentialOrigins.sorted()
            }
            return true
        } catch { return false }
    }

    /// Local provisioning drop (`agent-import.json` in Documents) used by
    /// earlier builds: deleted after its key is stored in the Keychain.
    private func importProvisioningFile() {
        let url = documents.appendingPathComponent("agent-import.json")
        guard storageError.isEmpty, let data = try? Data(contentsOf: url) else { return }
        do {
            let config = try JSONSerialization.jsonObject(with: data) as? [String: String] ?? [:]
            let existing = provider(LegacyProviderMigration.providerID)
            guard let migrated = LegacyProviderMigration.provider(endpoint: config["endpoint"] ?? existing?.inferenceURL,
                                                                  model: config["model"] ?? existing?.models.first?.id) else {
                throw failure("缺少有效的 HTTPS endpoint 或模型")
            }
            var record = existing ?? migrated
            record.inferenceURL = migrated.inferenceURL
            if record.model(migrated.models[0].id) == nil { record.models.insert(migrated.models[0], at: 0) }
            if let format = config["format"].flatMap(ModelAPIFormat.init(rawValue:)) { record.format = format }
            try save(record, newSecret: config["apiKey"] ?? "", removeSecret: false)
            try FileManager.default.removeItem(at: url)
        } catch { notice = "导入配置失败，请在模型服务中手动填写：\(error.localizedDescription)" }
    }

    private func refreshKeys() {
        keyed = Set(providers.map(\.id).filter { (try? ProviderKeychain.secret(for: $0)) != nil })
    }

    private func persistReporting() {
        do { try persist() } catch { notice = "服务商配置保存失败：\(error.localizedDescription)" }
    }

    private func persist() throws {
        guard storageError.isEmpty else { return }
        let stored = ProviderFile(providers: providers, defaultSelection: defaultSelection,
                                  deletedProviders: deletedProviders, legacySecretPending: legacySecretPending,
                                  keyOrigins: keyOrigins)
        try JSONEncoder().encode(stored).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
