import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

struct AssistantHistoryCodecTests {
    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func initialNamespaceHasOneEmptyPrimaryAndRoundTripsWithExplicitNulls() throws {
        let file = HistoryFile.initial(selection: nil)
        #expect(file.sessions.count == 1 && file.primary?.messages.isEmpty == true)
        #expect(file.selectedID == file.assistant.primarySessionID && file.primary?.title == ChatSession.primaryTitle)
        let data = try HistoryCodec.encode(file)
        let root = try object(data)
        #expect(root["generation"] as? String == "assistant-v1" && root["schemaVersion"] as? Int == 1)
        let assistant = try #require(root["assistant"] as? [String: Any])
        // Nullable business keys are present with explicit null, not omitted.
        #expect(assistant.keys.contains("pendingNext") && assistant["pendingNext"] is NSNull)
        #expect(assistant.keys.contains("primaryNotice") && assistant["primaryNotice"] is NSNull)
        let session = try #require((root["sessions"] as? [[String: Any]])?.first)
        for key in ["selection", "conflictOf", "workspaceID"] { #expect(session.keys.contains(key) && session[key] is NSNull) }
        #expect(try HistoryCodec.decode(data) == file)
    }

    @Test func nonCurrentFormatsAreRejectedWithoutConversion() throws {
        let legacy = try JSONSerialization.data(withJSONObject: ["version": 3, "selectedID": NSNull(), "sessions": []])
        #expect(throws: HistoryError.unsupportedGeneration("缺少 generation")) { try HistoryCodec.decode(legacy) }
        var root = try object(HistoryCodec.encode(.initial(selection: nil)))
        root["generation"] = "assistant-v0"
        #expect(throws: HistoryError.unsupportedGeneration("assistant-v0")) {
            try HistoryCodec.decode(JSONSerialization.data(withJSONObject: root))
        }
        root["generation"] = "assistant-v1"; root["schemaVersion"] = 2
        #expect(throws: HistoryError.unsupportedSchema(2)) { try HistoryCodec.decode(JSONSerialization.data(withJSONObject: root)) }
        #expect(throws: HistoryError.unreadable("不是 JSON 对象")) { try HistoryCodec.decode(Data("[]".utf8)) }
    }

    @Test func missingRequiredOrNullableKeysAndWrongTypesAreRejected() throws {
        let base = try object(HistoryCodec.encode(.initial(selection: nil)))
        func rejects(_ change: (inout [String: Any]) -> Void) throws {
            var root = base
            change(&root)
            let data = try JSONSerialization.data(withJSONObject: root)
            #expect(throws: (any Error).self) { try HistoryCodec.decode(data) }
        }
        try rejects { $0["selectedID"] = nil }
        try rejects { $0["deletedSessions"] = nil }
        try rejects { $0["assistant"] = nil }
        for key in ["pendingNext", "primaryNotice", "memory", "scopeIndex", "memoryReceipts", "compactions"] {
            try rejects { root in var a = root["assistant"] as! [String: Any]; a[key] = nil; root["assistant"] = a }
        }
        for key in ["selection", "conflictOf", "workspaceID", "draftAttachments", "attachments", "metadataUpdatedAt", "title"] {
            try rejects { root in
                var rows = root["sessions"] as! [[String: Any]]; rows[0][key] = nil; root["sessions"] = rows
            }
        }
        try rejects { root in var rows = root["sessions"] as! [[String: Any]]; rows[0]["draft"] = 5; root["sessions"] = rows }
    }

    @Test func duplicateIDsInsideOneSessionFailButConflictCopiesMayShareMessages() throws {
        var file = HistoryFile.initial(selection: nil)
        let message = AgentTranscriptMessage(role: .user, text: "共享")
        var copy = ChatSession(title: "副本")
        copy.messages = [message]; copy.conflictOf = file.assistant.primarySessionID
        file.sessions[0].messages = [message]
        file.sessions.append(copy)
        #expect(try HistoryCodec.decode(HistoryCodec.encode(file)) == file)
        var duplicated = file
        duplicated.sessions[0].messages.append(message)
        #expect(throws: HistoryError.invalid("会话内重复消息 ID")) { try HistoryCodec.encode(duplicated) }
        var sameSession = file
        sameSession.sessions.append(file.sessions[0])
        #expect(throws: HistoryError.invalid("重复会话 ID")) { try HistoryCodec.encode(sameSession) }
    }

    @Test func pendingOwnershipAndDetachedPayloadAreValidated() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        let detached = AgentTranscriptMessage(role: .user, text: "下一件事")
        let pending = PendingNext(sessionID: primary, prompt: .detached(message: detached, attachments: []),
                                  selection: ModelSelection(providerID: UUID(), modelID: "m"), workspaceID: nil,
                                  backend: .ddi, clipboardAllowed: true, acceptedOrdinal: 1, state: .queued,
                                  references: [], acceptedAt: Date(timeIntervalSince1970: 1))
        file.assistant.pendingNext = pending
        #expect(try HistoryCodec.decode(HistoryCodec.encode(file)).assistant.pendingNext == pending)
        // Same ID in history and detached pending: double ownership.
        var double = file
        double.sessions[0].messages = [detached]
        #expect(throws: HistoryError.invalid("待处理请求与历史消息重复所有权")) { try HistoryCodec.encode(double) }
        // Detached prompts never carry image bytes, snapshots or provider items.
        var image = detached
        image.images = [AgentImageAttachment(label: "x", mimeType: "image/png", data: Data([1, 2, 3]), pixelWidth: 1, pixelHeight: 1)]
        var withImage = file
        withImage.assistant.pendingNext?.prompt = .detached(message: image, attachments: [])
        #expect(throws: HistoryError.invalid("待处理请求包含不允许的载荷")) { try HistoryCodec.encode(withImage) }
        var items = detached
        items.providerItems = [.object(["id": .string("r")])]
        var withItems = file
        withItems.assistant.pendingNext?.prompt = .detached(message: items, attachments: [])
        #expect(throws: HistoryError.invalid("待处理请求包含不允许的载荷")) { try HistoryCodec.encode(withItems) }
        // Promoted receipts must name a prompt in history.
        var promoted = file
        promoted.assistant.pendingNext?.prompt = .promoted(promptID: UUID())
        #expect(throws: HistoryError.invalid("已提升请求不在历史中")) { try HistoryCodec.encode(promoted) }
        // Detached JSON contains no image data key content.
        let json = String(decoding: try HistoryCodec.encode(file), as: UTF8.self)
        #expect(!json.contains("\"data\""))
    }

    @Test func decodeIsPureAndLaunchRecoveryInterruptsWithoutRescheduling() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        let prompt = AgentTranscriptMessage(role: .user, text: "打开设置")
        try file.acceptRoot(prompt, attachments: [], in: primary, scope: .general)
        try file.commitDispatchPermit(root: prompt.id, sessionID: primary, scope: .general)
        file.assistant.pendingNext = PendingNext(sessionID: primary,
            prompt: .detached(message: AgentTranscriptMessage(role: .user, text: "然后"), attachments: []),
            selection: ModelSelection(providerID: UUID(), modelID: "m"), workspaceID: nil, backend: .wda,
            clipboardAllowed: false, acceptedOrdinal: 7, state: .queued, references: [], acceptedAt: Date())
        let decoded = try HistoryCodec.decode(HistoryCodec.encode(file))
        #expect(decoded.primary?.state == .running && decoded.assistant.pendingNext?.state == .queued)
        var recovered = decoded
        recovered.recoverAfterLaunch()
        #expect(recovered.primary?.state == .interrupted && recovered.primary?.detail == HistoryCodec.interruptedDetail)
        #expect(recovered.assistant.pendingNext?.state == .needsResume)
        #expect(recovered.assistant.scopeIndex.scopedRoot(prompt.id)?.dispatchAuthorized == true)
        #expect(recovered.primary?.messages.map(\.id) == [prompt.id])
    }

    @Test func missingPrimaryPointerBecomesRecoveryStateInsteadOfFirstSession() throws {
        var file = HistoryFile.initial(selection: nil)
        let other = ChatSession(title: "任务")
        file.sessions = [other]
        let decoded = try HistoryCodec.decode(HistoryCodec.encode(file))
        #expect(decoded.primary == nil)
        var recovered = decoded
        recovered.recoverAfterLaunch()
        #expect(recovered.assistant.primaryNotice == .missing)
        #expect(recovered.assistant.primarySessionID != other.id)
    }

    @Test func scopeRowsRejectDuplicatesAndDanglingMembers() throws {
        var file = HistoryFile.initial(selection: nil)
        let primary = file.assistant.primarySessionID
        let prompt = AgentTranscriptMessage(role: .user, text: "a")
        try file.acceptRoot(prompt, attachments: [], in: primary, scope: .workspace(UUID()))
        let reply = AgentTranscriptMessage(role: .assistant, text: "b")
        try file.appendEvent(reply, to: primary, root: prompt.id)
        let data = try HistoryCodec.encode(file)
        #expect(try HistoryCodec.decode(data).assistant.scopeIndex == file.assistant.scopeIndex)
        var root = try object(data)
        var assistant = root["assistant"] as! [String: Any]
        var index = assistant["scopeIndex"] as! [String: Any]
        var members = index["messageRoots"] as! [[String: Any]]
        members.append(members[0])
        index["messageRoots"] = members
        assistant["scopeIndex"] = index; root["assistant"] = assistant
        #expect(throws: (any Error).self) { try HistoryCodec.decode(JSONSerialization.data(withJSONObject: root)) }
        members.removeLast()
        members.append(["messageID": UUID().uuidString, "rootPromptID": UUID().uuidString])
        index["messageRoots"] = members; assistant["scopeIndex"] = index; root["assistant"] = assistant
        #expect(throws: (any Error).self) { try HistoryCodec.decode(JSONSerialization.data(withJSONObject: root)) }
    }
}

struct ContextEstimatorTests {
    @Test func estimatesCJKTextImagesAndProviderPayloadWithoutTrapping() {
        #expect(ContextEstimator.textTokens("你好") == 4)
        #expect(ContextEstimator.textTokens("abcdef") == 2)
        let huge = AgentImageAttachment(label: "x", mimeType: "image/png", data: Data(), pixelWidth: Int.max, pixelHeight: Int.max)
        #expect(ContextEstimator.imageTokens(huge) == ContextEstimator.unknownImageTokens)
        let photo = AgentImageAttachment(label: "x", mimeType: "image/png", data: Data(), pixelWidth: 1024, pixelHeight: 1024)
        #expect(ContextEstimator.imageTokens(photo) == 85 + 170 * 4)
        var message = AgentTranscriptMessage(role: .assistant, text: "a")
        let plain = ContextEstimator.messageTokens(message)
        message.providerItems = [.object(["type": .string("reasoning"), "encrypted_content": .string(String(repeating: "x", count: 3000))])]
        #expect(ContextEstimator.messageTokens(message) > plain + 900)
        var estimator = ContextEstimator()
        estimator.calibration = .infinity
        #expect(estimator.calibrated(10) == 10)
        estimator.calibration = 2
        #expect(estimator.calibrated(Int.max) == Int.max / 4)
        var calibrating = ContextEstimator()
        calibrating.calibrate(estimatedRaw: 1000, actualInputTokens: 1500)
        #expect(calibrating.calibration > 1 && calibrating.calibration <= 2)
        let before = calibrating.calibration
        calibrating.calibrate(estimatedRaw: 1000, actualInputTokens: 100_000) // outlier ignored
        #expect(calibrating.calibration == before)
    }
}

struct ProviderConfigTests {
    @Test func endpointValidationRejectsInsecureAndCredentialBearingURLs() throws {
        #expect(try EndpointValidation.validate(" https://api.example.com/v1/chat/completions ", field: "u")
                == "https://api.example.com/v1/chat/completions")
        #expect(throws: Never.self) {
            try EndpointValidation.validate("https://g.example.com/v1beta/models/{model}:generateContent", field: "u")
        }
        #expect(throws: ProviderError.insecureURL("u")) { try EndpointValidation.validate("http://api.example.com/v1", field: "u") }
        #expect(throws: ProviderError.credentialInURL("u")) { try EndpointValidation.validate("https://u:p@api.example.com/v1", field: "u") }
        #expect(throws: ProviderError.credentialInURL("u")) { try EndpointValidation.validate("https://api.example.com/v1?key=abc", field: "u") }
        #expect(throws: ProviderError.credentialInURL("u")) { try EndpointValidation.validate("https://api.example.com/v1?access_token=abc", field: "u") }
        #expect(throws: ProviderError.invalidURL("u")) { try EndpointValidation.validate("https:///nohost", field: "u") }
    }

    /// The common Settings file is used in place: an earlier build's version-1
    /// file keeps provider IDs, default, tombstones, key origins and its pending
    /// flag; budgets are an additive key that earlier readers ignore.
    @Test func commonProviderFileKeepsIDsOriginsDefaultAndBudgets() throws {
        let provider = ProviderRecord(name: "P", inferenceURL: "https://a.example.com/v1/responses",
                                      models: [ProviderModelEntry(id: "m", supportsImages: false)],
                                      updatedAt: Date(timeIntervalSinceReferenceDate: 1000))
        let selection = ModelSelection(providerID: provider.id, modelID: "m")
        let tombstone = Tombstone(id: UUID(), deletedAt: Date(timeIntervalSinceReferenceDate: 5))
        let origins = [provider.id.uuidString: ["https://a.example.com"]]
        func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        func earlier(_ fields: [String: Any]) throws -> Data {
            var root: [String: Any] = ["version": 1, "providers": [try json(provider)]]
            root.merge(fields) { $1 }
            return try JSONSerialization.data(withJSONObject: root)
        }
        let full = try earlier(["defaultSelection": try json(selection), "deletedProviders": [try json(tombstone)],
                                "legacySecretPending": true, "keyOrigins": origins])
        var file = try JSONDecoder().decode(ProviderFile.self, from: full)
        #expect(file.providers == [provider] && file.defaultSelection == selection && file.deletedProviders == [tombstone])
        #expect(file.keyOrigins == origins && file.legacySecretPending && file.budgetOverrides.isEmpty)
        // Keys an earlier writer omitted are defaults, not errors.
        let sparse = try JSONDecoder().decode(ProviderFile.self, from: earlier([:]))
        #expect(sparse.providers == [provider] && sparse.defaultSelection == nil && sparse.keyOrigins.isEmpty)
        #expect(sparse.deletedProviders.isEmpty && !sparse.legacySecretPending)
        // A local budget round-trips, and the written file still reads with the earlier reader.
        let override = ContextBudgetOverride(providerID: provider.id, modelID: "m", contextWindow: 128_000)
        file.budgetOverrides = [override]
        let written = try JSONEncoder().encode(file)
        let again = try JSONDecoder().decode(ProviderFile.self, from: written)
        #expect(again.providers == [provider] && again.defaultSelection == selection && again.keyOrigins == origins)
        #expect(again.deletedProviders == [tombstone] && again.legacySecretPending && again.budgetOverrides == [override])
        let previous = try JSONDecoder().decode(EarlierProviderFileV1.self, from: written)
        #expect(previous.version == 1 && previous.providers == [provider] && previous.defaultSelection == selection)
        #expect(previous.keyOrigins == origins && previous.deletedProviders == [tombstone] && previous.legacySecretPending == true)
        // No default: the key is omitted, as earlier builds wrote it.
        let root = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProviderFile(providers: [provider])))
                                as? [String: Any])
        #expect(root["defaultSelection"] == nil && root["version"] as? Int == 1)
        // Other versions and the unreleased assistant-v1 settings shape are refused, never converted.
        #expect(throws: ProviderError.unsupportedVersion(2)) {
            try JSONDecoder().decode(ProviderFile.self, from: earlier(["version": 2]))
        }
        let unreleased = #"{"generation":"assistant-v1","schemaVersion":1,"providers":[],"defaultSelection":null,"deletedProviders":[],"keyOrigins":{},"budgetOverrides":[]}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ProviderFile.self, from: Data(unreleased.utf8)) }
        file.budgetOverrides = [override, override]
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ProviderFile.self, from: JSONEncoder().encode(file)) }
    }

    /// The assistant primary without a model takes the Settings default; an
    /// existing choice and other conversations are untouched; no history appears.
    @Test func primaryWithoutModelAdoptsTheSettingsDefault() throws {
        let configured = ModelSelection(providerID: UUID(), modelID: "m")
        var file = HistoryFile.initial(selection: nil)
        let task = ChatSession(selection: nil)
        file.sessions.append(task)
        let metadata = file.primary?.metadataUpdatedAt
        #expect(try file.adoptDefaultSelection(nil) == false && file.primary?.selection == nil)
        #expect(try file.adoptDefaultSelection(configured))
        #expect(file.primary?.selection == configured && file.primary?.messages.isEmpty == true)
        #expect(file.primary?.metadataUpdatedAt == metadata && file.session(task.id)?.selection == nil)
        let explicit = ModelSelection(providerID: UUID(), modelID: "n")
        try file.editSession(file.assistant.primarySessionID) { $0.selection = explicit }
        #expect(try file.adoptDefaultSelection(configured) == false && file.primary?.selection == explicit)
        #expect(try HistoryCodec.decode(HistoryCodec.encode(file)).primary?.selection == explicit)
    }

    @Test func budgetPolicyHardCapsOnlyKnownOrExplicitLimits() throws {
        let unknown = try ContextBudgetPolicy.resolve(nil)
        #expect(unknown.hardCeiling == nil && unknown.target == 24_000 && unknown.source == .unknown)
        let known = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", contextWindow: 128_000))
        #expect(known.hardCeiling == 128_000 - 4096 - 10_240 && known.source == .knownWindow(128_000))
        let small = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", contextWindow: 16_000))
        #expect(small.hardCeiling == 16_000 - 4096 - 2048)
        let explicit = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m",
                                                                             contextWindow: 128_000, inputCeiling: 50_000))
        #expect(explicit.hardCeiling == 50_000 && explicit.source == .explicitCeiling(50_000))
        #expect(throws: (any Error).self) {
            try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", contextWindow: 6000))
        }
        #expect(throws: (any Error).self) {
            try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", inputCeiling: 0))
        }
        // Extreme values are refused instead of overflowing.
        for value in [Int.max, Int.min, -1, 10_000_001] {
            #expect(throws: (any Error).self) {
                try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", contextWindow: value))
            }
            #expect(throws: (any Error).self) {
                try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", inputCeiling: value))
            }
        }
        let largest = try ContextBudgetPolicy.resolve(ContextBudgetOverride(providerID: UUID(), modelID: "m", contextWindow: 10_000_000))
        #expect(largest.summaryTrigger > 0 && largest.recentTarget > 0)
        let provider = ProviderRecord(name: "W", inferenceURL: "https://a.example.com/v1/messages",
                                      models: [ProviderModelEntry(id: "m", supportsImages: false)])
        let config = try RunConfiguration.resolve(ModelSelection(providerID: provider.id, modelID: "m"), providers: [provider],
            secret: { _ in nil }, boundOrigins: { _ in nil },
            budgetOverride: ContextBudgetOverride(providerID: provider.id, modelID: "m", inputCeiling: 9000))
        #expect(config.budget.hardCeiling == 9000)
    }

    @Test func resolutionIsStrictAndCapturesEverything() throws {
        let provider = ProviderRecord(name: "Work", format: .messages, inferenceURL: "https://a.example.com/v1/messages",
                                      models: [ProviderModelEntry(id: "text-only", supportsImages: false)])
        let selection = ModelSelection(providerID: provider.id, modelID: "text-only")
        let config = try RunConfiguration.resolve(selection, providers: [provider], secret: { _ in "sk-secret" }, boundOrigins: { _ in provider.credentialOrigins })
        #expect(config.label == "text-only · Work" && config.format == .messages && !config.supportsImages)
        #expect(config.secret == "sk-secret")
        #expect(!String(describing: config).contains("sk-secret") && !String(reflecting: config).contains("sk-secret"))
        #expect(config.agentModel.isVision == false)
        #expect(throws: ProviderError.noSelection) { try RunConfiguration.resolve(nil, providers: [provider], secret: { _ in nil }, boundOrigins: { _ in nil }) }
        #expect(throws: ProviderError.providerDeleted) { try RunConfiguration.resolve(selection, providers: [], secret: { _ in nil }, boundOrigins: { _ in nil }) }
        var disabled = provider; disabled.isEnabled = false
        #expect(throws: ProviderError.providerDisabled("Work")) { try RunConfiguration.resolve(selection, providers: [disabled], secret: { _ in nil }, boundOrigins: { _ in nil }) }
        let missing = ModelSelection(providerID: provider.id, modelID: "gone")
        #expect(throws: ProviderError.modelMissing("Work", "gone")) { try RunConfiguration.resolve(missing, providers: [provider], secret: { _ in nil }, boundOrigins: { _ in nil }) }
    }

    @Test func providerRecordEncodingHasNoSecretField() throws {
        let provider = ProviderRecord(name: "P", inferenceURL: "https://a.example.com/v1")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(provider)) as? [String: Any]
        let keys = Set(object?.keys.map { $0.lowercased() } ?? [])
        #expect(keys.allSatisfy { !$0.contains("key") && !$0.contains("secret") && !$0.contains("credential") })
    }
}

/// The version-1 reader of earlier builds: optional keys may be absent, unknown keys are ignored.
private struct EarlierProviderFileV1: Decodable {
    var version: Int
    var providers: [ProviderRecord]
    var defaultSelection: ModelSelection?
    var deletedProviders: [Tombstone]?
    var legacySecretPending: Bool?
    var keyOrigins: [String: [String]]?
}
