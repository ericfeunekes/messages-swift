# messages-swift

Native Swift access to Apple Messages for agents, with readable conversation names, contact resolution and saved thread aliases.

The primary interface is a local stdio MCP server over shared Swift operations. A diagnostic CLI can use those same operations when needed. Intel macOS is the initial validation target.

This repository currently contains the requirements and design. There is no installable implementation yet.

## Intended experience

- Find a conversation by a person's name, a group name or a saved alias.
- Read and search history with contact names and conversation details already joined into the results.
- Use a selected Google Contacts account as the intended contact authority. Keep roughly 100 frequent contacts in a derived local cache and resolve other people on demand.
- Read image attachments and summarize message activity.
- Draft without sending. Before a send, the agent shows the exact recipients, content and files for confirmation, then uses its client's normal approval path.

The design is informed by OpenAI's observed Messages tool behavior and the public [imsg Swift project](https://github.com/openclaw/imsg). This is an independent implementation, not an OpenAI or Apple product. It does not use decompiled code, proprietary binaries or process injection.

## Documentation

- [Requirements](docs/requirements.md): intended behavior and scope.
- [Architecture](docs/architecture.md): shared Swift operations, MCP, state and integration boundaries.
- [Validation](docs/validation.md): the evidence required before claiming a capability works.
- [Open decisions](docs/decisions.md): unresolved product choices and engineering questions.
- [References](docs/references.md): source provenance and limits of the research.
- [Agent guidance](AGENTS.md): how to work in this repository.

## Development

Keep changes tied to the requirements. Resolve a blocking product decision before implementing its dependent behavior. Define the typed operation contract before adding an adapter, and test at the integration boundary being changed.

Build, test and installation commands will be documented when the executable exists. No public claim of runtime compatibility is based only on the current source review.

## Privacy and licensing

Real messages, contacts, attachment files, aliases and runtime databases stay outside this repository. Test data must be synthetic or explicitly redistributable. See the [reference rules](docs/references.md#source-and-data-boundaries).

Licensed under [MIT](LICENSE). No third-party implementation code is included in this initial documentation commit; reused components will retain their applicable notices.
