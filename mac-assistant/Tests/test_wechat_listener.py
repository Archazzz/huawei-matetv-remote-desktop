import importlib.util
import json
import plistlib
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from notifications.server import Config, Device, Inbox

FILE = Path(__file__).resolve().parents[1] / "wechat_listener.py"
spec = importlib.util.spec_from_file_location("wechat_listener", FILE)
listener = importlib.util.module_from_spec(spec)
spec.loader.exec_module(listener)
NOW = 1_800_000_000.0


def blob(title="测试联系人", body="测试微信通知", subtitle=""):
    return plistlib.dumps({"req": {"titl": title, "subt": subtitle, "body": body,
                                  "usda": b"must-not-decode-private-chat-metadata"}}, fmt=plistlib.FMT_BINARY)


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "notifications.sqlite"
        self.db = sqlite3.connect(self.path)
        self.db.executescript('CREATE TABLE app(app_id INTEGER PRIMARY KEY, identifier TEXT);'
                             'CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,delivered_date REAL,data BLOB);')
        self.db.executemany("INSERT INTO app VALUES (?,?)", [(1, listener.BUNDLE_ID), (2, "com.other.app"), (3, "COM.TENCENT.XINWECHAT")])
        self.clock = NOW

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def insert(self, *, source=1, text=None, delivered=None):
        result = self.db.execute("INSERT INTO record(app_id,uuid,delivered_date,data) VALUES(?,?,?,?)",
                               (source, b"test-uuid", (self.clock if delivered is None else delivered) - listener.APPLE_EPOCH,
                                blob() if text is None else text))
        self.db.commit()
        return result.lastrowid

    def test_baseline_never_reads_old_bodies_and_poll_excludes_other_apps(self):
        self.insert(text=b"historical-secret-not-even-valid-plist")
        source = listener.Source(self.path, clock=lambda: self.clock)
        self.assertEqual(source.cursor, 1)
        self.assertEqual(source.poll(include_content=True), ([], False))
        self.clock += 1
        self.insert(source=2, text=b"foreign-private-body")
        self.insert(source=3, text=b"wrong-case-source")
        self.insert()
        rows, reset = source.poll(include_content=True)
        self.assertFalse(reset)
        self.assertEqual(len(rows), 1)
        event = listener.make_event(rows[0], include_content=True, now=self.clock)
        self.assertEqual((event["appId"], event["body"], event["contentState"]), ("wechat", "测试微信通知", "unknown"))
        self.assertEqual(source.poll(include_content=True), ([], False))

    def test_withheld_mode_does_not_select_blob(self):
        source = listener.Source(self.path, clock=lambda: self.clock)
        self.clock += 1
        self.insert(text=b"private text should never be read")
        rows, _ = source.poll(include_content=False)
        self.assertIsNone(rows[0][3])
        event = listener.make_event(rows[0], include_content=False, now=self.clock)
        self.assertEqual((event["title"], event["body"], event["contentState"]), ("微信通知", "", "hidden"))

    def test_delayed_historical_or_oversize_payload_not_decoded(self):
        source = listener.Source(self.path, clock=lambda: self.clock)
        self.clock += 1
        self.insert(delivered=NOW - 300)
        self.insert(text=b"x" * (listener.MAX_BLOB + 1))
        rows, _ = source.poll(include_content=True)
        self.assertEqual(len(rows), 1)
        self.assertIsNone(rows[0][3])
        with self.assertRaises(listener.UnsupportedSource):
            listener.make_event(rows[0], include_content=True, now=self.clock)

    def test_unknown_schema_fails_closed_before_bodies(self):
        source = listener.Source(self.path, clock=lambda: self.clock)
        self.db.execute("ALTER TABLE record ADD COLUMN changed TEXT")
        self.db.commit()
        with self.assertRaises(listener.UnsupportedSource):
            source.poll(include_content=True)

    def test_readonly_connection_rejects_writes(self):
        source = listener.Source(self.path, clock=lambda: self.clock)
        connection = source._connect()
        try:
            with self.assertRaises(sqlite3.OperationalError):
                connection.execute("DELETE FROM record")
        finally:
            connection.close()

    def test_clear_rebaselines_instead_of_replaying(self):
        self.insert()
        source = listener.Source(self.path, clock=lambda: self.clock)
        self.db.execute("DELETE FROM record")
        self.db.commit()
        self.assertEqual(source.poll(include_content=True), ([], True))

    def test_batches_do_not_drop_other_new_wechat_rows(self):
        source = listener.Source(self.path, clock=lambda: self.clock)
        self.clock += 1
        for _ in range(listener.MAX_BATCH + 3):
            self.insert()
        first, _ = source.poll(include_content=True)
        second, _ = source.poll(include_content=True)
        self.assertEqual((len(first), len(second)), (listener.MAX_BATCH, 3))
        self.assertEqual(source.poll(include_content=True), ([], False))

    def test_original_text_truncation_and_invalid_source(self):
        row = (1, b"uuid", NOW - listener.APPLE_EPOCH, blob(body="🙂" * 8001, subtitle="副标题"), listener.BUNDLE_ID)
        event = listener.make_event(row, include_content=True, now=NOW)
        self.assertTrue(event["body"].startswith("副标题\n"))
        self.assertEqual(len(event["body"]), 8000)
        self.assertEqual(event["contentState"], "truncated")
        with self.assertRaises(listener.UnsupportedSource):
            listener.make_event((*row[:4], "other"), include_content=True, now=NOW)
        with self.assertRaises(ValueError):
            listener.make_event((1,b"id",NOW-listener.APPLE_EPOCH,blob(body="bad\x00"),listener.BUNDLE_ID), include_content=True, now=NOW)

    def test_output_matches_relay_validation(self):
        token = "writer-" + "w" * 40
        config = Config("127.0.0.1", 24443, Path("unused"), Path("unused"), "reader-" + "r" * 40,
                        (Device("wechat-helper", "Mac", "saved-mac", token, {"wechat": "微信"}),), 10)
        inbox = Inbox(config, lambda: int(NOW * 1000))
        for number, include in enumerate([False, True]):
            row = (number + 1, b"uuid", NOW - listener.APPLE_EPOCH, blob(), listener.BUNDLE_ID)
            event = listener.make_event(row, include_content=include, now=NOW)
            self.assertEqual(inbox.publish(config.devices[0], event)[0], 201)

    def test_source_permission_denied_not_retried_or_fallback(self):
        with patch.object(Path, "open", side_effect=PermissionError(1, "denied")):
            with self.assertRaises(PermissionError):
                listener.Source(self.path)


if __name__ == "__main__":
    unittest.main()
