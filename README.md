# messages-swift

Native Swift access to Apple Messages for agents, with readable conversation names, contact resolution and saved thread aliases.

A native menu-bar app owns permissions and shared Swift operations; agents connect through a local stdio MCP bridge. A diagnostic CLI can use those same operations when needed. Intel macOS is the initial validation target.

The implementation provides conversation finding, reading, decoded-body search, activity counts, [bounded active-session incoming watches](docs/schemas.md#active-session-incoming-watch), durable local aliases, message-bound image/file retrieval and text/file sending through the public Messages scripting boundary. The [send contract](docs/schemas.md#sending) distinguishes acceptance from delivery; real sending and client approval still require the [live validation](docs/validation.md#minimal-live-send-plan-for-the-integration-owner).

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
- [Local schemas](docs/schemas.md): typed operations, filters and result interpretation.
- [Validation](docs/validation.md): the evidence required before claiming a capability works.
- [Open decisions](docs/decisions.md): unresolved product choices and engineering questions.
- [References](docs/references.md): source provenance and limits of the research.
- [Agent guidance](AGENTS.md): how to work in this repository.

## Development

Keep changes tied to the requirements. Resolve a blocking product decision before implementing its dependent behavior. Define the typed operation contract before adding an adapter, and test at the integration boundary being changed.

Build with Swift 6.1 or later on macOS:

```sh
swift build --product messages-mcp
swift test
```

Install with `./scripts/install-menu-app.sh`, then open `~/Applications/Messages Swift.app`.
The [runtime setup](docs/architecture.md#runtime-setup) covers permissions, contact-source selection and client registration. [Validation](docs/validation.md#implementation-commands) includes the synthetic MCP test commands. Native Intel is the tested architecture; the declared macOS 14 floor and Apple Silicon remain untested.

The [private ChatGPT tunnel setup](docs/architecture.md#private-chatgpt-tunnel)
keeps the installed app as the only Messages runtime and uses the OpenAI tunnel
client's stdio profile. It is installed separately from the app.

## Privacy and licensing

Real messages, contacts, attachment files, aliases and runtime databases stay outside this repository. Test data must be synthetic or explicitly redistributable. See the [reference rules](docs/references.md#source-and-data-boundaries).

Licensed under [MIT](LICENSE). The narrowly adapted public imsg parser and query references retain [MIT attribution](THIRD_PARTY_NOTICES.md). The Swift MCP SDK is pinned to a minimal [0.12.1-based compatibility patch](docs/architecture.md#runtime-setup) with its resolved dependency graph.
