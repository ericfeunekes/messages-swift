# Validation

The requirements define intended behavior. This document defines what would prove it. Preparatory experiments have exercised selected boundaries; they do not validate a production implementation.

## Preparatory evidence: September 8, 2026

A synthetic native Swift stdio fixture built on Intel using the official Swift MCP SDK 0.12.1 at `a0ae212ebf6eab5f754c3129608bc5557637e605`. An independent official Python MCP 1.26.0 client negotiated protocol 2025-11-25 and passed 12 checks covering initialization, tool/schema listing, runtime argument errors, structured success/domain errors, PNG bytes and inert write-shaped argument echoes. Deliberately changing the returned message caused an assertion failure; restoring it passed. No real Messages operation occurred.

This proves local protocol transport, not desktop discovery, image rendering or conversational approval. A separate installed Codex app-server probe failed before initialization while waiting for an existing state backfill. Desktop registration and a fixture-enabled task remain necessary proof boundaries. The inert fixture’s closed-world hints must not be copied to a production send, which has external effects.

A metadata-only public Contacts Swift probe also ran on Intel. Existing Contacts permission was undetermined, so it exited without fetching contacts or changing permission. Public API research supports selected-container and non-unified fetches; live account isolation, freshness and lookup cost remain unproven.

The pinned public IMsgCore built on Intel Swift 6.1.2. The unmodified selected test suite failed compilation when the compiler timed out on a concatenated byte-array expression. Splitting that expression into equivalent typed appends preserved its bytes and assertions; 76 selected synthetic tests then passed. This is not a pristine upstream-suite pass.

A real SQLite probe with 100,000 synthetic rows passed descending-pagination checks for equal timestamps, an insertion fence including backdated arrivals, half-open dates, pre-limit filters and conversation-membership versus sender semantics. Its warm SQL-only p95 was 1.36 ms; that excludes Swift decoding and name enrichment and is not the complete history-operation latency.

The public-core release search returned correct rare and absent results on a 100,000-message, approximately 36 MiB on-disk fixture with 50% attributed-only bodies. In the measured repeat, each search took 11.91–12.04 seconds, failing the proposed five-second budget. Whole-process peak RSS was 44.02 MiB, including fixture setup and six searches; no isolated allocation or cold-disk claim is made. The single-pass follow-up preserved the fixture, decoder, candidate predicates, coalescing checkpoints and result assertions. All 77 selected tests passed, including a scan-count check that failed the original implementation and passed the change. Search took 5.8689–5.9038 seconds, approximately half the baseline, with whole-process peak RSS 43.82 MiB. The proposed five-second bound remains unmet. No index or scope reduction was used. Stable synthetic results are proven; concurrent-writer snapshot behavior and unindexed/common-match performance remain unproven.

## Search profiling and matching-policy experiment

Continued profiling separated the remaining costs. Instrumented matching time was approximately 4.75–5.18 seconds; row decoding was 0.79–0.88 seconds, including only 0.069–0.076 seconds in the attributed-body parser. SQLite iteration time included its text-matching callback, so these intervals overlap and must not be summed. An independent CPU sample placed the dominant stacks in case-insensitive String.range and string/Character transformation. Native unarchiving occurs during fixture generation, not runtime search.

One streaming scan plus text-first matching and shared text resolution reduced the unchanged workload to 5.315–5.446 seconds. All 79 selected tests passed, including a test that detected and removed duplicate audio-transcript queries. This retained the existing matching behavior but still missed the proposed five-second target.

A separate native NSString matcher experiment exposed a contract distinction. On the tested Mac, the old String.range path matched st for a query of ß inside İstanbul; an isolated probe printed the scalars, actual substring and range. Native search rejected that result. Other differences concerned matches inside combined characters, which are a separate policy issue. This is not evidence about OpenAI's implementation or all Foundation versions.

The preferred policy proposal combines native case-insensitive/canonical search with whole Swift Character boundaries. It continues after a rejected partial match, uses one boundary pass plus a set and forward-only position, and retains the existing exact-comparison mode. All 80 selected tests passed. Deliberately stopping at the first rejected partial match failed three later-valid cases; restoring continuation passed. Independent review found no material objection after replacing repeated linear boundary lookups. This is an explicit proposed matching contract, not bug-for-bug equivalence to the old path.

| Frozen 100,000-message workload | Time per rare/no-match search |
|---|---:|
| Original public-core implementation | 11.91–12.04 s |
| One streaming scan | 5.87–5.90 s |
| Shared text-first resolution, existing matcher | 5.315–5.446 s |
| Native matcher with whole-Character policy | 1.098–1.138 s |

The final policy experiment used the same evaluator, fixture, queries, indexes and assertions, with 50% attributed-only bodies. Whole-process peak RSS was 43.84 MiB, including setup and six searches. No persistent text index or cache was introduced. The performance proposal passes for this policy on the controlled warm workload; the strict old-behavior path does not. These samples are not a p95 or real-history benchmark.

Separate probes found common-match limit-50 searches in roughly 2–4 ms with the ordering index and 0.3–0.5 seconds without it on the text-first implementation. A reject-heavy final-matcher probe scaled from approximately 2.3 ms at 1,000 graphemes to 39.8 ms at 16,000. These do not replace the frozen evaluator or establish a universal worst-case bound. A WAL probe confirmed that an active read statement and its nested read see a consistent pre-commit snapshot until the statement ends; long-reader WAL retention and live contention remain unmeasured.

The source adaptation and policy tests remain preparatory artifacts. The owner has accepted the matching policy recorded in [decisions](decisions.md#search-matching-policy). Production adoption still requires implementation, integration tests and the remaining live boundaries. The underlying baseline still needs the separately specified explicit decoding-failure model.

## Source and fixture policy

Reuse suitable public Swift parser, schema, Contacts and attachment fixtures with their licenses and expected outcomes intact. Fixture tests should exercise real SQLite queries and decoding; mocks are reserved for controlled variations or failures. Do not commit real conversations, contact directories, attachment files or user aliases.

The reviewed imsg tests cover attributed bodies, unread selection, schema variation, attachment handling, Contacts resolution and forward-cursor edge cases. They are useful starting points, not proof of this project's distinct contract or its live Mac integration.

## Required evidence

| Boundary | Proof |
|---|---|
| Swift and dependencies | Build on x86_64; verify selected dependency and deployment-target compatibility |
| MCP adapter | Real initialize, tool listing and read invocation in the intended client; schema/result handling and image presentation |
| Conversation directory | Selected Google account scoping, source identity through the chosen adapter, duplicate names, linked contact handles, unnamed and named groups, stable aliases, exact membership and sender-versus-membership distinctions |
| Cache and aliases | Cold/warm lookup, restart persistence, FIFO eviction distinct from refresh order, daily/on-use refresh, alias preservation and immediate alias updates, missing contacts and permission changes |
| Message query | Real SQLite fixtures; filters applied before limits; equal timestamps; arrivals during descending continuation; database replacement |
| Decoding | Known attributed bodies, Unicode/emoji/multiline text, attachment-only messages, explicit decoding failures and the agreed reaction/edit/preview model |
| Activity | Consistent counts with history, partial-day bounds, daylight-saving transitions, Monday weeks, empty buckets and stable continuation bounds |
| Images and files | Attachment identity tied to message results; missing files; supported image decoding; no arbitrary-path read through the image operation |
| Agent/client policy | Draft causes no send; approved preview invokes the intended write; changed content needs a new preview; client rejection causes no write |
| Send integration | Direct and existing-group destinations, new direct recipients, text/files, partial outcomes and uncertain completion; no automatic retry or service switching |
| Performance | Cold/warm timings and peak memory, including rare-term/no-match decoded-body search at representative scale |

Test core behavior independently of MCP, then test adapter wiring separately. If a diagnostic CLI is added, test real argument parsing, JSON output, stderr and exit statuses rather than duplicating the core tests.

## Live Mac checks

Use a clearly chosen small conversation scope for a read, a Contacts lookup and an image. For sending, obtain approval of the exact test recipient, text and files before executing. An approved, locally accepted write and delivery are different observations; report only what the chosen boundary establishes.

New-group creation needs its own public-API proof if included in the release. Existing group sends and single new-recipient sends do not prove it. Do not enable injected/private operations to make the test pass.

## Completion reporting

Record what was run, the authoritative outcome, and any untested boundaries. Source review, available schemas and a successful launch are not substitutes for the behavior being claimed. Do not add production receipt tables or repeated readbacks to compensate for missing tests.

Build and synthetic integration commands are below. Live setup remains a separate authorized validation boundary.

## Implementation commands

From the repository root with Swift 6.1 or later:

```sh
swift build --product messages-mcp
swift test
swift build --product MCPTestServer
uv venv .scratch/protocol-venv
uv pip install --python .scratch/protocol-venv/bin/python 'mcp==1.26.0'
.scratch/protocol-venv/bin/python Tests/Protocol/client_test.py
```

For environments where compiler caches must remain in the checkout:

```sh
mkdir -p .scratch/tmp .scratch/cache
TMPDIR="$PWD/.scratch/tmp" CLANG_MODULE_CACHE_PATH="$PWD/.scratch/cache/clang" \
  swift test --disable-sandbox --cache-path "$PWD/.scratch/cache/swiftpm" -j 2
```

`--disable-sandbox` disables SwiftPM's build subprocess sandbox, not macOS privacy
controls. Network access is needed for the pinned public dependencies on a fresh
checkout. The implementation run used the existing preparatory Python MCP 1.26.0
virtual environment instead of reinstalling it. The protocol script creates only
synthetic SQLite and state files under `.scratch/`.

The retained suite exercises real SQLite queries, exact-nanosecond continuation
through the terminal page, new backdated arrivals, changed filters/query,
replacement database rejection, half-open dates, unread selection, participant
handle alternatives and exact membership. Shared-operation tests exercise names
before limits, duplicate-name candidates, GUID aliases, group-aware 90-day cache
population, on-use refresh and selected-identity warm reads. Local-state tests
exercise actual atomic files, FIFO order, restart, write failures and permissions.
Parser tests include native NSArchiver fixtures, Unicode policy and malformed
bodies. The independent Python client exercises the actual Swift stdio adapter,
including typedstream bodies, structured results, alias restart and input errors.

The native Intel implementation and synthetic integration are exercised; they do
not establish real Messages schema compatibility, private Contacts permission or
selected-account isolation, Mac synchronization latency, desktop discovery,
rendering, client approval, or send behavior. The declared macOS 14 deployment
floor has not been run on macOS 14; Apple Silicon is untested. The frozen 100,000-row
preparatory benchmark was not changed or rerun as a production performance claim.
Integrated production latency and live WAL contention remain unmeasured.

The response preserves source row kinds and independent edited/retracted state;
activity normalization remains an explicit decision in [decisions](decisions.md).
Sending (direct and existing group, text/files with partial/uncertain outcomes),
activity buckets/counts and message-bound image access remain first-release work.
No placeholder operation claims success for those capabilities.

### Initial implementation result: September 8, 2026, commit 582be93

Apple Swift 6.1.2 on x86_64 macOS 26.6.2 built both native executables. The final
suite passed 34 XCTest cases and 11 Swift Testing tests. The independent Python
MCP 1.26.0 client passed 12 checks. Deliberately relaxing the arrival fence caused
three continuation failures; restoring it passed the full suite. The documentation
graph found no broken local links. These are synthetic implementation results,
with the live and performance limits above unchanged.

## Integration-review corrections

The correction suite adds composite message/chat association pagination through
terminal pages, exact error assertions, 10,000 failed-body diagnostics with bounded
examples, sparse mixed histories, persistent-connection replacement during a read,
concurrent pathname exchange and normal WAL append visibility. A 10,000-unrelated-chat
fixture measures SQLite instruction work for exact retrieval; it makes no latency
claim. Busy-group fixtures distinguish actual authors from passive members.

Controlled Contacts adapter tests inspect the exact identifier-plus-matching-field
requests, non-unified fetches, candidate-container checks before named person
fetches, foreign/missing IDs,
selected duplicate owners and approximate phone candidates. Actual indexed native
Contacts behavior remains a live permission/isolation/completeness gate. Production
runtime tests exercise the same composition as main with real SQLite/state and an
injected source/clock/runner; they cover configuration, cold/overdue startup,
scheduling, failure, cancellation and actual executable error sanitization.

On the tested Mac, replacement during an open read produced SQLite's extended
IOERR_VNODE (6922) from HAS_MOVED instead of a successful moved flag. This is a
failed opened-file check, not evidence that the pathname is unchanged. Apple
describes vnode errors after direct invalidating database-file operations in its
[Core Data session](https://devstreaming-cdn.apple.com/videos/wwdc/2016/242vdhuk4hmwrxnb465/242/242_whats_new_in_core_data.pdf?dl=1).

Final run logs and independent review returns are retained separately by commit
under ignored revision evidence directories; earlier mutable logs are not relabeled
as current-commit approvals. Full source/test changes are frozen before each final
run and review. The live setup, multi-process and remaining release limits above
continue to apply.

## Menu-bar app and local bridge

The menu-bar app owns the native permission and shared state lifetime. Synthetic
socket tests exercise actual MCP initialization from two clients, shared aliases,
independent request IDs, fragmented/oversized input, backpressure, half-close,
shutdown, private path checks, stale endpoints and rejected duplicate ownership.
Completed sessions release during the listener lifetime. Cancellation of a partial
response closes that connection so a later frame cannot append to unfinished JSON.

The integrated run passed 51 XCTest and 29 Swift Testing tests. An independent
Python MCP 1.26.0 client passed the existing 15 protocol checks. Four additional
bridge subprocess checks cover a 1 MiB request/2 MiB response with partial writes,
app EOF while stdin remains open, closed-peer writes without SIGPIPE termination,
and rejection of regular-file and real-socket symlink endpoints. Run them with:

```sh
swift build --product MCPBridgeTestClient
.scratch/protocol-venv/bin/python Tests/Protocol/bridge_test.py
```

The bridge test also accepts `MESSAGES_BRIDGE_TEST_BINARY` for isolated mutation
runs. This is test-runner configuration, not a production fixture mode. Removing
the relay's socket-EOF exit caused a bounded timeout. Relaxing the inbound frame
limit failed its oversized-frame test. Disabling completed-session reaping failed
100 weak-reference release assertions. Restored production source passed.

A read-only native core smoke test on one recent real conversation read two pages
of ten rows, found no overlapping message identities, reported no first-page
decoding failures and found a sampled decoded-text query. Aggregate elapsed time
was 0.284 seconds; no message content or identifiers were logged. This is a narrow
core observation, not a production latency benchmark or Contacts/MCP proof.

A separately launched, locally signed AppKit setup probe received user-granted
Contacts access and listed container metadata through the public API. Direct
Codex-child requests were denied because macOS attributed them to Codex's identity.
The successful probe establishes the app-owned consent direction. The installed
production app has a different identity and requires its own live Contacts and
Messages access checks, selected-container confirmation and client discovery.
The locally rebuilt ad-hoc signed app has requested Contacts consent again after an update; grant persistence must not be assumed. Sending,
counts and image access remain outside this foundation installation.

## Permission setup controller

The permission tests import the actual menu app and construct its AppKit settings
window and controls. Injected async permission requests resume from a detached
task; granted, denied and error outcomes have distinct UI assertions, including
retry after error. Repeated setup clicks produce one pending request. Launch,
Check Again and app activation exercise window reuse, visible status updates,
configured/default database-path routing and absence of repeated prompts or
settings launches. Saved source and custom paths survive refresh and failed
source enumeration. Real temporary-file checks include readable, missing,
directory and chmod-000 denial cases; controlled errno values cover classification.
Suppressing first-launch setup presentation made its owning test fail, then the
source was restored. These tests do not automate macOS consent or substitute for
live grants under the installed app identity.

The installed unified setup window was captured and inspected on the target Mac.
Contacts and Messages access status, setup/settings actions, source controls and
Check Again were visible without clipping. At that check the rebuilt app reported
Contacts not requested and Messages access denied; real consent and the final
end-to-end read remained pending user action. The synthetic suite passed 51 XCTest
and 37 Swift Testing tests.

A live warm read exposed CNErrorDomain code 2 with a property-not-fetched exception
in the native Contacts predicate path. Candidate phone/email fetches now request
the matching field as well as the identifier. Seven focused adapter tests passed,
including a provider that rejects missing predicate fields, exact key sets and
selected-container exclusion. A subsequent installed-app check passed the native warm-read path: one named
participant was bound to the selected Contacts container, ten message rows had
zero decoding failures, and decoded-text search found its sampled message. Two
simultaneous MCP clients shared the app connection/cursor successfully, and the
first remained usable after the second exited. The read-only check took 1.959
seconds overall; private payloads were not logged.

The installed app was then signed with an existing certificate identity from the
user login keychain. Its designated requirement names the app identifier, Apple
certificate chain and certificate subject rather than a per-build code hash.
The installer reads the saved local certificate choice for future updates.
