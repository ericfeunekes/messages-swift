"""Actual MCP bytes from synthetic SQLite/files; no native Messages or Contacts access.

Requires mcp==1.26.0 and Pillow==11.3.0. Pillow independently decodes the native
ImageIO output, including pixels, dimensions and format rather than trusting tags.
"""
import asyncio
import base64
import io
import json
import shutil
import sqlite3
import subprocess
from pathlib import Path

from PIL import Image
from mcp import StdioServerParameters
import client_test as fixture

ROOT = fixture.ROOT
DIRECTORY = ROOT / ".scratch/attachment-protocol"
fixture.DATABASE = DIRECTORY / "fixture.sqlite"
fixture.STATE_DIRECTORY = DIRECTORY / "state"
ORIGINALS = {}
PRIOR_FALLBACK = None


def prepare():
    DIRECTORY.mkdir(parents=True, exist_ok=True)
    fixture.build_database()
    for name in ("red.png", "oriented.jpg", "document.pdf", "report.dat"):
        shutil.copyfile(ROOT / "Tests/Fixtures/Attachments" / name, DIRECTORY / name)
    red = Image.new("RGB", (24, 12), (255, 0, 0))
    Image.new("RGB", (4096, 1024), (0, 255, 0)).save(DIRECTORY / "large.png")
    red.save(DIRECTORY / "animated.gif", save_all=True,
             append_images=[Image.new("RGB", red.size, (0, 0, 255))], duration=100, loop=0)
    (DIRECTORY / "bad.png").write_bytes(b"\x89PNG\r\n\x1a\nmalformed")
    (DIRECTORY / "limit.bin").write_bytes(bytes(range(256)) * (8 * 1024 * 1024 // 256))
    (DIRECTORY / "oversize.bin").write_bytes(b"x" * (8 * 1024 * 1024 + 1))
    symlink = DIRECTORY / "link.png"
    symlink.unlink(missing_ok=True)
    symlink.symlink_to(DIRECTORY / "red.png")
    with sqlite3.connect(fixture.DATABASE) as database:
        database.execute("ALTER TABLE attachment ADD COLUMN guid TEXT")
        for index, (name, mime, uti) in enumerate([
            ("red.png", "image/png", "public.png"),
            ("large.png", "image/png", "public.png"),
            ("animated.gif", "image/gif", "com.compuserve.gif"),
            ("oriented.jpg", "image/jpeg", "public.jpeg"),
            ("document.pdf", "application/pdf", "com.adobe.pdf"),
            ("report.dat", None, None),
            ("bad.png", "image/png", "public.png"),
            ("limit.bin", "application/octet-stream", None),
            ("oversize.bin", None, None),
            ("link.png", "image/png", "public.png"),
            ("missing.png", "image/png", "public.png"),
        ], start=2):
            path = DIRECTORY / name
            if name == "report.dat":
                stored = DIRECTORY / "opaque-storage"
                path.replace(stored)
                path = stored
            original = path.read_bytes() if path.is_file() else b""
            ORIGINALS[name] = original
            guid = "attachment:/%? 文" if name == "report.dat" else f"attachment-{name}"
            database.execute("INSERT INTO attachment (ROWID, guid, filename, transfer_name, mime_type, uti, total_bytes) VALUES (?, ?, ?, ?, ?, ?, ?)",
                             (index, guid, str(path), name, mime, uti, len(original)))
            database.execute("INSERT INTO message_attachment_join VALUES (?, ?)", (5, index))
        fallback = DIRECTORY / "fallback.txt"
        fallback.write_bytes(b"connection-scoped original")
        database.execute("INSERT INTO message (ROWID, guid, date, is_from_me, item_type) VALUES (10, NULL, 10000000000, 0, 0)")
        database.execute("INSERT INTO chat_message_join VALUES (1, 10)")
        database.execute("INSERT INTO attachment (ROWID, guid, filename, transfer_name, mime_type) VALUES (99, NULL, ?, 'fallback.txt', 'text/plain')", (str(fallback),))
        database.execute("INSERT INTO message_attachment_join VALUES (10, 99)")


async def checks(client, _initialization):
    global PRIOR_FALLBACK
    tools = {tool.name: tool for tool in (await client.list_tools()).tools}
    for name in ("read_image", "read_attachment"):
        assert tools[name].annotations.readOnlyHint is True
        assert tools[name].inputSchema["required"] == ["messageID", "attachmentID"]
        assert tools[name].inputSchema["additionalProperties"] is False
    page = fixture.content(await client.call_tool("read_messages", {"chatID": "chat-direct"}))
    message = next(row for row in page["messages"] if row["id"] == "message-attachment")
    attachments = {a["filename"]: a for a in message["attachments"]}
    fixture.record("attachment tools and real history metadata")
    fallback = next(row for row in page["messages"] if any(a["filename"] == "fallback.txt" for a in row["attachments"]))
    fallback_args = {"messageID": fallback["id"], "attachmentID": fallback["attachments"][0]["id"]}
    retrieved = await client.call_tool("read_attachment", fallback_args)
    assert not retrieved.isError
    assert base64.b64decode(retrieved.content[1].resource.blob, validate=True) == b"connection-scoped original"
    if PRIOR_FALLBACK is not None:
        rejected = await client.call_tool("read_attachment", PRIOR_FALLBACK)
        assert rejected.isError and fixture.content(rejected)["error"]["code"] == "attachment_not_found"
    PRIOR_FALLBACK = fallback_args
    fixture.record("history-issued fallback IDs retrieve bytes and reject another store's IDs")

    def arguments(name):
        return {"messageID": message["id"], "attachmentID": attachments[name]["id"]}

    for name, dimensions, pixel in [
        ("red.png", (24, 12), (255, 0, 0)),
        ("large.png", (2048, 512), (0, 255, 0)),
        ("animated.gif", (24, 12), (255, 0, 0)),
        ("oriented.jpg", (12, 24), None),
    ]:
        result = await client.call_tool("read_image", arguments(name))
        assert not result.isError, result
        assert str(DIRECTORY) not in json.dumps(result.model_dump(mode="json"))
        info = fixture.content(result)
        assert len(result.content) == 2 and result.content[1].type == "image"
        image_content = result.content[1]
        assert image_content.mimeType == "image/png" and info["mimeType"] == "image/png"
        raw = base64.b64decode(image_content.data, validate=True)
        image = Image.open(io.BytesIO(raw))
        image.load()
        assert image.format == "PNG" and image.size == dimensions
        assert (info["width"], info["height"]) == dimensions
        assert info["originalByteCount"] == len(ORIGINALS[name])
        assert info["returnedByteCount"] == len(raw)
        assert info["sourceByteLimit"] == 32 * 1024 * 1024
        assert info["returnedByteLimit"] == 8 * 1024 * 1024
        assert info["maxPixelDimension"] == 2048
        assert info["maxSourcePixelCount"] == 100_000_000
        assert info["frameIndex"] == 0
        if name == "animated.gif":
            assert info["frameCount"] == 2
        if pixel is not None:
            assert image.convert("RGB").getpixel((0, 0)) == pixel
        fixture.record(f"native image output independently decoded: {name}")

    for name, mime in [("document.pdf", "application/pdf"), ("report.dat", "application/octet-stream"),
                       ("red.png", "image/png"), ("limit.bin", "application/octet-stream")]:
        result = await client.call_tool("read_attachment", arguments(name))
        assert not result.isError, result
        assert str(DIRECTORY) not in json.dumps(result.model_dump(mode="json"))
        info = fixture.content(result)
        assert len(result.content) == 2 and result.content[1].type == "resource"
        resource = result.content[1].resource
        assert resource.mimeType == mime and info["mimeType"] == mime
        assert info["name"] == name
        assert str(resource.uri).startswith("messages-attachment:///")
        if name == "report.dat":
            assert str(resource.uri) == "messages-attachment:///message-attachment/attachment%3A%2F%25%3F%20%E6%96%87"
        assert str(DIRECTORY) not in str(resource.uri)
        assert base64.b64decode(resource.blob, validate=True) == ORIGINALS[name]
        assert info["returnedByteCount"] == len(ORIGINALS[name])
        assert info["sourceByteLimit"] == info["returnedByteLimit"] == 8 * 1024 * 1024
        fixture.record(f"complete original embedded resource: {name}")

    for tool, args, expected in [
        ("read_attachment", {**arguments("red.png"), "messageID": "message-old"}, "attachment_not_found"),
        ("read_attachment", {**arguments("red.png"), "attachmentID": "not-associated"}, "attachment_not_found"),
        ("read_attachment", arguments("missing.png"), "attachment_unavailable"),
        ("read_attachment", arguments("link.png"), "attachment_unsafe_file"),
        ("read_attachment", arguments("oversize.bin"), "attachment_too_large"),
        ("read_image", arguments("document.pdf"), "unsupported_image"),
        ("read_image", arguments("bad.png"), "invalid_image"),
    ]:
        result = await client.call_tool(tool, args)
        assert result.isError and fixture.content(result)["error"]["code"] == expected, result
        assert len(result.content) == 1
        assert str(DIRECTORY) not in json.dumps(result.model_dump(mode="json"))
    fixture.record("association, unavailable, unsafe, oversize, document and malformed failures")

    for tool in ("read_image", "read_attachment"):
        for args in ({"messageID": message["id"]}, {**arguments("red.png"), "path": str(DIRECTORY / "red.png")},
                     {**arguments("red.png"), "attachmentID": None}, {**arguments("red.png"), "messageID": ""}):
            await fixture.assert_invalid_params(client, tool, args)
    fixture.record("actual MCP rejects paths, missing, null and empty identifiers")


async def main():
    prepare()
    await fixture.with_client(fixture.server_parameters(reset_state=True), checks)
    # Exercise the app's actual local socket transport and the production relay
    # implementation with a synthetic operations owner, never the installed app.
    socket_root = ROOT / ".scratch/as"
    socket_root.mkdir(mode=0o700, exist_ok=True)
    socket_path = socket_root / "r/m.sock"
    parameters = fixture.server_parameters(reset_state=True)
    process = subprocess.Popen([parameters.command, *parameters.args, "--socket", str(socket_path)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        assert await asyncio.wait_for(asyncio.to_thread(process.stdout.readline), 15) == b"ready\n"
        bridge = ROOT / ".build/debug/MCPBridgeTestClient"
        await fixture.with_client(StdioServerParameters(command=str(bridge), args=[str(socket_path)]), checks)
        fixture.record("complete attachment journey through Unix socket and stdio relay")
    finally:
        process.stdin.close()
        try:
            await asyncio.wait_for(asyncio.to_thread(process.wait), 15)
        except TimeoutError:
            process.kill()
            process.wait()
        assert process.returncode == 0, process.stderr.read().decode()
    print("All attachment MCP checks passed with synthetic SQLite/files only.")


if __name__ == "__main__":
    asyncio.run(main())
