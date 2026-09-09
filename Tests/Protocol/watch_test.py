"""Protocol proof for active-session incoming watches using synthetic SQLite WAL.

This starts the fixture's real Unix-socket MCP server and uses the production
stdio/socket relay.  The only data created is a synthetic database below
.scratch/.
"""

import asyncio
import json
import os
import sqlite3
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRATCH = ROOT / ".scratch/watch-protocol"
DATABASE = SCRATCH / "messages.sqlite"
STATE = SCRATCH / "state"
SOCKET = ROOT / ".scratch/ws/r/m.sock"  # Keep the Unix-domain pathname short.
SERVER = Path(os.environ.get("MESSAGES_MCP_TEST_SERVER", ROOT / ".build/debug/MCPTestServer"))
BRIDGE = Path(os.environ.get("MESSAGES_BRIDGE_TEST_BINARY", ROOT / ".build/debug/MCPBridgeTestClient"))


def record(name):
    print(f"PASS {name}")


def build_database():
    SCRATCH.mkdir(parents=True, exist_ok=True)
    for path in (DATABASE, DATABASE.with_name(DATABASE.name + "-wal"), DATABASE.with_name(DATABASE.name + "-shm")):
        path.unlink(missing_ok=True)
    with sqlite3.connect(DATABASE) as database:
        assert database.execute("PRAGMA journal_mode=WAL").fetchone()[0].lower() == "wal"
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
        database.execute("INSERT INTO chat VALUES (?, ?, ?, ?)", ("chat-watch", "watch@example.test", "Watch group", "iMessage"))
        database.execute("INSERT INTO handle VALUES (?)", ("watch@example.test",))
        database.execute("INSERT INTO chat_handle_join VALUES (?, ?)", (1, 1))
        add_message(database, "existing", "existing history", incoming=True)


def add_message(database, guid, text, incoming=True, event=False):
    database.execute("""
        INSERT INTO message (guid, date, text, attributedBody, is_from_me, is_read, service, handle_id,
          associated_message_guid, associated_message_type, item_type, balloon_bundle_id, date_edited, date_retracted)
        VALUES (?, ?, ?, NULL, ?, 0, 'iMessage', 1, ?, ?, 0, NULL, NULL, NULL)
    """, (guid, time.time_ns(), text, 0 if incoming else 1, "existing" if event else None, 2000 if event else None))
    database.execute("INSERT INTO chat_message_join VALUES (?, ?)", (1, database.execute("SELECT last_insert_rowid()").fetchone()[0]))


def append_arrival(guid, text, incoming=True, event=False):
    with sqlite3.connect(DATABASE) as writer:
        assert writer.execute("PRAGMA journal_mode=WAL").fetchone()[0].lower() == "wal"
        add_message(writer, guid, text, incoming=incoming, event=event)


class Client:
    def __init__(self):
        self.process = None
        self.next_id = 1
        self.responses = {}

    async def start(self):
        self.process = await asyncio.create_subprocess_exec(
            str(BRIDGE), str(SOCKET), stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        initialized = await self.request("initialize", {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "clientInfo": {"name": "watch-protocol", "version": "1"},
        })
        assert initialized["result"]["serverInfo"]["name"] == "messages-swift"
        await self.notify("notifications/initialized")

    async def send(self, value):
        self.process.stdin.write(json.dumps(value, separators=(",", ":")).encode() + b"\n")
        await self.process.stdin.drain()

    async def notify(self, method, params=None):
        value = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            value["params"] = params
        await self.send(value)

    async def request(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        await self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        return await self.response(request_id)

    async def begin(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        await self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        return request_id

    async def response(self, request_id):
        if request_id in self.responses:
            return self.responses.pop(request_id)
        while True:
            line = await self.process.stdout.readline()
            assert line, (await self.process.stderr.read()).decode()
            response = json.loads(line)
            if response.get("id") == request_id:
                return response
            if "id" in response:
                self.responses[response["id"]] = response

    async def tool(self, name, arguments):
        response = await self.request("tools/call", {"name": name, "arguments": arguments})
        assert "result" in response, response
        result = response["result"]
        payload = json.loads(result["content"][0]["text"])
        return result, payload

    async def close(self):
        if self.process is None:
            return
        self.process.stdin.close()
        await self.process.stdin.wait_closed()
        try:
            await asyncio.wait_for(self.process.wait(), 3)
        except TimeoutError:
            self.process.kill()
            await self.process.wait()


async def establish(client):
    result, payload = await client.tool("watch_messages", {"chatID": "chat-watch", "waitSeconds": 0})
    assert not result.get("isError") and payload["status"] == "no_match" and payload["cursor"]
    assert payload["page"]["messages"] == [] and payload["page"]["events"] == []
    return payload["cursor"]


async def main():
    assert SERVER.is_file(), f"Build MCPTestServer first: {SERVER}"
    assert BRIDGE.is_file(), f"Build MCPBridgeTestClient first: {BRIDGE}"
    build_database()
    # The server verifies both immediate socket directories are private. chmod
    # also repairs directories left by an interrupted prior synthetic run.
    for directory in (SOCKET.parent.parent, SOCKET.parent):
        directory.mkdir(mode=0o700, exist_ok=True)
        directory.chmod(0o700)
    SOCKET.unlink(missing_ok=True)
    server = await asyncio.create_subprocess_exec(
        str(SERVER), "--database", str(DATABASE), "--state-directory", str(STATE), "--reset-state", "--socket", str(SOCKET),
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    clients = []
    try:
        assert await asyncio.wait_for(server.stdout.readline(), 15) == b"ready\n"
        one, two = Client(), Client()
        clients.extend((one, two))
        await one.start()
        await two.start()
        tools = await one.request("tools/list", {})
        schema = {tool["name"]: tool for tool in tools["result"]["tools"]}["watch_messages"]["inputSchema"]
        assert schema["required"] == ["chatID"]
        assert schema["properties"]["waitSeconds"]["minimum"] == 0 and schema["properties"]["waitSeconds"]["maximum"] == 20
        assert schema["properties"]["limit"]["minimum"] == 1 and schema["properties"]["limit"]["maximum"] == 100
        record("watch tool schema through socket relay")

        cursor_one, cursor_two = await establish(one), await establish(two)
        append_arrival("outgoing", "must not arrive", incoming=False)
        append_arrival("arrival-one", "first incoming")
        _, first = await one.tool("watch_messages", {"chatID": "chat-watch", "cursor": cursor_one, "waitSeconds": 0})
        _, second = await two.tool("watch_messages", {"chatID": "chat-watch", "cursor": cursor_two, "waitSeconds": 0})
        assert first["status"] == second["status"] == "messages"
        assert [row["id"] for row in first["page"]["messages"]] == ["arrival-one"]
        assert [row["id"] for row in second["page"]["messages"]] == ["arrival-one"]
        assert "chat" in first["page"] and first["page"].get("nextCursor") is None
        cursor_one = first["cursor"]
        record("two clients retain independent cursors and ignore outgoing rows")

        started = time.monotonic()
        _, timeout = await one.tool("watch_messages", {"chatID": "chat-watch", "cursor": cursor_one, "waitSeconds": 1})
        elapsed = time.monotonic() - started
        assert timeout["status"] == "no_match" and .7 <= elapsed < 3
        cursor_one = timeout["cursor"]
        record("bounded timeout returns required cursor")

        pending = await one.begin("tools/call", {"name": "watch_messages", "arguments": {"chatID": "chat-watch", "cursor": cursor_one, "waitSeconds": 20}})
        await asyncio.sleep(.15)
        # Same connection remains usable while its watch is suspended.
        read = await asyncio.wait_for(one.request("tools/call", {"name": "read_messages", "arguments": {"chatID": "chat-watch", "limit": 1}}), 2)
        search = await asyncio.wait_for(one.request("tools/call", {"name": "search_messages", "arguments": {"query": "existing"}}), 2)
        assert "result" in read and "result" in search
        append_arrival("arrival-two", "second incoming", event=True)
        watched = await asyncio.wait_for(one.response(pending), 3)
        payload = json.loads(watched["result"]["content"][0]["text"])
        assert payload["status"] == "messages" and [row["id"] for row in payload["page"]["events"]] == ["arrival-two"]
        replay_result, replay = await one.tool("watch_messages", {"chatID": "chat-watch", "cursor": cursor_one, "waitSeconds": 0})
        assert not replay_result.get("isError") and replay["status"] == "messages"
        assert [row["id"] for row in replay["page"]["events"]] == ["arrival-two"]
        record("pending watch does not block read/search; arrival and replay retain enriched rows")

        for arguments in ({}, {"chatID": "chat-watch", "waitSeconds": -1}, {"chatID": "chat-watch", "waitSeconds": 21},
                          {"chatID": "chat-watch", "limit": 0}, {"chatID": "chat-watch", "limit": 101},
                          {"chatID": "chat-watch", "waitSeconds": 1.5}, {"chatID": "chat-watch", "unexpected": True}):
            response = await one.request("tools/call", {"name": "watch_messages", "arguments": arguments})
            assert response.get("error", {}).get("code") == -32602, response
        record("watch input schema rejects missing, out-of-range, fractional and extra arguments")

        # Cancellation leaves the connection usable with the same cursor; a
        # separate pending connection below covers relay-disconnect cleanup.
        abandoned = Client()
        clients.append(abandoned)
        await abandoned.start()
        abandoned_cursor = await establish(abandoned)
        # Omitted waitSeconds is a pending default wait, rather than an implicit
        # zero-query; cancellation keeps this check bounded.
        pending = await abandoned.begin("tools/call", {"name": "watch_messages", "arguments": {"chatID": "chat-watch", "cursor": abandoned_cursor}})
        await asyncio.sleep(.15)  # Exercise cancellation after the handler starts.
        await abandoned.notify("notifications/cancelled", {"requestId": pending, "reason": "fixture disconnect"})
        # A cancelled JSON-RPC request must not later emit a tool result on this
        # connection. Read briefly, then use the same connection and cursor.
        try:
            line = await asyncio.wait_for(abandoned.process.stdout.readline(), .2)
        except TimeoutError:
            pass
        else:
            raise AssertionError(f"cancelled watch emitted a response: {line!r}")
        follow_up, _ = await abandoned.tool("read_messages", {"chatID": "chat-watch", "limit": 1})
        assert not follow_up.get("isError") and pending not in abandoned.responses
        append_arrival("after-cancellation", "visible after cancellation")
        _, after_cancel = await asyncio.wait_for(abandoned.tool("watch_messages", {"chatID": "chat-watch", "cursor": abandoned_cursor, "waitSeconds": 1}), 3)
        assert after_cancel["status"] == "messages"
        assert [row["id"] for row in after_cancel["page"]["messages"]] == ["after-cancellation"]
        assert pending not in abandoned.responses
        try:
            line = await asyncio.wait_for(abandoned.process.stdout.readline(), .2)
        except TimeoutError:
            pass
        else:
            raise AssertionError(f"cancelled wait emitted data or closed the connection after arrival: {line!r}")

        disconnected = Client()
        clients.append(disconnected)
        await disconnected.start()
        disconnected_cursor = await establish(disconnected)
        await disconnected.begin("tools/call", {"name": "watch_messages", "arguments": {"chatID": "chat-watch", "cursor": disconnected_cursor, "waitSeconds": 20}})
        await disconnected.close()
        fresh = Client()
        clients.append(fresh)
        await fresh.start()
        fresh_cursor = await establish(fresh)
        append_arrival("after-disconnect", "visible after disconnect")
        _, after = await asyncio.wait_for(fresh.tool("watch_messages", {"chatID": "chat-watch", "cursor": fresh_cursor, "waitSeconds": 1}), 3)
        assert after["status"] == "messages" and [row["id"] for row in after["page"]["messages"]] == ["after-disconnect"]
        record("cancelled and disconnected waits release the socket session")

        defaults = Client()
        clients.append(defaults)
        await defaults.start()
        defaults_cursor = await establish(defaults)
        for number in range(51):
            append_arrival(f"default-limit-{number}", "default limit arrival")
        _, default_page = await defaults.tool("watch_messages", {"chatID": "chat-watch", "cursor": defaults_cursor})
        assert default_page["status"] == "messages" and len(default_page["page"]["messages"]) == 50
        assert [row["id"] for row in default_page["page"]["messages"]] == [f"default-limit-{number}" for number in range(50)]
        record("omitted limit returns the documented 50-record page")
    finally:
        for client in clients:
            await client.close()
        server.stdin.close()
        await server.stdin.wait_closed()
        try:
            await asyncio.wait_for(server.wait(), 10)
        except TimeoutError:
            server.kill()
            await server.wait()
        assert server.returncode == 0, (await server.stderr.read()).decode()


if __name__ == "__main__":
    asyncio.run(main())
