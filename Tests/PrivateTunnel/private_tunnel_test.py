#!/usr/bin/env python3
"""Inert contract checks for the local private-tunnel deployment helpers."""

import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / "scripts/install-private-tunnel.sh"
RUNTIME = ROOT / "scripts/private-tunnel/run-private-tunnel.sh"
WRAPPER = ROOT / "scripts/private-tunnel/messages-mcp-stdio.sh"
UNINSTALL = ROOT / "scripts/uninstall-private-tunnel.sh"
SERVICE = ROOT / "scripts/private-tunnel/private-tunnel-service.sh"
SECRET = "cp-private-test-key-must-not-appear"

def executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(0o700)

class PrivateTunnelTests(unittest.TestCase):
    def setUp(self) -> None:
        self.work = Path(tempfile.mkdtemp(prefix="messages-private-tunnel-"))
        self.launchctl_mode = ""
        self.home = self.work / "home with space"
        self.app_bridge = self.home / "Applications/Messages Swift.app/Contents/MacOS/messages-mcp"
        self.app_bridge.parent.mkdir(parents=True)
        executable(self.app_bridge, "#!/bin/zsh\nprintf '%s:%s\\n' \"${CONTROL_PLANE_API_KEY-unset}\" \"${OPENAI_API_KEY-unset}\" > \"$BRIDGE_ENV_RECORD\"\n")
        self.fake_tunnel = self.work / "fake-tunnel-client"
        self.tunnel_record = self.work / "tunnel-record"
        executable(self.fake_tunnel, "#!/bin/zsh\nset -euo pipefail\ncommand=\"$1\"\nprintf '%s\\n' \"$command\" >> \"$TUNNEL_RECORD\"\nshift\nprintf '%s\\0' \"$@\" >> \"$TUNNEL_ARGUMENTS\"\n[[ \"${CONTROL_PLANE_API_KEY:-}\" == \"" + SECRET + "\" ]] || exit 91\nif [[ \"$command\" == \"init\" ]]; then\n  mcp=\"\"; profile_dir=\"\"; previous=\"\"\n  for value in \"$@\"; do [[ \"$previous\" == \"--mcp-command\" ]] && mcp=\"$value\"; [[ \"$previous\" == \"--profile-dir\" ]] && profile_dir=\"$value\"; previous=\"$value\"; done\n  print -r -- \"$mcp\" > \"$MCP_COMMAND_RECORD\"\n  mkdir -p \"$profile_dir\"; print -r -- 'control_plane_api_key: env:CONTROL_PLANE_API_KEY' > \"$profile_dir/messages-stdio.yaml\"\nelse\n  eval \"$(<\"$MCP_COMMAND_RECORD\")\"\nfi\n")
        self.fake_launchctl = self.work / "fake-launchctl"
        executable(self.fake_launchctl, "#!/bin/zsh\nif [[ \"${FAKE_LAUNCHCTL_MODE:-}\" == print-unknown && \"$1\" == print ]]; then print -u2 'launchctl unavailable'; exit 71; fi\nif [[ \"${FAKE_LAUNCHCTL_MODE:-}\" == bootout-fail && \"$1\" == bootout ]]; then print -u2 'bootout failed'; exit 72; fi\nprintf '%s\\0' \"$@\" >> \"$LAUNCHCTL_RECORD\"\n")

    def tearDown(self) -> None:
        shutil.rmtree(self.work)

    def env(self) -> dict[str, str]:
        env = os.environ.copy()
        env.update(HOME=str(self.home), CONTROL_PLANE_API_KEY=SECRET, MESSAGES_SWIFT_LAUNCHCTL_BIN=str(self.fake_launchctl), FAKE_LAUNCHCTL_MODE=self.launchctl_mode, LAUNCHCTL_RECORD=str(self.work / "launchctl-record"), TUNNEL_RECORD=str(self.tunnel_record), TUNNEL_ARGUMENTS=str(self.work / "tunnel-arguments"), MCP_COMMAND_RECORD=str(self.work / "mcp-command"), BRIDGE_ENV_RECORD=str(self.work / "bridge-env"))
        return env

    def command(self, command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(command, text=True, capture_output=True, env=self.env(), check=check)

    def test_install_writes_private_key_and_exact_supervision(self) -> None:
        result = self.command([str(INSTALL), "--tunnel-id", "tunnel_0123456789abcdef0123456789abcdef", "--tunnel-client", str(self.fake_tunnel)])
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        runtime_root = self.home / "Library/Application Support/messages-swift/private-tunnel"
        key_file = runtime_root / "runtime-key"
        self.assertEqual(key_file.read_text(), SECRET)
        self.assertEqual(stat.S_IMODE(key_file.stat().st_mode), 0o600)
        tunnel = plistlib.loads((self.home / "Library/LaunchAgents/com.ericfeunekes.messages-swift.private-tunnel.plist").read_bytes())
        app = plistlib.loads((self.home / "Library/LaunchAgents/com.ericfeunekes.messages-swift.app-supervisor.plist").read_bytes())
        for payload in (tunnel, app):
            self.assertTrue(payload["RunAtLoad"]); self.assertTrue(payload["KeepAlive"]); self.assertEqual(payload["ThrottleInterval"], 30); self.assertNotIn(SECRET, repr(payload))
        self.assertEqual(app["ProgramArguments"], ["/usr/bin/open", "-g", "-W", str(self.home / "Applications/Messages Swift.app")])
        wrapper = tunnel["ProgramArguments"][tunnel["ProgramArguments"].index("--mcp-command") + 1]
        self.assertEqual(wrapper, str(self.home / ".messages-swift/private-tunnel/messages-mcp-stdio"))
        launchctl_arguments = (self.work / "launchctl-record").read_bytes()
        self.assertIn(b"bootstrap", launchctl_arguments)
        self.assertIn(b"com.ericfeunekes.messages-swift.app-supervisor.plist", launchctl_arguments)
        self.assertIn(b"com.ericfeunekes.messages-swift.private-tunnel.plist", launchctl_arguments)
        self.command(tunnel["ProgramArguments"])
        self.assertEqual((self.work / "bridge-env").read_text(), "unset:unset\n")
        self.assertIn(b"home\\ with\\ space/.messages-swift/private-tunnel/messages-mcp-stdio", (self.work / "tunnel-arguments").read_bytes())

    def test_runtime_uses_env_reference_and_scrubs_bridge_environment(self) -> None:
        key_file = self.work / "runtime-key"; key_file.write_text(SECRET); key_file.chmod(0o600)
        profile = self.work / "profile dir"; health = self.work / "health dir/health.url"; wrapper = self.work / "no-space-wrapper"
        shutil.copy2(WRAPPER, wrapper); wrapper.chmod(0o700)
        result = self.command([str(RUNTIME), "--tunnel-client", str(self.fake_tunnel), "--tunnel-id", "tunnel_0123456789abcdef0123456789abcdef", "--key-file", str(key_file), "--profile-dir", str(profile), "--health-url-file", str(health), "--mcp-command", str(wrapper)])
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        arguments = (self.work / "tunnel-arguments").read_bytes().split(b"\0")
        self.assertIn(b"sample_mcp_stdio_local", arguments); self.assertIn(b"env:CONTROL_PLANE_API_KEY", arguments); self.assertIn(b"127.0.0.1:0", arguments); self.assertNotIn(SECRET.encode(), arguments)
        self.assertNotIn(SECRET, (profile / "messages-stdio.yaml").read_text())
        self.assertEqual((self.work / "bridge-env").read_text(), "unset:unset\n")

    def test_runtime_rejects_insecure_key(self) -> None:
        key_file = self.work / "insecure-key"; key_file.write_text(SECRET); key_file.chmod(0o644)
        wrapper = self.work / "wrapper"; executable(wrapper, "#!/bin/zsh\n")
        result = self.command([str(RUNTIME), "--tunnel-client", str(self.fake_tunnel), "--tunnel-id", "tunnel_0123456789abcdef0123456789abcdef", "--key-file", str(key_file), "--profile-dir", str(self.work / "profiles"), "--health-url-file", str(self.work / "health.url"), "--mcp-command", str(wrapper)], check=False)
        self.assertEqual(result.returncode, 77); self.assertIn("missing or unsafe", result.stderr); self.assertFalse(self.tunnel_record.exists())

    def test_runtime_accepts_space_in_wrapper_path(self) -> None:
        key_file = self.work / "runtime-key"; key_file.write_text(SECRET); key_file.chmod(0o600)
        wrapper = self.work / "wrapper with space"; executable(wrapper, "#!/bin/zsh\n")
        result = self.command([str(RUNTIME), "--tunnel-client", str(self.fake_tunnel), "--tunnel-id", "tunnel_0123456789abcdef0123456789abcdef", "--key-file", str(key_file), "--profile-dir", str(self.work / "profiles"), "--health-url-file", str(self.work / "health.url"), "--mcp-command", str(wrapper)], check=False)
        self.assertEqual(result.returncode, 0); self.assertTrue(self.tunnel_record.exists())

    def test_uninstall_preserves_key_unless_explicitly_requested(self) -> None:
        self.command([str(INSTALL), "--tunnel-id", "tunnel_0123456789abcdef0123456789abcdef", "--tunnel-client", str(self.fake_tunnel)])
        key_file = self.home / "Library/Application Support/messages-swift/private-tunnel/runtime-key"
        self.command([str(UNINSTALL)]); self.assertTrue(key_file.exists()); self.assertFalse((self.home / "Library/LaunchAgents/com.ericfeunekes.messages-swift.private-tunnel.plist").exists())
        self.command([str(UNINSTALL), "--delete-key"]); self.assertFalse(key_file.exists())

    def test_unknown_or_failed_stop_is_not_treated_as_absent(self) -> None:
        self.command([str(INSTALL), "--tunnel-id", "tunnel_0123456789abcdef0123456789abcdef", "--tunnel-client", str(self.fake_tunnel)])
        self.launchctl_mode = "print-unknown"
        result = self.command([str(SERVICE), "stop"], check=False)
        self.assertEqual(result.returncode, 71)
        self.launchctl_mode = "bootout-fail"
        result = self.command([str(SERVICE), "stop"], check=False)
        self.assertEqual(result.returncode, 72)

if __name__ == "__main__":
    unittest.main(verbosity=2)
