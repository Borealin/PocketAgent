import AgentKit
import Foundation

/// Editor-only presets. Stored providers still contain their exact addresses;
/// selecting a preset never changes a provider's ID, models or key binding.
nonisolated enum ProviderConnectionPreset: String, CaseIterable, Identifiable {
    case compatible, responses, sub2API, anthropic, gemini, custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .compatible: "OpenAI 兼容"
        case .responses: "OpenAI Responses"
        case .sub2API: "Sub2API"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .custom: "自定义完整地址"
        }
    }
    var format: ModelAPIFormat {
        switch self {
        case .compatible, .custom: .chatCompletions
        case .responses, .sub2API: .responses
        case .anthropic: .messages
        case .gemini: .generateContent
        }
    }
    static func matching(_ format: ModelAPIFormat) -> ProviderConnectionPreset {
        switch format {
        case .chatCompletions: .compatible
        case .responses: .responses
        case .messages: .anthropic
        case .generateContent: .gemini
        }
    }
    var detail: String {
        switch self {
        case .compatible: "适用于提供 Chat Completions 的服务。填写服务给出的 Base URL 和 Key 即可。"
        case .responses: "适用于提供 Responses 的服务。只填写 Base URL，自动生成请求和模型目录地址。"
        case .sub2API: "填写 Sub2API 实例地址和 Key，协议须匹配 Key 的分组与模型。Antigravity 分组的 Messages 地址需以 /antigravity/v1 结尾，Gemini 地址需以 /antigravity/v1beta 结尾。已有路径前缀不会自动追加版本。"
        case .anthropic: "使用 Messages 协议，模型目录和推理地址共用一个 Base URL。"
        case .gemini: "使用 Generate Content 协议；只有实例根地址时默认使用 /v1beta。"
        case .custom: "保留完整推理地址和独立模型目录 Base URL，适用于非标准路由。"
        }
    }
}

nonisolated struct ProviderEndpoints: Equatable, Sendable {
    let baseURL: String
    let inferenceURL: String
    let modelsBaseURL: String
    var modelsURL: String { modelsBaseURL + "/models" }

    /// Reopen in the one-field editor only when deriving both addresses is
    /// exactly reversible. A custom route, independent catalog or disabled
    /// catalog must stay in custom mode. No host or brand is inferred.
    static func standardInput(for record: ProviderRecord) -> String? {
        guard !record.modelsBaseURL.isEmpty,
              let input = standardInferenceInput(for: record),
              let endpoints = try? resolve(baseURL: input, format: record.format),
              endpoints.modelsBaseURL == record.modelsBaseURL else { return nil }
        return input
    }

    /// A user explicitly selecting a standard preset opts into a shared
    /// catalog base. Recognize the inference route independently so an absent
    /// or custom catalog need not force retyping; opening the editor still
    /// uses the stricter two-address check above.
    static func standardInferenceInput(for record: ProviderRecord) -> String? {
        guard let endpoints = try? resolve(baseURL: record.inferenceURL, format: record.format),
              endpoints.inferenceURL == record.inferenceURL else { return nil }
        if (try? resolve(baseURL: endpoints.baseURL, format: record.format)) == endpoints { return endpoints.baseURL }
        // Unversioned /responses, for example, must retain that explicit
        // endpoint as the input: a bare host would otherwise receive /v1.
        return record.inferenceURL
    }

    /// Derive standard protocol paths only. A pasted known endpoint is removed
    /// as a whole suffix, so /v1 and gateway prefixes are never duplicated.
    /// Query strings and ambiguous path components belong in custom mode.
    static func resolve(baseURL raw: String, format: ModelAPIFormat) throws -> ProviderEndpoints {
        let field = "Base URL"
        let value = try EndpointValidation.validate(raw, field: field)
        guard var components = URLComponents(string: value), components.query == nil,
              let host = components.host, !host.isEmpty else { throw ProviderError.invalidURL(field) }
        let encoded = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        // One leading and optional trailing slash are allowed; interior empty
        // components are not collapsed because they can denote another route.
        var segments = Array(encoded.dropFirst())
        if segments.last == "" { segments.removeLast() }
        let decoded = try segments.map { segment -> String in
            guard let text = String(segment).removingPercentEncoding,
                  !text.isEmpty, text != ".", text != "..", !text.contains("/"), !text.contains("\\") else {
                throw ProviderError.invalidURL(field)
            }
            return text
        }
        var endpointCount = 0
        if decoded.suffix(2).elementsEqual(["chat", "completions"]) { endpointCount = 2 }
        else if let last = decoded.last, ["responses", "messages", "models"].contains(last) { endpointCount = 1 }
        else if decoded.count >= 2, decoded[decoded.count - 2] == "models",
                let last = decoded.last, last.hasSuffix(":generateContent"), last != ":generateContent" {
            endpointCount = 2
        }
        if endpointCount > 0 { segments.removeLast(endpointCount) }
        // A full unversioned endpoint intentionally describes an unversioned
        // API. A bare host is the only input which receives a default version.
        if segments.isEmpty, endpointCount == 0 {
            segments = [Substring(format == .generateContent ? "v1beta" : "v1")]
        }
        guard !segments.contains(where: { $0.contains("{model}") || $0.lowercased().contains("%7bmodel%7d") }) else {
            throw ProviderError.invalidURL(field)
        }
        components.percentEncodedPath = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard let base = components.string else { throw ProviderError.invalidURL(field) }
        let suffix: String
        switch format {
        case .chatCompletions: suffix = "/chat/completions"
        case .responses: suffix = "/responses"
        case .messages: suffix = "/messages"
        case .generateContent: suffix = "/models/{model}:generateContent"
        }
        return ProviderEndpoints(baseURL: base, inferenceURL: base + suffix, modelsBaseURL: base)
    }

    /// Custom records stay verbatim; endpoint derivation is explicitly opt-in.
    static func applying(baseURL: String?, to record: ProviderRecord) throws -> ProviderRecord {
        var result = record
        if let baseURL {
            let endpoints = try resolve(baseURL: baseURL, format: record.format)
            result.inferenceURL = endpoints.inferenceURL
            result.modelsBaseURL = endpoints.modelsBaseURL
        }
        if result.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.name = URLComponents(string: result.inferenceURL)?.host ?? ""
        }
        return try result.validated()
    }
}

/// Catalog refresh adds newly advertised models without removing selections,
/// manually entered rows or manually adjusted image capabilities.
nonisolated enum ProviderCatalogMerge {
    static func merge(_ fetched: [ProviderModelEntry], into existing: [ProviderModelEntry]) -> [ProviderModelEntry] {
        var result = existing
        var known = Set(existing.map(\.id))
        for var entry in fetched {
            entry.id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.id.isEmpty else { continue }
            if known.insert(entry.id).inserted { result.append(entry) }
        }
        return result
    }
}
