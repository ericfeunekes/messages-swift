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
        Tool(name: "watch_messages", description: "Wait for incoming new chat associations in one exact chat during this active call only. Default/max wait 20 seconds; zero establishes a cursor without waiting. Without cursor starts now. Resume exclusively with returned cursor; replay may duplicate data. Does not wake idle clients or detect all edits/deletions. Ordinary rows and events retain read semantics.", inputSchema: object(["chatID": string, "cursor": string, "waitSeconds": ["type": "integer", "minimum": 0, "maximum": 20], "limit": ["type": "integer", "minimum": 1, "maximum": 100]], required: ["chatID"]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "read_image", description: "View a message-bound image attachment as PNG. Native decoding, first frame, orientation applied, longest edge at most 2048 pixels. Source limit 32 MiB and 100 million pixels; output limit 8 MiB. No cloud download. Use IDs from history/search.", inputSchema: object(["messageID": string, "attachmentID": string], required: ["messageID", "attachmentID"]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "read_attachment", description: "Retrieve complete original bytes of a message-bound file as an embedded MCP resource, with name and MIME metadata. Maximum 8 MiB; larger files fail without truncation. No cloud download. Use IDs from history/search; paths are not accepted.", inputSchema: object(["messageID": string, "attachmentID": string], required: ["messageID", "attachmentID"]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "send_message", description: "Send only after confirmation of an exact recipients/service/text/files preview, including when the initial request says send. Drafting never calls this tool. Exactly one destination: existing direct/group chatID (find aliases/names first), or one recipient with explicit service. Ambiguous names/handles return choices. Text then files in order, stops on rejection/unknown; never retry automatically. Accepted is not delivered.", inputSchema: object(["chatID": string, "recipients": ["type": "array", "items": participant], "service": ["type": "string", "enum": ["iMessage", "SMS", "RCS"]], "text": string, "files": ["type": "array", "items": string]]), annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)),
        Tool(name: "find_chats", description: "Find enriched conversations by name, handle, alias or participant membership. Ambiguous people return candidates. Repeat filters with cursor.", inputSchema: object(common.merging(discovery) { _, new in new }.merging(["query": string]) { _, new in new }), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "read_messages", description: "Read one exact chat GUID, newest first. Ordinary messages and typed events are separate; check decoding diagnostics. Repeat filters with cursor.", inputSchema: object(common.merging(["chatID": string]) { _, new in new }, required: ["chatID"]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "search_messages", description: "Search readable bodies with canonical case-insensitive whole-Character matching. Participant filters select whole chats. Diagnostics indicate incomplete coverage. Repeat filters with cursor.", inputSchema: object(common.merging(discovery) { _, new in new }.merging(["query": string, "chatID": string]) { _, new in new }, required: ["query"]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
        Tool(name: "count_message_activity", description: "Count user messages, excluding retracted messages and reactions/previews/unknown events. Overall deduplicates messages across chats. Calendar buckets use the reported time zone and Monday weeks. Ranking orders chats by whole-range counts, retaining chronological buckets. Defaults to the Mac time zone on the first request. Repeat inputs with cursor.", inputSchema: object(common.merging(discovery) { _, new in new }.merging([
            "chatID": string, "timeZone": string,
            "groupBy": ["type": "string", "enum": ["overall", "chat"]],
            "bucket": ["type": "string", "enum": ["none", "day", "week", "month"]],
            "ranking": ["type": "string", "enum": ["chronological", "total", "sent", "received"]],
        ]) { _, new in new }), annotations: .init(readOnlyHint: true, openWorldHint: false)),
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
            guard let minimum = definition["minimum"]?.intValue, let maximum = definition["maximum"]?.intValue,
                  (minimum...maximum).contains(number) else { throw MCPError.invalidParams("Integer is outside the permitted range") }
        case ("boolean", .bool): break
        default: throw MCPError.invalidParams("Argument has the wrong type")
        }
    }
}
