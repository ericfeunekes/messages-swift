# Local operation schemas

These are this project's own version 1 schemas. The typed definitions live in
`Sources/MessagesCore/OperationModels.swift`; MCP accepts the same camelCase keys.
Unknown keys, wrong types and explicit nulls for non-nullable inputs are invalid.
Dates are ISO-8601 strings with an explicit offset. Start is inclusive and end is
exclusive. Limits default to 50 and range from 1 through 100.

## Inputs

| Tool | Fields |
|---|---|
| `find_chats` | Optional `query`; `participants` defaults to `[]`; `membership` defaults to `contains_all`; `dateRange` defaults to `{}`; `unreadOnly` defaults to `false`; `limit`; optional `cursor` |
| `read_messages` | Required `chatID`; `dateRange`, `unreadOnly`, `limit`, optional `cursor` |
| `search_messages` | Required nonempty `query`; optional `chatID`; `participants`, `membership`, `dateRange`, `unreadOnly`, `limit`, optional `cursor` |
| `set_chat_alias` | Required `chatID` and `alias`; string sets/replaces this chat's alias, null removes it |

`chatID` is the source `chat.guid`, never its row number or `chat_identifier`.
`dateRange` contains optional `start` and `end`. `membership` is `contains_all` or
`exact`. Each participant selector has exactly one of `query` (a name or handle)
and `sourceIdentity` (`containerID` and `id` from a returned contact candidate).
Names do not merge source contacts. Ambiguous lookup returns candidates for an
explicit choice, rather than selecting the first person. Membership selects
whole conversations, including messages sent by their other participants.

For continuation, repeat the original inputs with the returned `cursor`.
Cursors are opaque, preserve filters and the initial arrival fence, and reject
changed scope or replacement databases. They are not offsets. Results are newest
first with source row order breaking equal timestamps. New backdated arrivals
are excluded from an existing message continuation.

## Results

Find returns `chats`, `contactCandidates` and optional `nextCursor`. Each chat
includes `chatID`, `label`, `nativeName`, `alias`, `participants`, `service`,
`lastActivity` and `unreadCount` (omitted when the source lacks read state). Label precedence is local alias, native
name, then participant names/handles. Participants keep their handle and selected
source identity when uniquely resolved; a shared handle is not one merged person.

Read returns the enriched `chat`, `messages`, `events`, `decodingDiagnostics` and
optional `nextCursor`. Search returns the same record collections, enriched
`chats` and `contactCandidates`. Ordinary user messages and attachment-only rows
are in `messages`. Proven reaction, system or preview rows and unclassified rows
are separate typed `events`. Both preserve source identity and readable text.
There is no timestamp/sender preview coalescing. Associations and edit/retraction
markers are reported only when the source supports them; no original text or edit
history is invented. Missing classification metadata means unknown.

Bodies distinguish decoded text, absent bodies and failed decoding. Search uses
the native canonical case-insensitive whole-Character matcher on readable bodies,
including attributed-only content and typed events. Failed decoding produces a
diagnostic even on an empty search page; no matches is not proof of complete
coverage when diagnostics are present. Attachments carry metadata and availability,
not file contents. Message and event collections together form the page; consumers
must not treat either array's length as activity counts.

MCP returns structured JSON plus equivalent text. Invalid invocations use JSON-RPC
invalid-params errors; expected operation failures use `isError: true` and an
`error` object with a stable `code`; alias collisions also return conflicting `chatIDs`. Alias writes change only local metadata.
Sending, activity counts and production image access have no registered handlers
in this slice; their requirements remain part of the first release.
