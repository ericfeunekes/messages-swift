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
    Directory --> Contacts[Selected Google Contacts account adapter]
    Directory --> State[Contact cache and saved aliases]
    Directory --> DB[Messages database: read only]
    History --> DB
    Images --> Files[Local message attachments]
    Send --> Scripting[Messages public scripting surface]
```

One local executable can host MCP for the client session. It does not require a system service or a network listener. A CLI, if added, calls the same operations in-process and does not introduce a second cache or query implementation. The core has no MCP, terminal-output or approval-dialog dependency.

Use the official Swift MCP SDK for the adapter after verifying compatible pinned versions. Tool descriptions and schemas should be compact and explicit. Deferred tool discovery is client-dependent and is a validation question, not a reason to assume every schema is always in context.

## Conversation directory

The directory joins chat records with names from the selected Google Contacts account and local thread aliases before returning results. Google Contacts is the intended authority; macOS Contacts is a possible access layer when it faithfully exposes that account, not an additional authority. The proposed display-label order is saved alias, native thread name, then participant names; native name and participants remain visible alongside the label.

Person lookup expands contact handles; conversation lookup matches membership. A request for a conversation with a person must include the other participants' messages, not only rows sent by that person. Missing and ambiguous names are distinct results.

Keep aliases as durable user-owned records associated with stable chat identity. Contact information and frequent-contact rankings are disposable cache data. Cache refresh must not delete aliases or undo a just-written alias. A missing chat must not cause its alias to bind silently to another thread.

A small local SQLite store is the proposed persistence mechanism. Its installation path, cache ranking and invalidation contract are resolved in [open decisions](decisions.md). Keep runtime state outside the repository. Do not inject the complete directory into each model prompt; return the relevant enriched records.

Cache data supports discovery and display. Resolve the current destination and participants before presenting a send preview. A cached label alone is not a write destination.

The smaller local access candidate uses a user-confirmed Google-backed Contacts container with non-unified fetches and device-local contact IDs. The public container API does not prove the Google login behind a display label, so selection is an explicit setup action. Cache refresh then reads the Mac’s synchronized values; it does not force an upstream Google sync. This is acceptable only if the owner accepts ordinary sync freshness. Google server IDs are not necessary for this local cache. A missing container requires reselection rather than silent rebinding. Source-isolation and lookup performance remain untested.

## Message integration and upstream reuse

Open Apple's Messages database read-only. Resolve contact names from the selected Google Contacts account, either through correctly scoped macOS synchronization or a direct Google adapter; that access choice remains open. Use the public Messages scripting surface for supported sends. Initial OS permission setup is separate from the conversational approval policy in [requirements](requirements.md#reading-drafting-and-sending).

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

The people cache uses FIFO eviction and refreshes records daily or on use, whichever is sooner. Refresh and eviction order are separate: an existing record's refresh does not move it to the back of the queue under the proposed interpretation. Keep user aliases immediately consistent and independent of cache refresh/eviction. A process may retain hot lookups while connected to MCP, but persistence must also work across process restarts. Daily refresh while active and overdue refresh at startup avoid requiring a separate daemon.
