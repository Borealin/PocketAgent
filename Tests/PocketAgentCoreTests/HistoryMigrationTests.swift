import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

struct HistoryMigrationTests {
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func message(_ m: AgentTranscriptMessage) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(m))
    }

    @Test func v1DropsOnlyCounterModeAndKeepsRealIDsAndMessages() throws {
        let real = UUID(), demo = UUID()
        let user = AgentTranscriptMessage(role: .user, text: "打开设置")
        let data = try json(["version": 1, "selectedID": real.uuidString, "sessions": [
            ["id": real.uuidString, "title": "真实", "messages": [try message(user)], "mode": "agent",
             "draft": "草稿", "state": "running", "detail": "", "updatedAt": 0],
            ["id": demo.uuidString, "title": "计数", "messages": [], "mode": "counter",
             "draft": "", "state": "idle", "detail": "", "updatedAt": 0],
        ]])
        let legacy = ModelSelection(providerID: LegacyProviderMigration.providerID, modelID: "m")
        let file = try HistoryMigration.decode(data, legacySelection: legacy)
        #expect(file.sessions.map(\.id) == [real])
        #expect(file.sessions[0].messages == [user])
        #expect(file.sessions[0].draft == "草稿")
        #expect(file.sessions[0].state == .interrupted)
        #expect(file.sessions[0].selection == legacy)
        #expect(file.selectedID == real)
        #expect(file.version == 3)
    }

    @Test func v2RepairsToolOrderWithoutReplayingOrDroppingMessages() throws {
        let call = AgentToolCall(id: "c1", name: "tap", arguments: .object([:]))
        let assistant = AgentTranscriptMessage(role: .assistant, toolCalls: [call])
        let later = AgentTranscriptMessage(role: .assistant, text: "done")
        let result = AgentTranscriptMessage(role: .tool, text: "ok", toolCallID: "c1", toolName: "tap")
        let session = ["id": UUID().uuidString, "title": "t", "draft": "", "state": "queued", "detail": "",
                       "updatedAt": 0, "messages": [try message(assistant), try message(later), try message(result)]] as [String: Any]
        let file = try HistoryMigration.decode(try json(["version": 2, "sessions": [session]]), legacySelection: nil)
        #expect(file.sessions[0].messages.map(\.id) == [assistant.id, result.id, later.id])
        #expect(file.sessions[0].state == .interrupted)
        #expect(file.sessions[0].selection == nil)
    }

    @Test func currentVersionKeepsExplicitSelectionAndRoundTrips() throws {
        var session = ChatSession(selection: ModelSelection(providerID: UUID(), modelID: "x"))
        session.messages = [AgentTranscriptMessage(role: .user, text: "hi")]
        let data = try HistoryMigration.encode(HistoryFile(selectedID: session.id, sessions: [session], deletedSessions: []))
        let other = ModelSelection(providerID: UUID(), modelID: "legacy")
        let file = try HistoryMigration.decode(data, legacySelection: other)
        #expect(file.sessions[0].selection == session.selection)
        #expect(file.sessions[0].messages == session.messages)
    }

    @Test func unknownVersionAndDuplicateIDsFail() throws {
        #expect(throws: HistoryError.unsupportedVersion(9)) {
            try HistoryMigration.decode(try json(["version": 9, "sessions": []]), legacySelection: nil)
        }
        let id = UUID().uuidString
        let row: [String: Any] = ["id": id, "messages": []]
        #expect(throws: HistoryError.duplicateSessionIDs) {
            try HistoryMigration.decode(try json(["version": 2, "sessions": [row, row]]), legacySelection: nil)
        }
        #expect(throws: HistoryError.unreadable) { try HistoryMigration.decode(Data("[]".utf8), legacySelection: nil) }
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

    @Test func legacyDefaultsMigrateToDeterministicProvider() throws {
        let a = try #require(LegacyProviderMigration.provider(endpoint: "https://gw.example.net/v1/responses", model: "m-1"))
        let b = try #require(LegacyProviderMigration.provider(endpoint: "https://gw.example.net/v1/responses", model: "m-1"))
        #expect(a.id == LegacyProviderMigration.providerID && a.id == b.id)
        #expect(a.format == .responses && a.name == "gw.example.net")
        #expect(a.models == [ProviderModelEntry(id: "m-1", supportsImages: true)])
        #expect(LegacyProviderMigration.selection(for: a) == ModelSelection(providerID: a.id, modelID: "m-1"))
        #expect(LegacyProviderMigration.provider(endpoint: nil, model: "m") == nil)
        #expect(LegacyProviderMigration.provider(endpoint: "http://insecure.example/v1", model: "m") == nil)
        #expect(LegacyProviderMigration.keychainService(info: nil) == "PocketAgent.ModelAPI")
        #expect(LegacyProviderMigration.keychainService(info: "") == "PocketAgent.ModelAPI")
        #expect(LegacyProviderMigration.keychainService(info: "Custom.Service") == "Custom.Service")
        #expect(LegacyProviderMigration.keychainAccount == "deepseek")
    }

    @Test func resolutionIsStrictAndCapturesEverything() throws {
        let provider = ProviderRecord(name: "Work", format: .messages, inferenceURL: "https://a.example.com/v1/messages",
                                      models: [ProviderModelEntry(id: "text-only", supportsImages: false)])
        let selection = ModelSelection(providerID: provider.id, modelID: "text-only")
        let config = try RunConfiguration.resolve(selection, providers: [provider], secret: { _ in "sk-secret" }, boundOrigins: { _ in provider.credentialOrigins })
        #expect(config.label == "Work · text-only" && config.format == .messages && !config.supportsImages)
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
