import AgentKit
import Foundation

/// Freeze a bounded observation before the SDK's generic text projection.
/// Raw results stay intact for history; only whole trailing nodes are omitted.
nonisolated enum PhoneToolResult {
    static let maximumModelBytes = 64 * 1024

    /// Shared by the phone executor and the contract fixtures.
    static func encode(_ envelope: [String: Any], isError: Bool = false) throws -> (content: String, isError: Bool) {
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return (String(decoding: data, as: UTF8.self), isError)
    }

    static func make(callID: String, content: String, isError: Bool) throws -> AgentToolResult {
        var result = AgentToolResult(callID: callID, content: content, isError: isError)
        guard let value = try? AgentJSONValue.decode(Data(content.utf8)),
              var envelope = AgentSensitiveDataRedactor.redactedJSON(value).objectValue,
              var screen = envelope["screen"]?.objectValue,
              screen["snapshot_id"]?.numberValue != nil,
              let elements = screen["elements"]?.arrayValue else { return result }
        let sourceTruncated = screen["truncated"]?.boolValue == true
        func encode(_ count: Int) -> Data {
            screen["elements"] = .array(Array(elements.prefix(count)))
            screen["truncated"] = .bool(sourceTruncated || count < elements.count)
            screen["model_omitted_elements"] = .number(Double(elements.count - count))
            envelope["screen"] = .object(screen)
            return AgentJSONValue.object(envelope).encodedData
        }
        var data = encode(elements.count)
        if data.count > maximumModelBytes {
            data = encode(0)
            if data.count > maximumModelBytes {
                // A remote failure explanation can be large after an action
                // was sent. Keep outcome/no-replay fields, shortening only prose.
                var shortened: [AgentJSONValue] = []
                for key in ["message", "error"] {
                    if let text = envelope[key]?.stringValue, text.utf8.count > 2048 {
                        envelope[key] = .string(HostToolResult.clip(text, bytes: 2048) + "…（说明已缩短）")
                        shortened.append(.string(key))
                    }
                }
                if !shortened.isEmpty { envelope["projection_shortened_fields"] = .array(shortened) }
                data = encode(0)
            }
            guard data.count <= maximumModelBytes else { throw OversizedMetadata() }
            var lower = 0, upper = elements.count
            // Keep the longest prefix fitting the encoded, redacted byte budget.
            while lower < upper {
                let count = (lower + upper + 1) / 2
                let candidate = encode(count)
                if candidate.count <= maximumModelBytes { lower = count; data = candidate }
                else { upper = count - 1 }
            }
        }
        result.modelContent = String(decoding: data, as: UTF8.self)
        result.hasBoundedModelContent = true
        return result
    }

    private struct OversizedMetadata: LocalizedError {
        var errorDescription: String? { "屏幕观察的元数据超过上限，未提供可操作的节点；请重新观察。" }
    }
}
