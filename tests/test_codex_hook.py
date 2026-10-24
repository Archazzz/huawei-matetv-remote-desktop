import contextlib
import io
import json
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from notifications import codex_hook as hook
from notifications.server import Config, Device, Inbox

TOKEN = "hook-test-" + "x" * 40
NOW = 1_800_000_000_000


def payload(**changes):
    return {"hook_event_name": "Stop", "session_id": "sample-session", "turn_id": "sample-turn",
            "last_assistant_message": "已完成。\n请检查结果。", "stop_hook_active": False,
            "cwd": "/private/project", "input_messages": ["private prompt"],
            "transcript_path": "/private/transcript", **changes}


class EventTests(unittest.TestCase):
    def test_real_relay_accepts_exact_text_and_only_allowed_fields(self):
        event = hook.make_event(payload(), now_ms=NOW)
        cfg = Config("127.0.0.1", 24443, Path("unused"), Path("unused"), "tv-" + "t" * 40,
                     (Device("mac", "Mac", "saved-mac", TOKEN, {"codex": "Codex"}),), 10)
        inbox = Inbox(cfg, lambda: NOW)
        self.assertEqual(inbox.publish(cfg.devices[0], event)[0], 201)
        self.assertEqual(event["body"], payload()["last_assistant_message"])
        self.assertEqual(event["contentState"], "complete")
        serialized = json.dumps(event)
        for private in ("private prompt", "/private/project", "/private/transcript", "sample-session"):
            self.assertNotIn(private, serialized)

    def test_unicode_truncation_identity_and_concurrent_turns(self):
        event = hook.make_event(payload(last_assistant_message="字🙂" * 5000), now_ms=NOW)
        self.assertEqual(len(event["body"]), 8000)
        self.assertEqual(event["contentState"], "truncated")
        same = hook.make_event(payload(last_assistant_message="字🙂" * 5000), now_ms=NOW)
        self.assertEqual(same, event)
        other = hook.make_event(payload(turn_id="another-turn"), now_ms=NOW)
        self.assertNotEqual(other["eventId"], event["eventId"])

    def test_no_spurious_completion_or_approval_decision(self):
        for changes in ({"stop_hook_active": True}, {"last_assistant_message": None},
                        {"last_assistant_message": ""}, {"hook_event_name": "SubagentStop"},
                        {"hook_event_name": "PermissionRequest", "tool_name": "exec"}):
            self.assertIsNone(hook.make_event(payload(**changes)))
        event = hook.make_event(payload(hook_event_name="PermissionRequest", tool_name="exec",
                                       tool_input={"password": "secret"}), permission_requests=True)
        self.assertEqual(event["title"], "Codex 权限请求")
        self.assertEqual(event["body"], "工具：exec")
        self.assertEqual(event["contentState"], "unknown")
        self.assertNotIn("secret", json.dumps(event))

    def test_invalid_text_and_duplicate_fields_fail_closed(self):
        for text in ("text\x00", "text\r", "\ud800", 123):
            with self.assertRaises(ValueError):
                hook.make_event(payload(last_assistant_message=text))
        with self.assertRaises(ValueError):
            hook.strict_json(b'{"a":1,"a":2}')

    def test_merge_preserves_foreign_settings_and_is_idempotent(self):
        original = {"extension": {"opaque": 1}, "hooks": {"Stop": [{"matcher": "foreign", "hooks": [
            {"type": "command", "command": "existing-notifier", "custom": True}]}],
            "PermissionRequest": [{"hooks": [{"type": "command", "command": "approval-hook"}]}]}}
        result = hook.merged_hooks(original, "screenlink-command")
        self.assertEqual(result["hooks"]["Stop"][0], original["hooks"]["Stop"][0])
        self.assertEqual(result["hooks"]["PermissionRequest"], original["hooks"]["PermissionRequest"])
        self.assertEqual(result["extension"], original["extension"])
        self.assertEqual(len(original["hooks"]["Stop"]), 1)
        self.assertEqual(hook.merged_hooks(result, "screenlink-command"), result)

    def test_failed_hook_has_no_stdout_and_always_succeeds(self):
        result = subprocess.run([sys.executable, str(Path(hook.__file__)), "--config", "/nonexistent/config"],
                                input=b'{"malformed":', capture_output=True, timeout=6)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))

    def test_total_deadline_kills_slow_worker(self):
        class SlowWorker:
            def __init__(self):
                self.killed = False
            def communicate(self, raw=None, timeout=None):
                if timeout is not None:
                    raise subprocess.TimeoutExpired("worker", timeout)
            def kill(self):
                self.killed = True
        worker = SlowWorker()
        with patch.object(hook.subprocess, "Popen", return_value=worker):
            hook.run_hook(Path("unused"), b"{}")
        self.assertTrue(worker.killed)

    def test_prepare_does_not_overwrite_existing_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            existing = Path(tmp) / "hooks.json"
            existing.write_text('{"hooks":{}}')
            with contextlib.redirect_stderr(io.StringIO()):
                code = hook.main(["prepare-hooks", "--existing", str(existing), "--output", str(existing),
                                  "--config", str(Path(tmp) / "config.json")])
            self.assertEqual(code, 1)
            self.assertEqual(existing.read_text(), '{"hooks":{}}')


@unittest.skipUnless(shutil.which("openssl"), "openssl required for local TLS integration")
class TLSTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.path = Path(cls.tmp.name)
        config = cls.path / "openssl.cnf"
        config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n'
                          '[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\n'
                          'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,digitalSignature,keyEncipherment\n')
        cls.cert, cls.key = cls.path / "ca.pem", cls.path / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-keyout", str(cls.key), "-out", str(cls.cert), "-config", str(config)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.requests = []
        cls.redirect = False
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                cls.requests.append((self.path, self.headers.get("Authorization"), json.loads(body)))
                self.send_response(307 if cls.redirect else 201)
                if cls.redirect:
                    self.send_header("Location", "/stolen")
                self.end_headers()
                self.wfile.write(b'{"accepted":true}')
            def log_message(self, *args):
                pass
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(cls.cert), str(cls.key))
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = {"relayUrl": f"https://localhost:{cls.server.server_port}", "token": TOKEN,
                    "caFile": str(cls.cert)}

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.tmp.cleanup()

    def setUp(self):
        type(self).requests.clear()
        type(self).redirect = False

    def test_verified_tls_sends_exact_payload(self):
        event = hook.make_event(payload())
        hook.deliver(self.base, event)
        self.assertEqual(self.requests, [("/v1/events", "Bearer " + TOKEN, event)])

    def test_full_hook_process_delivers_without_output(self):
        config = self.path / "worker-config.json"
        config.write_text(json.dumps(self.base))
        result = subprocess.run([sys.executable, str(Path(hook.__file__)), "--config", str(config)],
                                input=json.dumps(payload()).encode(), capture_output=True, timeout=6)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.requests[0][2]["body"], payload()["last_assistant_message"])

    def test_hostname_mismatch_prevents_credential_transmission(self):
        cfg = {**self.base, "relayUrl": self.base["relayUrl"].replace("localhost", "127.0.0.1")}
        with self.assertRaises(Exception):
            hook.deliver(cfg, hook.make_event(payload()))
        self.assertEqual(self.requests, [])

    def test_redirect_is_not_followed(self):
        type(self).redirect = True
        with self.assertRaises(Exception):
            hook.deliver(self.base, hook.make_event(payload()))
        self.assertEqual([r[0] for r in self.requests], ["/v1/events"])

    def test_config_rejects_http_credentials_in_url_and_bad_tokens(self):
        path = self.path / "config.json"
        for changes in ({"relayUrl": "http://localhost"}, {"relayUrl": "https://user:pass@localhost"},
                        {"relayUrl": "https://localhost/extra"}, {"token": "short"},
                        {"permissionRequests": "false"}):
            path.write_text(json.dumps({**self.base, **changes}))
            with self.assertRaises(ValueError):
                hook.load_config(path)
        path.write_text(json.dumps(self.base))
        self.assertFalse(hook.load_config(path)["permissionRequests"])


if __name__ == "__main__":
    unittest.main()
