"""Production framed relay over real pipes/private Unix sockets; inert fault injection."""
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get('MESSAGES_BRIDGE_TEST_BINARY', ROOT / '.build/debug/MCPBridgeTestClient')).resolve()
SCRATCH = ROOT / '.scratch'
SCRATCH.mkdir(exist_ok=True)
INIT = {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'test', 'version': '1'}}}
RESULT = {'protocolVersion': '2025-06-18', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'fixture', 'version': '1'}}

def wire(obj):
    return json.dumps(obj, separators=(',', ':')).encode() + b'\n'

def request(i, name='read_messages', **args):
    return {'jsonrpc': '2.0', 'id': i, 'method': 'tools/call', 'params': {'name': name, 'arguments': args}}

class Peer:
    def __init__(self, conn):
        self.conn = conn
        self.data = b''
    def receive(self):
        while b'\n' not in self.data:
            chunk = self.conn.recv(65536)
            assert chunk, 'unexpected EOF'
            self.data += chunk
        line, self.data = self.data.split(b'\n', 1)
        return json.loads(line)
    def send(self, obj):
        self.conn.sendall(wire(obj))
    def initialize(self):
        assert self.receive() == INIT
        self.send({'jsonrpc': '2.0', 'id': 1, 'result': RESULT})
        assert self.receive()['method'] == 'notifications/initialized'

class Client:
    def __init__(self, p):
        self.p = p
        self.data = b''
    def send(self, obj):
        self.p.stdin.write(wire(obj)); self.p.stdin.flush()
    def receive(self, timeout=8):
        while b'\n' not in self.data:
            assert select.select([self.p.stdout], [], [], timeout)[0], 'response timed out'
            chunk = os.read(self.p.stdout.fileno(), 65536)
            assert chunk, 'stdio unexpectedly closed'
            self.data += chunk
        line, self.data = self.data.split(b'\n', 1)
        return json.loads(line)
    def initialize(self):
        self.send(INIT)
        assert self.receive()['result'] == RESULT
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=3)
        assert self.p.returncode == 0

def run_case(name, serve, interact):
    with tempfile.TemporaryDirectory(prefix='bridge-', dir=SCRATCH) as base:
        runtime = Path(base) / 'rt'; runtime.mkdir(mode=0o700)
        listener = socket.socket(socket.AF_UNIX)
        old = os.getcwd()
        try:
            os.chdir(runtime); listener.bind('mcp.sock'); os.chmod('mcp.sock', 0o600)
        finally:
            os.chdir(old)
        listener.listen(); listener.settimeout(10)
        failures = []
        def accept():
            conn, _ = listener.accept(); conn.settimeout(30)
            return conn
        def work():
            try: serve(accept)
            except BaseException as e: failures.append(e)
        thread = threading.Thread(target=work, daemon=True); thread.start()
        p = subprocess.Popen([str(BINARY), 'mcp.sock'], cwd=runtime, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try: interact(Client(p))
        finally:
            if p.poll() is None: p.kill()
            p.wait(timeout=3); listener.close(); thread.join(timeout=12)
        assert not thread.is_alive(), 'server leaked'
        assert not failures, repr(failures)
        assert p.stderr.read() == b''
    print('PASS ' + name)

closed = threading.Event()
def idle_server(accept):
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
    closed.set()
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
        assert peer.receive() == request(2)
        peer.send({'jsonrpc': '2.0', 'id': 2, 'result': {'ok': True}})
        assert conn.recv(1) == b''
def idle_client(c):
    c.initialize(); assert closed.wait(5)
    c.send(request(2)); assert c.receive() == {'jsonrpc': '2.0', 'id': 2, 'result': {'ok': True}}
    c.close()
run_case('idle app restart retains client and reinitializes backend', idle_server, idle_client)

# A long-lived stdio owner can carry distinct logical MCP clients. An idle
# second initialize creates a fresh backend socket rather than weakening the
# SDK's duplicate-initialize guard.
def logical_session_server(accept):
    with accept() as conn:
        Peer(conn).initialize()
        assert conn.recv(1) == b''
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
        assert peer.receive() == request(2)
        peer.send({'jsonrpc': '2.0', 'id': 2, 'result': {'secondSession': True}})
        assert conn.recv(1) == b''
def logical_session_client(c):
    c.initialize(); c.initialize()
    c.send(request(2)); assert c.receive()['result'] == {'secondSession': True}
    c.close()
run_case('idle repeated initialize creates a fresh backend session', logical_session_server, logical_session_client)

# Losing an initial handshake must not permanently block a later explicit one.
def failed_initial_server(accept):
    with accept() as conn:
        assert Peer(conn).receive() == INIT
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
        assert peer.receive() == request(2)
        peer.send({'jsonrpc': '2.0', 'id': 2, 'result': {'ready': True}})
        assert conn.recv(1) == b''
def failed_initial_client(c):
    c.send(INIT)
    assert c.receive()['error']['data']['disposition'] == 'outcome_unknown'
    c.initialize(); c.send(request(2)); assert c.receive()['result']['ready']
    c.close()
run_case('failed initialization permits a later explicit session', failed_initial_server, failed_initial_client)

# Do not rotate an active backend: a send already submitted to it remains
# uncertain if disconnected, and this bridge must still deliver its response.
outstanding_started = threading.Event()
outstanding_rejected = threading.Event()
def outstanding_initialize_server(accept):
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
        assert peer.receive() == request(2, 'send_message')
        outstanding_started.set()
        assert outstanding_rejected.wait(5)
        peer.send({'jsonrpc': '2.0', 'id': 2, 'result': {'oldSession': True}})
        assert peer.receive() == request(3)
        peer.send({'jsonrpc': '2.0', 'id': 3, 'result': {'stillConnected': True}})
        assert conn.recv(1) == b''
def outstanding_initialize_client(c):
    c.initialize(); c.send(request(2, 'send_message')); assert outstanding_started.wait(5)
    c.send(INIT)
    rejected = c.receive(); assert rejected['id'] == 1 and rejected['error']['code'] == -32600
    assert 'active' in rejected['error']['message']
    outstanding_rejected.set()
    assert c.receive() == {'jsonrpc': '2.0', 'id': 2, 'result': {'oldSession': True}}
    c.send(request(3)); assert c.receive()['result'] == {'stillConnected': True}
    c.close()
run_case('active request rejects repeated initialize and preserves its response', outstanding_initialize_server, outstanding_initialize_client)

# A partially written attachment-sized request is active even before the app
# receives its full JSON frame. Its later initialize must be rejected locally.
partial_write_started = threading.Event()
def partial_write_initialize_server(accept):
    with accept() as conn:
        Peer(conn).initialize()
        prefix = conn.recv(65_536)
        assert prefix and b'\n' not in prefix
        partial_write_started.set()
        while conn.recv(65_536): pass
def partial_write_initialize_client(c):
    c.initialize(); c.send(request(2, 'send_message', text='x' * (12 * 1024 * 1024)))
    assert partial_write_started.wait(5)
    c.send(INIT)
    rejected = c.receive(); assert rejected['id'] == 1 and rejected['error']['code'] == -32600
    assert 'active' in rejected['error']['message']
    c.close()
run_case('partially written request rejects repeated initialize without rotating backend', partial_write_initialize_server, partial_write_initialize_client)

for partial in (False, True):
    effects = []
    def interrupted_server(accept):
        with accept() as conn:
            peer = Peer(conn); peer.initialize()
            assert peer.receive() == request(2, 'send_message')
            effects.append('sent')
            if partial: conn.sendall(b'{"jsonrpc":"2.0","id":2,"result":{"text":"partial')
        with accept() as conn:
            peer = Peer(conn); peer.initialize()
            assert peer.receive() == request(3)
            peer.send({'jsonrpc': '2.0', 'id': 3, 'result': {'ok': True}})
            assert conn.recv(1) == b''
    def interrupted_client(c):
        c.initialize(); c.send(request(2, 'send_message'))
        result = c.receive(); assert result['id'] == 2 and 'unknown' in result['error']['message']
        assert result['error']['data']['disposition'] == 'outcome_unknown'
        c.send(request(3)); assert c.receive()['id'] == 3
        c.close()
    run_case('interrupted send, no replay, partial response=' + str(partial), interrupted_server, interrupted_client)
    assert effects == ['sent']

# A complete attachment-sized response must survive framing and partial writes.
large = 'x' * (12 * 1024 * 1024 + 17)
def large_server(accept):
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
        assert peer.receive() == request(2, payload=large)
        encoded = wire({'jsonrpc': '2.0', 'id': 2, 'result': {'data': large}})
        for offset in range(0, len(encoded), 7919): conn.sendall(encoded[offset:offset + 7919])
        assert conn.recv(1) == b''
def large_client(c):
    c.initialize(); c.send(request(2, payload=large))
    assert c.receive(timeout=30)['result']['data'] == large
    c.close()
run_case('12 MiB request and response preserve complete JSON across partial writes', large_server, large_client)

watch_started = threading.Event()
def cancel_server(accept):
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
        assert peer.receive() == request(2, 'watch_messages')
        watch_started.set()
        assert peer.receive() == {'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': 2}}
        assert peer.receive() == request(131)
        peer.send({'jsonrpc': '2.0', 'id': 131, 'result': {}})
        assert conn.recv(1) == b''
def cancel_client(c):
    c.initialize(); c.send(request(2, 'watch_messages')); assert watch_started.wait(5)
    c.send({'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': 2}})
    c.send(request(131)); assert c.receive()['result'] == {}
    c.close()
run_case('cancellation forwarded and stdin EOF closes backend', cancel_server, cancel_client)

waiting = threading.Event()
handshake_started = threading.Event()
def handshake_eof_server(accept):
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
    waiting.set()
    with accept() as conn:
        assert Peer(conn).receive() == INIT
        handshake_started.set()
        assert conn.recv(1) == b''
def handshake_eof_client(c):
    c.initialize(); assert waiting.wait(5)
    c.send(request(2)); assert handshake_started.wait(5); c.close()
run_case('stdin EOF during reconnect handshake exits promptly', handshake_eof_server, handshake_eof_client)

# Close while only a prefix of a large send request reached the app. The next
# connection must receive initialization and the new read, never remaining bytes.
def write_loss_server(accept):
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
        prefix = conn.recv(1024)
        assert prefix and b'\n' not in prefix
        conn.shutdown(socket.SHUT_RDWR)
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
        assert peer.receive() == request(3)
        peer.send({'jsonrpc': '2.0', 'id': 3, 'result': {}})
        assert conn.recv(1) == b''
def write_loss_client(c):
    c.initialize(); c.send(request(2, 'send_message', text=large))
    assert c.receive()['error']['data']['disposition'] == 'outcome_unknown'
    c.send(request(3)); assert c.receive()['result'] == {}
    c.close()
run_case('backend loss mid-request write discards remainder without replay', write_loss_server, write_loss_client)

for mode in ('timeout', 'mismatch', 'EOF'):
    reconnect_ready = threading.Event()
    def bad_handshake_server(accept):
        with accept() as conn:
            Peer(conn).initialize()
        reconnect_ready.set()
        with accept() as conn:
            peer = Peer(conn); assert peer.receive() == INIT
            if mode == 'mismatch':
                peer.send({'jsonrpc': '2.0', 'id': 1, 'result': {**RESULT, 'capabilities': {}}})
            if mode != 'EOF': assert conn.recv(1) == b''
        with accept() as conn:
            peer = Peer(conn); peer.initialize()
            assert peer.receive() == request(3)
            peer.send({'jsonrpc': '2.0', 'id': 3, 'result': {}})
            assert conn.recv(1) == b''
    def bad_handshake_client(c):
        c.initialize(); assert reconnect_ready.wait(5)
        c.send(request(2)); assert c.receive()['error']['data']['disposition'] == 'not_submitted'
        c.send(request(3)); assert c.receive()['result'] == {}
        c.close()
    run_case('failed reinitialization ' + mode + ' fails only new request and permits later connection', bad_handshake_server, bad_handshake_client)

with tempfile.TemporaryDirectory(prefix='bridge-', dir=SCRATCH) as base:
    runtime = Path(base) / 'rt'; runtime.mkdir(mode=0o700)
    for kind in ('missing', 'file', 'symlink'):
        path = runtime / 'mcp.sock'
        if kind == 'file': path.write_text('preserve me'); path.chmod(0o600)
        if kind == 'symlink': path.symlink_to('missing-target')
        p = subprocess.Popen([str(BINARY), 'mcp.sock'], cwd=runtime, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        c = Client(p); c.send(INIT)
        assert c.receive()['error']['data']['disposition'] == 'not_submitted'
        assert p.poll() is None
        c.close()
        if kind == 'file': assert path.read_text() == 'preserve me'; path.unlink()
        if kind == 'symlink': assert path.is_symlink(); path.unlink()
print('PASS unavailable and unsafe endpoints return error without exiting or modifying endpoint')

reused_done = threading.Event()
def reused_server(accept):
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
        assert peer.receive() == request(1)
        peer.send({'jsonrpc': '2.0', 'id': 1, 'result': {'tool': True}})
        assert peer.receive() == request('second')
        conn.sendall(wire({'jsonrpc': '2.0', 'id': 'second', 'result': {'complete': True}}) + b'{"partial":')
    reused_done.set()
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
        assert peer.receive() == request('after')
        peer.send({'jsonrpc': '2.0', 'id': 'after', 'result': {}})
        assert conn.recv(1) == b''
def reused_client(c):
    c.initialize(); c.send(request(1)); assert c.receive()['result']['tool']
    c.send(request('second')); assert c.receive()['result']['complete']
    assert reused_done.wait(5)
    c.send(request('after')); assert c.receive()['result'] == {}
    c.close()
run_case('reused and string IDs retain handshake; complete response drains before partial EOF', reused_server, reused_client)

saturated_started = threading.Event()
def saturated_server(accept):
    with accept() as conn:
        peer = Peer(conn); peer.initialize()
        for i in range(2, 130): assert peer.receive() == request(i)
        saturated_started.set()
        assert peer.receive() == {'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': 2}}
        assert peer.receive() == request(131)
        peer.send({'jsonrpc': '2.0', 'id': 131, 'result': {}})
        assert conn.recv(1) == b''
def saturated_client(c):
    c.initialize()
    for i in range(2, 131): c.send(request(i))
    overload = c.receive(); assert overload['id'] == 130 and 'not submitted' in overload['error']['message']
    assert saturated_started.wait(5)
    c.send({'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': 2}})
    c.send(request(131)); assert c.receive()['result'] == {}
    c.close()
run_case('bounded in-flight capacity rejects excess without blocking cancellation or EOF', saturated_server, saturated_client)

for extra in (False, True):
    app_closed = threading.Event()
    restoring = threading.Event()
    controls_written = threading.Event()
    effects = []
    def cancelled_restore_server(accept):
        with accept() as conn: Peer(conn).initialize()
        app_closed.set()
        with accept() as conn:
            peer = Peer(conn); assert peer.receive() == INIT
            restoring.set(); assert controls_written.wait(5)
            peer.send({'jsonrpc': '2.0', 'id': 1, 'result': RESULT})
            assert peer.receive()['method'] == 'notifications/initialized'
            while True:
                message = peer.receive()
                if message.get('method') == 'tools/call':
                    if message['params']['name'] == 'send_message': effects.append('sent')
                    peer.send({'jsonrpc': '2.0', 'id': message['id'], 'result': {}})
                    if message['id'] == 10: break
            assert conn.recv(1) == b''
    def cancelled_restore_client(c):
        c.initialize(); assert app_closed.wait(5)
        c.send(request(2, 'send_message'))
        assert restoring.wait(5)
        # Place ordinary queued work before the cancellation, including a frame
        # larger than one input read. Control processing must reach past it.
        batch = b''
        if extra:
            batch += wire(request(3, payload='q' * 100000)) + wire(request(4))
        batch += wire({'jsonrpc': '2.0', 'method': 'notifications/cancelled', 'params': {'requestId': 2}})
        batch += wire(request(10))
        c.p.stdin.write(batch); c.p.stdin.flush(); controls_written.set()
        expected = [3, 4, 10] if extra else [10]
        assert [c.receive()['id'] for _ in expected] == expected
        c.close()
    run_case('cancel during restoration never submits send; queued work ahead=' + str(extra), cancelled_restore_server, cancelled_restore_client)
    assert effects == []

for during_handshake in (False, True):
    app_closed = threading.Event()
    restoring = threading.Event()
    stale_written = threading.Event()
    def stale_server(accept):
        with accept() as conn:
            peer = Peer(conn); peer.initialize()
            assert peer.receive() == request(90)
        app_closed.set()
        with accept() as conn:
            peer = Peer(conn); assert peer.receive() == INIT
            restoring.set(); assert stale_written.wait(5)
            peer.send({'jsonrpc': '2.0', 'id': 1, 'result': RESULT})
            assert peer.receive()['method'] == 'notifications/initialized'
            assert peer.receive() == request(2)
            peer.send({'jsonrpc': '2.0', 'id': 2, 'result': {}})
            assert peer.receive() == request(3), 'old-session traffic reached new backend'
            peer.send({'jsonrpc': '2.0', 'id': 3, 'result': {}})
            assert conn.recv(1) == b''
    def stale_client(c):
        c.initialize(); c.send(request(90))
        assert c.receive()['error']['data']['disposition'] == 'outcome_unknown'
        assert app_closed.wait(5)
        stale = wire({'jsonrpc': '2.0', 'id': 'old-server-request', 'result': {'stale': True}})
        stale += wire({'jsonrpc': '2.0', 'method': 'notifications/roots/list_changed'})
        stale += wire({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        if during_handshake:
            c.send(request(2)); assert restoring.wait(5)
            c.p.stdin.write(stale); c.p.stdin.flush()
        else:
            c.p.stdin.write(wire(request(2)) + stale); c.p.stdin.flush()
        stale_written.set()
        assert c.receive()['id'] == 2
        c.send(request(3)); assert c.receive()['id'] == 3
        c.close()
    run_case('discard old responses/notifications during restoration=' + str(during_handshake), stale_server, stale_client)
