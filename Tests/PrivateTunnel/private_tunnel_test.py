#!/usr/bin/env python3
"""Inert contract checks for the local private-tunnel deployment helpers."""

import os
import plistlib
import shutil
import stat
import signal
import shlex
import uuid
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
        scratch = ROOT / ".scratch/private-tunnel-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        self.work = Path(tempfile.mkdtemp(prefix="messages-private-tunnel-", dir=scratch))
        self.launchctl_mode = ""
        self.processes = []
        self.home = self.work / "home with space é's"
        self.app_bridge = self.home / "Applications/Messages Swift.app/Contents/MacOS/messages-mcp"
        self.app_bridge.parent.mkdir(parents=True)
        executable(self.app_bridge, "#!/bin/zsh\nprintf '%s:%s\\n' \"${CONTROL_PLANE_API_KEY-unset}\" \"${OPENAI_API_KEY-unset}\" > \"$BRIDGE_ENV_RECORD\"\n")
        self.fake_tunnel = self.work / "fake-tunnel-client"
        self.tunnel_record = self.work / "tunnel-record"
        executable(self.fake_tunnel, "#!/bin/zsh\nset -euo pipefail\ncommand=\"$1\"\nprintf '%s\\n' \"$command\" >> \"$TUNNEL_RECORD\"\nshift\nprintf '%s\\0' \"$@\" >> \"$TUNNEL_ARGUMENTS\"\n[[ \"${CONTROL_PLANE_API_KEY:-}\" == \"" + SECRET + "\" ]] || exit 91\nif [[ \"$command\" == \"init\" ]]; then\n  mcp=\"\"; profile_dir=\"\"; previous=\"\"\n  for value in \"$@\"; do [[ \"$previous\" == \"--mcp-command\" ]] && mcp=\"$value\"; [[ \"$previous\" == \"--profile-dir\" ]] && profile_dir=\"$value\"; previous=\"$value\"; done\n  print -r -- \"$mcp\" > \"$MCP_COMMAND_RECORD\"\n  mkdir -p \"$profile_dir\"; print -r -- 'control_plane_api_key: env:CONTROL_PLANE_API_KEY' > \"$profile_dir/messages-stdio.yaml\"\nelse\n  eval \"$(<\"$MCP_COMMAND_RECORD\")\"\nfi\n")
        self.fake_launchctl = self.work / "fake-launchctl"
        executable(self.fake_launchctl, "#!/bin/zsh\nif [[ \"${FAKE_LAUNCHCTL_MODE:-}\" == print-unknown && \"$1\" == print ]]; then print -u2 'launchctl unavailable'; exit 71; fi\nif [[ \"${FAKE_LAUNCHCTL_MODE:-}\" == bootout-fail && \"$1\" == bootout ]]; then print -u2 'bootout failed'; exit 72; fi\nprintf '%s\\0' \"$@\" >> \"$LAUNCHCTL_RECORD\"\n")

    def tearDown(self) -> None:
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)
            if process.stdout:
                process.stdout.close()
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
        arguments = (self.work / "tunnel-arguments").read_bytes().split(b"\0")
        command = arguments[arguments.index(b"--mcp-command") + 1].decode()
        self.assertEqual(shlex.split(command), [wrapper])

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

    def run_menu_update(self, mode: str, managed: bool, missing_app: bool = False, process_name: str | None = None) -> subprocess.CompletedProcess[str]:
        if managed:
            self.command([str(INSTALL), "--tunnel-id", "tunnel_0123456789abcdef0123456789abcdef", "--tunnel-client", str(self.fake_tunnel)])
        fixture = self.work / "update-repo"
        (fixture / "scripts/private-tunnel").mkdir(parents=True)
        installer_source = (ROOT / "scripts/install-menu-app.sh").read_text()
        if process_name:
            # Substitute only the external process identity; execute the real stop/wait logic.
            installer_source = installer_source.replace('pgrep -x "Messages Swift"', f'pgrep -x "{process_name}"')
            installer_source = installer_source.replace('/usr/bin/killall -TERM "Messages Swift"', f'/usr/bin/killall -TERM "{process_name}"')
            self.assertNotIn('killall -TERM "Messages Swift"', installer_source)
        executable(fixture / "scripts/install-menu-app.sh", installer_source)
        shutil.copy2(SERVICE, fixture / "scripts/private-tunnel/private-tunnel-service.sh")
        package = fixture / "packaging"
        package.mkdir()
        info = plistlib.dumps({"CFBundleIdentifier": "com.ericfeunekes.messages-swift"})
        (package / "Info.plist").write_bytes(info)
        (package / "MessagesSwift.entitlements").write_bytes(plistlib.dumps({}))
        (self.app_bridge.parents[1] / "Info.plist").write_bytes(info)
        build = fixture / ".build/release"
        build.mkdir(parents=True)
        for name in ("Messages Swift", "messages-mcp"):
            executable(build / name, "#!/bin/zsh\nexit 0\n")
        fake_bin = self.work / "update-bin"
        fake_bin.mkdir()
        for name in ("swift", "codesign"):
            executable(fake_bin / name, "#!/bin/zsh\nexit 0\n")
        # No application PID exists in this fixture; never enter the native kill path.
        if process_name is None:
            executable(fake_bin / "pgrep", "#!/bin/zsh\nexit 1\n")
        executable(fake_bin / "ditto", "#!/usr/bin/env python3\nimport os,sys,shutil,pathlib\npathlib.Path(os.environ['COPY_MARKER']).write_text('copied')\nwith open(os.environ['LAUNCHCTL_RECORD'], 'a') as f: f.write('copy|bundle\\n')\nshutil.copytree(sys.argv[1],sys.argv[2])\n")
        (self.work / "launchctl-record").write_text("")
        executable(self.fake_launchctl, """#!/bin/zsh
print -r -- "$1|${3:-$2}" >> "$LAUNCHCTL_RECORD"
if [[ "$1" == print && "$FAKE_LAUNCHCTL_MODE" == absent ]]; then print -u2 'Could not find service'; exit 113; fi
if [[ "$1" == print && "$FAKE_LAUNCHCTL_MODE" == only-app && "$2" == *private-tunnel ]]; then print -u2 'Could not find service'; exit 113; fi
if [[ "$1" == print && "$FAKE_LAUNCHCTL_MODE" == print-unknown ]]; then print -u2 'launchctl unavailable'; exit 71; fi
if [[ "$1" == bootout && "$FAKE_LAUNCHCTL_MODE" == bootout-fail ]]; then exit 72; fi
if [[ "$1" == bootout && "$FAKE_LAUNCHCTL_MODE" == app-stop-fail && "$2" == *app-supervisor ]]; then exit 74; fi
if [[ "$1" == bootstrap && "$FAKE_LAUNCHCTL_MODE" == bootstrap-fail ]]; then exit 73; fi
if [[ "$1" == bootstrap && "$FAKE_LAUNCHCTL_MODE" == tunnel-resume-fail && "$3" == *private-tunnel.plist ]]; then exit 75; fi
exit 0
""")
        env = self.env()
        env.update(PATH=str(fake_bin) + os.pathsep + env["PATH"], FAKE_LAUNCHCTL_MODE=mode if managed else "absent", COPY_MARKER=str(self.work / "copied"))
        self.update_fixture = fixture
        if missing_app:
            shutil.rmtree(self.app_bridge.parents[2])
        return subprocess.run([str(fixture / "scripts/install-menu-app.sh")], env=env, text=True, capture_output=True)

    def test_app_update_without_tunnel_remains_supported(self) -> None:
        result = self.run_menu_update("", managed=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.work / "copied").exists())

    def test_failed_supervisor_stop_blocks_app_replacement(self) -> None:
        result = self.run_menu_update("bootout-fail", managed=True)
        self.assertEqual(result.returncode, 72, result.stderr)
        self.assertFalse((self.work / "copied").exists())

    def test_failed_stop_blocks_repair_of_missing_app(self) -> None:
        result = self.run_menu_update("bootout-fail", managed=True, missing_app=True)
        self.assertEqual(result.returncode, 72, result.stderr)
        self.assertFalse((self.work / "copied").exists())

    def test_unknown_supervisor_state_blocks_app_replacement(self) -> None:
        result = self.run_menu_update("print-unknown", managed=True)
        self.assertEqual(result.returncode, 71, result.stderr)
        self.assertFalse((self.work / "copied").exists())

    def test_failed_supervisor_resume_returns_failure_and_cleans_staging(self) -> None:
        result = self.run_menu_update("bootstrap-fail", managed=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Failed to resume", result.stderr)
        self.assertTrue((self.work / "copied").exists())
        self.assertEqual(list((self.update_fixture / ".scratch").iterdir()), [])

    def lifecycle_events(self) -> list[str]:
        return [line for line in (self.work / "launchctl-record").read_text().splitlines() if not line.startswith("print|")]

    def test_update_restarts_tunnel_to_replace_its_stdio_bridge(self) -> None:
        result = self.run_menu_update("", managed=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.lifecycle_events()
        self.assertEqual([e.split("|")[0] for e in events], ["bootout", "bootout", "copy", "bootstrap", "bootstrap"])
        self.assertTrue(events[0].endswith("private-tunnel"))
        self.assertTrue(events[1].endswith("app-supervisor"))
        self.assertTrue(events[3].endswith("app-supervisor.plist"))
        self.assertTrue(events[4].endswith("private-tunnel.plist"))

    def test_app_stop_failure_restores_tunnel_without_replacing_bundle(self) -> None:
        result = self.run_menu_update("app-stop-fail", managed=True)
        self.assertEqual(result.returncode, 74, result.stderr)
        self.assertFalse((self.work / "copied").exists())
        starts = [e for e in self.lifecycle_events() if e.startswith("bootstrap|")]
        self.assertEqual(len(starts), 1)
        self.assertTrue(starts[0].endswith("private-tunnel.plist"))

    def test_tunnel_resume_failure_is_not_success(self) -> None:
        result = self.run_menu_update("tunnel-resume-fail", managed=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Failed to resume", result.stderr)
        self.assertTrue((self.work / "copied").exists())

    def test_update_does_not_start_a_previously_stopped_tunnel(self) -> None:
        result = self.run_menu_update("only-app", managed=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        starts = [e for e in self.lifecycle_events() if e.startswith("bootstrap|")]
        self.assertEqual(len(starts), 1)
        self.assertTrue(starts[0].endswith("app-supervisor.plist"))

    def start_inert_app_process(self, ignore_term: bool) -> tuple[str, subprocess.Popen]:
        name = "MsgTest" + uuid.uuid4().hex[:6]
        program = self.work / name
        source = program.with_suffix(".c")
        source.write_text('#include <signal.h>\n#include <unistd.h>\nint main(int argc, char **argv) { signal(SIGTERM, argc > 1 ? SIG_IGN : SIG_DFL); write(1, "ready\\n", 6); for (;;) pause(); }\n')
        build_env = os.environ.copy()
        build_env["TMPDIR"] = str(self.work)
        subprocess.run(["cc", str(source), "-o", str(program)], env=build_env, check=True, capture_output=True)
        process = subprocess.Popen([str(program)] + (["ignore"] if ignore_term else []), stdout=subprocess.PIPE)
        self.processes.append(process)
        self.assertEqual(process.stdout.readline(), b"ready\n")
        found = subprocess.run(["pgrep", "-x", name], text=True, capture_output=True, check=True)
        self.assertEqual(found.stdout.split(), [str(process.pid)])
        return name, process

    def test_running_app_terminates_before_replacement(self) -> None:
        name, process = self.start_inert_app_process(False)
        result = self.run_menu_update("", managed=True, process_name=name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(process.wait(timeout=2), -signal.SIGTERM)
        self.assertTrue((self.work / "copied").exists())

    def test_unresponsive_app_preserves_bundle_and_resumes_jobs(self) -> None:
        name, process = self.start_inert_app_process(True)
        result = self.run_menu_update("", managed=True, process_name=name)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not stop", result.stderr)
        self.assertIsNone(process.poll())
        self.assertFalse((self.work / "copied").exists())
        starts = [e for e in self.lifecycle_events() if e.startswith("bootstrap|")]
        self.assertEqual(len(starts), 2)

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
