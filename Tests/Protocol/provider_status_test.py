"""Raw provider fields through real read/search MCP; synthetic SQLite only."""
import asyncio
import shutil
import sqlite3
import sys
import uuid

sys.dont_write_bytecode = True
import client_test as base

FIELDS = ("isSent", "isDelivered", "deliveryErrorCode")


async def check_present(client, _initialization):
    read = base.content(await client.call_tool("read_messages", {"chatID": "chat-direct", "limit": 100}))
    search = base.content(await client.call_tool("search_messages", {"query": "status", "chatID": "chat-direct", "limit": 100}))
    read_rows = {row["id"]: row for row in read["messages"]}
    search_rows = {row["id"]: row for row in search["messages"]}
    expected = {
        "message-old": (False, False, 0),
        "message-attributed": (True, True, 0),
        "message-attachment": (False, False, 25),
    }
    for identity, values in expected.items():
        for rows in (read_rows, search_rows):
            assert tuple(rows[identity][field] for field in FIELDS) == values
    for rows in (read_rows, search_rows):
        unknown = rows["edited-retracted"]
        assert all(field not in unknown for field in FIELDS)
        attachment = rows["message-attachment"]["attachments"][0]
        assert attachment["availability"] == "available"
        assert attachment["transferState"] == 6
    assert read_rows["message-attachment"]["attachments"] == search_rows["message-attachment"]["attachments"]
    args = {"messageID": "message-attachment", "attachmentID": read_rows["message-attachment"]["attachments"][0]["id"]}
    for tool in ("read_attachment", "read_image"):
        retrieved = await client.call_tool(tool, args)
        assert not retrieved.isError, (tool, base.content(retrieved))
        assert base.content(retrieved)["metadata"]["transferState"] == 6
    base.record("read/search preserve raw zero/nonzero/NULL provider values and independent availability")


async def check_missing(client, _initialization):
    for name, args in [
        ("read_messages", {"chatID": "chat-direct", "limit": 100}),
        ("search_messages", {"query": "status", "chatID": "chat-direct", "limit": 100}),
    ]:
        result = base.content(await client.call_tool(name, args))
        assert result["messages"]
        for row in result["messages"]:
            assert all(field not in row for field in FIELDS)
            for attachment in row["attachments"]:
                assert "transferState" not in attachment
    row = next(row for row in result["messages"] if row["id"] == "message-attachment")
    args = {"messageID": row["id"], "attachmentID": row["attachments"][0]["id"]}
    for tool in ("read_attachment", "read_image"):
        retrieved = await client.call_tool(tool, args)
        assert not retrieved.isError, (tool, base.content(retrieved))
        assert "transferState" not in base.content(retrieved)["metadata"]
    base.record("missing source columns remain unknown in read/search and attachment/image metadata")


async def main():
    root = base.ROOT / ".scratch" / f"provider-status-{uuid.uuid4()}"
    root.mkdir(parents=True)
    base.STATE_DIRECTORY = root / "state"
    base.DATABASE = root / "chat.sqlite"
    try:
        base.build_database()
        attachment = root / "synthetic.png"
        attachment.write_bytes((base.ROOT / "Tests/Fixtures/Attachments/red.png").read_bytes())
        with sqlite3.connect(base.DATABASE) as db:
            db.executescript("""
                ALTER TABLE message ADD COLUMN is_sent INTEGER;
                ALTER TABLE message ADD COLUMN is_delivered INTEGER;
                ALTER TABLE message ADD COLUMN error INTEGER;
                ALTER TABLE attachment ADD COLUMN transfer_state INTEGER;
                UPDATE message SET text='status zero', is_sent=0, is_delivered=0, error=0 WHERE ROWID=1;
                UPDATE message SET text='status delivered', is_sent=1, is_delivered=1, error=0 WHERE ROWID=2;
                UPDATE message SET text='status file', is_sent=0, is_delivered=0, error=25 WHERE ROWID=5;
                UPDATE message SET text='status unknown' WHERE ROWID=9;
                UPDATE attachment SET transfer_state=6;
            """)
            db.execute("UPDATE attachment SET filename=?, transfer_name='synthetic.png', mime_type='image/png'", (str(attachment),))
        await base.with_client(base.server_parameters(), check_present)
        with sqlite3.connect(base.DATABASE) as db:
            for column in ("is_sent", "is_delivered", "error"):
                db.execute(f"ALTER TABLE message DROP COLUMN {column}")
            db.execute("ALTER TABLE attachment DROP COLUMN transfer_state")
        await base.with_client(base.server_parameters(), check_missing)
    finally:
        shutil.rmtree(root)
    print("All synthetic provider-status MCP checks passed.")


if __name__ == "__main__":
    asyncio.run(main())
