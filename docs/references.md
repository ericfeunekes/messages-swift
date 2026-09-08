# References and provenance

Sources were inspected on September 8, 2026. Observable behavior, public source and implementation inference are distinct evidence categories.

## OpenAI Messages

[OpenAI's Messages documentation](https://learn.chatgpt.com/docs/plugins#use-apple-messages-from-codex) describes local iMessage/SMS/RCS reading and sending, macOS permissions, send approval and the Apple Silicon desktop restriction.

A read-only inspection of the official Apple Silicon ChatGPT installer identified Messages plugin version `1.0.1000926` in app version `26.901.51231`. Its packaged entry point starts a native client in Messages MCP mode. Readable tool descriptions establish conversation finding, paginated history/search, sending text/files, activity counts and image attachment access. They also describe stable chat identifiers and page-local references.

The package declares a proprietary license. Its raw files, icon, extracted strings and binaries are not part of this repository. No decompilation or disassembly was used. This project's independently written requirements do not claim access to OpenAI's source, a complete tool schema, or exact runtime parity.

## Public imsg source

[Reviewed checkout](https://github.com/openclaw/imsg/tree/1db058697a1f6705d907516e668acf2e25ab57d8), commit `1db058697a1f6705d907516e668acf2e25ab57d8`. The repository is MIT-licensed and exposes an `IMsgCore` Swift library. The inspected build script includes x86_64. These facts establish a source/build route, not a completed build of this project.

Relevant source areas at that revision:

- [Package definition](https://github.com/openclaw/imsg/blob/1db058697a1f6705d907516e668acf2e25ab57d8/Package.swift) and [universal build script](https://github.com/openclaw/imsg/blob/1db058697a1f6705d907516e668acf2e25ab57d8/scripts/build-universal.sh).
- [Message paging](https://github.com/openclaw/imsg/blob/1db058697a1f6705d907516e668acf2e25ab57d8/Sources/IMsgCore/MessageStore%2BMessages.swift), [queries](https://github.com/openclaw/imsg/blob/1db058697a1f6705d907516e668acf2e25ab57d8/Sources/IMsgCore/MessageStore%2BQueries.swift) and [sender/date filters](https://github.com/openclaw/imsg/blob/1db058697a1f6705d907516e668acf2e25ab57d8/Sources/IMsgCore/MessageFilter.swift).
- [Body search](https://github.com/openclaw/imsg/blob/1db058697a1f6705d907516e668acf2e25ab57d8/Sources/IMsgCore/MessageStore%2BSearch.swift), [typed-stream parser](https://github.com/openclaw/imsg/blob/1db058697a1f6705d907516e668acf2e25ab57d8/Sources/IMsgCore/TypedStreamParser.swift) and [Contacts resolver](https://github.com/openclaw/imsg/blob/1db058697a1f6705d907516e668acf2e25ab57d8/Sources/IMsgCore/ContactResolver.swift).
- [Basic sender](https://github.com/openclaw/imsg/blob/1db058697a1f6705d907516e668acf2e25ab57d8/Sources/IMsgCore/MessageSender.swift), [statistics](https://github.com/openclaw/imsg/blob/1db058697a1f6705d907516e668acf2e25ab57d8/Sources/IMsgCore/MessageStore%2BStats.swift) and [core tests](https://github.com/openclaw/imsg/tree/1db058697a1f6705d907516e668acf2e25ab57d8/Tests/IMsgCoreTests).

The public read/query and basic scripting paths are the baseline. Advanced injected helpers and private-framework functionality are outside this project's scope. Library sender filters, forward cursors and daily counts are not substitutes for the conversation filters, descending continuation and arbitrary-window counts in our requirements.

## Platform and protocol

- [Apple Contacts](https://developer.apple.com/documentation/contacts/cncontactstore): public authorization and contact-fetch API.
- Installed macOS Messages scripting dictionary, inspected using `sdef`: text/file sends to a participant or chat, account/participant/chat metadata; no history-message class. Dictionary presence does not establish live send or group-creation success.
- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk): public Swift server/client implementation and stdio transport.
- [MCP tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools): schemas, structured results and image content. Select supported protocol/dependency versions during implementation.
- [OpenAI local MCP support](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) and [public conformance tests](https://github.com/openai/codex/blob/main/scripts/mcp_conformance/server.py): host integration references, not proof that a custom server is already working.

## Source and data boundaries

Public documentation is original prose with source links. Reused open-source code or fixtures must retain their required license and attribution. Proprietary extracted artifacts remain outside the repository.

Messages databases, contact caches, aliases and attachments are user data. Keep them outside Git and outside test logs. Use synthetic or explicitly redistributable fixtures. A schema inspection does not authorize publishing real row values.
