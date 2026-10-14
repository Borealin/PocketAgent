import AgentKit

/// Gemini's FunctionDeclaration.parameters is an OpenAPI Schema, not arbitrary
/// JSON Schema. Keep runtime validation strict and adapt only its wire copy.
nonisolated enum ProviderToolSchema {
    static func prepare(_ request: AgentModelRequest, format: ModelAPIFormat) -> AgentModelRequest {
        guard format == .generateContent else { return request }
        var result = request
        result.tools = request.tools.map { tool in
            var wire = tool
            wire.inputSchema = gemini(tool.inputSchema)
            return wire
        }
        return result
    }

    private static func gemini(_ schema: AgentJSONValue) -> AgentJSONValue {
        guard var object = schema.objectValue else { return schema }
        object.removeValue(forKey: "additionalProperties")
        object.removeValue(forKey: "uniqueItems")
        if let properties = object["properties"]?.objectValue {
            object["properties"] = .object(properties.mapValues(gemini))
        }
        if let items = object["items"] { object["items"] = gemini(items) }
        if let variants = object["anyOf"]?.arrayValue { object["anyOf"] = .array(variants.map(gemini)) }
        return .object(object)
    }
}
