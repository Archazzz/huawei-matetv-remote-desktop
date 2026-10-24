"""Notification-only Codex hook. No transcript access, approval output or user config edits."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import ssl
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, HTTPSHandler, ProxyHandler, Request, build_opener

MAX_INPUT = 1024 * 1024
DELIVERY_DEADLINE = 4
HOOK_STATUS = "屏间：转发 Codex 完成事件"


def strict_json(raw: bytes):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate field")
            result[key] = value
        return result
    return json.loads(raw.decode("utf-8"), object_pairs_hook=pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError("invalid number")))


def valid_text(value, limit, empty=False):
    if not isinstance(value, str) or len(value) > limit or (not empty and not value.strip()):
        raise ValueError("invalid text")
    if any((ord(c) < 32 and c not in "\n\t") or 127 <= ord(c) <= 159 or
           0xD800 <= ord(c) <= 0xDFFF for c in value):
        raise ValueError("invalid text")
    return value


def load_config(path: Path):
    data = strict_json(path.read_bytes())
    required = {"relayUrl", "token", "caFile"}
    if not isinstance(data, dict) or not required <= data.keys() or data.keys() - required - {"permissionRequests"}:
        raise ValueError("invalid config")
    origin = urlsplit(data["relayUrl"])
    if origin.scheme != "https" or not origin.hostname or origin.username or origin.password or \
            origin.query or origin.fragment or origin.path not in ("", "/"):
        raise ValueError("HTTPS origin required")
    if origin.port is not None and not 1 <= origin.port <= 65535:
        raise ValueError("invalid port")
    token = data["token"]
    if not isinstance(token, str) or not 32 <= len(token) <= 256 or not token.isascii() or \
            any(ord(c) < 33 or ord(c) > 126 for c in token) or "REPLACE" in token:
        raise ValueError("invalid token")
    if type(data.get("permissionRequests", False)) is not bool:
        raise ValueError("permissionRequests must be boolean")
    ca = Path(valid_text(data["caFile"], 4096))
    if not ca.is_absolute():
        ca = path.parent / ca
    return {**data, "caFile": str(ca.resolve()), "permissionRequests": data.get("permissionRequests", False)}


def make_event(payload, *, permission_requests=False, now_ms=None):
    if not isinstance(payload, dict):
        raise ValueError("object required")
    kind = payload.get("hook_event_name")
    if kind == "Stop":
        # Avoid notifying again for a continuation initiated by a blocking Stop hook.
        if payload.get("stop_hook_active", False) is not False:
            return None
        body = payload.get("last_assistant_message")
        if body is None or body == "":
            return None
        valid_text(body, MAX_INPUT)
        state = "truncated" if len(body) > 8000 else "complete"
        body = body[:8000]
        title = "Codex 回答完成"
    elif kind == "PermissionRequest" and permission_requests:
        # This event precedes automatic/user approval. Never say it is awaiting a human.
        tool = valid_text(payload.get("tool_name"), 128)
        body, title, state = "工具：" + tool, "Codex 权限请求", "unknown"
    else:
        return None
    session = valid_text(payload.get("session_id"), 256)
    turn = valid_text(payload.get("turn_id"), 256)
    # Opaque identity only: never forward prompt, cwd, tool arguments or transcript path.
    identity = [kind, session, turn]
    if kind == "PermissionRequest":
        identity.append(body)
    digest = hashlib.sha256(json.dumps(identity, ensure_ascii=False).encode()).hexdigest()
    now = int(time.time() * 1000) if now_ms is None else now_ms
    return {"eventId": "codex-" + digest, "appId": "codex", "appName": "Codex",
            "title": title, "body": body, "createdAt": now, "expiresAt": now + 300000,
            "contentState": state}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


def deliver(config, event):
    context = ssl.create_default_context(cafile=config["caFile"])
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    request = Request(config["relayUrl"].rstrip("/") + "/v1/events",
                      data=json.dumps(event, ensure_ascii=False).encode("utf-8"),
                      headers={"Authorization": "Bearer " + config["token"],
                               "Content-Type": "application/json"}, method="POST")
    opener = build_opener(ProxyHandler({}), HTTPSHandler(context=context), NoRedirect())
    with opener.open(request, timeout=2) as response:
        result = strict_json(response.read(4097))
        if response.status not in (200, 201) or not isinstance(result, dict) or result.get("accepted") is not True:
            raise ValueError("not accepted")


def worker(config_path, raw):
    config = load_config(config_path)
    event = make_event(strict_json(raw), permission_requests=config["permissionRequests"])
    if event is not None:
        deliver(config, event)


def run_hook(config_path, raw):
    """A worker deadline also bounds DNS, TLS and servers sending slow responses."""
    if len(raw) > MAX_INPUT:
        return
    child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--worker", "--config", str(config_path)],
                             stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        child.communicate(raw, timeout=DELIVERY_DEADLINE)
    except subprocess.TimeoutExpired:
        child.kill()
        child.communicate()


def merged_hooks(existing, command):
    """Return a new candidate; preserve unknown fields and every pre-existing handler."""
    result = json.loads(json.dumps(existing))
    if not isinstance(result, dict):
        raise ValueError("hooks root must be object")
    hooks = result.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("hooks must be object")
    groups = hooks.setdefault("Stop", [])
    if not isinstance(groups, list):
        raise ValueError("Stop must be list")
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            raise ValueError("invalid Stop handler group")
        for handler in group["hooks"]:
            if isinstance(handler, dict) and handler.get("command") == command:
                return result
    groups.append({"hooks": [{"type": "command", "command": command, "timeout": 6,
                               "statusMessage": HOOK_STATUS}]})
    return result


def write_candidate(args):
    # Offline preparation only. Refuse in-place modification and refuse overwrite.
    existing = strict_json(args.existing.read_bytes()) if args.existing else {}
    if args.existing and args.existing.resolve() == args.output.resolve():
        raise ValueError("candidate must be a different file")
    command_args = [str(args.python.resolve()), str(Path(__file__).resolve()), "--config", str(args.config.resolve())]
    command = subprocess.list2cmdline(command_args) if os.name == "nt" else shlex.join(command_args)
    result = merged_hooks(existing, command)
    with args.output.open("x", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False, indent=2)
        output.write("\n")


def main(argv=None):
    args_list = list(sys.argv[1:] if argv is None else argv)
    if args_list[:1] == ["prepare-hooks"]:
        parser = argparse.ArgumentParser(description="Prepare merged hooks candidate without installing it")
        parser.add_argument("--existing", type=Path)
        parser.add_argument("--output", type=Path, required=True)
        parser.add_argument("--config", type=Path, required=True)
        parser.add_argument("--python", type=Path, default=Path(sys.executable))
        args = parser.parse_args(args_list[1:])
        try:
            write_candidate(args)
            return 0
        except Exception:
            print("Could not prepare hooks candidate; no existing file was changed.", file=sys.stderr)
            return 1
    # No stdout, no error payload, no allow/deny output, and always zero for hook calls.
    try:
        parser = argparse.ArgumentParser(add_help=False, exit_on_error=False)
        parser.add_argument("--config", type=Path, required=True)
        parser.add_argument("--worker", action="store_true")
        args = parser.parse_args(args_list)
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) <= MAX_INPUT:
            if args.worker:
                worker(args.config, raw)
            else:
                run_hook(args.config, raw)
    except (Exception, SystemExit):
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
