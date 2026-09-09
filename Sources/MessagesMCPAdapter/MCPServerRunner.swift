import Foundation
import MCP
import MessagesCore

public enum MCPServerRunner {
    public static func run(operations: MessagesOperations) async throws {
        try await run(operations: operations, transport: StdioTransport())
    }

    public static func run(operations: MessagesOperations, transport: any Transport) async throws {
        let server = Server(name: "messages-swift", version: "0.1.0", instructions: "Read and search local Messages with selected Contacts names, local aliases and message-bound images/files. Ambiguous contacts require a choice. Decoding diagnostics mean search coverage is incomplete. Attachment tools return bounded image views or complete original file bytes; errors do not deliver a file. Never interpret a cached label as a send destination.", capabilities: .init(tools: .init()))
        let tools = ToolSchemas.tools
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            guard let tool = tools.first(where: { $0.name == params.name }) else {
                throw MCPError.invalidParams("Unknown tool")
            }
            let arguments = Value.object(params.arguments ?? [:])
            try ToolSchemas.validate(arguments, against: tool.inputSchema)
            var fields = params.arguments ?? [:]
            if ["find_chats", "read_messages", "search_messages"].contains(params.name) {
                fields["dateRange"] = fields["dateRange"] ?? .object([:])
                fields["unreadOnly"] = fields["unreadOnly"] ?? false
                fields["limit"] = fields["limit"] ?? 50
            }
            if params.name == "find_chats" || params.name == "search_messages" {
                fields["participants"] = fields["participants"] ?? .array([])
                fields["membership"] = fields["membership"] ?? "contains_all"
            }
            let data = try JSONEncoder().encode(Value.object(fields))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
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
                case "read_image":
                    return try encodeAttachment(await operations.readImage(decoder.decode(ReadAttachmentInput.self, from: data)), image: true)
                case "read_attachment":
                    return try encodeAttachment(await operations.readAttachment(decoder.decode(ReadAttachmentInput.self, from: data)), image: false)
                case "find_chats":
                    return try encode(await operations.findChats(decoder.decode(FindChatsInput.self, from: data)))
                case "read_messages":
                    return try encode(await operations.readMessages(decoder.decode(ReadMessagesInput.self, from: data)))
                case "search_messages":
                    return try encode(await operations.searchMessages(decoder.decode(SearchMessagesInput.self, from: data)))
                default:
                    return try encode(await operations.setChatAlias(decoder.decode(SetChatAliasInput.self, from: data)))
                }
            } catch let error as MCPError { throw error }
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
            await transport.disconnect()
            throw error
        }
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

    private static func encode<T: Encodable>(_ object: T, isError: Bool = false) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(object)
        let value = try JSONDecoder().decode(Value.self, from: data)
        return try .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], structuredContent: value, isError: isError)
    }

    private static func domainCode(_ error: Error) -> String {
        // Each domain owns its errors; never emit raw errors containing paths or private values.
        if let error = error as? AttachmentReadError { return error.rawValue }
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
