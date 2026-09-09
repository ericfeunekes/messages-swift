# References and provenance

Sources were inspected on September 8–9, 2026. Observable behavior, public source and implementation inference are distinct evidence categories.

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

## Public conversation organization evidence

[Beeper platform-imessage at cda1545](https://github.com/beeper/platform-imessage/tree/cda1545b87db4aeb2ec266bd8f9f335eec67c323)
was inspected as prior art. Its `license.txt` is MIT. `MessagesDeepLink.swift`
constructs address/group/message links; `MessagesController.swift` implements
read-state, alert and deletion actions through Accessibility. This establishes
candidate interfaces, not this project's runtime support or targeting correctness.
Its selection checks can use predicted titles, focus/layout events or delays;
these do not independently identify a conversation. Its source notes that the UI
can merge direct service histories, so one database chat must not be assumed to
represent an entire native deletion scope.

The complete upstream implementation is not public-API-only: its window helper
uses CGS/SkyLight, localized labels load private ChatKit bundles, and the package
contains an IMessagePrivateSPI target. No such implementation was adopted here.
Four launch properties used upstream were absent from the installed public SDK.
Only public AppKit, Carbon Apple Events and ApplicationServices interfaces were
used in this project's independent navigation probes.

A local probe automatically navigated from an empty self-message composer to a
neutral composer and back to the exact observed synthetic self conversation,
without user clicks or message actions. This proves that one navigation path;
it does not prove arbitrary targets, draft preservation or unread-state behavior.
A secondary-instance probe returned a distinct Messages PID but could not obtain
a usable AX window. A later unsandboxed session check found the macOS login window
frontmost, so that run cannot establish that secondary automation is unsupported.
Live organization testing requires an interactive desktop and a verified target.

## Platform and protocol

- [Apple Contacts](https://developer.apple.com/documentation/contacts/cncontactstore): public authorization and contact-fetch API.
- Installed macOS Messages scripting dictionary, inspected using `sdef`: text/file sends to a participant or chat, account/participant/chat metadata; no history-message class. Dictionary presence does not establish live send or group-creation success.
- [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk): public Swift server/client implementation and stdio transport. The preparatory Intel fixture tested [0.12.1 at this commit](https://github.com/modelcontextprotocol/swift-sdk/tree/a0ae212ebf6eab5f754c3129608bc5557637e605) with an independent Python MCP 1.26.0 client; the production dependency choice remains subject to the application build.
- [MCP tools specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools): schemas, structured results and image content. Select supported protocol/dependency versions during implementation.
- [OpenAI local MCP support](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) and [public conformance tests](https://github.com/openai/codex/blob/main/scripts/mcp_conformance/server.py): host integration references, not proof that a custom server is already working.

## Contacts access findings

Apple’s public [container API](https://developer.apple.com/documentation/contacts/cncontainer), [container predicate](https://developer.apple.com/documentation/contacts/cncontact/predicateforcontactsincontainer(withidentifier:)) and [non-unified fetch option](https://developer.apple.com/documentation/contacts/cncontactfetchrequest/unifyresults) support a local scoping candidate. They do not automatically establish the Google login behind a container label. A user-confirmed source selection can resolve that setup question; runtime isolation still needs proof. Local reads reflect macOS synchronization, not a forced remote refresh.

For direct access, Google’s [contact search](https://developers.google.com/people/api/rest/v1/people/searchContacts) is prefix-based and capped at 30 results. [Connections listing](https://developers.google.com/people/api/rest/v1/people.connections/list) provides pagination for complete discovery. [Batch get](https://developers.google.com/people/api/rest/v1/people/getBatchGet) can refresh known contacts, with explicit source and field selection. These API contracts were inspected; native OAuth and directory operations have not been exercised by this project.

## Unicode matching references

[Unicode 16 case-folding data](https://www.unicode.org/Public/16.0.0/ucd/CaseFolding.txt) maps ß to ss and dotted capital İ to i plus combining dot under the default full fold. [Unicode's case-mapping guidance](https://www.unicode.org/faq/casemap_charprop.html) distinguishes case folding from lowercasing. These support reasoning about the isolated false match; they do not replace runtime reproduction or establish every platform's behavior.

The proposed matcher uses public [NSString searching](https://developer.apple.com/documentation/foundation/nsstring/range(of:options:range:locale:)) and Swift Character iteration. Canonical/case-insensitive comparison and whole-grapheme boundaries are distinct parts of the local contract. No framework code was decompiled or disassembled.

## Source and data boundaries

Public documentation is original prose with source links. Reused open-source code or fixtures must retain their required license and attribution. Proprietary extracted artifacts remain outside the repository.

Messages databases, contact caches, aliases and attachments are user data. Keep them outside Git and outside test logs. Use synthetic or explicitly redistributable fixtures. A schema inspection does not authorize publishing real row values.
