"""Real stdio MCP adapter against an inert, recording sender; no Messages access."""
import asyncio
import json
import shutil
import uuid
from pathlib import Path
import sys

sys.dont_write_bytecode = True
import client_test as base


async def checks(client, initialization):
    listed = {tool.name: tool for tool in (await client.list_tools()).tools}
    send = listed["send_message"]
    route = listed["resolve_send_route"]
    assert send.annotations.readOnlyHint is False
    assert send.annotations.idempotentHint is False
    assert send.annotations.openWorldHint is True
    assert route.annotations.readOnlyHint is True
    assert route.inputSchema["required"] == []
    assert route.inputSchema["properties"]["recipients"]["minItems"] == 1
    assert route.inputSchema["properties"]["recipients"]["maxItems"] == 1
    assert send.inputSchema["properties"]["recipients"]["minItems"] == 1
    assert send.inputSchema["properties"]["recipients"]["maxItems"] == 1
    assert "Drafting never calls" in initialization.instructions
    assert "confirmation" in send.description
    assert "approved" not in send.inputSchema["properties"]
    log = base.STATE_DIRECTORY / "send-invocations.jsonl"
    await client.call_tool("find_chats", {"query": "Alice Example"})
    await client.call_tool("read_messages", {"chatID": "chat-direct"})
    await client.call_tool("set_chat_alias", {"chatID": "chat-group", "alias": "Synthetic family"})
    await client.call_tool("find_chats", {"query": "Synthetic family"})
    assert not log.exists(), "draft preparation dispatched a message"
    base.record("draft preparation and advertised client confirmation guidance")

    direct_route = base.content(await client.call_tool("resolve_send_route", {"chatID": "chat-direct"}))
    assert direct_route["kind"] == "direct"
    assert direct_route["destination"]["chatID"] == "chat-direct"
    assert direct_route["suggestionBasis"] == "no_history"
    assert direct_route.get("suggestedService") is None
    assert isinstance(direct_route["serviceOptions"], list)
    group_route = base.content(await client.call_tool("resolve_send_route", {"chatID": "chat-group"}))
    assert group_route["kind"] == "group"
    assert group_route["destination"]["chatID"] == "chat-group"
    assert group_route.get("suggestedService") is None
    assert group_route["serviceOptions"] == []
    recipient_route = base.content(await client.call_tool("resolve_send_route", {
        "recipients": [{"query": "new@example.test"}]
    }))
    assert recipient_route["kind"] == "direct"
    assert recipient_route["destination"].get("chatID") is None
    assert recipient_route["destination"]["recipients"][0]["handle"] == "new@example.test"
    base.record("read-only direct and group route resolution exposes an honest suggestion basis")

    for args in [
        {"chatID": "chat-direct", "text": "x", "approved": True},
        {"chatID": "chat-direct", "files": None},
        {"chatID": "chat-direct", "text": ""},
        {"recipients": [{"query": "Alice"}], "service": "auto", "text": "x"},
        {"recipients": []},
        {"recipients": [{"query": "a@example.test"}, {"query": "b@example.test"}]},
    ]:
        await base.assert_invalid_params(client, "send_message", args)
    for args in [
        {"recipients": []},
        {"recipients": [{"query": "a@example.test"}, {"query": "b@example.test"}]},
        {"chatID": "chat-direct", "unexpected": True},
    ]:
        await base.assert_invalid_params(client, "resolve_send_route", args)
    for args, code in [
        ({"text": "x"}, "invalid_send_destination"),
        ({"chatID": "chat-direct", "recipients": [{"query": "Alice"}], "text": "x"}, "invalid_send_destination"),
        ({"chatID": "chat-group", "service": "iMessage", "text": "x"}, "invalid_send_destination"),
        ({"chatID": "chat-direct"}, "invalid_send_content"),
        ({"chatID": "missing", "text": "x"}, "chat_not_found"),
        ({"chatID": "chat-direct", "service": "iMessage", "files": [str(base.STATE_DIRECTORY / "missing")]}, "invalid_send_file"),
    ]:
        result = await client.call_tool("send_message", args)
        assert result.isError and base.content(result)["error"]["code"] == code
    assert not log.exists()
    base.record("send schema/domain validation dispatches nothing")

    ambiguous = base.content(await client.call_tool("send_message", {
        "recipients": [{"query": "Example"}], "service": "iMessage", "text": "x"
    }))
    assert ambiguous["status"] == "needs_choice" and len(ambiguous["contactCandidates"]) == 2
    assert not log.exists()
    base.record("ambiguous recipients stay choices at MCP boundary")

    files = [base.STATE_DIRECTORY / "α quoted ' one.txt", base.STATE_DIRECTORY / 'two " file.txt']
    for index, path in enumerate(files):
        path.write_text(f"Synthetic file {index}\n", encoding="utf-8")
    # Let macOS finish fresh-file metadata before production captures identity.
    for path in files:
        path.read_bytes()
    await asyncio.sleep(0.5)
    text = 'Synthetic “hello” 👨‍👩‍👧‍👦\n"quoted" \\ path; do shell script "false"'
    result = base.content(await client.call_tool("send_message", {
        "chatID": "chat-group", "text": text, "files": [str(path) for path in files]
    }))
    assert result["status"] == "sent" and result["delivery"] == "unconfirmed"
    assert [part["outcome"] for part in result["parts"]] == ["sent"] * 3
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    assert (calls[0]["target"], calls[0]["kind"], calls[0]["value"]) == ("chat-group", "text", text)
    for index, original in enumerate(files):
        row = calls[index + 1]
        staged = Path(row["value"])
        assert row["target"] == "chat-group" and row["kind"] == "file"
        assert staged != original and staged.is_relative_to(base.STATE_DIRECTORY / "outgoing")
        assert staged.name == original.name and staged.read_bytes() == original.read_bytes()
    assert Path(calls[1]["value"]).parent.parent == Path(calls[2]["value"]).parent.parent
    base.record("exact existing group plus Unicode text and multi-file ordering")

    automatic = base.content(await client.call_tool("send_message", {
        "chatID": "chat-direct", "text": "automatic synthetic message"
    }))
    assert automatic["status"] == "sent"
    assert automatic["attempts"][0]["service"] == "iMessage"
    assert automatic["attempts"][0]["part"]["outcome"] == "sent"
    base.record("automatic transport without route preflight or service at MCP boundary")

    direct = base.content(await client.call_tool("send_message", {
        "recipients": [{"query": "new@example.test"}], "service": "iMessage", "text": "new synthetic"
    }))
    assert direct["destination"]["recipients"][0]["handle"] == "new@example.test"
    assert direct["status"] == "unknown"
    last = json.loads(log.read_text().splitlines()[-1])
    assert last["target"] == "new@example.test" and last["service"] == "iMessage"
    base.record("new individual explicit service adapter route")

    failed = await client.call_tool("send_message", {
        "chatID": "chat-direct", "service": "iMessage", "text": "fixture-source-failed"
    })
    failed_content = base.content(failed)
    assert failed.isError and failed_content["status"] == "failed"
    assert failed_content["parts"][0]["outcome"] == "failed"
    assert failed_content["parts"][0]["deliveryErrorCode"] == 22
    assert failed_content["parts"][0]["correlation"] == "unique_source_match"
    base.record("accepted script submission with source error is an MCP tool failure")

    for marker, expected, part in [("fixture-unknown", "unknown", "unknown"), ("fixture-rejected", "partial", "failed")]:
        stopping = base.STATE_DIRECTORY / f"{marker}.txt"
        stopping.write_text("Synthetic failure injection\n")
        stopping.read_bytes()
        await asyncio.sleep(0.5)
        before = len(log.read_text().splitlines())
        result = base.content(await client.call_tool("send_message", {
            "chatID": "chat-direct", "service": "iMessage", "text": "first accepted", "files": [str(stopping), str(files[0])]
        }))
        assert result["status"] == expected and result["delivery"] == "unconfirmed"
        assert [part["outcome"] for part in result["parts"]] == ["sent", part, "not_attempted"]
        lines = log.read_text().splitlines()
        assert len(lines) == before + 2
        staged = Path(json.loads(lines[-1])["value"])
        assert staged.name == stopping.name
        assert staged.exists() == (expected == "unknown")
        if expected == "unknown":
            assert staged.read_bytes() == stopping.read_bytes()
            assert not (staged.parent.parent / "1").exists(), "unattempted stage must be removed"
    base.record("partial and unknown stop remaining parts without retries")


async def main():
    root = base.ROOT / ".scratch" / f"send-protocol-{uuid.uuid4()}"
    root.mkdir(parents=True)
    base.STATE_DIRECTORY = root / "state"
    base.DATABASE = root / "chat.sqlite"
    try:
        base.build_database()
        await base.with_client(base.server_parameters(), checks)
    finally:
        shutil.rmtree(root)
    print("All synthetic send MCP checks passed; no live send or client-consent proof claimed.")


if __name__ == "__main__":
    asyncio.run(main())
