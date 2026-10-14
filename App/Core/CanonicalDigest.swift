import AgentKit
import CryptoKit
import Foundation

/// Gate values (summary input/record, segment, history reference and commit
/// barrier digests) all use this one versioned, throwing canonical encoding:
/// sorted-key JSON of an explicit DTO, UTF-8, SHA-256. DTOs use ordered arrays,
/// canonical UUID strings and Int64 milliseconds; never UUID-keyed dictionaries
/// (JSON may encode those as unordered arrays) and never `StableHash.canonical`,
/// whose empty-Data fallback would make different values collide.
nonisolated enum CanonicalDigest {
    static let version = 1

    private struct Envelope<Value: Encodable>: Encodable {
        let domain: String
        let version: Int
        let value: Value
    }

    struct EncodingFailure: LocalizedError {
        let domain: String
        var errorDescription: String? { "无法计算一致性摘要（\(domain)）；本次操作已中止。" }
    }

    static func digest<Value: Encodable>(_ value: Value, domain: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(Envelope(domain: domain, version: version, value: value)) }
        catch { throw EncodingFailure(domain: domain) }
        guard !data.isEmpty else { throw EncodingFailure(domain: domain) }
        return "v\(version):" + hex(data)
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Exact memory fingerprint: NFC, CRLF/CR → LF, surrounding whitespace
    /// trimmed. No case or punctuation folding, so different facts never merge.
    static func normalizedContent(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func contentFingerprint(_ text: String) -> String {
        "v\(version):" + hex(Data(normalizedContent(text).utf8))
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

/// The stored identity of one real transcript message for gates: everything
/// that reaches a model or the user, but not request-only state (live images,
/// replay snapshots) and not timestamps that a delivery boundary rewrites.
nonisolated struct MessageDigestDTO: Encodable {
    struct Call: Encodable { let id: String; let name: String; let arguments: String; let providerItemID: String? }
    let id: String
    let role: String
    let text: String
    let modelText: String?
    let toolCalls: [Call]
    let toolCallID: String?
    let toolName: String?
    let isError: Bool
    let reasoning: [String]
    /// Opaque provider replay items (for example Responses reasoning items)
    /// are re-sent by provider encoders, so they are part of the identity.
    let providerItems: [String]
    /// Identity of user images: attachment IDs (bytes live in files).
    let imageIDs: [String]

    init(_ message: AgentTranscriptMessage, imageIDs: [UUID] = []) throws {
        id = message.id.uuidString
        role = message.role.rawValue
        text = message.text
        modelText = message.modelText
        toolCalls = try message.toolCalls.map {
            Call(id: $0.id, name: $0.name, arguments: try $0.arguments.canonicalString(), providerItemID: $0.providerItemID)
        }
        toolCallID = message.toolCallID
        toolName = message.toolName
        isError = message.isError
        reasoning = message.reasoning.map(\.text)
        providerItems = try message.providerItems.map { try $0.canonicalString() }
        self.imageIDs = imageIDs.map(\.uuidString)
    }

    static func digest(_ message: AgentTranscriptMessage) throws -> String {
        try CanonicalDigest.digest(try MessageDigestDTO(message), domain: "message")
    }

    /// What a model request carries for this message: the projected text
    /// (`modelText ?? text`), calls, tool identity, provider replay items and
    /// image identity. A stored message (images as attachment IDs) and the
    /// runtime's request copy (images with the same IDs) agree on it.
    static func requestDigest(_ message: AgentTranscriptMessage, imageIDs: [UUID]? = nil) throws -> String {
        var view = message
        view.text = message.modelText ?? message.text
        view.modelText = nil
        return try CanonicalDigest.digest(try MessageDigestDTO(view, imageIDs: imageIDs ?? message.images.map(\.id)),
                                          domain: "request-message")
    }

    static func callDigest(_ call: AgentToolCall) throws -> String {
        try CanonicalDigest.digest(Call(id: call.id, name: call.name, arguments: try call.arguments.canonicalString(),
                                        providerItemID: call.providerItemID),
                                   domain: "tool-call")
    }
}

nonisolated extension AgentJSONValue {
    /// Sorted-key JSON text; stable across processes for the same value.
    /// Throws instead of substituting another encoding.
    func canonicalString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return String(decoding: try encoder.encode(self), as: UTF8.self) }
        catch { throw CanonicalDigest.EncodingFailure(domain: "json-value") }
    }
}
