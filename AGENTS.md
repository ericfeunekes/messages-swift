# messages-swift

This repository defines a native Swift Messages integration for agents. Read [requirements](docs/requirements.md) before changing behavior, and [architecture](docs/architecture.md) before adding code or dependencies.

- For unresolved scope or policy, consult [open decisions](docs/decisions.md). Separate a product decision from an engineering question that can be tested. Do not turn an unaccepted proposal into a requirement.
- For tests and compatibility claims, follow [validation](docs/validation.md). Source inspection is not runtime proof. Keep names, queries, decoding and state in shared Swift operations; adapters handle transport and presentation.
- For upstream reuse, consult [references](docs/references.md). Use public source with its license and attribution. Do not decompile or disassemble proprietary binaries, publish extracted proprietary artifacts, use private-framework injection, or change macOS security settings.
- Keep real message/contact data, credentials, attachments and user aliases out of Git and logs. Use synthetic or redistributable fixtures. Scratch work belongs in ignored `.scratch/`.
- Conversational intent and send approval belong to agent/client guidance, not a second approval system inside the Swift core. The send policy is owned by [requirements](docs/requirements.md#reading-drafting-and-sending).
- When behavior changes, update its owning document and the relevant proof. Keep the README as the entry point instead of duplicating detailed requirements there.
