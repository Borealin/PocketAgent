import AgentKit
import Foundation
import Testing
@testable import PocketAgentCore

struct ProviderEndpointTests {
    @Test(arguments: ["https://api.example.com", "https://api.example.com/", " https://api.example.com/v1/ ",
                      "https://api.example.com/v1/models", "https://api.example.com/v1/responses",
                      "https://api.example.com/v1/chat/completions", "https://api.example.com/v1/messages/"])
    func standardInputsShareOneBase(_ raw: String) throws {
        let addresses = try ProviderEndpoints.resolve(baseURL: raw, format: .responses)
        #expect(addresses.baseURL == "https://api.example.com/v1")
        #expect(addresses.inferenceURL == "https://api.example.com/v1/responses")
        #expect(addresses.modelsURL == "https://api.example.com/v1/models")
    }

    @Test func gatewayPrefixAndExplicitVersionArePreserved() throws {
        let normal = try ProviderEndpoints.resolve(baseURL: "https://api.example.com/gateway/v1/responses", format: .chatCompletions)
        #expect(normal.inferenceURL == "https://api.example.com/gateway/v1/chat/completions")
        #expect(normal.modelsURL == "https://api.example.com/gateway/v1/models")
        let forced = try ProviderEndpoints.resolve(baseURL: "https://api.example.com/antigravity/v1", format: .messages)
        #expect(forced.inferenceURL == "https://api.example.com/antigravity/v1/messages")
        #expect(forced.modelsURL == "https://api.example.com/antigravity/v1/models")
        let newer = try ProviderEndpoints.resolve(baseURL: "https://api.example.com/gateway/v2", format: .responses)
        #expect(newer.inferenceURL == "https://api.example.com/gateway/v2/responses")
    }

    @Test func knownUnversionedFullEndpointsDoNotReceiveASecondVersion() throws {
        let endpoint = try ProviderEndpoints.resolve(baseURL: "https://api.example.com/responses", format: .responses)
        #expect(endpoint.inferenceURL == "https://api.example.com/responses")
        #expect(endpoint.modelsURL == "https://api.example.com/models")
        let catalog = try ProviderEndpoints.resolve(baseURL: "https://api.example.com/models/", format: .messages)
        #expect(catalog.inferenceURL == "https://api.example.com/messages")
    }

    @Test func geminiAcceptsHostVersionAndFullModelPaths() throws {
        let host = try ProviderEndpoints.resolve(baseURL: "https://api.example.com", format: .generateContent)
        #expect(host.inferenceURL == "https://api.example.com/v1beta/models/{model}:generateContent")
        for raw in ["https://api.example.com/v1beta/models/{model}:generateContent",
                    "https://api.example.com/v1beta/models/gemini-example:generateContent"] {
            let endpoint = try ProviderEndpoints.resolve(baseURL: raw, format: .generateContent)
            #expect(endpoint == host)
        }
        let forced = try ProviderEndpoints.resolve(baseURL: "https://api.example.com/antigravity/v1beta/models", format: .generateContent)
        #expect(forced.inferenceURL == "https://api.example.com/antigravity/v1beta/models/{model}:generateContent")
    }

    @Test func formatSwitchUsesChosenProtocolAndKeepsTheExplicitBase() throws {
        let formats: [(ModelAPIFormat, String)] = [(.chatCompletions, "chat/completions"), (.responses, "responses"),
                                                   (.messages, "messages"), (.generateContent, "models/{model}:generateContent")]
        for (format, suffix) in formats {
            let endpoint = try ProviderEndpoints.resolve(baseURL: "https://api.example.com/prefix/v1/chat/completions", format: format)
            #expect(endpoint.inferenceURL == "https://api.example.com/prefix/v1/" + suffix)
            #expect(endpoint.modelsURL == "https://api.example.com/prefix/v1/models")
        }
    }

    @Test func customRecordAndSelectedModelsRemainExact() throws {
        let entry = ProviderModelEntry(id: "manual", supportsImages: true)
        let original = ProviderRecord(name: "Personal", format: .responses,
                                      inferenceURL: "https://api.example.com/custom/run?region=west",
                                      modelsBaseURL: "https://catalog.example.com/gateway?region=west", models: [entry])
        let record = try ProviderEndpoints.applying(baseURL: nil, to: original)
        #expect(record == original)
        #expect(record.id == original.id && record.models == [entry])
        #expect(record.credentialOrigins == original.credentialOrigins)
        #expect(record.modelsBaseURL == "https://catalog.example.com/gateway?region=west")
    }

    @Test func derivingAddressesRetainsProviderIdentityAndDerivesOptionalName() throws {
        let original = ProviderRecord(format: .responses, models: [ProviderModelEntry(id: "kept", supportsImages: false)])
        let record = try ProviderEndpoints.applying(baseURL: "https://api.example.com", to: original)
        #expect(record.id == original.id && record.updatedAt == original.updatedAt && record.models == original.models)
        #expect(record.name == "api.example.com")
        #expect(record.inferenceURL == "https://api.example.com/v1/responses")
        #expect(record.modelsBaseURL == "https://api.example.com/v1")
    }

    @Test func reopeningStandardProviderPreservesEverySavedField() throws {
        for format in ModelAPIFormat.allCases {
            let created = try ProviderEndpoints.applying(baseURL: "https://api.example.com/gateway/v1", to:
                ProviderRecord(name: "Personal", format: format, isEnabled: false,
                               models: [ProviderModelEntry(id: "manual", supportsImages: true),
                                        ProviderModelEntry(id: "selected", supportsImages: false, fetched: true)]))
            let input = try #require(ProviderEndpoints.standardInput(for: created))
            #expect(input == "https://api.example.com/gateway/v1")
            #expect(try ProviderEndpoints.applying(baseURL: input, to: created) == created)
            #expect(ProviderConnectionPreset.matching(format).format == format)
            #expect(ProviderConnectionPreset.matching(format) != .sub2API)
        }
    }

    @Test func unversionedProviderReopeningDoesNotAddV1() throws {
        let created = ProviderRecord(name: "Explicit", format: .responses,
                                     inferenceURL: "https://api.example.com/responses", modelsBaseURL: "https://api.example.com")
        let input = try #require(ProviderEndpoints.standardInput(for: created))
        #expect(input == "https://api.example.com/responses")
        #expect(try ProviderEndpoints.applying(baseURL: input, to: created) == created)
    }

    @Test func nonstandardOrNonexactProviderMustReopenAsCustom() {
        let original = ProviderRecord(name: "Custom", format: .responses,
                                      inferenceURL: "https://api.example.com/v1/responses", modelsBaseURL: "https://api.example.com/v1")
        var records: [ProviderRecord] = []
        var changed = original; changed.inferenceURL = "https://api.example.com/custom/run"; records.append(changed)
        changed = original; changed.modelsBaseURL = ""; records.append(changed)
        changed = original; changed.modelsBaseURL = "https://catalog.example.com/v1"; records.append(changed)
        changed = original; changed.modelsBaseURL += "/"; records.append(changed)
        changed = original; changed.inferenceURL += "?region=west"; records.append(changed)
        changed = original; changed.inferenceURL += "/"; records.append(changed)
        changed = original; changed.format = .messages; records.append(changed)
        for record in records { #expect(ProviderEndpoints.standardInput(for: record) == nil) }
    }

    @Test func explicitPresetCanReuseStandardInferenceWithoutAnExistingCatalog() throws {
        let original = ProviderRecord(name: "Existing", format: .responses,
                                      inferenceURL: "https://api.example.com/gateway/v1/responses",
                                      models: [ProviderModelEntry(id: "selected", supportsImages: true)])
        #expect(ProviderEndpoints.standardInput(for: original) == nil)
        let input = try #require(ProviderEndpoints.standardInferenceInput(for: original))
        #expect(input == "https://api.example.com/gateway/v1")
        let optedIn = try ProviderEndpoints.applying(baseURL: input, to: original)
        #expect(optedIn.id == original.id && optedIn.name == original.name && optedIn.models == original.models)
        #expect(optedIn.inferenceURL == original.inferenceURL)
        #expect(optedIn.modelsBaseURL == "https://api.example.com/gateway/v1")
        #expect(original.modelsBaseURL.isEmpty)
    }

    @Test func explicitPresetPreservesUnversionedInferenceAndNeverGuessesUnknownRoutes() throws {
        var original = ProviderRecord(name: "Explicit", format: .responses, inferenceURL: "https://api.example.com/responses")
        let input = try #require(ProviderEndpoints.standardInferenceInput(for: original))
        #expect(input == original.inferenceURL)
        #expect(try ProviderEndpoints.applying(baseURL: input, to: original).inferenceURL == original.inferenceURL)
        original.inferenceURL = "https://api.example.com/custom/run"
        #expect(ProviderEndpoints.standardInferenceInput(for: original) == nil)
        original.inferenceURL = "https://api.example.com/v1/messages"
        #expect(ProviderEndpoints.standardInferenceInput(for: original) == nil)
    }

    @Test func derivationCannotBypassOriginBinding() throws {
        let original = ProviderRecord(name: "Kept", format: .responses, inferenceURL: "https://old.example.com/v1/responses",
                                      modelsBaseURL: "https://old.example.com/v1", models: [ProviderModelEntry(id: "m", supportsImages: false)])
        let changed = try ProviderEndpoints.applying(baseURL: "https://new.example.com", to: original)
        #expect(throws: ProviderError.keyOriginChanged("Kept")) {
            try RunConfiguration.resolve(ModelSelection(providerID: original.id, modelID: "m"), providers: [changed],
                                         secret: { _ in "test-only" }, boundOrigins: { _ in original.credentialOrigins })
        }
        #expect(try KeyBinding.afterSave(stored: original, saved: changed, bound: original.credentialOrigins,
                                         hasStoredKey: true, enteredNewKey: false, removeKey: false) == changed.credentialOrigins)
    }

    @Test(arguments: ["http://api.example.com", "https://user:password@api.example.com", "https://api.example.com?api_key=private",
                      "https://api.example.com?region=west", "https://api.example.com/v1#key", "https://api.example.com/a//v1",
                      "https://api.example.com/a/../v1", "https://api.example.com/a/%2E%2E/v1", "https://api.example.com/a%2Fv1",
                      "https://api.example.com/v1/{model}", "https://api.example.com/v1/\\\\oops"])
    func unsafeOrAmbiguousBasesAreRejected(_ raw: String) {
        #expect(throws: (any Error).self) { try ProviderEndpoints.resolve(baseURL: raw, format: .responses) }
    }

    @Test func catalogRefreshKeepsManualCapabilitiesAndAbsentSelectedModels() {
        let manual = ProviderModelEntry(id: "manual", supportsImages: false)
        let absent = ProviderModelEntry(id: "selected", supportsImages: true, fetched: true)
        let new = ProviderModelEntry(id: "new", supportsImages: true, fetched: true)
        let fetched = [ProviderModelEntry(id: " manual ", supportsImages: true, fetched: true),
                       ProviderModelEntry(id: " new ", supportsImages: true, fetched: true), new,
                       ProviderModelEntry(id: "", supportsImages: false, fetched: true)]
        #expect(ProviderCatalogMerge.merge(fetched, into: [manual, absent]) == [manual, absent, new])
    }
}
