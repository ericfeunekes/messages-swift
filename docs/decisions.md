# Open decisions

This is the register of unresolved requirements and design choices. It separates choices for the project owner from questions that source inspection or a prototype can answer. A proposal remains a proposal until accepted; dependent implementation should not silently settle it.

## Repository and license

- **Repository:** `messages-swift`.
- **Owner and visibility:** personal GitHub account `ericfeunekes`, public; authorized.
- **License:** MIT; selected by the owner. Reused third-party components retain their own applicable notices.

## Initial release scope

- **First release:** reading and sending together; selected by the owner.
- **New groups:** existing groups first; selected by the owner. Creation of new groups is outside the first release. New direct recipients and existing-group sending have distinct paths and must not be classified together.
- **Files:** text and local attachments are part of the intended send operation. Text precedes files in input order as separate commands, stopping at the first failure or unknown outcome. The local [send schema](schemas.md#sending) reports each part and never claims atomicity or delivery. File changes across commands stop remaining dispatch. Files are copied into private Messages-readable staging before any command; accepted/uncertain inputs are retained for asynchronous consumption, without an unproven expiry timer.

## Directory and cache

- **Contact authority:** Google Contacts associated with the user’s Gmail account; selected by the owner. The account identifier belongs in private setup, not public documentation.
- **Contact access:** use a user-selected Google-backed macOS Contacts container and existing Google-to-Mac synchronization; accepted by the owner. Fetch non-unified records from that container and do not infer account ownership from its display label. Do not build a direct Google API/OAuth connection. Google server-side IDs are unnecessary for this disposable single-Mac cache. Warm lookup requests non-unified identifiers plus the phone/email field required by the native matching predicate. It discards those transient matching values and validates the selected container before fetching named person details for results/cache. Unique exact phone owners retain joined names; approximate-only and shared owners remain explicitly unresolved. Actual native candidate completeness, container isolation, permissions and lookup costs remain integration checks. Contact cleanup/migration remains separate.

- **People cache:** approximately 100 entries with FIFO eviction; selected by the owner. The accepted initial directory baseline uses frequent contacts over 90 days: direct counterparts receive sent/received credit, and group rows credit the actual incoming author rather than passive members. After population, newly used people enter the cache and the earliest-added entry is evicted when full. Accepted interpretation: refreshing an existing record does not reset its FIFO position.
- **Freshness:** refresh daily or when a contact is used by an operation such as read or send, whichever is sooner; selected by the owner. The menu-bar app owns daily scheduling while active and overdue refresh on startup. No separate background service or login-start registration is required.
- **Aliases:** local to this Mac; selected by the owner. They are durable independently of the people cache and do not rename Messages threads. Normalized collisions return the conflicting conversation IDs; replacing an alias affects only its exact conversation.
- **Storage location:** choose one conventional macOS application-support location outside the checkout, separating durable aliases from replaceable contact cache data. The implementation uses Application Support/messages-swift, separate atomic JSON documents, a 0700 new directory and 0600 state files; see architecture.

## Platform and runtime

- **App ownership:** the owner accepts a small native menu-bar app for permissions, selected Contacts container, connection status and quit. The app owns one shared operation layer and cache across client sessions. Codex uses a thin stdio bridge to the app over user-local IPC. The existing read/search/alias MCP contract remains unchanged. No direct Google connection, auto-login service or additional release capabilities are added by this decision.

- **Platform floor:** proposed macOS 14+, reflecting the reviewed public Swift core, with Intel as the first tested architecture. Older Intel macOS support and Apple Silicon release coverage are not yet commitments.
- **Dependency:** the public IMsgCore builds on Intel, but its unchanged public API cannot express the required descending continuation, membership filtering, explicit decoding failures and arbitrary-range counts. Source seams are internal. A narrow maintained read/query adaptation is the supported recommendation; exact packaging and API contracts remain implementation decisions.
- **MCP integration:** a native Intel Swift fixture passed independent protocol tests; see [validation](validation.md#preparatory-evidence-september-8-2026). Actual desktop discovery, image rendering and normal agent/client approval remain open. A separate app-server probe was blocked before initialization; this does not establish a Messages or MCP product failure.

## Message interpretation

History/search retain ordinary and attachment-only rows as messages and separate reaction, preview and unknown rows as typed events. Missing classification columns mean unknown. Edited/retracted markers are orthogonal source state. No heuristic preview coalescing or original-text reconstruction occurs. The exact response is in [schemas](schemas.md).

Activity uses the shared source classifier: ordinary and attachment-only user messages count once, edited rows keep their original source date, and reactions, previews and unknown/system rows do not count. Source-marked retracted/unsent messages are excluded; accepted under the owner's explicit authorization to settle remaining details. History retains these rows with their retraction marker. Physical page length is not activity. Overall totals deduplicate source message rows across selected chats; per-chat totals retain each distinct source message/chat association.

Calendar timezone defaults to the Mac's current zone at the initial request and remains fixed through continuation. Weeks start Monday. Ranking compares whole-range conversation totals and retains each chat's chronological bucket series, including zeros. Explicit activity timestamps accept at most microsecond precision within the documented native Date range. Source and cursor bounds remain integer nanoseconds. An aggregate-result digest rejects mutations that would invalidate rank/offset continuation; it stores no bodies or historical snapshot. See [schemas](schemas.md#activity).

Incoming image/file retrieval follows the [local attachment contract](schemas.md#incoming-attachment-retrieval); real client viewing and file consumption remain live validation gates.

## Search matching policy

The owner requested continued decoded-search diagnosis. Profiling found that matching dominated decoding. Preserving the existing matcher reaches approximately 5.3–5.4 seconds on the fixed workload; a native matcher with whole Swift Character boundaries reaches approximately 1.1 seconds and fixes an isolated false match. See [validation](validation.md#search-profiling-and-matching-policy-experiment).

Accepted contract: case-insensitive, canonically equivalent substring matching that begins and ends at whole Swift Character boundaries. Combined letters and emoji are not split, and a rejected partial match must not prevent finding a later valid one. Exact mode remains full-string comparison. The owner accepted this faster matching rule. Preserve its tests when implementing; do not reproduce the demonstrated false match from the old Foundation path.

## Performance

Proposed initial targets on the Intel reference machine:

- warm directory lookup: p95 below 100 ms;
- one filtered history page: p95 below 500 ms;
- no-match decoded-body search over a controlled 100,000-message fixture: below 5 seconds.

The continued investigation supersedes the earlier six-second/indexing tradeoff. The preferred matching-policy prototype completes the unchanged controlled workload in 1.098–1.138 seconds without an index and passes the proposed five-second bound under that explicit policy. The old-matcher-preserving path remains above five seconds. The owner accepted the tested matching rule and the no-index approach. Measure representative integrated usage before making production-performance claims. See [validation](validation.md#search-profiling-and-matching-policy-experiment) for the prototype evidence and its limits.

## Requirements completion

Requirements are ready for the first implementation slice when its scope, relevant owner choices, typed operation contract and proof are explicit. Unresolved later capabilities can stay open without blocking independent work. A full release claim requires the applicable evidence in [validation](validation.md), not just agreement on this register.
