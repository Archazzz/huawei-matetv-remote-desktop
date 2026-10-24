"""Explicit, read-only, forward-only macOS WeChat system-notification listener."""
from __future__ import annotations
import argparse
from contextlib import closing
import hashlib
import json
import math
import os
import plistlib
import signal
import ssl
import sqlite3
import subprocess
import sys
import threading
import time
from pathlib import Path

# Both repository and packaged layout provide the shared, verified TLS sender.
REPO = Path(__file__).resolve().parent.parent
if (REPO / "notifications").is_dir():
    sys.path.insert(0, str(REPO))
from notifications.codex_hook import deliver, load_config, strict_json, valid_text

BUNDLE_ID = "com.tencent.xinWeChat"
APPLE_EPOCH = 978307200
MAX_BLOB = 1_048_576
MAX_BATCH = 20
SOURCE = Path.home() / "Library/Group Containers/group.com.apple.usernoted/db2/db"


class UnsupportedSource(Exception):
    pass


def report(state, **values):
    # Callers provide fixed state codes and numeric counters, never source text/errors.
    print(json.dumps({"state": state, **values}), flush=True)


def read_config(path):
    data = strict_json(path.read_bytes())
    if not isinstance(data, dict) or set(data) != {"relayConfig", "forwardContent", "pollSeconds"}:
        raise ValueError("invalid config")
    if type(data["forwardContent"]) is not bool or type(data["pollSeconds"]) not in (int, float) or \
            not 0.5 <= data["pollSeconds"] <= 10:
        raise ValueError("invalid config")
    relay = Path(valid_text(data["relayConfig"], 4096))
    if not relay.is_absolute():
        relay = path.parent / relay
    relay_config = load_config(relay)
    ssl.create_default_context(cafile=relay_config["caFile"])  # Validate local trust before touching source.
    return {**data, "relayConfig": relay.resolve()}


class Source:
    """The constructor reads schema and MAX(rowid), never existing notification bodies."""
    def __init__(self, path=SOURCE, *, clock=time.time):
        self.path, self.clock = Path(path), clock
        self.identity = None
        self.cursor = 0
        self.started = clock()
        self.schema_version = None
        self._baseline()

    def _connect(self):
        # Read only the SQLite signature first; TCC errors propagate without fallback.
        with self.path.open("rb") as stream:
            if stream.read(16) != b"SQLite format 3\x00":
                raise UnsupportedSource()
        connection = sqlite3.connect(self.path.as_uri() + "?mode=ro", uri=True, timeout=0.5)
        connection.execute("PRAGMA query_only=ON")
        return connection

    def _metadata(self, connection):
        required = {"record": {"rec_id", "app_id", "uuid", "delivered_date", "data"},
                    "app": {"app_id", "identifier"}}
        for table, fields in required.items():
            columns = {row[1] for row in connection.execute("PRAGMA table_info(" + table + ")")}
            if not fields <= columns:
                raise UnsupportedSource()
        connection.execute("SELECT r.rowid,r.rec_id,r.uuid,r.delivered_date,r.data,a.identifier "
                           "FROM record r JOIN app a ON a.app_id=r.app_id LIMIT 0")
        version = connection.execute("PRAGMA schema_version").fetchone()[0]
        high = connection.execute("SELECT COALESCE(MAX(rowid),0) FROM record").fetchone()[0]
        return version, high

    def _stat(self):
        stat = self.path.stat()
        return stat.st_dev, stat.st_ino

    def _baseline(self):
        identity = self._stat()
        with closing(self._connect()) as connection:
            self.schema_version, self.cursor = self._metadata(connection)
        if identity != self._stat():
            raise UnsupportedSource()
        self.identity = identity
        self.started = self.clock()

    def poll(self, *, include_content):
        # A replaced/cleared database starts at a new baseline, never replays old rows.
        if self._stat() != self.identity:
            self._baseline()
            return [], True
        with closing(self._connect()) as connection:
            connection.execute("BEGIN")
            version, high = self._metadata(connection)
            if version != self.schema_version:
                raise UnsupportedSource()
            if high < self.cursor:
                self.cursor, self.started = high, self.clock()
                return [], True
            now = self.clock()
            data = "CASE WHEN length(r.data)<=? THEN r.data ELSE NULL END" if include_content else "NULL"
            parameters = ([MAX_BLOB] if include_content else []) + [self.cursor, high, BUNDLE_ID,
                           max(self.started, now - 120) - APPLE_EPOCH, now + 60 - APPLE_EPOCH, MAX_BATCH]
            rows = connection.execute(
                "SELECT r.rowid,r.uuid,r.delivered_date," + data + ",a.identifier "
                "FROM record r JOIN app a ON a.app_id=r.app_id "
                "WHERE r.rowid>? AND r.rowid<=? AND a.identifier COLLATE BINARY=? "
                "AND r.delivered_date>=? AND r.delivered_date<=? "
                "ORDER BY r.rowid LIMIT ?", parameters).fetchall()
            if self._stat() != self.identity:
                raise UnsupportedSource()
            self.cursor = rows[-1][0] if len(rows) == MAX_BATCH else high
        return rows, False


def make_event(row, *, include_content, now=None):
    record, uuid, delivered, blob, source = row
    if source != BUNDLE_ID or type(record) is not int or type(delivered) not in (int, float) or \
            not math.isfinite(delivered):
        raise UnsupportedSource()
    now = time.time() if now is None else now
    created = round((delivered + APPLE_EPOCH) * 1000)
    if not (now - 120) * 1000 <= created <= (now + 60) * 1000:
        raise UnsupportedSource()
    title, body, state = "微信通知", "", "hidden"
    if include_content:
        if not isinstance(blob, bytes) or not 0 < len(blob) <= MAX_BLOB:
            raise UnsupportedSource()
        document = plistlib.loads(blob)
        if not isinstance(document, dict) or not isinstance(document.get("req"), dict):
            raise UnsupportedSource()
        request = document["req"]
        # Decode only notification presentation fields. Never unarchive usda/chat metadata.
        if not any(key in request for key in ("titl", "subt", "body")):
            raise UnsupportedSource()
        values = [valid_text(request.get(key, ""), MAX_BLOB, empty=True) for key in ("titl", "subt", "body")]
        title = values[0]
        body = "\n".join(value for value in values[1:] if value)
        state = "truncated" if len(title) > 256 or len(body) > 8000 else "unknown"
        title, body = title[:256], body[:8000]
        if not title.strip() and not body.strip():
            title = "微信通知"
        # Database fields don't establish what macOS preview privacy actually displayed.
        # Even exact fields are UNKNOWN, never falsely advertised as complete/visible.
    identity = [record, created, uuid.hex() if isinstance(uuid, bytes) else str(uuid or "")]
    digest = hashlib.sha256(json.dumps(identity).encode()).hexdigest()
    return {"eventId": "wechat-" + digest, "appId": "wechat", "appName": "微信",
            "title": title, "body": body, "createdAt": created, "expiresAt": created + 300000,
            "contentState": state}


def send_bounded(config, event):
    child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "deliver-worker", "--config", str(config)],
                             stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        child.communicate(json.dumps(event, ensure_ascii=False).encode(), timeout=4)
        return child.returncode == 0
    except subprocess.TimeoutExpired:
        return False
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate()


def listen(config_path, *, source_path=SOURCE, duration=None):
    config = read_config(config_path)
    source = Source(source_path)
    stop = threading.Event()
    previous = {}
    for sig in (signal.SIGINT, signal.SIGTERM):
        previous[sig] = signal.signal(sig, lambda *_: stop.set())
    deadline = time.monotonic() + duration if duration is not None else None
    accepted = rejected = failures = 0
    report("listening", historicalBodiesRead=0, forwardContent=config["forwardContent"])
    try:
        while not stop.is_set() and (deadline is None or time.monotonic() < deadline):
            try:
                rows, reset = source.poll(include_content=config["forwardContent"])
            except sqlite3.OperationalError as error:
                if getattr(error, "sqlite_errorcode", None) in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
                    stop.wait(config["pollSeconds"])
                    continue
                raise
            if reset:
                report("source_rebaselined", historicalBodiesRead=0)
            for row in rows:
                if stop.is_set():
                    break
                try:
                    event = make_event(row, include_content=config["forwardContent"])
                except (ValueError, TypeError, OverflowError, UnsupportedSource, plistlib.InvalidFileException):
                    rejected += 1
                    continue
                if send_bounded(config["relayConfig"], event):
                    accepted += 1
                else:
                    failures += 1
            if rows:
                report("batch", accepted=accepted, unsupported=rejected, deliveryFailures=failures)
            stop.wait(config["pollSeconds"])
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        report("stopped", accepted=accepted, unsupported=rejected, deliveryFailures=failures)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "listen", "deliver-worker"])
    parser.add_argument("--config", type=Path)
    parser.add_argument("--duration", type=float)
    args = parser.parse_args(argv)
    try:
        if args.command == "check":
            Source()
            report("readable", historicalBodiesRead=0)
        elif args.command == "deliver-worker":
            if args.config is None:
                return 1
            raw = sys.stdin.buffer.read(49153)
            if len(raw) > 49152:
                return 1
            deliver(load_config(args.config), strict_json(raw))
        else:
            if args.config is None or (args.duration is not None and not 1 <= args.duration <= 86400):
                raise ValueError()
            listen(args.config, duration=args.duration)
        return 0
    except PermissionError:
        report("access_denied")
    except FileNotFoundError:
        report("source_or_config_missing")
    except (sqlite3.Error, UnsupportedSource):
        report("source_unsupported_or_unavailable")
    except Exception:
        report("configuration_or_delivery_error")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
