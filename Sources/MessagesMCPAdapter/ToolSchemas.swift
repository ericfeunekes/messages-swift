import MCP

enum ToolSchemas {
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        .object(["type": "object", "properties": .object(properties), "required": .array(required.map(Value.string)), "additionalProperties": false])
    }
    static let string: Value = ["type": "string", "minLength": 1]
    static let dateRange = object(["start": string, "end": string])
    static let identity = object(["containerID": string, "id": string], required: ["containerID", "id"])
    static let participant = object(["query": string, "sourceIdentity": identity])
    static let common: [String: Value] = [
        "dateRange": dateRange, "unreadOnly": ["type": "boolean"],
        "limit": ["type": "integer", "minimum": 1, "maximum": 100], "cursor": string,
    ]
    static let discovery: [String: Value] = [
        "participants": ["type": "array", "items": participant],
        "membership": ["type": "string", "enum": ["contains_all", "exact"]],
    ]
    static let tools: [Tool] = [
        Tool(name: "find_chats", description: "Find enriched conversations by name, handle, alias or participant membership. Ambiguous people return candidates. Repeat filters with cursor.", inputSchema: object(common.merging(discovery) { _, new in new }.merging(["query": string]) { _, new in new }), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "read_messages", description: "Read one exact chat GUID, newest first. Ordinary messages and typed events are separate; check decoding diagnostics. Repeat filters with cursor.", inputSchema: object(common.merging(["chatID": string]) { _, new in new }, required: ["chatID"]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "search_messages", description: "Search readable bodies with canonical case-insensitive whole-Character matching. Participant filters select whole chats. Diagnostics indicate incomplete coverage. Repeat filters with cursor.", inputSchema: object(common.merging(discovery) { _, new in new }.merging(["query": string, "chatID": string]) { _, new in new }, required: ["query"]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "set_chat_alias", description: "Set or replace a local alias for an exact chat GUID; null removes it. Does not rename Messages or send anything.", inputSchema: object(["chatID": string, "alias": ["type": ["string", "null"], "minLength": 1]], required: ["chatID", "alias"]), annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)),
    ]

    /// The SDK publishes schemas; runtime validation remains the adapter's job.
    static func validate(_ value: Value, against schema: Value) throws {
        guard let definition = schema.objectValue else { throw MCPError.invalidParams("Invalid schema") }
        if case .array(let types) = definition["type"], types.contains("null"), value == .null { return }
        let type = definition["type"]?.stringValue ?? "string"
        switch (type, value) {
        case ("object", .object(let fields)):
            let properties = definition["properties"]?.objectValue ?? [:]
            let required = definition["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard Set(fields.keys).isSubset(of: Set(properties.keys)), required.allSatisfy({ fields[$0] != nil }) else {
                throw MCPError.invalidParams("Missing or unexpected arguments")
            }
            for (key, field) in fields { try validate(field, against: properties[key]!) }
        case ("array", .array(let values)):
            for item in values { try validate(item, against: definition["items"]!) }
        case ("string", .string(let text)):
            guard !text.isEmpty else { throw MCPError.invalidParams("Strings must not be empty") }
            if let allowed = definition["enum"]?.arrayValue, !allowed.contains(value) { throw MCPError.invalidParams("Invalid enum value") }
        case ("integer", .int(let number)):
            guard (1...100).contains(number) else { throw MCPError.invalidParams("Limit must be between 1 and 100") }
        case ("boolean", .bool): break
        default: throw MCPError.invalidParams("Argument has the wrong type")
        }
    }
}
