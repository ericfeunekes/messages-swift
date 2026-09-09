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
| Route preflight | Read-only enabled-account list, direct/group classification, historical hints, no-history options, and frozen explicit service before dispatch |
| Performance | Cold/warm timings and peak memory, including rare-term/no-match decoded-body search at representative scale |

Test core behavior independently of MCP, then test adapter wiring separately. If a diagnostic CLI is added, test real argument parsing, JSON output, stderr and exit statuses rather than duplicating the core tests.

## Live Mac checks

Use a clearly chosen small conversation scope for a read, a Contacts lookup and an image. For sending, obtain approval of the exact test recipient, text and files before executing. An approved, locally accepted write and delivery are different observations; report only what the chosen boundary establishes.

New-group creation needs its own public-API proof if included in the release. Existing group sends and single new-recipient sends do not prove it. Do not enable injected/private operations to make the test pass.

### Incoming attachment checks

The attachment boundary suite uses real synthetic SQLite associations and local
files. The independent Python client decodes the ImageIO output with Pillow and
compares original file bytes. It exercises both direct MCP stdio and the same
Unix-socket server/stdio relay used by the app, with a synthetic operations owner.
It never connects to the installed app. Run after `swift test`:

```sh
swift build --product MCPTestServer
swift build --product MCPBridgeTestClient
uv pip install --python .scratch/protocol-venv/bin/python 'mcp==1.26.0' 'pillow==11.3.0'
PYTHONDONTWRITEBYTECODE=1 .scratch/protocol-venv/bin/python Tests/Protocol/attachment_test.py
```

The synthetic [attachment fixtures](../Tests/Fixtures/Attachments) retain a red
PNG, an oriented JPEG, a small PDF and an unknown binary document for client
checks. The protocol script copies these and generates a two-frame GIF, a larger
PNG and files at/above the original-byte size limit. Working fixtures and state
remain under ignored `.scratch/attachment-protocol/`.
These tests prove server payloads, not Codex's ability to display or consume them.

After root integrates and installs the combined release under the saved signing
identity, root owns this read-only live check:

1. In an explicitly chosen small conversation, obtain one genuine image and one
   non-image attachment's IDs from history. Record only aggregate outcomes.
2. Call `read_image` through the installed MCP bridge. Confirm that Codex visibly
   receives the image and that the reported orientation, dimensions, frame choice
   and limits agree with the view. Do not claim original-image fidelity.
3. Call `read_attachment` for a genuine small PDF/document. Confirm that Codex's
   document capability can consume the returned embedded bytes and identify a
   private content detail correctly, without logging the detail. An accepted
   resource block alone does not prove delivery to that capability.
4. If an undownloaded attachment is available in the chosen scope, confirm the
   explicit unavailable result without downloading it. Keep any unavailable
   genuine fixture case recorded as untested rather than substituting a claim.

Real attachment paths, private content, macOS 14, Apple Silicon and client
rendering/consumption remain live gates until those checks are performed.

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
activity normalization follows the accepted rule in [decisions](decisions.md).
Sending synthetic proof and
live gates are defined in [sending boundary validation](#sending-boundary-validation).
Incoming attachment payload proof and live client gates are defined in
[incoming attachment checks](#incoming-attachment-checks).
Activity proof is below.
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

## Sending boundary validation

`SendOperationsTests` uses real synthetic SQLite and local files with controlled
send-boundary outcomes. It covers exact existing direct/group GUIDs, alias
lookup before exact selection, selected-source ambiguity, multiple handles,
formatted explicit phone numbers, new individual recipients, validation of the
whole file batch, ordering, rejected/unknown outcomes, cancellation, concurrent
batch exclusion, and file rewrite/replacement/deletion after an earlier command.
Read/find/alias preparation does not invoke the sender.

`MessagesScriptingTests` compiles the production script against the installed
public dictionary without executing it. It executes the shared routing body
through `NSAppleScript` and actual Apple Event argument descriptors with inert
boundary handlers. It checks Unicode/newlines/quotes, exact target selection,
missing/ambiguous service routes, unknown dispatch failure and permission denial
without execution. This proves the script/data boundary, not real Messages
account lookup or sending. The independent MCP client additionally exercises
structured arguments/results and records only synthetic dispatches:

```sh
swift build --product MCPTestServer
.scratch/protocol-venv/bin/python Tests/Protocol/send_test.py
```

The native setup tests inject Automation status and requests into the actual
AppKit controller, retain Contacts/FDA coverage, and distinguish setup from the
read runtime. Production permission checks and requests run off the main actor;
tests do not request system permission. Bundle property-list validation checks
the Automation usage description and entitlement. Signing/install and genuine
macOS authorization remain separate live gates.

### Minimal live-send plan for the integration owner

Do not execute this plan without Eric confirming each exact destination,
service, text and file preview. Use a chosen test recipient and an existing test
group; do not invent or infer either. The normal client must also approve the
invocation. First verify an inert client rejection produces no dispatch and that
drafting only prepares the preview. Root owns installation under the saved
signing identity and the app-owned Automation consent prompt.

Create two UTF-8 files in root's ignored `.scratch/live-send/`:

- `one.txt`: `Messages Swift synthetic attachment one.` followed by one newline.
- `two.txt`: `Messages Swift synthetic attachment two — café 🙂.` followed by one newline.

Preview and confirm these separate cases:

1. Existing direct chat: exact text `Messages Swift synthetic direct test — café 🙂.`
   followed by a newline and `Second line: "quoted" text.`, then `one.txt` and
   `two.txt` in that order. Check the returned ordered part statuses and inspect
   Messages for the intended conversation, text and both file contents.
2. Existing group: file-only `one.txt`, after previewing all current participants
   and the group's actual service. Check exact group placement and file content.
3. New individual recipient: text-only `Messages Swift synthetic new-recipient test.`
   with an explicit selected service and exact handle. Check placement; no group
   creation or service fallback is allowed.

Repeat a route only after a new exact approval, never automatically after an
unknown result. Verify available SMS/RCS routes separately before claiming them;
a missing or ambiguous native route must return `messages_route_unavailable`.
A command accepted by Messages is not delivered: report observed delivery
separately, or leave it unconfirmed. Never force a network failure by changing
account or security settings. Controlled partial/unknown failure tests remain
synthetic. Keep originals unchanged through batch preparation and dispatch.
The staging correction below retains private snapshots for Messages after the
operation returns; native asynchronous consumption remains a separate live gate.

### Sending implementation result

On Intel with Apple Swift 6.1.2, the complete suite passed 72 XCTest tests and
43 Swift Testing tests. The independent Python MCP 1.26.0 client passed 15
existing read/alias checks and six send checks. Disabling the batch-stop condition
caused eight assertions in the no-retry test to fail; restoring it passed that
test. Both packaging property lists passed `plutil -lint`, and the affected
documentation graph had no broken links. The AppKit/runtime regression performed
an actual synthetic `read_messages` call through its private socket with
Automation denied and not requested. These results do not establish genuine
Messages sending, OS consent, client confirmation behavior or delivery.

### Combined sending and attachment validation

The combined implementation passed 84 XCTest tests and 43 Swift Testing tests.
The independent Python MCP 1.26.0 client passed 15 read/alias checks, six inert
send checks and 25 attachment checks, including attachment retrieval through the
Unix socket and stdio relay. Pillow 11.3.0 independently decoded returned images.
Both packaging property lists passed validation. These synthetic results preserve
the live consent, exact-preview confirmation, sending and client attachment
consumption gates described above. Activity counts are not part of this build.


### Outgoing file-handoff correction

A live synthetic text/PNG/PDF batch delivered text but not files. Narrow native
logs identified imagent sandbox `file-read-data` denials and `Operation not
permitted` for both exact repository fixture paths. The app's successful local
file validation and AppleScript reply did not prove imagent could read them.
The correction stages all inputs in the app-owned Messages attachment directory
before any command. The numeric database error and transfer-state values are
not assigned undocumented enum meanings by this fix.

Synthetic tests use an injected staging root under `.scratch`, never the live
Messages directory. They exercise real copies, source changes, copy failures,
duplicate filenames, private modes, staged argument paths, ordering, retained
accepted/unknown inputs and cleanup of unhanded inputs on rejection/cancellation.
They do not establish imagent access on the live Mac.

The next live gate is **files only**, with root's authorization covering the
exact test destination and files: the same selected own-number iMessage conversation, and the
committed `Tests/Fixtures/Attachments/red.png` (81 bytes) followed by
`Tests/Fixtures/Attachments/document.pdf` (1529 bytes), with no text. Confirm
received image/document content and inspect only these new test rows/logs if
needed. Do not resend the earlier batch, change permissions or claim delivery
from the AppleScript reply. Root owns installation, test authorization and execution.

The staging correction passed 96 XCTest tests and 43 Swift Testing tests on the
Intel host, plus the six independent MCP send checks with staged paths/bytes and
retention assertions. The native consumer's access to the corrected staging path
remains a live gate; synthetic copy success does not claim delivery.


### Raw provider-status readback

Synthetic SQLite tests cover zero/nonzero flags, raw error/transfer values,
SQL NULL and missing columns through the shared read/search operations. The
independent adapter check uses the actual MCP fixture server:

```sh
.scratch/protocol-venv/bin/python Tests/Protocol/provider_status_test.py
```

An available local file with a nonzero raw transfer value is preserved without
claiming delivery. These fields do not decode undocumented Apple error enums,
change send acceptance semantics or start a status polling loop.

The provider-status addition passed 98 XCTest tests and 43 Swift Testing tests.
The independent MCP test passed read/search and attachment/image metadata checks
with present and missing status columns. The image check returned
`unsupported_image` inside the tool sandbox and passed unchanged outside it;
this is a test-environment limitation, not a decoded provider status.


## Activity validation

Run the activity-only tests with `swift test --filter Activity` and the independent
adapter checks with `.scratch/protocol-venv/bin/python Tests/Protocol/activity_test.py`.
The latter uses the compiled `MCPTestServer` and its own synthetic SQLite fixture.

Real SQLite tests reconcile shared-normalizer activity with complete history,
including attachment-only, failed-body, edited, retracted, reaction, preview and
unknown rows. They distinguish repeated associations, distinct physical rows with
identical GUIDs, global deduplication and per-chat counts. They cover partial and
empty ranges, zero buckets, Halifax DST, Monday weeks, month boundaries,
whole-range ranking with chronological series, exact membership, contact ambiguity,
alias enrichment, stable arrivals and terminal pagination.

Mutation tests cover direction changes, deletion, membership removal and
retraction during continuation. Body-only edits preserve counts and can continue;
foreign-store cursors and deleted selected chats retain distinct restart errors.
Removing the result-digest check caused the rank-change regression to fail;
removing the membership arrival fence caused its regression to fail. Both changes
were restored. Contemporary microsecond endpoints failed before the date conversion
fix and passed after it. Near-limit tests include clipped day/week/month intervals.
The MCP tests exercise input precision rejection, offset timestamps, reported-bound
round trips, retraction/history reconciliation and continuation errors.

Live counts still require root's read-only installed-app check: choose a short
explicit interval in one conversation, consume all history pages, count only
unretracted messages by stable source identity, and compare sent/received/total.
Repeat with day buckets and a small per-chat ranking. For cross-chat reconciliation,
deduplicate source identity overall and preserve each association per chat. If
public GUIDs are ambiguous, inspect exact source coordinates privately rather than
coalescing by text/date/sender. Log only aggregate outcomes and build identity.
No real messages, Contacts data or installed-app operations were used in these
synthetic tests. Live schema coverage, installed MCP behavior and performance
remain separate checks; this is not nanosecond-accurate timestamp input.


On September 9, 2026, the activity branch passed 71 XCTest cases and 37 Swift
Testing tests on Intel. The independent MCP clients passed 13 activity checks and
15 existing checks. Removing retraction exclusion caused four assertions across
the two retraction tests to fail; restoring it passed. These are branch-local
synthetic results; root owns combined-main integration and live reconciliation.

### Combined activity integration result

On September 9, 2026, the integrated eight-tool build passed 118 XCTest cases
and 43 Swift Testing tests. Independent Python MCP 1.26 clients passed 15
read/alias checks, six inert send checks, 25 attachment checks, two raw
provider-status checks and 13 activity checks. The activity inventory now requires
all eight tools; activity-specific timestamp precision leaves existing read/send
and attachment behavior intact. Logs are local under `.scratch/activity-integration/`.
No installed-app actions, real Messages/Contacts reads, sends or permission
changes were used. The read-only live activity reconciliation above remains the
integration owner's next gate. Existing sending, file consumption and platform
validation gates remain separate.

## Active-session incoming watch

`WatchTests` uses real synthetic SQLite/WAL and shared operations. It covers the
initial baseline, exclusive bounded continuation, outgoing exclusion, typed
events, late chat associations, backdated arrivals, replay, independent callers,
monotonic timeout/cancellation, unknown chats, scope/store mismatch, opened-file
replacement, changed/missing anchors, dangling associations, the 256-row physical
scan bound, and directory/raw-status preservation.

`disconnectedWatchReleasesItsOperationOwnerPromptly` initializes MCP on a real
socket pair, starts a 20-second watch, completes a same-session read, disconnects,
and checks that the operation owner releases within two seconds. This detects
a wait retained after its session exits; a fresh client's success alone does not
prove cleanup. `Tests/Protocol/watch_test.py` exercises the actual fixture socket
and stdio relay with independent JSON-RPC clients, concurrent read/search,
arrivals/replay, timeout, input validation, cancellation, disconnect and defaults.

```sh
swift test
swift build --product MCPTestServer
swift build --product MCPBridgeTestClient
PYTHONDONTWRITEBYTECODE=1 python3 Tests/Protocol/watch_test.py
```

These tests use inert data under ignored `.scratch/`. They do not exercise a real
incoming message, the installed app/client timeout, or provider association
ordering on a live database. Root owns any authorized installation and live QA.
Historical edits/deletions, lower-row insertions, identical anchor reuse and late
attachment/status updates remain the explicit unobserved cases in the
[watch schema](schemas.md#active-session-incoming-watch).

The Intel synthetic run passed 110 XCTest tests and 44 Swift Testing tests,
including 12 watch core tests and the socket lifetime check. The independent
watch protocol script passed seven checkpoints. Replacing association ordering
with message-row ordering failed the delayed-join test; removing session watch
cleanup failed the operation-release check. Restored source passed. Sandboxed
native-image/AppleScript/socket checks failed under restricted system access;
the complete run above passed outside that sandbox without live sends or
permission changes.

### Combined watch integration result

On September 9, 2026, the integrated nine-tool build passed 130 XCTest cases
and 44 Swift Testing tests. Independent clients passed 15 read/alias, six inert
send, 25 attachment, two raw provider-status, 13 activity and seven watch
checks. The watch proof uses synthetic SQLite WAL, the actual fixture Unix
socket server and the stdio relay. Session shutdown cancels only registered
watch waits; send dispatch, partial/unknown outcomes and staged-file cleanup
retain their existing ownership. Activity timestamp precision remains specific
to activity results. Logs are local under `.scratch/watch-integration/`.
No installation, live data, sending or permission changes were part of these
checks. Installed-client timeout and a genuine incoming-message watch remain
separate live gates for the integration owner.

### Sending status and route preflight

The September 9 routing/status update passed 149 XCTest cases and 44 Swift
Testing cases, plus the independent read/alias, send and activity MCP suites.
These include real SQLite mutations for source error 22, missing delivery
receipts, delayed competing messages, shared message associations, direct/group
separation, and successful ordered text/file parts. Route tests cover new numbers,
name/source-identity resolution, ambiguous contacts, unavailable relay, RCS history,
newer failed/pending attempts, backdated imports and duplicate service handles.
An existing reader also observes attributed-body replacement and decode failures.
The final `provider_reported` delivery label passed its rebuilt focused test.
Evidence is local under `.scratch/send-routing-validation/`; private message
history is not part of these fixtures. Installed sending remains a separate live
check, limited to the owner's authorized synthetic self-tests.

The installed signed app then passed a bounded synthetic self-test: text returned
`sent` with delivery initially false, and normal reads later showed delivery true.
An incoming watch received the text; cursor replay and consumed-cursor suppression
passed while a concurrent read completed in 74 ms. A synthetic image initially
returned `pending`, then source reads showed sent and the incoming image preserved
24-by-12 all-red pixels. An earlier source-validation rejection occurred before
dispatch; one revalidated attempt succeeded. No contractor or group messages were
sent in this validation. A fresh native Codex client discovered all ten tools and
used route preflight for a synthetic unknown number, receiving local iMessage/SMS
options with no historical suggestion. This proves active calls, not idle wakeups.

### Automatic transport boundary

Synthetic automatic-routing tests exercise the shared operation against SQLite
and the production AppleScript routing handler with inert boundary handlers.
They cover history/RCS relay selection, no enabled route, email isolation,
SMS-first routing for unfamiliar phones, one pre-dispatch alternative in either
direction, negotiated RCS observation,
explicit overrides, unchanged multipart payloads and no replay of successful
parts. Source failure, pending, missing/competing rows, delayed success and
conflicting delivery flags do not cause another attempt. The stdio MCP suite
also sends successfully with service omitted and checks returned attempts.
Disabling the alternative branch makes the negotiated-RCS test fail its status,
attempt-route and observed-service assertions; restored source passes.

Fresh synthetic file reads can acquire a later ctime update on this Mac even
when inode, size and mtime stay fixed. Initial and changed xattr name lists both
contained only `com.apple.provenance`; the writer of that metadata change is not
established. Fixtures read their files and allow setup metadata to settle before
production captures their identity. Production file guards are unchanged, and
post-dispatch rewrite/replacement/deletion tests retain their original assertions.

The public source error flags do not establish terminal non-send. In particular,
an accepted iMessage attempt followed by error 22 remains a reported failure,
without an automatic SMS replay. The available proof authorizes alternatives
only when the AppleScript handler reports route failure before dispatch begins.
This does not complete automatic recovery for a new Android number whose
submission is accepted first. No live send, native UI operation, installation
or OS permission change is part of these tests.

The earlier September 9 automatic-routing run passed 156 XCTest and 44 Swift Testing
cases, and all nine send MCP checks. The compiled test bundle ran from the
short repository checkout path because the isolated worktree path exceeds the
macOS Unix socket pathname limit. No source or runtime fix was made for that
fixture-path constraint. Evidence is under the routing worktree's ignored
`.scratch/automatic-routing/` directory.

The later SMS-default change passed all 43 focused send-operation tests. All eight
scripting tests also passed, including a real inert AppleScript regression that
raises the route-lookup error after dispatch for both SMS and iMessage and requires
`unknown`. The sole production sender and runtime wiring were independently
reviewed; no post-dispatch `unavailable` path exists. Its protocol explicitly makes
that no-dispatch guarantee part of the outcome contract.

The updated MCP suite passed the new SMS-default SQLite/adapter assertion before
failing a later attachment fixture assertion involving the existing ctime guard.
This is not a fully passing protocol-suite result. File-guard behavior was not
weakened. Complete focused logs are in `.scratch/default-transport-validation/`.

### App-restart connection recovery

`Tests/Protocol/bridge_test.py` runs the production recovering relay as a separate
process over real pipes and private Unix sockets. Its inert fault-injection
servers cover idle app loss, an executed send with a lost response (one side
effect, no replay), partial response JSON, complete response followed by a partial
frame, loss during request writes, cancellation, stdin EOF during restoration,
handshake timeout/mismatch/EOF, unavailable and unsafe endpoints, reused/string
request IDs, and 12 MiB JSON in both directions. Delayed-restoration cases
cancel a queued send both directly and behind more than one input chunk of
ordinary requests, and assert zero send side effects. Error assertions distinguish
`not_submitted` connection/handshake failures from `outcome_unknown` after writes.
Confirmed-disconnection and delayed-handshake batches include stale client
responses and notifications; the new backend receives only reinitialization and
the new requests. The frame test and handshake-EOF
test first failed against the initial implementation and passed after incremental
scanning and stdin lifetime handling were corrected.

`Tests/Protocol/bridge_restart_test.py` runs the actual Swift MCP SDK fixture and
synthetic SQLite store. It restarts that backend while retaining one stdio bridge
process, discovers all ten tools again, rejects an old store-bound watch cursor,
and interrupts an active watch before successfully restoring the next request.
It also cancels 130 consecutive SDK watches and confirms later discovery, proving
that cancellation retires pending IDs without waiting for a response.
This checks transport restoration through the production SDK composition; fault
injection owns the uncertain-send/no-replay proof.

```sh
swift build --product MCPTestServer
swift build --product MCPBridgeTestClient
PYTHONDONTWRITEBYTECODE=1 python3 Tests/Protocol/bridge_test.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/Protocol/bridge_restart_test.py
```

The scripts accept `MESSAGES_MCP_TEST_SERVER` and
`MESSAGES_BRIDGE_TEST_BINARY` for isolated build outputs. A deep worktree may set
`MESSAGES_RESTART_TEST_SOCKET` to a short task-owned scratch path that fits the
Unix socket pathname limit. Its two immediate parent directories must be private
and dedicated to this test; the restart script removes its socket, lock and those
directories after stopping its server.

These tests do not restart the installed app, read real Messages or Contacts,
send messages, or change permissions. The installed client must establish one
fresh session to pick up an updated bridge binary; real app/client restart QA
remains a separate integration check.

The integrated automatic-routing/recovery build passed 156 XCTest and 44 Swift
Testing cases, plus the final 17 bridge fault cases, three Swift SDK recovery
checkpoints and the send MCP suite. Installed QA retained the same bridge process
through a real menu-app restart: the active read-only watch was interrupted,
a fresh read worked, and the old store cursor was rejected. One authorized
synthetic self-text then sent successfully with no service argument, one recorded
attempt and one outgoing source row; its incoming content was verified. No live
write was deliberately interrupted and no contractor or group was messaged.

### Native client attachment and activity QA

On September 9, the installed app was exercised through Codex's native MCP
tools, using existing synthetic self-messages without further sends.
`read_image` returned an inline PNG that was visually inspected as the expected
24 by 12 red rectangle. `read_attachment` returned the complete 1,529-byte PDF
as an embedded resource; those exact bytes were decoded and rendered with
Poppler, and the single red-rectangle page was visually inspected. This closes
the native client image-viewing and document-consumption gates for these fixtures.
It does not establish every attachment format or file-size boundary.

Activity was reconciled against complete `read_messages` results over a fixed
UTC day. The self conversation contained 18 ordinary unretracted rows: 11
outgoing and 7 incoming. Overall counts matched, as did the two partial calendar
day buckets in America/Halifax. A separate top-three chat ranking returned
totals 33, 19 and 18; independent history calls reconciled each total and direction
split, with no pagination or decoding failures. Outgoing counts describe source
direction, including failed submissions, rather than successful delivery.

Redacted evidence and the received synthetic PDF/render are in the orchestration
workspace's ignored `.scratch/live-install/native-client-qa.md` and adjacent files.
One reused subagent client returned `Transport closed`; the root native client
succeeded. That particular client failure was not independently attributed to
the known pre-installation stale-bridge limitation.
