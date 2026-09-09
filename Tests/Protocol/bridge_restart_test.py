"""Real Swift MCP SDK/app composition restart; synthetic SQLite only."""
import asyncio
import os
from pathlib import Path
import watch_test as fixture

# A deep worktree path cannot fit sockaddr_un. The caller may supply a short,
# task-owned scratch pathname; both immediate parent directories must be private.
fixture.SOCKET = Path(os.environ.get('MESSAGES_RESTART_TEST_SOCKET', fixture.ROOT / '.scratch/rs/r/s'))
fixture.SCRATCH = fixture.ROOT / '.scratch/restart-protocol'
fixture.DATABASE = fixture.SCRATCH / 'messages.sqlite'
fixture.STATE = fixture.SCRATCH / 'state'

async def start_server():
    server = await asyncio.create_subprocess_exec(
        str(fixture.SERVER), '--database', str(fixture.DATABASE),
        '--state-directory', str(fixture.STATE), '--socket', str(fixture.SOCKET),
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    assert await asyncio.wait_for(server.stdout.readline(), 15) == b'ready\n', (await server.stderr.read()).decode()
    return server

async def stop(server):
    server.stdin.close()
    await asyncio.wait_for(server.wait(), 5)
    assert server.returncode == 0

async def main():
    fixture.build_database()
    for directory in (fixture.SOCKET.parent.parent, fixture.SOCKET.parent):
        directory.mkdir(mode=0o700, exist_ok=True); directory.chmod(0o700)
    fixture.SOCKET.unlink(missing_ok=True)
    client = fixture.Client()
    server = await start_server()
    try:
        await client.start()
        pid = client.process.pid
        cursor = await fixture.establish(client)
        await stop(server)
        server = await start_server()
        tools = await asyncio.wait_for(client.request('tools/list', {}), 8)
        assert len(tools['result']['tools']) == 10
        assert client.process.pid == pid
        result, payload = await client.tool('watch_messages', {'chatID': 'chat-watch', 'cursor': cursor, 'waitSeconds': 0})
        assert result.get('isError'), payload
        assert 'cursor' in str(payload).lower(), payload
        await fixture.establish(client)
        print('PASS real Swift SDK reinitializes on same stdio process; old store cursor remains invalid')
        pending = await client.begin('tools/call', {'name': 'watch_messages', 'arguments': {'chatID': 'chat-watch', 'cursor': await fixture.establish(client), 'waitSeconds': 20}})
        # An independent response establishes the preceding watch reached the SDK.
        assert 'result' in await client.request('tools/list', {})
        await stop(server)
        interrupted = await asyncio.wait_for(client.response(pending), 3)
        assert interrupted['error']['code'] == -32000
        server = await start_server()
        await fixture.establish(client)
        assert client.process.pid == pid
        print('PASS active SDK watch interrupted honestly; later request restores backend without replay')
        for _ in range(130):
            request_id = await client.begin('tools/call', {'name': 'watch_messages', 'arguments': {'chatID': 'chat-watch', 'cursor': await fixture.establish(client), 'waitSeconds': 20}})
            await client.notify('notifications/cancelled', {'requestId': request_id})
        assert 'result' in await client.request('tools/list', {})
        print('PASS 130 SDK cancellations retire requests without requiring a response')
    finally:
        await client.close()
        if server.returncode is None: await stop(server)
        fixture.SOCKET.unlink(missing_ok=True)
        (fixture.SOCKET.parent / "mcp.lock").unlink(missing_ok=True)
        fixture.SOCKET.parent.rmdir(); fixture.SOCKET.parent.parent.rmdir()

asyncio.run(main())
