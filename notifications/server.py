"""TLS-only notification inbox. Nothing starts on import; no remote passwords."""
from __future__ import annotations

import argparse
import hashlib
import hmac
import ipaddress
import json
import re
import secrets
import socket
import sqlite3
import ssl
import threading
import time
import uuid
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from .persistence import SnapshotStore

MAX_BODY_BYTES = 49152
MAX_TTL_MS = 24 * 60 * 60 * 1000
MAX_FUTURE_MS = 60000
IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
EVENT_FIELDS = {"eventId", "appId", "appName", "title", "body", "createdAt", "expiresAt", "contentState"}


class RequestError(Exception):
    def __init__(self, status: int, code: str):
        self.status, self.code = status, code
        super().__init__(code)


def text_field(value: object, limit: int, *, empty: bool = False) -> str:
    if not isinstance(value, str) or len(value) > limit or (not empty and not value.strip()):
        raise ValueError("invalid text")
    # Plain text only; retain meaningful newlines but reject control/surrogate code points.
    if any((ord(c) < 32 and c not in "\n\t") or 127 <= ord(c) <= 159 or
           0xD800 <= ord(c) <= 0xDFFF for c in value):
        raise ValueError("invalid text")
    return value


def identifier(value: object) -> str:
    if not isinstance(value, str) or IDENTIFIER.fullmatch(value) is None:
        raise ValueError("invalid identifier")
    return value


def secret(value: object) -> str:
    if not isinstance(value, str) or not 32 <= len(value) <= 256 or not value.isascii() or \
            any(c.isspace() for c in value) or "REPLACE" in value:
        raise ValueError("credentials must be independent random ASCII secrets of 32–256 characters")
    return value


def exact_keys(value: object, keys: set[str]) -> dict:
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError("unexpected or missing fields")
    return value


def strict_json(raw: bytes) -> object:
    def pairs(items: list[tuple[str, object]]) -> dict:
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate JSON field")
            result[key] = value
        return result
    return json.loads(raw.decode("utf-8"), object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError("invalid number")))


@dataclass(frozen=True)
class Device:
    device_id: str
    device_name: str
    host_id: str
    token: str
    apps: dict[str, str]


@dataclass(frozen=True)
class Config:
    listen_host: str
    listen_port: int
    cert: Path
    key: Path
    tv_token: str
    devices: tuple[Device, ...]
    max_events: int = 1000
    state_path: Path | None = None
    push: dict | None = None


def load_config(path: Path) -> Config:
    data = strict_json(path.read_bytes())
    required = {"listenHost", "listenPort", "tlsCert", "tlsKey", "tvToken", "devices", "maxEvents"}
    if not isinstance(data, dict) or not required <= set(data) or set(data) - required - {"statePath", "push"}:
        raise ValueError("unexpected or missing configuration fields")
    address = ipaddress.ip_address(data["listenHost"])
    # Explicit private/loopback/CGNAT addresses only. Never bind unspecified/global interfaces.
    networks = ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10") \
        if address.version == 4 else ("::1/128", "fc00::/7")
    permitted = any(address in ipaddress.ip_network(network) for network in networks)
    if not permitted or address.is_unspecified or address.is_multicast or address.is_link_local:
        raise ValueError("listenHost must be an explicit local/private/Tailscale address")
    port, capacity = data["listenPort"], data["maxEvents"]
    if type(port) is not int or not 1 <= port <= 65535 or type(capacity) is not int or not 1 <= capacity <= 10000:
        raise ValueError("invalid port or capacity")
    tv_token = secret(data["tvToken"])
    if not isinstance(data["devices"], list) or not 1 <= len(data["devices"]) <= 100:
        raise ValueError("devices must contain 1–100 entries")
    devices = []
    ids, tokens = set(), {tv_token}
    for row in data["devices"]:
        exact_keys(row, {"deviceId", "deviceName", "hostId", "token", "apps"})
        device_id, token = identifier(row["deviceId"]), secret(row["token"])
        if device_id in ids or token in tokens:
            raise ValueError("duplicate device or shared credential")
        apps = row["apps"]
        if not isinstance(apps, dict) or not 1 <= len(apps) <= 20:
            raise ValueError("apps must map allowed appId to trusted appName")
        checked_apps = {identifier(k): text_field(v, 80) for k, v in apps.items()}
        if checked_apps != {"codex": "Codex"}:
            raise ValueError("only Codex notifications are supported")
        devices.append(Device(device_id, text_field(row["deviceName"], 80),
                              text_field(row["hostId"], 128), token, checked_apps))
        ids.add(device_id)
        tokens.add(token)
    def config_path(name: str) -> Path:
        value = data[name]
        if not isinstance(value, str) or not value:
            raise ValueError("TLS paths are required")
        return (path.parent / value).resolve()
    state_path = config_path("statePath") if "statePath" in data else None
    push = data.get("push")
    if push is not None:
        exact_keys(push, {"serviceAccount", "category", "testMessage"})
        if state_path is None or type(push["testMessage"]) is not bool or \
                push["category"] not in ("WORK", "MARKETING"):
            raise ValueError("push requires persistent state and an explicitly approved category")
        if not isinstance(push["serviceAccount"], str) or not push["serviceAccount"]:
            raise ValueError("push serviceAccount path required")
        push = {**push, "serviceAccount": str((path.parent / push["serviceAccount"]).resolve())}
    return Config(str(address), port, config_path("tlsCert"), config_path("tlsKey"),
                  tv_token, tuple(devices), capacity, state_path, push)


def tls_context(config: Config) -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(config.cert, config.key)
    return context


class Inbox:
    def __init__(self, config: Config, clock=None, push_sender=None):
        self.config = config
        self.clock = clock or (lambda: int(time.time() * 1000))
        self.lock = threading.Lock()
        self.events: list[dict] = []
        self.cursor = 0
        self.pruned_through = 0
        self.stream_id = str(uuid.uuid4())
        self.registration: dict | None = None
        self.clicks: dict[str, dict] = {}
        self.jobs: list[dict] = []
        self.push_sender = push_sender
        self.state = SnapshotStore(config.state_path) if config.state_path is not None else None
        self.tv_identity = hashlib.sha256(config.tv_token.encode()).hexdigest()
        if self.state is not None:
            saved = self.state.load()
            if saved is not None:
                if saved.get("version") != 1:
                    raise ValueError("unsupported persistent notification state")
                self.events = saved["events"]
                self.cursor = saved["cursor"]
                self.pruned_through = saved["prunedThrough"]
                self.stream_id = saved["streamId"]
                if saved.get("tvIdentity") == self.tv_identity:
                    self.registration = saved["registration"]
                    self.clicks = saved["clicks"]
                    self.jobs = saved["jobs"]
            self._expire(self.clock())
            self._save()

    def _save(self):
        if self.state is not None:
            try:
                self.state.save({"version": 1, "events": self.events, "cursor": self.cursor,
                                 "prunedThrough": self.pruned_through, "streamId": self.stream_id,
                                 "tvIdentity": self.tv_identity, "registration": self.registration,
                                 "clicks": self.clicks, "jobs": self.jobs})
            except sqlite3.Error:
                # A rejected registration/event must not become live only in memory.
                if self.state.last_raw is not None:
                    saved = json.loads(self.state.last_raw)
                    self.events, self.cursor = saved["events"], saved["cursor"]
                    self.pruned_through, self.stream_id = saved["prunedThrough"], saved["streamId"]
                    if saved["tvIdentity"] == self.tv_identity:
                        self.registration, self.clicks, self.jobs = saved["registration"], saved["clicks"], saved["jobs"]
                    else:
                        self.registration, self.clicks, self.jobs = None, {}, []
                raise

    def _device_still_paired(self, event: dict) -> bool:
        return event.get("appId") == "codex" and event.get("appName") == "Codex" and any(device.device_id == event["deviceId"] and device.host_id == event["hostId"] and
                   device.apps.get(event["appId"]) == event["appName"] for device in self.config.devices)

    def authenticate(self, authorization: str | None, tv: bool) -> Device | None:
        if not isinstance(authorization, str) or not authorization.startswith("Bearer "):
            raise RequestError(401, "unauthorized")
        token = authorization[7:]
        if not 32 <= len(token) <= 256 or not token.isascii():
            raise RequestError(401, "unauthorized")
        digest = hashlib.sha256(token.encode("ascii")).digest()
        if tv:
            matched = hmac.compare_digest(digest, hashlib.sha256(self.config.tv_token.encode()).digest())
            if matched:
                return None
        else:
            selected = None
            # Scan all entries; do not return early based on a matching secret.
            for device in self.config.devices:
                if hmac.compare_digest(digest, hashlib.sha256(device.token.encode()).digest()):
                    selected = device
            if selected is not None:
                return selected
        raise RequestError(401, "unauthorized")

    def _expire(self, now: int) -> None:
        kept = []
        for event in self.events:
            if event["expiresAt"] <= now or not self._device_still_paired(event):
                self.pruned_through = max(self.pruned_through, event["cursor"])
            else:
                kept.append(event)
        self.events = kept
        cursors = {event["cursor"] for event in self.events}
        self.clicks = {nonce: item for nonce, item in self.clicks.items()
                       if item["cursor"] in cursors and item["expiresAt"] > now}
        self.jobs = [job for job in self.jobs if job["nonce"] in self.clicks]

    def publish(self, device: Device, payload: object) -> tuple[int, dict]:
        now = self.clock()
        try:
            event = dict(exact_keys(payload, EVENT_FIELDS))
            event["eventId"] = identifier(event["eventId"])
            event["appId"] = identifier(event["appId"])
            if event["appId"] != "codex" or event["appName"] != "Codex" or \
                    event["appId"] not in device.apps or event["appName"] != device.apps[event["appId"]]:
                raise RequestError(403, "source_not_allowed")
            text_field(event["appName"], 80)
            text_field(event["title"], 256, empty=True)
            text_field(event["body"], 8000, empty=True)
            if not event["title"].strip() and not event["body"].strip():
                raise ValueError("empty event")
            created, expires = event["createdAt"], event["expiresAt"]
            if type(created) is not int or type(expires) is not int or created < 0 or \
                    created > now + MAX_FUTURE_MS or expires <= now or expires <= created or \
                    expires - created > MAX_TTL_MS:
                raise ValueError("invalid event times")
            if event["contentState"] not in ("complete", "truncated", "hidden", "unknown"):
                raise ValueError("invalid content state")
        except (ValueError, TypeError):
            raise RequestError(400, "invalid_event") from None
        event.update(deviceId=device.device_id, deviceName=device.device_name, hostId=device.host_id)
        with self.lock:
            self._expire(now)
            for previous in self.events:
                if previous["deviceId"] == device.device_id and previous["eventId"] == event["eventId"]:
                    if {k: v for k, v in previous.items() if k != "cursor"} != event:
                        raise RequestError(409, "event_id_conflict")
                    self._save()
                    return 200, {"accepted": True, "duplicate": True, "cursor": previous["cursor"]}
            if len(self.events) >= self.config.max_events:
                raise RequestError(429, "inbox_full")
            self.cursor += 1
            event["cursor"] = self.cursor
            self.events.append(event)
            if self.registration is not None and self.push_sender is not None:
                nonce = secrets.token_urlsafe(32)
                self.clicks[nonce] = {"cursor": self.cursor, "expiresAt": event["expiresAt"],
                                     "generation": self.registration["generation"],
                                     "installationId": self.registration["installationId"],
                                     "scope": self.registration["scope"]}
                self.jobs.append({"nonce": nonce, "attempts": 0, "nextAt": now})
            self._save()
            return 201, {"accepted": True, "duplicate": False, "cursor": self.cursor}

    def poll(self, after: int) -> dict:
        if type(after) is not int or after < 0:
            raise RequestError(400, "invalid_cursor")
        with self.lock:
            self._expire(self.clock())
            self._save()
            reset = after > self.cursor or (after > 0 and after < self.pruned_through)
            start = 0 if after > self.cursor else after
            events = [dict(e) for e in self.events if e["cursor"] > start][:100]
            next_cursor = events[-1]["cursor"] if events else self.cursor
            return {"events": events, "nextCursor": next_cursor, "resetRequired": reset,
                    "streamId": self.stream_id}

    def register_push(self, payload: object) -> dict:
        if self.state is None:
            raise RequestError(503, "persistent_state_required")
        try:
            if not isinstance(payload, dict) or set(payload) not in (
                    {"installationId", "pushToken", "previewMode"},
                    {"installationId", "pushToken", "previewMode", "scope"}):
                raise ValueError("invalid registration")
            installation = identifier(payload["installationId"])
            token = text_field(payload["pushToken"], 4096)
            if not token.isascii() or any(c.isspace() for c in token):
                raise ValueError("invalid token")
            preview = payload["previewMode"]
            if preview not in ("full", "source"):
                raise ValueError("invalid preview")
            scope = text_field(payload.get("scope", "local"), 256)
        except (ValueError, TypeError):
            raise RequestError(400, "invalid_registration") from None
        with self.lock:
            if self.registration and self.registration["installationId"] != installation:
                raise RequestError(409, "installation_already_registered")
            fields = {"installationId": installation, "pushToken": token, "previewMode": preview, "scope": scope}
            unchanged = self.registration and all(self.registration[k] == v for k, v in fields.items())
            if not unchanged:
                self.registration = {**fields, "generation": str(uuid.uuid4())}
                self.clicks.clear()
                self.jobs.clear()
                self._save()
            return {"registered": True, "cloudConfigured": self.push_sender is not None}

    def revoke_push(self, payload: object) -> dict:
        try:
            installation = identifier(exact_keys(payload, {"installationId"})["installationId"])
        except (ValueError, TypeError):
            raise RequestError(400, "invalid_registration") from None
        with self.lock:
            if self.registration and self.registration["installationId"] == installation:
                self.registration = None
                self.clicks.clear()
                self.jobs.clear()
                self._save()
            return {"revoked": True}

    def resolve_push(self, payload: object) -> dict:
        try:
            exact_keys(payload, {"installationId", "clickNonce", "scope"})
            installation = identifier(payload["installationId"])
            nonce = payload["clickNonce"]
            scope = text_field(payload["scope"], 256)
            if not isinstance(nonce, str) or re.fullmatch(r"[A-Za-z0-9_-]{43}", nonce) is None:
                raise ValueError("invalid nonce")
        except (ValueError, TypeError):
            raise RequestError(400, "invalid_click") from None
        with self.lock:
            self._expire(self.clock())
            self._save()
            item = self.clicks.get(nonce)
            registration = self.registration
            if not item or not registration or installation != registration["installationId"] or \
                    installation != item["installationId"] or scope != item["scope"] or \
                    scope != registration["scope"] or item["generation"] != registration["generation"]:
                raise RequestError(404, "click_unavailable")
            event = next((event for event in self.events if event["cursor"] == item["cursor"]), None)
            if event is None or not self._device_still_paired(event):
                raise RequestError(404, "click_unavailable")
            return {"event": dict(event), "streamId": self.stream_id, "scope": scope}

    def process_push_once(self) -> bool:
        with self.lock:
            now = self.clock()
            self._expire(now)
            self.jobs = [job for job in self.jobs if job["attempts"] < 3]
            # Maintenance also runs with cloud disabled, so expired plaintext
            # does not wait for a TV poll before being removed from SQLite.
            self._save()
            if self.push_sender is None:
                return False
            job = next((job for job in self.jobs if job["nextAt"] <= now), None)
            if job is None or self.registration is None:
                return False
            nonce = job["nonce"]
            item = self.clicks[nonce]
            event = next(event for event in self.events if event["cursor"] == item["cursor"])
            registration = dict(self.registration)
            job["attempts"] += 1
            job["nextAt"] = now + 60000
            self._save()  # Persist before I/O: restart must not send an unbounded burst.
        try:
            sent = self.push_sender.send(dict(event), registration, nonce, now)
        except Exception:
            sent = False  # No exception details: providers may include credentials or payloads.
        with self.lock:
            # An in-flight request may finish after revoke; it cannot restore any mapping.
            if job not in self.jobs:
                return True
            if sent or job["attempts"] >= 3:
                self.jobs.remove(job)
            else:
                job["nextAt"] = self.clock() + 10000 * (2 ** (job["attempts"] - 1))
            self._save()
        return True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    server_version = "ScreenLinkNotifications"

    def setup(self):
        self.request.settimeout(5)
        super().setup()

    def log_message(self, format, *args):
        pass  # Paths, headers and event text never enter request logs.

    def _respond(self, status: int, value: dict):
        raw = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)

    def _handle(self, tv: bool):
        try:
            parsed = urlsplit(self.path)
            push_paths = {"/v1/push/register", "/v1/push/revoke", "/v1/push/resolve"}
            push_request = self.command == "POST" and parsed.path in push_paths
            if (parsed.path != "/v1/events" and not push_request) or parsed.fragment or parsed.scheme or parsed.netloc:
                raise RequestError(404, "not_found")
            if len(self.headers.get_all("Authorization", [])) != 1:
                raise RequestError(401, "unauthorized")
            inbox: Inbox = self.server.inbox
            device = inbox.authenticate(self.headers.get("Authorization"), tv or push_request)
            if tv:
                query = parse_qs(parsed.query, keep_blank_values=True)
                if set(query) != {"after"} or len(query["after"]) != 1 or \
                        re.fullmatch(r"[0-9]{1,16}", query["after"][0]) is None:
                    raise RequestError(400, "invalid_cursor")
                self._respond(200, inbox.poll(int(query["after"][0])))
            else:
                if parsed.query:
                    raise RequestError(400, "invalid_query")
                if self.headers.get("Transfer-Encoding") is not None or \
                        len(self.headers.get_all("Content-Length", [])) != 1:
                    raise RequestError(400, "invalid_content_length")
                length = self.headers.get("Content-Length", "")
                if not length.isascii() or not length.isdecimal() or len(length) > 8:
                    raise RequestError(400, "invalid_content_length")
                count = int(length)
                if not 1 <= count <= MAX_BODY_BYTES:
                    raise RequestError(413, "body_too_large")
                if self.headers.get_content_type() != "application/json":
                    raise RequestError(415, "json_required")
                raw = self.rfile.read(count)
                if len(raw) != count:
                    raise RequestError(400, "incomplete_body")
                try:
                    payload = strict_json(raw)
                except (ValueError, UnicodeError, RecursionError):
                    raise RequestError(400, "invalid_json") from None
                if push_request:
                    handlers = {"/v1/push/register": inbox.register_push,
                                "/v1/push/revoke": inbox.revoke_push,
                                "/v1/push/resolve": inbox.resolve_push}
                    code, value = 200, handlers[parsed.path](payload)
                else:
                    code, value = inbox.publish(device, payload)
                self._respond(code, value)
        except RequestError as error:
            self._respond(error.status, {"error": error.code})
        except sqlite3.Error:
            self._respond(503, {"error": "state_unavailable"})
        except (TimeoutError, ConnectionError, OSError):
            self.close_connection = True

    def do_GET(self):
        self._handle(True)

    def do_POST(self):
        self._handle(False)


class NotificationServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, config: Config):
        # Load TLS before opening a socket; a missing certificate cannot cause plaintext fallback.
        context = tls_context(config)
        self.address_family = socket.AF_INET6 if ":" in config.listen_host else socket.AF_INET
        sender = None
        if config.push is not None:
            from .huawei_push import HuaweiPush
            sender = HuaweiPush(config.push)
        self.inbox = Inbox(config, push_sender=sender)
        self.tls = context
        self.slots = threading.BoundedSemaphore(16)
        self.push_stop = threading.Event()
        self.push_worker = None
        super().__init__((config.listen_host, config.listen_port), Handler)
        if sender is not None or config.state_path is not None:
            self.push_worker = threading.Thread(target=self._push_loop, daemon=True)
            self.push_worker.start()

    def _push_loop(self):
        while not self.push_stop.wait(1):
            try:
                self.inbox.process_push_once()
            except Exception:
                # Fail closed and retain the queue; never log an exception containing event text.
                self.push_stop.wait(5)

    def server_close(self):
        self.push_stop.set()
        if self.push_worker is not None:
            self.push_worker.join(timeout=12)
        super().server_close()

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        wrapped = request
        try:
            request.settimeout(5)
            wrapped = self.tls.wrap_socket(request, server_side=True)
            self.finish_request(wrapped, client_address)
        except (OSError, ssl.SSLError):
            pass
        finally:
            self.shutdown_request(wrapped)
            self.slots.release()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        with NotificationServer(config) as server:
            print("ScreenLink notification TLS service started; no desktop collector is enabled.")
            server.serve_forever()
    except (ValueError, OSError, sqlite3.Error):
        parser.exit(1, "Configuration, certificate, or listener unavailable; no plaintext fallback.\n")


if __name__ == "__main__":
    main()
