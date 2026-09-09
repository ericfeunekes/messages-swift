import Foundation
import MCP
import MessagesCore

public enum MCPServerRunner {
    public static func run(operations: MessagesOperations) async throws {
        try await run(operations: operations, transport: StdioTransport())
    }

    public static func run(operations: MessagesOperations, transport: any Transport) async throws {
        let server = Server(name: "messages-swift", version: "0.1.0", instructions: "Read, search and count local Messages with selected Contacts names, local aliases and message-bound images/files. Ambiguous contacts require a choice. Drafting never calls send_message. Use resolve_send_route before previewing a direct send, then show resolved recipients, frozen service, exact text and files and obtain confirmation. An unchanged confirmed preview needs no second conversational confirmation; any change requires a revised preview. After confirmation, send directly to the resolved explicit handle or exact direct chatID with the frozen service; never resolve a contact name again. Group sends target exact existing chats and have no service argument. The client approves the invocation. Never retry an uncertain or partial send or change transport automatically. sent is a uniquely correlated post-dispatch source-row observation, not an AppleScript receipt or delivery guarantee; a source-confirmed failure is a tool error. Attachment tools return bounded image views or complete original file bytes; errors do not deliver a file. Decoding diagnostics mean search coverage is incomplete. Never interpret a cached label as a send destination or route guarantee.", capabilities: .init(tools: .init()))
        let watches = SessionWatches()
        let tools = ToolSchemas.tools
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            guard let tool = tools.first(where: { $0.name == params.name }) else {
                throw MCPError.invalidParams("Unknown tool")
            }
            let arguments = Value.object(params.arguments ?? [:])
            try ToolSchemas.validate(arguments, against: tool.inputSchema)
            var fields = params.arguments ?? [:]
            if ["find_chats", "read_messages", "search_messages", "count_message_activity"].contains(params.name) {
                fields["dateRange"] = fields["dateRange"] ?? .object([:])
                fields["unreadOnly"] = fields["unreadOnly"] ?? false
                fields["limit"] = fields["limit"] ?? 50
            }
            if params.name == "find_chats" || params.name == "search_messages" || params.name == "count_message_activity" {
                fields["participants"] = fields["participants"] ?? .array([])
                fields["membership"] = fields["membership"] ?? "contains_all"
            }
            if params.name == "watch_messages" {
                fields["waitSeconds"] = fields["waitSeconds"] ?? 20
                fields["limit"] = fields["limit"] ?? 50
            }
            if params.name == "send_message" { fields["files"] = fields["files"] ?? .array([]) }
            if params.name == "count_message_activity" {
                fields["groupBy"] = fields["groupBy"] ?? "overall"
                fields["bucket"] = fields["bucket"] ?? "none"
                fields["ranking"] = fields["ranking"] ?? "chronological"
            }
            let data = try JSONEncoder().encode(Value.object(fields))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                if params.name == "count_message_activity" {
                    guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else {
                        throw MCPError.invalidParams("Dates must be ISO-8601 strings with an offset")
                    }
                    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return date }
                    if let date = try? Date.ISO8601FormatStyle().parse(value) { return date }
                    throw MCPError.invalidParams("Dates must be ISO-8601 strings with an offset")
                }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: value) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                guard let date = formatter.date(from: value) else {
                    throw MCPError.invalidParams("Dates must be ISO-8601 strings with an offset")
                }
                return date
            }
            do {
                switch params.name {
                case "watch_messages":
                    let input = try decoder.decode(WatchMessagesInput.self, from: data)
                    return try encode(await watches.run { try await operations.watchMessages(input) })
                case "read_image":
                    return try encodeAttachment(await operations.readImage(decoder.decode(ReadAttachmentInput.self, from: data)), image: true)
                case "read_attachment":
                    return try encodeAttachment(await operations.readAttachment(decoder.decode(ReadAttachmentInput.self, from: data)), image: false)
                case "resolve_send_route":
                    return try encode(await operations.resolveSendRoute(decoder.decode(ResolveSendRouteInput.self, from: data)))
                case "send_message":
                    let result = try await operations.sendMessage(decoder.decode(SendMessageInput.self, from: data))
                    return try encode(result, isError: result.status == .failed || result.status == .partial)
                case "find_chats":
                    return try encode(await operations.findChats(decoder.decode(FindChatsInput.self, from: data)))
                case "read_messages":
                    return try encode(await operations.readMessages(decoder.decode(ReadMessagesInput.self, from: data)))
                case "search_messages":
                    return try encode(await operations.searchMessages(decoder.decode(SearchMessagesInput.self, from: data)))
                case "count_message_activity":
                    return try encode(await operations.countMessageActivity(decoder.decode(CountMessageActivityInput.self, from: data)), preciseDates: true)
                default:
                    return try encode(await operations.setChatAlias(decoder.decode(SetChatAliasInput.self, from: data)))
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as MCPError { throw error }
            catch is DecodingError { throw MCPError.invalidParams("Arguments do not match the typed operation schema") }
            catch {
                let conflicts: [String]?
                if case LocalStateError.aliasAlreadyUsed(_, let chatIDs) = error { conflicts = chatIDs }
                else { conflicts = nil }
                return try encode(DomainFailure(error: .init(code: domainCode(error), chatIDs: conflicts)), isError: true)
            }
        }
        do {
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } catch {
            await watches.stop()
            await transport.disconnect()
            throw error
        }
        await watches.stop()
        await server.stop()
        await transport.disconnect()
    }

    private static func encodeAttachment(_ attachment: AttachmentContent, image: Bool) throws -> CallTool.Result {
        let metadata = try encode(attachment.info)
        let payload: Tool.Content
        if image {
            payload = .image(data: attachment.data.base64EncodedString(), mimeType: attachment.mimeType, annotations: nil, _meta: nil)
        } else {
            // The URI names the embedded bytes; it is not a filesystem path or a
            // second resource-reading authority. IDs are separate URI segments.
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let message = attachment.info.messageID.addingPercentEncoding(withAllowedCharacters: allowed)!
            let attachmentID = attachment.info.attachmentID.addingPercentEncoding(withAllowedCharacters: allowed)!
            let uri = "messages-attachment:///\(message)/\(attachmentID)"
            payload = .resource(resource: .binary(attachment.data, uri: uri, mimeType: attachment.mimeType))
        }
        return try .init(content: metadata.content + [payload], structuredContent: metadata.structuredContent, isError: false)
    }

    private static func encode<T: Encodable>(_ object: T, isError: Bool = false, preciseDates: Bool = false) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if preciseDates {
            encoder.dateEncodingStrategy = .custom { date, encoder in
                let reference = date.timeIntervalSinceReferenceDate
                let seconds = floor(reference)
                let fraction = Int64(((reference - seconds) * 1_000_000).rounded())
                let whole = ISO8601DateFormatter().string(from: Date(timeIntervalSinceReferenceDate: seconds + Double(fraction / 1_000_000)))
                let value = String(whole.dropLast()) + String(format: ".%06lldZ", fraction % 1_000_000)
                var container = encoder.singleValueContainer()
                try container.encode(value)
            }
        }
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(object)
        let value = try JSONDecoder().decode(Value.self, from: data)
        return try .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], structuredContent: value, isError: isError)
    }

    private static func domainCode(_ error: Error) -> String {
        // Each domain owns its errors; never emit raw errors containing paths or private values.
        if let error = error as? WatchError { return error.rawValue }
        if let error = error as? AttachmentReadError { return error.rawValue }
        if let error = error as? SendValidationError { return error.rawValue }
        if let error = error as? SendRouteError { return error.rawValue }
        if let error = error as? ActivityError {
            switch error {
            case .invalidTimeZone: return "invalid_time_zone"
            case .continuationInvalidated: return "activity_changed_restart_required"
            }
        }
        if let error = error as? ContactsDirectoryError {
            switch error {
            case .permissionNotGranted: return "contacts_permission_not_granted"
            case .selectedContainerMissing: return "selected_contacts_container_missing"
            }
        }
        if let error = error as? LocalStateError {
            switch error {
            case .aliasAlreadyUsed: return "alias_already_used"
            case .unsupportedStateVersion: return "unsupported_state_version"
            case .duplicateCachedContactIdentity: return "duplicate_cached_contact_identity"
            }
        }
        if let error = error as? OperationError {
            switch error {
            case .unknownChat: return "chat_not_found"
            case .invalidLimit: return "invalid_limit"
            case .invalidCursor: return "invalid_cursor"
            case .invalidSelector: return "invalid_selector"
            case .contactNotFound: return "contact_not_found"
            case .invalidDirectory: return "invalid_directory"
            case .invalidQuery: return "invalid_query"
            }
        }
        if let error = error as? MessageStoreError {
            switch error {
            case .invalidLimit: return "invalid_limit"
            case .invalidDateRange: return "invalid_date_range"
            case .cursorFilterMismatch: return "cursor_mismatch"
            case .databaseReplaced: return "database_replaced"
            case .databaseIdentityUnavailable: return "database_check_failed"
            case .missingSchema: return "unsupported_database_schema"
            case .sqlite: return "database_error"
            }
        }
        return "operation_failed"
    }
}

private struct DomainFailure: Encodable {
    struct Detail: Encodable { let code: String; let chatIDs: [String]? }
    let error: Detail
}


/// SDK 0.12.1 cancels handlers on notifications, but stop() does not cancel
/// inbound handlers. Retain only this session's waits to end them on EOF too.
actor SessionWatches {
    private var stopped = false
    private var tasks: [UUID: Task<WatchMessagesResult, Error>] = [:]

    func run(_ operation: @escaping @Sendable () async throws -> WatchMessagesResult) async throws -> WatchMessagesResult {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let id = UUID()
        let task = Task { try await operation() }
        tasks[id] = task
        defer { tasks.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func stop() async {
        stopped = true
        let pending = Array(tasks.values)
        for task in pending { task.cancel() }
        for task in pending { _ = try? await task.value }
    }
}
