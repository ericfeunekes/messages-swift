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
changed scope or a different MessageStore connection. Restart the query after
server restart or database replacement; aliases are unaffected. They are not offsets. Message associations are newest
first by exact source (date, message row, chat row), all descending. The public
result identity is the pair (`id`, `chatID`); one message associated with two chats
is returned twice, with both associations preserved across page boundaries. New backdated arrivals
are excluded from an existing message continuation.

## Results

Find returns `chats`, `contactCandidates` and optional `nextCursor`. Each chat
includes `chatID`, `label`, `nativeName`, `alias`, `participants`, `service`,
`lastActivity` and `unreadCount` (omitted when the source lacks read state). Label precedence is local alias, native
name, then participant names/handles. Participants keep their handle and selected
source identity when uniquely resolved; a shared handle is not one merged person.

Read returns the enriched `chat`, `messages`, `events`, `decodingDiagnostics`,
`decodingFailureCount`, `scannedAssociationCount`, `unresolvedContactHandles`,
`contactCandidates` and optional `nextCursor`. Search returns the same record collections, enriched
`chats` and `contactCandidates`. Ordinary user messages and attachment-only rows
are in `messages`. Proven reaction, system or preview rows and unclassified rows
are separate typed `events`. Both preserve source identity and readable text.
There is no timestamp/sender preview coalescing. Associations and edit/retraction
markers are reported only when the source supports them; no original text or edit
history is invented. Missing classification metadata means unknown.

Bodies distinguish decoded text, absent bodies and failed decoding. Search uses
the native canonical case-insensitive whole-Character matcher on readable bodies,
including attributed-only content and typed events. `decodingFailureCount` is the
exact number of failed-body associations consumed by this call;
`decodingDiagnostics` contains at most ten examples. `scannedAssociationCount`
counts all structurally filtered associations consumed, including nonmatches.
The interval starts strictly after the request cursor and ends at the last
consumed association, or exhaustion. Lookahead checks existence only and is not
decoded, consumed or diagnosed. Counts can therefore be summed across all pages
without duplicating diagnostics. Search continuation can end with an empty page
containing only nonmatches/failures. No matches does not mean complete readable
coverage when `decodingFailureCount` is positive. Attachments carry metadata and availability,
not file contents. Message and event collections together form the page; consumers
must not treat either array's length as activity counts.

For warm phone lookups, native matching is best effort. `unresolvedContactHandles`
identifies handles whose ownership/completeness is unproven. Their participants
and senders remain handle-only, while `contactCandidates` preserves selected-source
possibilities, including approximate matches. These candidates are not resolved
identities and must not be silently selected. Full selected-container discovery
is separate from this candidate lookup.

MCP returns structured JSON plus equivalent text. Invalid invocations use JSON-RPC
invalid-params errors; expected operation failures use `isError: true` and an
`error` object with a stable `code`; alias collisions also return conflicting `chatIDs`. Alias writes change only local metadata.
Sending, activity counts and production image access have no registered handlers
in this slice; their requirements remain part of the first release.

Malformed cursor encodings return `invalid_cursor`; a valid cursor with changed
filters, search mode, or owning connection returns `cursor_mismatch`. SQLite's
opened-file moved signal returns `database_replaced`. A failed/unsupported
opened-file check returns `database_check_failed`; it is never treated as an
unchanged file. Both require a fresh server/store and new query.
