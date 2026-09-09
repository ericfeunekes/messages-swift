"""Independent MCP activity checks using only a synthetic SQLite Messages fixture."""

import asyncio
import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.shared.exceptions import McpError


ROOT = Path(__file__).resolve().parents[2]
SCRATCH = ROOT / ".scratch/activity-protocol"
DATABASE = SCRATCH / "fixture.sqlite"
STATE_DIRECTORY = SCRATCH / "state"
SERVER = Path(os.environ.get("MESSAGES_ACTIVITY_MCP_TEST_SERVER", os.environ.get(
    "MESSAGES_MCP_TEST_SERVER", ROOT / ".build/debug/MCPTestServer")))

RANGE = {
    "start": "2024-03-09T12:00:00-04:00",
    "end": "2024-03-11T12:00:00-03:00",
}
SUBSECOND_RANGE = {
    "start": "2024-03-12T12:00:00.123456-03:00",
    "end": "2024-03-12T12:00:00.223456-03:00",
}
MICROSECOND_RANGE = {
    "start": "2024-03-13T12:00:00.000007-03:00",
    "end": "2024-03-13T12:00:00.000008-03:00",
}


def record(name):
    print(f"PASS {name}")


def content(result):
    assert result.structuredContent is not None
    assert result.content and result.content[0].type == "text"
    assert json.loads(result.content[0].text) == result.structuredContent
    return result.structuredContent


def apple_nanos(iso):
    instant = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(timezone.utc)
    delta = instant - datetime(2001, 1, 1, tzinfo=timezone.utc)
    return ((delta.days * 86_400 + delta.seconds) * 1_000_000_000) + (delta.microseconds * 1_000)


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def assert_timestamp(actual, expected):
    difference = abs((timestamp(actual) - timestamp(expected)).total_seconds())
    assert difference <= 0.000001, (actual, expected, difference)


def build_database():
    SCRATCH.mkdir(parents=True, exist_ok=True)
    if DATABASE.exists():
        DATABASE.unlink()
    with sqlite3.connect(DATABASE) as database:
        database.executescript("""
            CREATE TABLE chat (guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE handle (id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE message (
                guid TEXT, date INTEGER NOT NULL, text TEXT, attributedBody BLOB,
                is_from_me INTEGER NOT NULL, is_read INTEGER, service TEXT, handle_id INTEGER,
                associated_message_guid TEXT, associated_message_type INTEGER, item_type INTEGER,
                balloon_bundle_id TEXT, date_edited INTEGER, date_retracted INTEGER
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE attachment (
                guid TEXT, filename TEXT, transfer_name TEXT, uti TEXT, mime_type TEXT,
                total_bytes INTEGER, is_sticker INTEGER
            );
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
        """)
        database.executemany("INSERT INTO chat (guid, chat_identifier, display_name, service_name) VALUES (?, ?, ?, ?)", [
            ("chat-direct", "alice@example.test", None, "iMessage"),
            ("chat-empty", "alice@example.test", None, "iMessage"),
            ("chat-group", "group:alice-bob", "Project group", "iMessage"),
        ])
        database.executemany("INSERT INTO handle (id) VALUES (?)", [("alice@example.test",), ("bob@example.test",)])
        database.executemany("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)", [
            (1, 1), (2, 1), (3, 1), (3, 2),
        ])
        rows = [
            ("direct-received", "2024-03-09T18:00:00-04:00", "ordinary", 0, 1, None, None, 0, None, None),
            ("direct-edited", "2024-03-10T03:30:00-03:00", "edited", 1, 1, None, None, 0, None, 1),
            ("direct-attachment", "2024-03-10T04:00:00-03:00", None, 0, 1, None, None, 0, None, None),
            ("direct-failed", "2024-03-10T05:00:00-03:00", None, 0, 1, b"\x04\x0btruncated", None, 0, None, None),
            ("group-sent", "2024-03-10T06:00:00-03:00", "group", 1, 1, None, None, 0, None, None),
            ("shared", "2024-03-10T07:00:00-03:00", "shared", 0, 1, None, None, 0, None, None),
            ("reaction", "2024-03-10T08:00:00-03:00", "Loved", 0, 1, None, "direct-received", 2000, None, None),
            ("preview", "2024-03-10T09:00:00-03:00", "Preview", 0, 1, None, None, 0, "com.apple.messages.URLBalloonProvider", None),
            ("unknown", "2024-03-10T10:00:00-03:00", "Unknown", 0, 1, None, None, 1, None, None),
            ("subsecond-start", SUBSECOND_RANGE["start"], "included start", 0, 1, None, None, 0, None, None),
            ("subsecond-middle", "2024-03-12T12:00:00.173456-03:00", "included middle", 1, 1, None, None, 0, None, None),
            ("subsecond-end", SUBSECOND_RANGE["end"], "excluded end", 0, 1, None, None, 0, None, None),
            ("microsecond-start", MICROSECOND_RANGE["start"], "included microsecond start", 0, 1, None, None, 0, None, None),
            ("microsecond-end", MICROSECOND_RANGE["end"], "excluded microsecond end", 0, 1, None, None, 0, None, None),
        ]
        database.executemany("""
            INSERT INTO message
              (guid, date, text, attributedBody, is_from_me, is_read, service, handle_id,
               associated_message_guid, associated_message_type, item_type, balloon_bundle_id,
               date_edited, date_retracted)
            VALUES (?, ?, ?, ?, ?, ?, 'iMessage', 1, ?, ?, ?, ?, ?, NULL)
        """, [
            (guid, apple_nanos(at), text, body, from_me, read, associated, associated_type,
             item_type, balloon, edited)
            for guid, at, text, from_me, read, body, associated, associated_type, balloon, edited in rows
            for item_type in [0 if guid not in {"unknown"} else 1]
        ])
        database.executemany("INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)", [
            (1, 1), (1, 2), (1, 3), (1, 4), (3, 5), (1, 6), (3, 6),
            (1, 7), (1, 8), (1, 9),
            (1, 10), (1, 11), (1, 12),
            (1, 13), (1, 14),
        ])
        database.execute("""
            INSERT INTO attachment (guid, filename, transfer_name, uti, mime_type, total_bytes, is_sticker)
            VALUES ('attachment-1', '/synthetic/missing.jpg', 'missing.jpg', 'public.jpeg', 'image/jpeg', 10, 0)
        """)
        database.execute("INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (3, 1)")


def parameters():
    return StdioServerParameters(
        command=str(SERVER),
        args=["--database", str(DATABASE), "--state-directory", str(STATE_DIRECTORY), "--reset-state"],
        env={**os.environ, "TZ": "America/Halifax"},
    )


async def with_client(operation):
    async with stdio_client(parameters()) as (read, write):
        async with ClientSession(read, write) as client:
            initialization = await client.initialize()
            await operation(client, initialization)


async def invalid_params(client, arguments):
    try:
        await client.call_tool("count_message_activity", arguments)
    except McpError as error:
        assert error.error.code == -32602, error
    else:
        raise AssertionError(f"accepted invalid activity arguments: {arguments!r}")


async def domain_error(client, arguments, code):
    result = await client.call_tool("count_message_activity", arguments)
    assert result.isError
    assert content(result)["error"]["code"] == code


def counts(row):
    assert set(row["counts"]) == {"total", "sent", "received"}
    return row["counts"]


async def activity_checks(client, initialization):
    assert initialization.serverInfo.name == "messages-swift"
    listed = await client.list_tools()
    assert {tool.name for tool in listed.tools} == {
        "find_chats", "read_messages", "search_messages", "set_chat_alias", "count_message_activity",
        "read_image", "read_attachment", "send_message", "watch_messages",
    }
    schema = {tool.name: tool.inputSchema for tool in listed.tools}["count_message_activity"]
    assert schema["additionalProperties"] is False
    assert schema["properties"]["groupBy"]["enum"] == ["overall", "chat"]
    assert schema["properties"]["bucket"]["enum"] == ["none", "day", "week", "month"]
    assert schema["properties"]["ranking"]["enum"] == ["chronological", "total", "sent", "received"]
    record("initialize activity inventory and schema")

    defaults = content(await client.call_tool("count_message_activity", {"dateRange": RANGE}))
    assert defaults["groupBy"] == "overall"
    assert defaults["bucket"] == "none"
    assert defaults["ranking"] == "chronological"
    assert defaults["timeZone"] == "America/Halifax"
    record("activity defaults use the Mac time zone")

    for arguments in [
        {"groupBy": "team"},
        {"bucket": None},
        {"ranking": "largest"},
        {"timeZone": "Mars/Olympus"},
        {"dateRange": {"start": "2024-03-10T00:00:00"}},
        {"dateRange": {"start": "2024-03-10T00:00:00.1234567Z"}},
        {"dateRange": {"start": "2024-03-10T00:00:00.123456789Z"}},
        {"dateRange": {"start": RANGE["end"], "end": RANGE["start"]}},
        {"cursor": "not-a-cursor"},
        {"dateRange": None},
        {"unexpected": True},
    ]:
        date_range = arguments.get("dateRange")
        if arguments.get("timeZone") == "Mars/Olympus":
            await domain_error(client, arguments, "invalid_time_zone")
        elif isinstance(date_range, dict) and date_range.get("start") == RANGE["end"]:
            await domain_error(client, arguments, "invalid_date_range")
        elif arguments.get("cursor") == "not-a-cursor":
            await domain_error(client, arguments, "invalid_cursor")
        else:
            await invalid_params(client, arguments)
    record("strict activity fields enums null zone date and cursor errors")

    decoded = content(await client.call_tool("read_messages", {"chatID": "chat-direct", "limit": 50}))
    assert decoded["decodingFailureCount"] == 1
    attachment = next(message for message in decoded["messages"] if message["id"] == "direct-attachment")
    assert attachment["kind"] == "attachment" and attachment["attachments"][0]["id"] == "attachment-1"

    overall = content(await client.call_tool("count_message_activity", {
        "dateRange": RANGE, "timeZone": "America/Halifax", "bucket": "day",
    }))
    assert len(overall["rows"]) == 3
    assert [counts(row) for row in overall["rows"]] == [
        {"total": 1, "sent": 0, "received": 1},
        {"total": 5, "sent": 2, "received": 3},
        {"total": 0, "sent": 0, "received": 0},
    ]
    assert_timestamp(overall["rows"][0]["start"], "2024-03-09T16:00:00Z")
    assert_timestamp(overall["rows"][-1]["end"], "2024-03-11T15:00:00Z")
    record("failed body remains counted once alongside edited rows while events are excluded")

    per_chat = content(await client.call_tool("count_message_activity", {
        "dateRange": RANGE, "timeZone": "America/Halifax", "groupBy": "chat", "bucket": "day",
        "ranking": "total", "limit": 100,
    }))
    rows_by_chat = {}
    for row in per_chat["rows"]:
        rows_by_chat.setdefault(row["chatID"], []).append(counts(row))
    assert list(rows_by_chat) == ["chat-direct", "chat-group", "chat-empty"]
    assert rows_by_chat == {
        "chat-direct": [
            {"total": 1, "sent": 0, "received": 1},
            {"total": 4, "sent": 1, "received": 3},
            {"total": 0, "sent": 0, "received": 0},
        ],
        "chat-group": [
            {"total": 0, "sent": 0, "received": 0},
            {"total": 2, "sent": 1, "received": 1},
            {"total": 0, "sent": 0, "received": 0},
        ],
        "chat-empty": [{"total": 0, "sent": 0, "received": 0}] * 3,
    }
    assert {chat["chatID"] for chat in per_chat["chats"]} == set(rows_by_chat)
    record("whole-range chat ranking retains each chronological calendar series and empty chats")

    exact = content(await client.call_tool("count_message_activity", {
        "dateRange": RANGE, "timeZone": "America/Halifax", "groupBy": "chat", "bucket": "none",
        "participants": [{"query": "Alice Example"}], "membership": "exact",
    }))
    assert [row["chatID"] for row in exact["rows"]] == ["chat-direct", "chat-empty"]
    direct = next(chat for chat in exact["chats"] if chat["chatID"] == "chat-direct")
    assert direct["participants"] == [{
        "handle": "alice@example.test", "displayName": "Alice Example",
        "sourceIdentity": {"containerID": "synthetic-selected-container", "id": "alice"},
    }]
    record("exact name membership returns enriched selected-source chats")

    equal = content(await client.call_tool("count_message_activity", {
        "dateRange": {"start": RANGE["start"], "end": RANGE["start"]},
        "timeZone": "America/Halifax", "bucket": "none",
    }))
    assert len(equal["rows"]) == 1 and counts(equal["rows"][0]) == {"total": 0, "sent": 0, "received": 0}
    empty_calendar = content(await client.call_tool("count_message_activity", {
        "dateRange": {"start": RANGE["start"], "end": RANGE["start"]},
        "timeZone": "America/Halifax", "bucket": "day",
    }))
    assert empty_calendar["rows"] == []
    record("equal intervals retain the unbucketed zero row and have no calendar buckets")

    subsecond = content(await client.call_tool("count_message_activity", {
        "dateRange": SUBSECOND_RANGE, "timeZone": "America/Halifax", "bucket": "none",
    }))
    assert len(subsecond["rows"]) == 1
    assert counts(subsecond["rows"][0]) == {"total": 2, "sent": 1, "received": 1}
    assert_timestamp(subsecond["resolvedDateRange"]["start"], SUBSECOND_RANGE["start"])
    assert_timestamp(subsecond["resolvedDateRange"]["end"], SUBSECOND_RANGE["end"])
    assert_timestamp(subsecond["rows"][0]["start"], SUBSECOND_RANGE["start"])
    assert_timestamp(subsecond["rows"][0]["end"], SUBSECOND_RANGE["end"])
    round_trip = content(await client.call_tool("count_message_activity", {
        "dateRange": subsecond["resolvedDateRange"], "timeZone": "America/Halifax", "bucket": "none",
    }))
    assert [counts(row) for row in round_trip["rows"]] == [counts(row) for row in subsecond["rows"]]
    record("subsecond half-open bounds preserve native precision and round-trip counts")

    microsecond = content(await client.call_tool("count_message_activity", {
        "dateRange": MICROSECOND_RANGE, "timeZone": "America/Halifax", "bucket": "none",
    }))
    assert [counts(row) for row in microsecond["rows"]] == [{"total": 1, "sent": 0, "received": 1}]
    assert_timestamp(microsecond["rows"][0]["start"], MICROSECOND_RANGE["start"])
    assert_timestamp(microsecond["rows"][0]["end"], MICROSECOND_RANGE["end"])
    record("one-microsecond half-open endpoint includes only the start row")

    cursor_arguments = {
        "dateRange": RANGE, "timeZone": "America/Halifax", "groupBy": "chat", "bucket": "day",
        "ranking": "total", "limit": 1,
    }
    first = content(await client.call_tool("count_message_activity", cursor_arguments))
    assert first["nextCursor"] and first["rows"][0]["chatID"] == "chat-direct"
    with sqlite3.connect(DATABASE) as database:
        database.execute("""
            INSERT INTO message (guid, date, text, is_from_me, is_read, service, handle_id, item_type)
            VALUES (?, ?, ?, 0, 1, 'iMessage', 1, 0)
        """, ("late-arrival", apple_nanos("2024-03-10T12:00:00-03:00"), "late arrival"))
        database.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, last_insert_rowid())")
    second = content(await client.call_tool("count_message_activity", {
        **cursor_arguments, "cursor": first["nextCursor"],
    }))
    assert second["rows"][0]["chatID"] == "chat-direct"
    assert counts(second["rows"][0]) == {"total": 4, "sent": 1, "received": 3}
    await domain_error(client, {**cursor_arguments, "bucket": "week", "cursor": first["nextCursor"]}, "cursor_mismatch")
    record("cursor repeats all arguments and excludes later arrivals")

    direction_arguments = {**cursor_arguments, "ranking": "sent"}
    direction_first = content(await client.call_tool("count_message_activity", direction_arguments))
    assert direction_first["rows"][0]["chatID"] == "chat-direct"
    with sqlite3.connect(DATABASE) as database:
        database.execute("UPDATE message SET is_from_me = 0 WHERE guid = 'direct-edited'")
    await domain_error(client, {**direction_arguments, "cursor": direction_first["nextCursor"]},
                       "activity_changed_restart_required")
    record("in-place direction change that changes chat ranking requires restart")

    body_first = content(await client.call_tool("count_message_activity", direction_arguments))
    assert body_first["nextCursor"] and body_first["rows"][0]["chatID"] == "chat-group"
    with sqlite3.connect(DATABASE) as database:
        database.execute("UPDATE message SET text = 'body-only update' WHERE guid = 'direct-received'")
    body_second = content(await client.call_tool("count_message_activity", {
        **direction_arguments, "cursor": body_first["nextCursor"],
    }))
    assert body_second["rows"] and body_second["rows"][0]["chatID"] == "chat-group"
    record("body-only update preserves an activity continuation")

    retract_first = content(await client.call_tool("count_message_activity", direction_arguments))
    with sqlite3.connect(DATABASE) as database:
        database.execute("UPDATE message SET date_retracted = 1 WHERE guid = 'group-sent'")
    await domain_error(client, {**direction_arguments, "cursor": retract_first["nextCursor"]},
                       "activity_changed_restart_required")
    after = content(await client.call_tool("count_message_activity", {
        "chatID": "chat-group", "dateRange": RANGE, "timeZone": "America/Halifax",
    }))
    history = content(await client.call_tool("read_messages", {"chatID": "chat-group", "dateRange": RANGE}))
    assert any(row["id"] == "group-sent" and row["isRetracted"] for row in history["messages"])
    eligible = {row["id"]: row for row in history["messages"] if not row["isRetracted"]}
    assert counts(after["rows"][0]) == {"total": len(eligible), "sent": 0, "received": 1}
    record("retraction invalidates continuation and fresh counts reconcile with unretracted history")


async def main():
    assert SERVER.is_file(), f"Build MCPTestServer first: {SERVER}"
    build_database()
    await with_client(activity_checks)
    print("All activity MCP checks passed using synthetic SQLite and fixture contacts only.")


if __name__ == "__main__":
    asyncio.run(main())
