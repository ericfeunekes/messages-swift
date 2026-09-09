# Requirements

## Purpose

Make Apple Messages usable through natural references to people and conversations. The agent receives readable names and joined context rather than assembling database identifiers, contact records and chat membership itself.

The implementation is native Swift, local, lightweight and fast. It exposes typed operations primarily through stdio MCP. A CLI is a secondary adapter when useful for diagnostics or manual scripting. The [architecture](architecture.md) owns the implementation boundaries.

## People and conversations

- Find conversations by contact name, phone number, email address, native Messages name or a saved local alias.
- Google Contacts associated with the user’s selected Gmail account is the authoritative upstream directory. Access its selected macOS Contacts container using existing system synchronization; do not build a direct Google connection. The local cache is derived data, not a second contact-maintenance system.
- Expand a contact to its associated handles using source identity. Do not merge people merely because their display names match. The access adapter must preserve the selected account boundary.
- Return stable chat identity, readable label, native name, saved alias, participants, service, recent activity and unread information together.
- Match conversations containing all named participants. Exact membership excludes additional participants; it is distinct from filtering individual message senders.
- Surface ambiguous contacts and conversations as candidate matches with enough context to choose. A ranked first result is not authorization to choose a send destination.
- Allow a user-assigned name to identify the same thread across sessions. Alias persistence is independent of the contact cache.
- Cache contact information for approximately 100 people, initially using the frequent-contact directory and then FIFO eviction. Refresh a contact daily or when used by a read/send/other operation, whichever is sooner. This accelerates lookup but does not limit which people can be resolved.
- Keep thread aliases local to this Mac and durable independently of contact refresh or eviction.

Accepted cache choices and remaining execution details are recorded in [decisions](decisions.md#directory-and-cache).

## Reading, drafting and sending

Read-only listing, filtering, searching, counts and image access have no custom per-chat approval prompts. Required macOS permissions remain in force. Reads do not mark messages as read, send read receipts or mutate conversation state.

Drafting is an agent action and never invokes a send. Before any send, including a request to send an explanation, the agent presents the resolved recipients, exact content and attachment list and asks for confirmation. An affirmative reply to that preview authorizes that exact send through the client's normal auto-approval path. The agent does not add another conversational confirmation for an unchanged approved preview. Changing the recipients, content or files requires a revised preview.

The assistant owns interpreting intent and showing the preview. The client owns approval of the actual invocation. The Swift operation validates its arguments and executes the requested action; it does not authenticate conversational consent or maintain a parallel approval broker. OS Automation permission is a separate boundary.

A send result distinguishes an operation accepted by Messages from confirmed delivery. An uncertain result does not trigger an automatic retry, transport change or duplicate send. Text plus multiple files must not be described as atomic unless the send boundary proves that behavior. If only part succeeds, report that partial outcome.

The first release includes reading and sending. The policy above governs every send that is exposed.

Group sending targets existing conversations in the first release. Creating new groups is outside that release; this does not exclude new individual recipients.

## Operations

These names describe the intended operation surface. Exact input and output schemas are authored locally before implementation; they are not claimed to reproduce unpublished OpenAI schemas.

| Operation | Required behavior |
|---|---|
| `find_chats` | Name/alias/contact resolution, participant membership, date and unread filtering, enriched results |
| `read_messages` | One exact chat; newest-first pages, date/unread filtering and attachment metadata |
| `search_messages` | Case-insensitive body search, conversation membership and date filters, newest-first pages |
| `send_message` | Exactly one destination selector: stable chat identity or resolved recipients; text, local files or both, within the approved release scope |
| `count_message_activity` | Total/sent/received counts over a date range, overall or per chat, calendar buckets and ranking |
| `read_image` | An image attachment identified by a message result, returned in a form the agent can view |
| `read_attachment` | Complete bounded original file bytes identified by a message and its associated attachment; usable by the agent's existing document tools |
| `set_chat_alias` | Set, replace or remove a local name for an exact conversation; a local metadata write, not a message send |

## History and search semantics

- Start dates are inclusive; end dates are exclusive.
- History and search are newest first with a deterministic tie-breaker. Continuation preserves filters and ordering, including equal timestamps and arrivals between pages.
- Apply conversation, participant and date filters before the returned-page limit. Filtering a truncated global page is incorrect.
- Search readable decoded body text, including messages whose plain-text field is empty. A decoding failure is not a successful blank message.
- Case-insensitive substring matching respects canonical equivalence and whole Swift Character boundaries. Do not match a component inside a combined letter or emoji; continue past rejected partial matches to find later valid matches. Use the tested native-matcher direction without a persistent body index.
- Preserve attachment-only messages and report attachment availability. History returns attachment metadata, not all file contents.
- Stable chat identifiers can be reused across calls. Page-local participant and sender references are valid only within their own response, which includes the names needed to interpret them.
- The treatment of reactions, edits, retractions, system rows and preview rows must be settled in the message model before count/search implementations depend on it. See [message interpretation](decisions.md#message-interpretation).

## Activity and attachments

Counts use the same source classification as history. Source-marked retracted/unsent messages remain visible in history but are excluded from activity totals. Edits do not add messages. Counts support half-open date ranges, sent/received splits, an explicit reported time zone, Monday week boundaries and empty intervals. Resolved bounds remain stable across continuation pages. Daily totals alone cannot answer partial-day ranges.

Image and file access resolve an attachment belonging to a message result. Neither is an arbitrary filesystem reader. Missing or undownloaded attachments remain distinguishable from absent attachments. File access preserves original bytes and type/name metadata; size limits fail explicitly without truncation. Image views report resizing and frame selection. No automatic cloud fetch is required. Outgoing files are shown in the preview and validated before sending.

## Scope boundaries

- Intel macOS is the initial validation target. The minimum supported macOS version and Apple Silicon release coverage remain [open](decisions.md#platform-and-runtime).
- Existing public Swift source and tests may be reused with their licenses. The implementation does not wrap the imsg CLI as its domain layer.
- No decompilation, disassembly, proprietary binary redistribution, private-framework injection or macOS security-setting changes.
- No requirement to edit or unsend messages, emit typing indicators/read receipts, create polls, manage accounts or provide a remote messaging bot.
- Contact reconciliation, deduplication, migration and edits to the authoritative contact directory are separate work. This project consumes the resulting directory and does not merge or move contacts.
- A native menu-bar app owns OS permission setup, selected Contacts source, connection status and the shared operation/cache lifetime. Multiple agent connections use that one owner. No separate background service, cloud service, embedded language model or general plugin framework is required.

Acceptance evidence belongs in [validation](validation.md); this document defines intended behavior, not a claim that it is already implemented.
