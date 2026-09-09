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
| `send_message` | Exactly one of `chatID` or `recipients` (one participant selector); `service` required only with recipients (`iMessage`, `SMS`, `RCS`); optional nonempty `text`; `files` defaults to `[]` (absolute local file paths); text or files required |
| `set_chat_alias` | Required `chatID` and `alias`; string sets/replaces this chat's alias, null removes it |
| `read_image` | Required nonempty `messageID` and `attachmentID` from history/search; no path or rendering options |
| `read_attachment` | Required nonempty `messageID` and `attachmentID` from history/search; no path |

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

For warm phone lookups, native matching is best effort. A single exact normalized
selected-source owner retains its joined name and identity. `unresolvedContactHandles`
identifies approximate-only, unmatched or ambiguous handles; their participants
and senders remain handle-only. `contactCandidates` preserves selected-source
possibilities with `requestedHandle` and `match` (`exact` or `approximate`), so
approximate candidates are not silently selected or detached from their query.
Native candidate completeness and country normalization remain live proof limits. Full selected-container discovery
is separate from this candidate lookup.

MCP returns structured JSON plus equivalent text. Invalid invocations use JSON-RPC
invalid-params errors; expected operation failures use `isError: true` and an
`error` object with a stable `code`; alias collisions also return conflicting `chatIDs`. Alias writes change only local metadata.
Activity counts remain a separate first-release operation.

Malformed cursor encodings return `invalid_cursor`; a valid cursor with changed
filters, search mode, or owning connection returns `cursor_mismatch`. SQLite's
opened-file moved signal returns `database_replaced`. A failed/unsupported
opened-file check returns `database_check_failed`; it is never treated as an
unchanged file. Both require a fresh server/store and new query.

## Incoming attachment retrieval

Both attachment tools resolve the exact message identity and its joined attachment
identity in the current database. GUID-less identities returned by history remain
valid only for that store connection. Neither tool accepts a filesystem path.
History metadata remains unchanged; its availability is an observation at listing
time, not a promise that retrieval will succeed later. No content is cached or
downloaded from iCloud.

`read_attachment` returns complete original bytes as one base64 MCP embedded
resource, with an opaque message/attachment URI and the original filename in
structured metadata. MIME selection uses source MIME, then source UTI, then name
extension, then `application/octet-stream`; this labels bytes without parsing or
converting documents. The original source MIME and UTI remain in attachment metadata;
its filename is the display name, never the internal storage path.
Files larger than 8 MiB are rejected, never truncated. Agents can pass the returned
bytes to their existing PDF or document tools.

`read_image` reads at most 32 MiB of source bytes through native ImageIO. It returns
one PNG MCP image: frame zero, orientation applied, at most 2,048 pixels on the
longest edge, no upscaling, and at most 8 MiB of encoded output. The source must be
an ImageIO-supported image (including HEIC when the OS supports it); PDFs are
documents for `read_attachment`, not images for `read_image`. Sources above
100 million pixels are rejected before pixel decoding. The structured result
reports source MIME, source dimensions, frame count, selected frame zero, rendered
dimensions, output MIME, original byte count and returned byte count. Both tools
report `sourceByteLimit` and `returnedByteLimit`; image results also report
`maxPixelDimension` and `maxSourcePixelCount`. The image view does not
claim to preserve animation, all pages, metadata or the original encoding.

Expected failures use `isError: true` with `error.code`: `attachment_not_found`
(message or associated attachment absent), `attachment_unavailable` (missing path,
undownloaded, unreadable or failed read), `attachment_unsafe_file` (symlink,
nonregular file or invalid source path), `attachment_too_large`,
`unsupported_image`, or `invalid_image`. No failure exposes file paths. Opened
files must be regular local files; path traversal through symlinks is rejected,
and bounded reads use the same descriptor checked by `fstat`.

Owning proof uses synthetic SQLite message/attachment associations, actual files,
native image encode/decode fixtures, and an independent MCP client that checks
returned bytes and MIME. Cases cover association mismatch, connection-scoped IDs,
missing files, symlinks and nonregular files, unsupported and malformed images,
image resizing/frame selection, file MIME handling and exact size boundaries.
## Sending

`chatID` selects an exact existing direct or group GUID and forbids a service
override. Resolve names and aliases through `find_chats`, then preview the chosen
chat's participants and service before sending. A label is never a chat ID.
`recipients` contains exactly one selector for an individual, including a new
individual. It requires an explicit service in the confirmed preview. Multiple
recipients do not create a new group. An explicit full phone number or email
selects that handle without expanding to other addresses on its contact. A name
or source identity with multiple handles returns choices. Names resolve only
against the selected Contacts source; duplicate names remain separate candidates.

The result has `status`, `delivery: "unconfirmed"`, optional `destination`,
`contactCandidates`, `handleCandidates`, `parts` and optional `errorCode`.
`destination` reports an optional `chatID`, service and recipients. A
`needs_choice` result sends nothing; choose the contact/handle and obtain a revised
preview confirmation. Validation failures use the normal error envelope with
`invalid_send_destination`, `invalid_send_content` or `invalid_send_file`.

Each part has its zero-based `index`, `kind` (`text` or `file`), optional
zero-based `fileIndex`, `outcome` and optional stable `errorCode`. Text precedes
files in their supplied order. Outcomes are `accepted`, `rejected`, `unknown` or
`not_attempted`. Sending stops at the first rejection or unknown outcome; later
parts remain `not_attempted`. Overall status is `accepted` only when every part
is accepted, `partial` when some are accepted before a known failure, `unknown`
when any dispatch is uncertain, and `rejected` when none are accepted and none
are uncertain. Unknown takes precedence even after earlier accepted parts.
`accepted` means Messages accepted the command, never confirmed delivery.
Concurrent batches return `send_in_progress` without dispatch; no automatic
retry, duplicate send, new-group creation or service switching occurs.

All files must be readable regular files before the first command. Relative
paths, final-component symlinks, directories, missing files and NUL strings are
rejected. File identity, size and modification/change times are checked again
before each command, catching changes across earlier awaited sends. A changed
file stops the batch with `send_file_changed`. This does not freeze a path after
handoff to Messages or verify what Messages later reads. Keep approved files
unchanged until Messages finishes processing them.

The public scripting adapter requires Automation permission already granted by
the setup UI. It does not prompt on a send. Existing chats use the exact scripting
chat ID with no recipient fallback. Individual routing requires exactly one
enabled account of the requested service; an unavailable or ambiguous route is
reported as a rejected part with `messages_route_unavailable`. A dictionary service name does not establish that this Mac can send
through that service. Genuine service/target behavior remains a live test gate.
