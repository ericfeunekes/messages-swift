"""Independent MCP client checks for the synthetic Messages operations server.

The server is compiled from this package and reads only the synthetic SQLite
fixture and synthetic ContactsDirectorySource constructed by MCPTestServer.
"""

import asyncio
import json
import os
import sqlite3
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.shared.exceptions import McpError


ROOT = Path(__file__).resolve().parents[2]
SERVER = Path(os.environ.get("MESSAGES_MCP_TEST_SERVER", ROOT / ".build/debug/MCPTestServer"))
STATE_DIRECTORY = ROOT / ".scratch/protocol-test-state"
DATABASE = ROOT / ".scratch/protocol-fixture.sqlite"
PRIOR_CURSOR = None


def record(name):
    print(f"PASS {name}")


def content(result):
    assert result.structuredContent is not None
    assert result.content and result.content[0].type == "text"
    assert json.loads(result.content[0].text) == result.structuredContent
    return result.structuredContent


def build_database():
    DATABASE.parent.mkdir(parents=True, exist_ok=True)
    if DATABASE.exists():
        DATABASE.unlink()
    with sqlite3.connect(DATABASE) as database:
        database.executescript("""
            CREATE TABLE chat (guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE handle (id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE message (
                guid TEXT, date INTEGER NOT NULL, text TEXT, attributedBody BLOB,
                is_from_me INTEGER NOT NULL, is_read INTEGER, service TEXT,
                handle_id INTEGER, associated_message_guid TEXT,
                associated_message_type INTEGER, item_type INTEGER,
                balloon_bundle_id TEXT, date_edited INTEGER, date_retracted INTEGER
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, PRIMARY KEY(chat_id, message_id));
            CREATE TABLE attachment (filename TEXT, transfer_name TEXT, uti TEXT, mime_type TEXT, total_bytes INTEGER, is_sticker INTEGER);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        """)
        database.executemany("INSERT INTO chat (guid, chat_identifier, display_name, service_name) VALUES (?, ?, ?, ?)", [
            ("chat-direct", "alice@example.test", None, "iMessage"),
            ("chat-group", "group:alice-bob", "Project group", "iMessage"),
        ])
        database.executemany("INSERT INTO handle (id) VALUES (?)", [("alice@example.test",), ("bob@example.test",)])
        database.executemany("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)", [(1, 1), (2, 1), (2, 2)])
        attributed_text = b"Needle in attributed body"
        typed_stream_body = bytes([4, 11]) + b"typedstream" + bytes([0x01, 0x2B, len(attributed_text)]) + attributed_text
        database.executemany("""
            INSERT INTO message
              (guid, date, text, attributedBody, is_from_me, is_read, service, handle_id,
               associated_message_guid, associated_message_type, item_type, balloon_bundle_id,
               date_edited, date_retracted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            ("message-old", 1_000_000_000, "Older ordinary message", None, 0, 1, "iMessage", 1, None, None, 0, None, None, None),
            ("message-attributed", 2_000_000_000, None, typed_stream_body, 0, 0, "iMessage", 1, None, None, 0, None, None, None),
            ("message-failed", 3_000_000_000, None, b"\x04\x0btruncated", 0, 0, "iMessage", 1, None, None, 0, None, None, None),
            ("group-message", 4_000_000_000, "Group ordinary message", None, 0, 1, "iMessage", 1, None, None, 0, None, None, None),
            ("message-attachment", 5_000_000_000, None, None, 0, 1, "iMessage", 1, None, None, 0, None, None, None),
            ("reaction-row", 6_000_000_000, "Loved", None, 0, 1, "iMessage", 1, "message-old", 2000, 0, None, None, None),
            ("unknown-row", 7_000_000_000, "Unclassified readable content", None, 0, 1, "iMessage", 1, None, None, 1, None, None, None),
            ("preview-row", 8_000_000_000, "Preview readable content", None, 0, 1, "iMessage", 1, None, None, 0, "com.apple.messages.URLBalloonProvider", None, None),
            ("edited-retracted", 9_000_000_000, "Current text", None, 0, 1, "iMessage", 1, None, None, 0, None, 1, 1),
        ])
        database.execute("INSERT INTO attachment (filename, transfer_name, uti, mime_type, total_bytes, is_sticker) VALUES (?, ?, ?, ?, ?, ?)", ("/synthetic/missing.jpg", "missing.jpg", "public.jpeg", "image/jpeg", 10, 0))
        database.execute("INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?, ?)", (5, 1))
        database.executemany("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [
            (1, 1), (2, 1), (1, 2), (1, 3), (2, 4), (1, 5), (1, 6), (1, 7), (1, 8), (1, 9),
        ])


def server_parameters(reset_state=False):
    arguments = ["--database", str(DATABASE), "--state-directory", str(STATE_DIRECTORY)]
    if reset_state:
        arguments.append("--reset-state")
    return StdioServerParameters(command=str(SERVER), args=arguments)


async def with_client(parameters, operation):
    async with stdio_client(parameters) as (read, write):
        async with ClientSession(read, write) as client:
            initialization = await client.initialize()
            await operation(client, initialization)


async def assert_invalid_params(client, tool, arguments):
    try:
        await client.call_tool(tool, arguments)
    except McpError as error:
        assert error.error.code == -32602, error
    else:
        raise AssertionError(f"{tool} accepted invalid arguments: {arguments!r}")


async def first_process(client, initialization):
    global PRIOR_CURSOR
    assert initialization.serverInfo.name == "messages-swift"
    record("initialize")

    listed = await client.list_tools()
    assert {tool.name for tool in listed.tools} == {
        "find_chats",
        "read_messages",
        "search_messages",
        "set_chat_alias",
        "read_image",
        "read_attachment",
        "send_message",

        "count_message_activity",
    }
    by_name = {tool.name: tool for tool in listed.tools}
    assert by_name["read_messages"].inputSchema["required"] == ["chatID"]
    assert by_name["set_chat_alias"].inputSchema["required"] == ["chatID", "alias"]
    assert by_name["search_messages"].inputSchema["properties"]["query"]["minLength"] == 1
    assert by_name["find_chats"].inputSchema["additionalProperties"] is False
    record("tool inventory and schemas")

    contains = content(await client.call_tool("find_chats", {
        "participants": [{"query": "Alice Example"}],
        "membership": "contains_all",
    }))
    assert {chat["chatID"] for chat in contains["chats"]} == {"chat-direct", "chat-group"}
    assert all("label" in chat and "participants" in chat for chat in contains["chats"])

    exact = content(await client.call_tool("find_chats", {
        "participants": [{"query": "Alice Example"}],
        "membership": "exact",
    }))
    assert [chat["chatID"] for chat in exact["chats"]] == ["chat-direct"]
    record("contains and exact conversation membership")

    page_one = content(await client.call_tool("read_messages", {"chatID": "chat-direct", "limit": 1}))
    assert page_one["chat"]["chatID"] == "chat-direct"
    first_records = page_one["messages"] + page_one["events"]
    assert len(first_records) == 1
    assert page_one["nextCursor"]
    page_two = content(await client.call_tool("read_messages", {
        "chatID": "chat-direct",
        "limit": 1,
        "cursor": page_one["nextCursor"],
    }))
    second_records = page_two["messages"] + page_two["events"]
    assert len(second_records) == 1
    assert second_records[0]["id"] != first_records[0]["id"]
    record("backward cursor wiring")
    PRIOR_CURSOR = page_one["nextCursor"]
    for bad_cursor in ["not-base64", "e30="]:
        invalid = await client.call_tool("read_messages", {"chatID": "chat-direct", "cursor": bad_cursor})
        assert invalid.isError and content(invalid)["error"]["code"] == "invalid_cursor"
    mismatch = await client.call_tool("read_messages", {"chatID": "chat-direct", "unreadOnly": True, "cursor": PRIOR_CURSOR})
    assert mismatch.isError and content(mismatch)["error"]["code"] == "cursor_mismatch"
    record("exact invalid_cursor and cursor_mismatch errors")

    full = content(await client.call_tool("search_messages", {"query": "ordinary message", "limit": 100}))
    expected = [(row["id"], row["chatID"]) for row in full["messages"]]
    pairs = []
    arguments = {"query": "ordinary message", "limit": 1}
    failures = scanned = 0
    for _ in range(20):
        page = content(await client.call_tool("search_messages", arguments))
        pairs.extend((row["id"], row["chatID"]) for row in page["messages"])
        failures += page["decodingFailureCount"]
        scanned += page["scannedAssociationCount"]
        assert len(page["decodingDiagnostics"]) <= 10
        if not page.get("nextCursor"):
            break
        arguments["cursor"] = page["nextCursor"]
    else:
        raise AssertionError("global association continuation did not terminate")
    assert pairs == expected and len(pairs) == 3
    assert failures == full["decodingFailureCount"] == 1
    assert scanned == full["scannedAssociationCount"] == 10
    record("global association pagination and nonduplicated diagnostic totals")

    classified = content(await client.call_tool("read_messages", {"chatID": "chat-direct", "limit": 20}))
    messages = {message["id"]: message for message in classified["messages"]}
    events = {event["id"]: event for event in classified["events"]}
    assert messages["message-attachment"]["kind"] == "attachment"
    assert messages["edited-retracted"]["isEdited"] is True
    assert messages["edited-retracted"]["isRetracted"] is True
    assert events["reaction-row"]["kind"] == "reaction"
    assert events["reaction-row"]["associatedMessageID"] == "message-old"
    assert events["unknown-row"]["kind"] == "unknown"
    assert events["preview-row"]["kind"] == "preview"
    assert events["preview-row"].get("associatedMessageID") is None
    record("message and event classification without heuristic coalescing")

    search = content(await client.call_tool("search_messages", {"query": "Needle"}))
    assert [message["id"] for message in search["messages"]] == ["message-attributed"]
    assert search["decodingDiagnostics"]
    assert all(diagnostic["messageID"] == "message-failed" for diagnostic in search["decodingDiagnostics"])
    record("search result and decoding coverage gap")

    failed_only = content(await client.call_tool("search_messages", {"query": "no-match"}))
    assert failed_only["messages"] == []
    assert failed_only["decodingDiagnostics"]
    record("failed-decode-only search page")

    unknown = await client.call_tool("read_messages", {"chatID": "missing-chat"})
    assert unknown.isError
    assert content(unknown)["error"]["code"] == "chat_not_found"
    record("domain unknown chat")

    invalid_range = await client.call_tool("find_chats", {
        "dateRange": {
            "start": "2100-01-01T00:00:00Z",
            "end": "2001-01-01T00:00:00Z",
        },
    })
    assert invalid_range.isError
    assert content(invalid_range)["error"]["code"] == "invalid_date_range"
    record("invalid far-future date range")

    for tool, arguments in [
        ("read_messages", {"chatID": None}),
        ("read_messages", {"chatID": "chat-direct", "extra": True}),
        ("find_chats", {"participants": None}),
        ("find_chats", {"dateRange": {"start": None, "unexpected": "x"}}),
        ("search_messages", {"query": ""}),
        ("set_chat_alias", {"chatID": "chat-direct"}),
    ]:
        await assert_invalid_params(client, tool, arguments)
    record("wrong extra and null arguments")

    alias = content(await client.call_tool("set_chat_alias", {"chatID": "chat-direct", "alias": "Family"}))
    assert alias["chatID"] == "chat-direct"
    assert alias["alias"] == "Family"
    record("alias write")


async def second_process(client, _initialization):
    result = content(await client.call_tool("find_chats", {"query": "Family"}))
    assert [chat["chatID"] for chat in result["chats"]] == ["chat-direct"]
    assert result["chats"][0]["alias"] == "Family"
    record("alias survives process restart")
    stale = await client.call_tool("read_messages", {"chatID": "chat-direct", "cursor": PRIOR_CURSOR})
    assert stale.isError and content(stale)["error"]["code"] == "cursor_mismatch"
    record("new process rejects prior connection cursor")


async def main():
    assert SERVER.is_file(), f"Build MCPTestServer first: {SERVER}"
    build_database()
    await with_client(server_parameters(reset_state=True), first_process)
    await with_client(server_parameters(), second_process)
    print("All MCP integration checks passed using synthetic SQLite and contacts only.")


if __name__ == "__main__":
    asyncio.run(main())
