# Open decisions

This is the register of unresolved requirements and design choices. It separates choices for the project owner from questions that source inspection or a prototype can answer. A proposal remains a proposal until accepted; dependent implementation should not silently settle it.

## Repository and license

- **Working name:** `messages-swift`; confirmation requested. Naming does not affect the operation contract.
- **Owner and visibility:** personal GitHub account `ericfeunekes`, public; authorized.
- **License:** MIT; selected by the owner. Reused third-party components retain their own applicable notices.

## Initial release scope

- **First release:** reading and sending together; selected by the owner.
- **New groups:** existing groups first; selected by the owner. Creation of new groups is outside the first release. New direct recipients and existing-group sending have distinct paths and must not be classified together.
- **Files:** text and local attachments are part of the intended send operation. The atomicity and partial-outcome contract for multiple files require an implementation decision and proof.

## Directory and cache

- **Contact authority:** Google Contacts associated with the user’s Gmail account; selected by the owner. The account identifier belongs in private setup, not public documentation.
- **Contact access:** source research supports proving a user-selected Google-backed macOS Contacts container first if ordinary Google-to-Mac sync freshness is acceptable. That freshness choice is with the owner. Fetch non-unified records from the selected container; do not infer a Google login from its display label. Direct People API remains the alternative when reads must be independent of Mac sync. Google server-side contact IDs are not required for a disposable single-Mac cache. Actual container isolation and lookup costs still need runtime proof. Contact cleanup/migration remains separate.

- **People cache:** approximately 100 entries with FIFO eviction; selected by the owner. The accepted initial directory baseline uses frequent contacts over 90 days, including group participation. After population, newly used people enter the cache and the earliest-added entry is evicted when full. Working interpretation: refreshing an existing record does not reset its FIFO position.
- **Freshness:** refresh daily or when a contact is used by an operation such as read or send, whichever is sooner; selected by the owner. Daily scheduling while the server runs and overdue refresh on startup are the proposed execution details; no separate daemon.
- **Aliases:** local to this Mac; selected by the owner. They are durable independently of the people cache and do not rename Messages threads. Proposed normalized collisions require explicit replacement or disambiguation.
- **Storage location:** choose one conventional macOS application-support location outside the checkout, separating durable aliases from replaceable contact cache data. Exact path and permissions are an engineering choice to record before installation.

## Platform and runtime

- **Platform floor:** proposed macOS 14+, reflecting the reviewed public Swift core, with Intel as the first tested architecture. Older Intel macOS support and Apple Silicon release coverage are not yet commitments.
- **Dependency:** the public IMsgCore builds on Intel, but its unchanged public API cannot express the required descending continuation, membership filtering, explicit decoding failures and arbitrary-range counts. Source seams are internal. A narrow maintained read/query adaptation is the supported recommendation; exact packaging and API contracts remain implementation decisions.
- **MCP integration:** a native Intel Swift fixture passed independent protocol tests; see [validation](validation.md#preparatory-evidence-september-8-2026). Actual desktop discovery, image rendering and normal agent/client approval remain open. A separate app-server probe was blocked before initialization; this does not establish a Messages or MCP product failure.

## Message interpretation

Define how history, search and counts treat reaction events, edited/retracted messages, system rows and URL-preview rows. They must share one consistent message model. OpenAI's exact internal rules are unknown. Use public fixtures and visible behavior to choose a clear local contract.

## Performance

Proposed initial targets on the Intel reference machine:

- warm directory lookup: p95 below 100 ms;
- one filtered history page: p95 below 500 ms;
- no-match decoded-body search over a controlled 100,000-message fixture: below 5 seconds.

These targets remain proposed. Removing repeated prefix scans reduced correct rare/no-match decoded-body search from approximately 12 seconds to 5.87–5.90 seconds on the unchanged controlled 100,000-message fixture. The five-second proposal remains unmet. See [validation](validation.md#preparatory-evidence-september-8-2026) for the measurement and correctness limits. The recommendation is to proceed with the simpler no-index approach and measure normal usage before adding a persistent index; owner confirmation is pending. Do not describe this as meeting the five-second proposal or silently narrow search/omit decoded text.

## Requirements completion

Requirements are ready for the first implementation slice when its scope, relevant owner choices, typed operation contract and proof are explicit. Unresolved later capabilities can stay open without blocking independent work. A full release claim requires the applicable evidence in [validation](validation.md), not just agreement on this register.
