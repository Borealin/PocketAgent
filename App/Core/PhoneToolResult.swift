import AgentKit
import Foundation

/// Freeze a bounded observation before the SDK's generic text projection.
/// Raw results stay intact for history; only whole trailing nodes are omitted.
nonisolated enum PhoneToolResult {
    static let maximumModelBytes = 64 * 1024

    static func make(callID: String, content: String, isError: Bool) throws -> AgentToolResult {
        var result = AgentToolResult(callID: callID, content: content, isError: isError)
        guard let value = try? AgentJSONValue.decode(Data(content.utf8)),
              var fields = AgentSensitiveDataRedactor.redactedJSON(value).objectValue,
              fields["snapshot_id"]?.numberValue != nil,
              let elements = fields["elements"]?.arrayValue else { return result }
        let sourceTruncated = fields["truncated"]?.boolValue == true
        func encode(_ count: Int) -> Data {
            fields["elements"] = .array(Array(elements.prefix(count)))
            fields["truncated"] = .bool(sourceTruncated || count < elements.count)
            fields["model_omitted_elements"] = .number(Double(elements.count - count))
            return AgentJSONValue.object(fields).encodedData
        }
        var data = encode(elements.count)
        if data.count > maximumModelBytes {
            data = encode(0)
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
