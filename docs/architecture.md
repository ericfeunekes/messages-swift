# Architecture

## Shared Swift operations

The primary agent interface is stdio MCP over a native Swift operation layer. The layer owns contact joins, conversation identity, aliases, queries, decoding, state and sending. Transport adapters parse and validate their input, invoke typed operations and present results.

```mermaid
flowchart TD
    MCP[Stdio MCP adapter] --> Operations[Typed Swift operations]
    CLI[Optional diagnostic CLI] --> Operations
    Operations --> Directory[Conversation directory]
    Operations --> History[Message queries and decoding]
    Operations --> Send[Messages send integration]
    Operations --> Images[Native image reader]
    Directory --> Contacts[Selected macOS Contacts container]
    Directory --> State[Contact cache and saved aliases]
    Directory --> DB[Messages database: read only]
    History --> DB
    Images --> Files[Local message attachments]
    Send --> Scripting[Messages public scripting surface]
```

One local executable can host MCP for the client session. It does not require a system service or a network listener. A CLI, if added, calls the same operations in-process and does not introduce a second cache or query implementation. The core has no MCP, terminal-output or approval-dialog dependency.

Use the official Swift MCP SDK for the adapter after verifying compatible pinned versions. Tool descriptions and schemas should be compact and explicit. Deferred tool discovery is client-dependent and is a validation question, not a reason to assume every schema is always in context.

## Conversation directory

The directory joins chat records with names from the selected Google Contacts account and local thread aliases before returning results. Google Contacts is the upstream authority; its user-selected macOS Contacts container is the accepted access layer, using normal system synchronization. The display-label order is saved alias, native thread name, then participant names; native name and participants remain visible alongside the label.

Person lookup expands contact handles; conversation lookup matches membership. A request for a conversation with a person must include the other participants' messages, not only rows sent by that person. Missing and ambiguous names are distinct results.

Keep aliases as durable user-owned records associated with stable chat identity. Contact information and frequent-contact rankings are disposable cache data. Cache refresh must not delete aliases or undo a just-written alias. A missing chat must not cause its alias to bind silently to another thread.

Two atomic JSON files hold local state: contacts.json contains the disposable FIFO cache, and aliases.json contains GUID-keyed user aliases. Their versioned schemas and private path are described below. Keep runtime state outside the repository. Do not inject the complete directory into each model prompt; return the relevant enriched records.

Cache data supports discovery and display. Resolve the current destination and participants before presenting a send preview. A cached label alone is not a write destination.

Use a user-confirmed Google-backed Contacts container with non-unified fetches and device-local contact IDs. The public container API does not prove the Google login behind a display label, so selection is an explicit setup action. Cache refresh reads the Mac’s synchronized values; it does not force an upstream Google sync. The owner accepts ordinary sync freshness. Google server IDs and a direct Google connection are not needed. A missing container requires reselection rather than silent rebinding. Source-isolation and lookup performance remain integration checks.

## Message integration and upstream reuse

Open Apple's Messages database read-only. Resolve contact names through the selected Google-backed macOS Contacts container and existing synchronization. No direct Google adapter or OAuth setup is part of this implementation. Use the public Messages scripting surface for supported sends. Initial OS permission setup is separate from the conversational approval policy in [requirements](requirements.md#reading-drafting-and-sending).

The reviewed imsg source exposes an in-process `IMsgCore` library and x86_64 builds. Its decoding, schema and attachment code and tests are useful references. Reuse only the needed public components; do not enable its injected helper or private-framework operations.

The following differences require implementation work rather than a cosmetic adapter:

- imsg's forward ROWID catch-up cursor is not backward, newest-first history continuation.
- Its history participant filter matches senders, not a conversation's participant set.
- Its daily statistics do not supply arbitrary partial-day range counts or the full ranked calendar-bucket contract.
- Enriched name resolution, saved aliases and the bounded frequent-contact cache are this project's operation layer.
- Attachment paths and metadata still need MCP image presentation and clear multiple-file send outcomes.

The preparatory build and query probe support a narrow maintained adaptation of the public read/query/decoding code: required connection and decoder seams are internal, so an external wrapper cannot supply the complete contract unchanged. Keep the adaptation small and omit unneeded CLI/private-helper code. Do not fetch complete history through a public API merely to emulate missing filters or continuation. Preserve applicable upstream license notices and test expectations.

## Approval ownership

Agent guidance implements draft-versus-send intent and the exact-preview policy. The client approves the invocation. The core checks destination and file arguments and reports the send result honestly. This project does not copy OpenAI's private read/send permission stores or invent a model-set confirmation flag as evidence of consent.

Verify the normal host flow with an inert operation before enabling real sends. If the client's behavior differs from the intended flow, record the observed gap rather than adding a second approval system without a decision.

## Simplicity and performance

The tested search direction is one streaming scan, shared searchable-text resolution before full record construction, and native Foundation matching under an explicit whole-Character policy. Profiling identified case-insensitive matching as the dominant remaining cost; attributed-body parsing was a small fraction. The preferred policy prototype completes the controlled 100,000-message workload in about 1.1 seconds without a persistent body index. It corrects a reproduced false match in the old path and is not certified bug-for-bug equivalent. The [matching-policy decision](decisions.md#search-matching-policy) remains explicit; [validation](validation.md#search-profiling-and-matching-policy-experiment) records tests, timings and limits. Production code still needs the shared message model, source integration and live verification.

The people cache uses FIFO eviction and refreshes records daily or on use, whichever is sooner. Refresh and eviction order are separate: an existing record's refresh does not move it to the back of the queue under the accepted interpretation. Keep user aliases immediately consistent and independent of cache refresh/eviction. A process may retain hot lookups while connected to MCP, but persistence must also work across process restarts. Daily refresh while active and overdue refresh at startup avoid requiring a separate daemon.

## Runtime setup

The package has a shared `MessagesCore` library, a thin `MessagesMCPAdapter`, and
one `messages-mcp` executable. It links the system SQLite library and the pinned
official Swift MCP SDK 0.12.1. `MCPTestServer` is a separate synthetic test target;
production has no fixture flag, send stub or private helper.

Create a private JSON configuration outside the repository:

```json
{
  "containerID": "USER-CONFIRMED-DEVICE-LOCAL-CONTAINER-ID"
}
```

The selected container must already be synchronized with the intended Google
account and explicitly confirmed by the user. A container display name does not
prove account ownership. This executable checks existing Contacts authorization;
it does not request it or change account, sync or security settings. Authorizing
the final executable/host and obtaining the selected container ID are live setup
steps still requiring validation. Do not put actual IDs in public configuration.

Optional absolute `databasePath` and `stateDirectory` values override
`~/Library/Messages/chat.db` and `~/Library/Application Support/messages-swift`.
Unknown keys and relative paths are rejected. Run:

```sh
.build/debug/messages-mcp --config /absolute/path/to/private-config.json
```

Stdout carries MCP only. Startup errors and background-refresh failures use
sanitized stderr messages. The MCP [operation schemas](schemas.md) own the wire
contract. Reads never open the Messages database for writing.

`contacts.json` is version 1 with `containerID`, `isSeeded` and FIFO `entries`;
each entry carries `person` (source identity, display name, handles), `admittedAt`
and `refreshedAt`. `aliases.json` is version 1 with a `chat.guid`-to-name map.
Internal dates use Foundation's Codable reference-date seconds. Cache replacement
or source reselection does not replace the alias file. Unsupported versions and
malformed state fail rather than being silently reset. New state directories use
0700 and state files 0600. Use one active server per state directory; concurrent
process writers are not supported by this slice.

First population ranks the selected source's people over the preceding 90 days.
A one-member conversation credits its counterpart for sent and received source
rows. A multi-member conversation credits only the actual incoming author;
outgoing group rows give no passive member credit. Repeated associations to the
same person credit a source row once. This cache-baseline rule does not settle the
later logical activity-count normalizer. Current membership cardinality is used;
no display-name/routing-string guess distinguishes a residual one-member group.
Later admission evicts the earliest entry at 100 people; refresh preserves order.

Operations batch used-contact writes. Exact reads and alias lookup query an exact
chat GUID; search enriches only returned/diagnostic-example chat GUIDs. Name
discovery may inspect all candidates. Participant and unread joins are batched
rather than fetched once per unrelated chat.

Warm contact reads use non-unified identifier/email/phone predicates to obtain
minimal candidate IDs from the local Contacts index. Each candidate's container
is checked against the explicit binding before fetching names/handles. Foreign
records are neither materialized, cached nor returned. All selected candidates
are retained, including uncached shared-handle owners. Phone matching is documented
best effort; the response exposes unresolved handles and candidate people rather
than asserting unique ownership from approximate hits. This avoids application
full-container enumeration in the warm candidate path, but does not prove native
index performance or complete phone-normalization equivalence. Full name discovery
still enumerates the selected container. The API sequence is not an atomic Contacts
snapshot; linked/removed IDs and native matching require the live proof gate.

On startup and once per minute while active, the server checks for contacts from
an earlier local calendar day and refreshes them. Every use refreshes the selected
contact's synchronized values even within the same day. Failed refreshes do not
mark records fresh. The process owns this schedule; there is no daemon.

`ApplicationRuntime` is the production composition used by `main`: it constructs
the real SQLite store and local state, refreshes on startup, and owns cancellation
of the periodic refresh task when MCP exits. Tests supply a clock, selected-source
adapter and runner at this same dependency boundary; production has no test flags.

A MessageStore owns one lazy, persistent read-only SQLite connection and serializes
its per-call read transactions. Cursors carry that connection's instance identity,
exact source nanoseconds, message and chat row coordinates, immutable filters and
an arrival fence. There is no stat-before-open identity claim and no reopen by
pathname. SQLite's HAS_MOVED result is checked before/after each read; errors fail
closed. Normal WAL access keeps the original SQLite pathname. A new store/server
rejects old cursors, even if pointed at the same file; GUID aliases remain durable.
This is append-stable continuation, not a historical snapshot through edits,
deletions or membership changes.
