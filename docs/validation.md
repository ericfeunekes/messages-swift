# Validation

The requirements define intended behavior. This document defines what would prove it. No runtime tests have been executed for this project yet.

## Source and fixture policy

Reuse suitable public Swift parser, schema, Contacts and attachment fixtures with their licenses and expected outcomes intact. Fixture tests should exercise real SQLite queries and decoding; mocks are reserved for controlled variations or failures. Do not commit real conversations, contact directories, attachment files or user aliases.

The reviewed imsg tests cover attributed bodies, unread selection, schema variation, attachment handling, Contacts resolution and forward-cursor edge cases. They are useful starting points, not proof of this project's distinct contract or its live Mac integration.

## Required evidence

| Boundary | Proof |
|---|---|
| Swift and dependencies | Build on x86_64; verify selected dependency and deployment-target compatibility |
| MCP adapter | Real initialize, tool listing and read invocation in the intended client; schema/result handling and image presentation |
| Conversation directory | Selected Google account scoping, source identity through the chosen adapter, duplicate names, linked contact handles, unnamed and named groups, stable aliases, exact membership and sender-versus-membership distinctions |
| Cache and aliases | Cold/warm lookup, restart persistence, expiry/invalidation, alias preservation and immediate alias updates, missing contacts and permission changes |
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

Build and test commands belong here once a real package and test targets exist; there are no placeholder commands to treat as executed.
