"""Cloud contracts tested with fakes and local RSA signing; no cloud requests/listeners."""
import base64
import json
import os
import sqlite3
import subprocess
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from notifications.huawei_push import AUDIENCE, HuaweiPush, NoRedirect, compact
from notifications.server import Inbox, RequestError, load_config
import test_notifications as notification_tests
from test_notifications import NOW, TV_TOKEN, DEVICE_TOKEN, config, event, request


class FakePush:
    def __init__(self, success=True):
        self.calls = []
        self.success = success

    def send(self, event, registration, nonce, now):
        self.calls.append((event, registration, nonce, now))
        return self.success


class PersistentPushTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.now = NOW
        self.config = replace(config(), state_path=Path(self.directory.name) / "state.sqlite")
        self.sender = FakePush()
        self.inboxes = []
        self.inbox = self.restart()
        self.registration = {"installationId": "tv-install-1", "pushToken": "synthetic-token",
                             "previewMode": "full", "scope": "local"}

    def restart(self, conf=None, sender=True):
        inbox = Inbox(conf or self.config, lambda: self.now, self.sender if sender else None)
        self.inboxes.append(inbox)
        return inbox

    def tearDown(self):
        for inbox in self.inboxes:
            if inbox.state:
                inbox.state.close()
        self.directory.cleanup()

    def publish(self):
        self.inbox.publish(self.config.devices[0], event())
        return next(iter(self.inbox.clicks))

    def resolve(self, nonce, **changes):
        return {"installationId": "tv-install-1", "scope": "local", "clickNonce": nonce, **changes}

    def test_persists_event_cursor_registration_and_click_across_restart(self):
        self.assertEqual(self.inbox.register_push(self.registration), {"registered": True, "cloudConfigured": True})
        nonce = self.publish()
        stream = self.inbox.stream_id
        resumed = self.restart()
        resolved = resumed.resolve_push(self.resolve(nonce))
        self.assertEqual(resolved["event"]["hostId"], "saved-card-one")
        self.assertEqual(resolved["event"]["cursor"], 1)
        self.assertEqual(resolved["streamId"], stream)
        self.assertEqual(resumed.poll(0)["nextCursor"], 1)
        self.assertEqual(resumed.publish(self.config.devices[0], event())[0], 200)
        self.assertEqual(os.stat(self.config.state_path).st_mode & 0o777, 0o600)

    def test_http_roles_register_resolve_revoke_and_forged_scope(self):
        self.assertEqual(request(self.inbox, path="/v1/push/register", payload=self.registration)[0], 401)
        self.assertEqual(request(self.inbox, path="/v1/push/register", token=TV_TOKEN, payload=self.registration)[0], 200)
        nonce = self.publish()
        for change in [{"scope": "other"}, {"installationId": "other"}, {"clickNonce": "z" * 43}]:
            status, response = request(self.inbox, path="/v1/push/resolve", token=TV_TOKEN,
                                       payload=self.resolve(nonce, **change))
            self.assertEqual((status, response), (404, {"error": "click_unavailable"}))
        status, body = request(self.inbox, path="/v1/push/resolve", token=TV_TOKEN, payload=self.resolve(nonce))
        self.assertEqual(status, 200)
        self.assertEqual(body["event"]["deviceId"], "mac-one")
        self.assertEqual(request(self.inbox, path="/v1/push/revoke", token=TV_TOKEN,
                                 payload={"installationId": "tv-install-1"})[0], 200)
        self.assertFalse(self.inbox.process_push_once())
        self.assertEqual(request(self.inbox, path="/v1/push/resolve", token=TV_TOKEN,
                                 payload=self.resolve(nonce))[0], 404)

    def test_idempotent_register_preserves_nonce_but_rotation_revokes(self):
        self.inbox.register_push(self.registration)
        nonce = self.publish()
        self.inbox.register_push(self.registration)
        self.inbox.resolve_push(self.resolve(nonce))
        with self.assertRaises(RequestError) as failure:
            self.inbox.register_push({**self.registration, "installationId": "other-install"})
        self.assertEqual(failure.exception.status, 409)
        self.inbox.resolve_push(self.resolve(nonce))
        self.inbox.register_push({**self.registration, "pushToken": "rotated-token"})
        with self.assertRaises(RequestError):
            self.inbox.resolve_push(self.resolve(nonce))
        self.assertEqual(self.inbox.jobs, [])

    def test_expiration_pairing_removal_and_tv_credential_rotation_reject_click(self):
        self.inbox.register_push(self.registration)
        nonce = self.publish()
        no_device = self.restart(replace(self.config, devices=(self.config.devices[1],)))
        with self.assertRaises(RequestError):
            no_device.resolve_push(self.resolve(nonce))
        self.assertEqual(no_device.poll(0)["events"], [])
        # Use a new event after the cleanup snapshot to test token rotation separately.
        self.inbox._save()
        rotated = self.restart(replace(self.config, tv_token="new-token-" + "n" * 40))
        self.assertIsNone(rotated.registration)
        with self.assertRaises(RequestError):
            rotated.resolve_push(self.resolve(nonce))
        self.now += 300001
        with self.assertRaises(RequestError):
            self.inbox.resolve_push(self.resolve(nonce))

    def test_no_sender_never_sends_or_queues_and_requires_persistence(self):
        off = self.restart(sender=False)
        self.assertFalse(off.register_push(self.registration)["cloudConfigured"])
        off.publish(self.config.devices[0], event())
        self.assertFalse(off.process_push_once())
        self.assertEqual(off.jobs, [])
        self.assertEqual(self.sender.calls, [])
        with self.assertRaises(RequestError) as failure:
            Inbox(config()).register_push(self.registration)
        self.assertEqual(failure.exception.status, 503)

    def test_worker_bounded_retry_no_resend_success_and_resolve_idempotence(self):
        self.inbox.register_push(self.registration)
        nonce = self.publish()
        self.sender.success = False
        self.assertTrue(self.inbox.process_push_once())
        self.assertFalse(self.inbox.process_push_once())
        self.now += 10001
        self.inbox.process_push_once()
        self.now += 20001
        self.sender.success = True
        self.inbox.process_push_once()
        self.now += 60001
        self.assertFalse(self.inbox.process_push_once())
        self.assertEqual(len(self.sender.calls), 3)
        self.assertEqual(self.inbox.resolve_push(self.resolve(nonce)), self.inbox.resolve_push(self.resolve(nonce)))

    def test_crash_after_third_attempt_does_not_retry_fourth(self):
        self.inbox.register_push(self.registration)
        self.publish()
        self.inbox.jobs[0].update(attempts=3, nextAt=NOW)
        self.inbox._save()
        resumed = self.restart()
        self.assertFalse(resumed.process_push_once())
        self.assertEqual(self.sender.calls, [])

    def test_maintenance_removes_expired_persistent_data_without_cloud(self):
        off = self.restart(sender=False)
        off.publish(self.config.devices[0], event())
        self.now += 300001
        self.assertFalse(off.process_push_once())
        self.assertEqual(off.state.load()["events"], [])
        self.assertEqual(self.sender.calls, [])

    def test_failed_persistence_does_not_activate_registration_or_accept_event(self):
        with patch.object(self.inbox.state, "save", side_effect=sqlite3.OperationalError("synthetic failure")):
            with self.assertRaises(sqlite3.Error):
                self.inbox.register_push(self.registration)
            self.assertIsNone(self.inbox.registration)
            with self.assertRaises(sqlite3.Error):
                self.inbox.publish(self.config.devices[0], event())
            self.assertEqual((self.inbox.cursor, self.inbox.events, self.inbox.jobs), (0, [], []))
        self.inbox.register_push(self.registration)
        self.assertEqual(self.inbox.publish(self.config.devices[0], event())[0], 201)


class Response:
    status = 200
    def __init__(self, code="80000000"):
        self.code = code
    def __enter__(self):
        return self
    def __exit__(self, *args):
        pass
    def read(self, limit):
        return compact({"code": self.code, "msg": "Success", "requestId": "synthetic"})


class RecordingOpener:
    def __init__(self):
        self.requests = []
        self.code = "80000000"
    def open(self, request, timeout):
        self.requests.append(request)
        return Response(self.code)


class HuaweiSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.root = Path(cls.directory.name)
        cls.key = cls.root / "synthetic-private.pem"
        cls.pub = cls.root / "synthetic-public.pem"
        subprocess.run(["/usr/bin/openssl", "genrsa", "-out", str(cls.key), "2048"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["/usr/bin/openssl", "rsa", "-in", str(cls.key), "-pubout", "-out", str(cls.pub)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        account = {"project_id": "synthetic-project", "key_id": "synthetic-key", "sub_account": "synthetic-issuer",
                   "private_key": cls.key.read_text()}
        cls.account = cls.root / "synthetic-account.json"
        cls.account.write_text(json.dumps(account))
        cls.account.chmod(0o600)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def sender(self):
        self.opener = RecordingOpener()
        return HuaweiPush({"serviceAccount": str(self.account), "category": "WORK", "testMessage": True},
                          opener=self.opener)

    def test_real_ps256_signature_and_claims_verify_locally(self):
        sender = self.sender()
        token = sender.jwt(NOW // 1000)
        header, claims, signature = token.split(".")
        decode = lambda value: base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        self.assertEqual(json.loads(decode(header))["alg"], "PS256")
        parsed = json.loads(decode(claims))
        self.assertEqual((parsed["iss"], parsed["aud"], parsed["exp"] - parsed["iat"]),
                         ("synthetic-issuer", AUDIENCE, 3600))
        signature_path = self.root / "signature.bin"
        signature_path.write_bytes(decode(signature))
        result = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-verify", str(self.pub),
                                 "-signature", str(signature_path), "-sigopt", "rsa_padding_mode:pss",
                                 "-sigopt", "rsa_pss_saltlen:32"], input=(header + "." + claims).encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.opener.requests, [])

    def test_v3_payload_privacy_expiry_and_provider_result(self):
        sender = self.sender()
        value = {**event(body="中" * 8000), "deviceName": "示例电脑", "deviceId": "mac", "hostId": "private-host", "cursor": 42}
        registration = {"installationId": "install", "pushToken": "synthetic", "previewMode": "source"}
        self.assertTrue(sender.send(value, registration, "n" * 43, NOW))
        request = self.opener.requests[-1]
        self.assertEqual(request.full_url, "https://push-api.cloud.huawei.com/v3/synthetic-project/messages:send")
        payload = json.loads(request.data)
        notification = payload["payload"]["notification"]
        self.assertFalse(notification["foregroundShow"])
        self.assertNotIn("中", notification["body"])
        self.assertNotIn("hostId", json.dumps(payload))
        self.assertEqual(notification["clickAction"]["data"],
                         {"screenLinkPushNonce": "n" * 43, "screenLinkInstallationId": "install"})
        registration["previewMode"] = "full"
        payload = sender.payload(value, registration, "n" * 43, NOW)
        self.assertLessEqual(len(compact({k: v for k, v in payload.items() if k != "target"})), 4096)
        self.opener.code = "80100000"
        self.assertFalse(sender.send(value, registration, "n" * 43, NOW))
        count = len(self.opener.requests)
        self.assertFalse(sender.send(value, registration, "n" * 43, NOW + 300001))
        self.assertEqual(len(self.opener.requests), count)
        self.assertIsNone(NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid"))


class OptionalConfigTests(unittest.TestCase):
    def test_optional_persistence_and_push_validation(self):
        data = notification_tests.ConfigTests().valid()
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "config.json"
            data["statePath"] = "state.sqlite"
            data["push"] = {"serviceAccount": "account.json", "category": "WORK", "testMessage": True}
            path.write_text(json.dumps(data))
            config_value = load_config(path)
            self.assertEqual(config_value.state_path, (Path(root) / "state.sqlite").resolve())
            del data["statePath"]
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                load_config(path)


if __name__ == "__main__":
    unittest.main()
