"""Actual relay-process checks against synthetic user-private Unix sockets."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get('MESSAGES_BRIDGE_TEST_BINARY', ROOT / '.build/debug/MCPBridgeTestClient'))
SCRATCH = ROOT / '.scratch'

def run_case(name, handler, interaction):
    with tempfile.TemporaryDirectory(prefix='br-', dir=SCRATCH) as base:
        runtime = Path(base) / 'rt'
        runtime.mkdir(mode=0o700)
        path = runtime / 'mcp.sock'
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(path))
        os.chmod(path, 0o600)
        listener.listen()
        listener.settimeout(8)
        failures = []
        def serve():
            try:
                conn, _ = listener.accept()
                with conn:
                    conn.settimeout(8)
                    handler(conn)
            except BaseException as error:
                failures.append(error)
        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        process = subprocess.Popen([str(BINARY), str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            interaction(process)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=8)
            listener.close()
            thread.join(timeout=8)
        assert not thread.is_alive(), 'Server did not terminate'
        assert not failures, repr(failures)
    print('PASS ' + name)

request = b'r' * (1024 * 1024 + 37)
response = b's' * (2 * 1024 * 1024 + 59)
def exchange(conn):
    chunks = []
    while True:
        block = conn.recv(4093)
        if not block:
            break
        chunks.append(block)
    assert b''.join(chunks) == request
    for offset in range(0, len(response), 7919):
        conn.sendall(response[offset:offset + 7919])
def full_exchange(process):
    out, err = process.communicate(request, timeout=15)
    assert process.returncode == 0 and out == response and not err
run_case('large partial-write duplex exchange and stdin half-close', exchange, full_exchange)

def close_app(conn):
    conn.sendall(b'final-response\n')
def open_stdin(process):
    # Keep stdin open: app EOF must still terminate the client.
    process.wait(timeout=8)
    assert process.returncode == 0
    assert process.stdout.read() == b'final-response\n'
    process.stdin.close()
run_case('app EOF exits bridge with stdin still open', close_app, open_stdin)

def reset_app(conn):
    conn.shutdown(socket.SHUT_RDWR)
def writing_at_exit(process):
    process.communicate(b'x' * 200000, timeout=8)
    assert process.returncode in (0, 1), 'Bridge terminated by a signal'
run_case('closed-peer write never kills bridge with SIGPIPE', reset_app, writing_at_exit)

with tempfile.TemporaryDirectory(prefix='br-', dir=SCRATCH) as base:
    runtime = Path(base) / 'rt'
    runtime.mkdir(mode=0o700)
    path = runtime / 'mcp.sock'
    path.write_text('preserve me')
    os.chmod(path, 0o600)
    result = subprocess.run([str(BINARY), str(path)], capture_output=True, timeout=8)
    assert result.returncode == 1 and path.read_text() == 'preserve me'
    path.unlink()
    destination = runtime / 'target'
    target_socket = socket.socket(socket.AF_UNIX)
    target_socket.bind(str(destination))
    os.chmod(destination, 0o600)
    target_socket.listen()
    path.symlink_to(destination)
    try:
        result = subprocess.run([str(BINARY), str(path)], capture_output=True, timeout=8)
        assert result.returncode == 1 and path.is_symlink()
    finally:
        target_socket.close()
print('PASS regular-file and symlink endpoints rejected without mutation')
