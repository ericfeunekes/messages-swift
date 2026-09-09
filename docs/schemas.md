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
are in `messages`. Reaction and preview rows and unclassified rows (including unsupported system events)
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

## Raw provider status in reads

Ordinary/attachment message results in both `read_messages` and `search_messages`
include optional `isSent` and `isDelivered` from the source integer flags, and
optional `deliveryErrorCode` from the source `error`. Attachment metadata includes
optional raw `transferState` from `transfer_state`. Missing columns and SQL NULL
remain unknown and are omitted; known false flags and numeric zero remain present.
No Apple error/state label is inferred from these numbers. For example, a locally
`available` attachment can coexist with an unsuccessful transfer state: local
file availability is independent of delivery. These are observed provider fields,
not a new send receipt or a promise that status has settled. `send_message` still
reports only command acceptance with delivery unconfirmed, without polling.

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
`invalid_send_destination`, `invalid_send_content`, `invalid_send_file`,
`send_file_changed` or `send_file_staging_failed`.

Each part has its zero-based `index`, `kind` (`text` or `file`), optional
zero-based `fileIndex`, `outcome` and optional stable `errorCode`. A uniquely
observed source row also reports `messageID`, raw `isSent`/`isDelivered`/error,
`observedService`, and `correlation: "unique_source_match"`. This correlation
uses one bounded post-dispatch candidate matched by exact destination and decoded
text (or normalized staged attachment path); it is evidence, not a Message ID
returned by AppleScript. Zero or competing candidates are `unknown`, never
chosen by row order. Text precedes files in their supplied order. Outcomes are
`sent`, `pending`, `failed`, `unknown` or `not_attempted`. Sending stops at the
first failed or unknown outcome; later parts remain `not_attempted`. `sent`
requires source `isSent: true` with no conflicting error; delivery remains
separate and may be false. `failed` requires source `isSent: false` plus a
nonzero source error. A successful scripting command without a safe observation
is `unknown`; it is never described as sent. Aggregate `failed` and `partial`
are MCP tool errors, while an uncertain result is not retried.
Concurrent batches return `send_in_progress` without dispatch; no automatic
retry, duplicate send, new-group creation or service switching occurs.

All files must be readable regular files before the first command. Relative
paths, final-component symlinks, directories, missing files and NUL strings are
rejected. The operation copies every validated file into a unique private batch
under `~/Library/Messages/Attachments/messages-swift` before the first command.
Each file keeps its original name in a separate index directory, so duplicate
names cannot overwrite one another. Copies use validated open source descriptors;
source identity, size and modification/change times are checked across copying
and before each command. A changed source stops with `send_file_changed`; staging
destination/copy failures report `send_file_staging_failed` without dispatching
any part. A source that disappears or becomes unreadable after initial validation
also reports `send_file_changed`.

Messages receives only the staged paths. Accepted or uncertain file transfers
retain their staged inputs after the operation returns for native asynchronous
consumption. Files known not to have been handed off are removed, including
unattempted files after rejection or cancellation. There is no expiry timer or
sweep of other batches/history attachments. The private retained copies can use
disk space until a separately defined cleanup policy is implemented; script
acceptance is not evidence that it is safe to delete them. Staging does not prove
delivery or authenticate whether content changed since the agent's preview.

The public scripting adapter requires Automation permission already granted by
the setup UI. It does not prompt on a send. Existing chats use the exact scripting
chat ID with no recipient fallback. Individual routing requires exactly one
enabled account of the requested service; an unavailable or ambiguous route is
reported as a rejected part with `messages_route_unavailable`. A dictionary service name does not establish that this Mac can send
through that service. Genuine service/target behavior remains a live test gate.

## Activity

`count_message_activity` uses optional `chatID`, `participants`, `membership` and
`unreadOnly` with the same conversation semantics as search. It accepts
`dateRange`, `timeZone` (an IANA identifier, default the Mac’s current zone at the initial request), `groupBy` (`overall`
or `chat`, default `overall`), `bucket` (`none`, `day`, `week`, `month`, default
`none`), `ranking` (`chronological`, `total`, `sent`, `received`, default
`chronological`), `limit` and `cursor`.

A missing end resolves to the invocation time. A missing start resolves to the
earliest structurally matching source date before that end, or the end itself
when no such row exists. Equal bounds are a valid empty interval; reversed bounds
are invalid. The result reports `resolvedDateRange`, `timeZone`, `groupBy`,
`bucket`, `ranking`, `rows`, enriched `chats`, `contactCandidates` and optional
`nextCursor`. Ambiguous contacts return candidates with no rows or resolved range.

Explicit MCP timestamps accept at most six fractional digits; higher precision
is rejected, not silently rounded. The invocation-time default and native Swift
Date arguments resolve to the nearest microsecond. The supported Date range is within 2^33 seconds of 2001-01-01 UTC
(roughly 1728–2273), where Foundation can represent that resolution; ranges outside those limits
return `invalid_date_range`. This is not nanosecond-accurate input. Source
timestamps, inferred earliest source bounds and cursor bounds retain their raw
integer nanoseconds. Display dates report microseconds, so an inferred boundary
closer than a microsecond to a source timestamp is not a lossless replacement for
the cursor. Continuation uses stored integer bounds, never reparsed display dates.

Each row has optional `chatID`, exact clipped `start` and `end`, and `counts`
(`total`, `sent`, `received`). Sent/received are source direction counts from
`isFromMe`, not delivery confirmations. Failed outgoing records can count;
provider delivery fields remain separate. Without buckets, each group has one row, including
an empty interval. Calendar buckets intersect the requested interval; partial
first/last buckets retain the exact requested bounds. Gregorian days/months and
Monday weeks use the reported time zone, including daylight-saving transitions.
Calendar bucketing of an empty interval returns no rows. Zero buckets are included.
Per-chat groups include matching source chats even when they have no activity.

Overall output is chronological. Per-chat output orders chats by the selected
whole-range count descending, breaking ties by chat GUID then source chat row ascending; chronological
ranking orders chats by GUID. Every chat retains its chronological bucket series,
including zeros. Pagination limits rows, so a chat’s series can span pages.
Repeat all inputs with the cursor. Resolved dates and time zone, source message/chat/message-association/membership-association
arrival fences and resolved participant groups remain fixed for continuation.
Changes to existing source rows are visible; this is an arrival-fenced query, not
a retained historical database snapshot. A digest of the sparse counts, chat coordinates and interval boundaries detects
changes that would invalidate row offsets or ranks, returning
`activity_changed_restart_required`. It stores no bodies or historical snapshot.
Edits that leave these output counts and coordinates unchanged do not invalidate
continuation; chat labels and contact enrichment remain current. Changed inputs, changed resolved
membership or another store connection reject continuation.

Ordinary and attachment-only messages count once, including edited rows at their
original source date. Source-marked retracted/unsent messages are excluded, while
history retains them with `isRetracted: true`. Reactions, previews and
unknown/system events do not count.
Overall rows count each physical source message ROWID once across matching chats;
per-chat rows count each distinct (message ROWID, chat ROWID) once. Repeated join
rows do not increase counts. No GUID, timestamp, sender or text heuristic merges
separate source rows. These coordinates preserve the same source identity used
by history; public history IDs and chat GUIDs remain unchanged. Body decoding
failure does not erase a classified message from activity.

A retraction that changes a continued aggregate returns
`activity_changed_restart_required`; a fresh request excludes the retracted row.

## Active-session incoming watch

`watch_messages` accepts required exact `chatID`, optional opaque `cursor`,
`waitSeconds` (integer 0–20, default 20), and `limit` (1–100, default 50).
The wait budget uses a monotonic clock and stays below the 60-second MCP client
request timeout with margin. Zero performs one bounded query and can establish
an initial cursor. Without a cursor, the call starts after the current highest
`chat_message_join.ROWID`; it does not return existing history. Establish a cursor
with zero wait before a wait whose response might be lost.

The result contains `status` (`messages` or `no_match`), a required `cursor`, and
`page` with the existing enriched read result fields (without a history cursor).
Incoming ordinary rows and typed events both qualify; outgoing rows do not.
Each collection follows ascending association ROWID, independent of message
dates; interleaving between messages and events is not encoded. The exclusive
cursor advances over their combined arrival stream. At most
`limit` associations are decoded/returned. Polls inspect at most 256 association
rows and suspend between batches. `scannedAssociationCount` counts the consumed
incoming associations in the selected chat; unrelated polling rows are not
decoded. `no_match` means no matching association was
consumed before this call's budget expired, not proof that no backlog exists.
Continue with the returned cursor to inspect remaining arrivals.

The cursor is caller-owned, exclusive, reusable and bound to this exact chat and
MessageStore connection. No global acknowledged position exists. Replaying an
input cursor can replay previously returned records; consumers deduplicate by
message/chat identity. Use the returned cursor only after consuming the response.
There is no durable cursor/snapshot/receipt store. Restart rejects old cursors.
Database replacement uses the existing opened-file check. A cursor retains one
association anchor (ROWID, message row, chat row, message GUID, chat GUID); a
missing/changed anchor fails with `watch_position_invalidated`. Reorganization
outside that anchor is not exhaustively detected. RowID reuse that recreates the
same anchor, insertion at/below the consumed position, changes to older rows,
edits, deletions, provider flags settling, and attachments arriving later are
not observable guarantees. This is append/new-association watching, not a change
log. It requires a rowid join table and referenced message/chat rows to exist when
an association becomes visible. A dangling association fails explicitly with
`watch_position_invalidated`; it is not silently consumed.

Watching association insertion rather than message insertion preserves a message
whose `chat_message_join` appears later, even after newer message rows were
consumed. Polling has no notification-registration gap: every next query resumes
from the last consumed association. No full-history body decoding occurs. Pending
waits release the operation actor; cancellation/disconnect ends their work. This
tool runs only for an active request. It does not wake idle clients, create user
instructions, schedule automation, or keep a daemon running.
