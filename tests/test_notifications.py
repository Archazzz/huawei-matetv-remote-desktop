import io
import json
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from notifications.server import (
    Config, Device, Handler, Inbox, MAX_BODY_BYTES, MAX_TTL_MS,
    NotificationServer, RequestError, load_config, strict_json,
)


NOW = 1_800_000_000_000
TV_TOKEN = "tv-" + "t" * 48
DEVICE_TOKEN = "writer-" + "w" * 48
SECOND_TOKEN = "other-" + "o" * 48


def config(max_events=1000):
    return Config("127.0.0.1", 24443, Path("missing.pem"), Path("missing.key"), TV_TOKEN,
                  (Device("mac-one", "Mac 示例", "saved-card-one", DEVICE_TOKEN,
                          {"codex": "Codex"}),
                   Device("mac-two", "另一台 Mac", "saved-card-two", SECOND_TOKEN,
                          {"codex": "Codex"})), max_events)


def event(event_id="task-1", **changes):
    result = {"eventId": event_id, "appId": "codex", "appName": "Codex", "title": "测试完成",
              "body": "这是合成内容\n第二行", "createdAt": NOW, "expiresAt": NOW + 300000,
              "contentState": "complete"}
    result.update(changes)
    return result


class FakeSocket:
    """Exercise HTTP framing/authentication without listening on any interface."""
    def __init__(self, raw):
        self.input = io.BytesIO(raw)
        self.output = bytearray()

    def settimeout(self, timeout):
        pass

    def makefile(self, *args):
        return self.input

    def sendall(self, data):
        self.output.extend(data)


def request(inbox, method="POST", path="/v1/events", token=DEVICE_TOKEN,
            payload=None, raw=None, extras=None):
    data = raw if raw is not None else json.dumps(payload or event(), ensure_ascii=False).encode()
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json",
               "Content-Length": str(len(data))}
    headers.update(extras or {})
    wire = (f"{method} {path} HTTP/1.0\r\n" +
            "".join(f"{k}: {v}\r\n" for k, v in headers.items()) + "\r\n").encode() + data
    sock = FakeSocket(wire)
    Handler(sock, ("127.0.0.1", 10000), SimpleNamespace(inbox=inbox))
    head, body = bytes(sock.output).split(b"\r\n\r\n", 1)
    return int(head.split(b" ")[1]), json.loads(body)


class InboxTests(unittest.TestCase):
    def setUp(self):
        self.now = NOW
        self.inbox = Inbox(config(), lambda: self.now)
        self.device = self.inbox.config.devices[0]

    def failure(self, status, payload):
        with self.assertRaises(RequestError) as result:
            self.inbox.publish(self.device, payload)
        self.assertEqual(result.exception.status, status)

    def test_identity_bound_to_credential_and_app_allowlist(self):
        device = self.inbox.authenticate("Bearer " + DEVICE_TOKEN, False)
        self.inbox.publish(device, event())
        actual = self.inbox.poll(0)["events"][0]
        self.assertEqual((actual["deviceId"], actual["deviceName"], actual["hostId"]),
                         ("mac-one", "Mac 示例", "saved-card-one"))
        for key in ("deviceId", "deviceName", "hostId", "cursor"):
            self.failure(400, event(**{key: "forged"}))
        self.failure(403, event(appId="other"))
        self.failure(403, event(appName="伪造软件"))

    def test_rejects_retired_source_even_with_stale_device_allowlist(self):
        stale = replace(self.device, apps={"codex": "Codex", "wechat": "微信"})
        with self.assertRaises(RequestError) as result:
            self.inbox.publish(stale, event(appId="wechat", appName="微信"))
        self.assertEqual(result.exception.status, 403)
        self.assertEqual(self.inbox.poll(0)["events"], [])

    def test_roles_and_malformed_credentials(self):
        self.assertIsNone(self.inbox.authenticate("Bearer " + TV_TOKEN, True))
        for token, tv in [(TV_TOKEN, False), (DEVICE_TOKEN, True), ("wrong" * 10, False),
                          ("非ASCII" * 12, False)]:
            with self.subTest(tv=tv, length=len(token)), self.assertRaises(RequestError) as result:
                self.inbox.authenticate("Bearer " + token, tv)
            self.assertEqual(result.exception.status, 401)

    def test_idempotency_conflict_and_device_namespace(self):
        self.assertEqual(self.inbox.publish(self.device, event())[0], 201)
        status, result = self.inbox.publish(self.device, event())
        self.assertEqual((status, result["duplicate"], result["cursor"]), (200, True, 1))
        self.failure(409, event(body="changed"))
        self.inbox.publish(self.inbox.config.devices[1], event())
        self.assertEqual([e["cursor"] for e in self.inbox.poll(0)["events"]], [1, 2])

    def test_concurrent_retries_add_only_once(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.inbox.publish(self.device, event()), range(32)))
        self.assertEqual(sum(code == 201 for code, _ in results), 1)
        self.assertEqual(len(self.inbox.poll(0)["events"]), 1)

    def test_expiration_and_capacity_release(self):
        self.inbox = Inbox(config(1), lambda: self.now)
        self.inbox.publish(self.device, event(expiresAt=NOW + 1))
        self.failure(429, event("task-2"))
        self.now += 2
        self.inbox.publish(self.device, event("task-2"))
        response = self.inbox.poll(0)
        self.assertFalse(response["resetRequired"])
        self.assertEqual([e["eventId"] for e in response["events"]], ["task-2"])

    def test_time_validation(self):
        for changes in [{"expiresAt": NOW}, {"createdAt": NOW + 60001},
                        {"expiresAt": NOW + MAX_TTL_MS + 1}, {"createdAt": True},
                        {"expiresAt": "later"}, {"createdAt": -1}]:
            with self.subTest(changes=changes):
                self.failure(400, event(**changes))

    def test_text_and_field_validation(self):
        for changes in [{"body": "x" * 8001}, {"title": "x" * 257}, {"body": "\x00secret"},
                        {"body": "\ud800"}, {"title": "", "body": " \t"},
                        {"contentState": "guessed"}, {"eventId": "../file"}, {"body": []}]:
            with self.subTest(keys=list(changes)):
                self.failure(400, event(**changes))
        value = event()
        del value["body"]
        self.failure(400, value)
        # Markup remains inert text; no HTML transformation or command execution exists.
        text = "<script>alert(1)</script> $(echo secret)"
        self.inbox.publish(self.device, event(body=text))
        self.assertEqual(self.inbox.poll(0)["events"][0]["body"], text)

    def test_pagination_cursor_and_restart_identity(self):
        for i in range(105):
            self.inbox.publish(self.device, event(f"id-{i}"))
        first = self.inbox.poll(0)
        self.assertEqual((len(first["events"]), first["nextCursor"]), (100, 100))
        second = self.inbox.poll(first["nextCursor"])
        self.assertEqual([e["cursor"] for e in second["events"]], [101, 102, 103, 104, 105])
        self.assertEqual(self.inbox.poll(105)["events"], [])
        self.assertTrue(self.inbox.poll(999)["resetRequired"])
        restarted = Inbox(config(), lambda: NOW)
        self.assertNotEqual(first["streamId"], restarted.poll(0)["streamId"])
        with self.assertRaises(RequestError):
            self.inbox.poll(-1)

    def test_poll_returns_copies(self):
        self.inbox.publish(self.device, event())
        result = self.inbox.poll(0)
        result["events"][0]["hostId"] = "tampered"
        self.assertEqual(self.inbox.poll(0)["events"][0]["hostId"], "saved-card-one")

    def test_expired_gap_requests_reset_once_then_rebaseline(self):
        self.inbox.publish(self.device, event("first"))
        self.inbox.publish(self.device, event("expires", expiresAt=NOW + 1))
        self.inbox.publish(self.device, event("third"))
        self.now += 2
        self.assertTrue(self.inbox.poll(1)["resetRequired"])
        baseline = self.inbox.poll(0)
        self.assertFalse(baseline["resetRequired"])
        self.assertEqual([e["cursor"] for e in baseline["events"]], [1, 3])


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.inbox = Inbox(config(), lambda: NOW)

    def test_post_get_and_authorization_roles(self):
        self.assertEqual(request(self.inbox)[0], 201)
        status, value = request(self.inbox, "GET", "/v1/events?after=0", TV_TOKEN)
        self.assertEqual(status, 200)
        self.assertEqual(value["events"][0]["hostId"], "saved-card-one")
        self.assertEqual(request(self.inbox, token=TV_TOKEN)[0], 401)
        self.assertEqual(request(self.inbox, "GET", "/v1/events?after=0")[0], 401)

    def test_bad_query_unknown_route_and_body_framing(self):
        for path in ["/v1/events", "/v1/events?after=-1", "/v1/events?after=1&after=2",
                     "/v1/events?after=0&hostId=forged"]:
            self.assertEqual(request(self.inbox, "GET", path, TV_TOKEN)[0], 400)
        self.assertEqual(request(self.inbox, path="/other")[0], 404)
        self.assertEqual(request(self.inbox, extras={"Transfer-Encoding": "chunked"})[0], 400)
        self.assertEqual(request(self.inbox, extras={"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(request(self.inbox, extras={"Content-Length": str(MAX_BODY_BYTES + 1)})[0], 413)
        self.assertEqual(request(self.inbox, extras={"Content-Length": "NaN"})[0], 400)

    def test_json_duplicate_keys_utf8_and_safe_errors(self):
        for raw in [b'{"eventId":"first","eventId":"second"}', b'\xff', b'{"x":NaN}', b'[]']:
            status, response = request(self.inbox, raw=raw)
            self.assertEqual(status, 400)
            self.assertEqual(set(response), {"error"})


class ConfigTests(unittest.TestCase):
    def valid(self):
        return {"listenHost": "127.0.0.1", "listenPort": 24443, "tlsCert": "cert.pem",
                "tlsKey": "key.pem", "tvToken": TV_TOKEN, "maxEvents": 100,
                "devices": [{"deviceId": "example", "deviceName": "Example", "hostId": "card",
                             "token": DEVICE_TOKEN, "apps": {"codex": "Codex"}}]}

    def load(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(data))
            return load_config(path)

    def test_private_binding_and_independent_credentials(self):
        self.assertEqual(self.load(self.valid()).listen_host, "127.0.0.1")
        for host in ["0.0.0.0", "::", "8.8.8.8", "224.0.0.1", "169.254.1.1", "240.0.0.1"]:
            data = self.valid()
            data["listenHost"] = host
            with self.subTest(host=host), self.assertRaises(ValueError):
                self.load(data)
        data = self.valid()
        data["devices"][0]["token"] = TV_TOKEN
        with self.assertRaises(ValueError):
            self.load(data)
        data = self.valid()
        data["tvToken"] = "REPLACE_WITH_DIFFERENT_RANDOM_SECRET"
        with self.assertRaises(ValueError):
            self.load(data)

    def test_configuration_cannot_reenable_retired_sources(self):
        for apps in [{"wechat": "微信"}, {"codex": "Codex", "wechat": "微信"}, {"codex": "微信"}]:
            data = self.valid()
            data["devices"][0]["apps"] = apps
            with self.subTest(apps=apps), self.assertRaises(ValueError):
                self.load(data)

    def test_missing_tls_cannot_open_listener(self):
        with patch("notifications.server.ThreadingHTTPServer.__init__") as init:
            with self.assertRaises(OSError):
                NotificationServer(config())
            init.assert_not_called()


if __name__ == "__main__":
    unittest.main()
