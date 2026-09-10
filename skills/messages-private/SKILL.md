---
name: messages-private
description: Read, search, review and summarize text messages; check received messages, conversations and activity; view attachments; and draft or send replies through the Messages Private MCP. Use for requests about texts, iMessage, SMS/RCS, message history, or following up with people by text.
---

# Messages Private

Use the connected **Messages Private** app to access Apple Messages on the user's Mac. Discover its tools and use their current schemas. The skill provides guidance; the app provides access. If its tools are unavailable, ask the user to enable Messages Private for this chat. If the connection fails, report the error; the Mac and its Messages Swift app and tunnel must be running and online.

## Find and read

Resolve people, phone numbers, native group names or saved aliases with `find_chats`. Use the returned `chatID` for subsequent calls. If several people or conversations match, present the relevant candidates rather than choosing a send destination by rank.

| Request | Tool |
|---|---|
| Review a conversation or check received messages | `read_messages` |
| Find words or topics in message history | `search_messages` |
| Compare sent/received activity or summarize counts over time | `count_message_activity` |
| View an image | `read_image` |
| Retrieve an original file | `read_attachment` |
| Save a convenient local conversation name | `set_chat_alias` |
| Wait briefly for incoming messages during this conversation | `watch_messages` |

Keep reads scoped to the request; they need no extra conversational approval. Follow returned cursors when more results are needed, retaining the same filters. Check decoding diagnostics before claiming search coverage is complete. Date ranges include the start and exclude the end.

Use message and attachment IDs from current history or search results. Attachment tools retrieve files belonging to messages, not arbitrary paths. ChatGPT may separately request permission to materialize a returned file. Local aliases do not rename conversations in Messages. `watch_messages` waits only during an active call; it does not monitor unattended or wake a chat later.

## Draft and send

Draft replies in the conversation without calling `send_message`. Before sending—even when the initial request says “send”—show the resolved recipients, exact text and any attachments, then ask for confirmation. An unchanged confirmed preview needs no second conversational confirmation. Explicit approval for a bounded test sequence applies within that sequence.

Call `send_message` with the confirmed exact chat or resolved recipient. Normally omit `service`: the app selects the transport. `resolve_send_route` is an optional read-only diagnostic. Existing groups are supported; creating new groups is not.

Outgoing file paths must exist on the Mac; a ChatGPT upload is not automatically a Mac file. Report this limitation when relevant.

Describe the returned sending and delivery status accurately. An uncertain or partial result must not trigger an automatic retry or transport change. Report what succeeded and what remains uncertain.

Native deletion, pinning, muting and read-state changes are not exposed by this MCP.
