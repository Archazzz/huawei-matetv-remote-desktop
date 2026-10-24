"""Optional Huawei V3 sender. Construction/signing never sends network requests."""
from __future__ import annotations

import base64
import json
import os
import re
import stat
import subprocess
import tempfile
from pathlib import Path
from urllib.error import URLError
from urllib.request import HTTPRedirectHandler, HTTPSHandler, ProxyHandler, Request, build_opener

ENDPOINT = "https://push-api.cloud.huawei.com/v3/{project}/messages:send"
AUDIENCE = "https://oauth-login.cloud.huawei.com/oauth2/v3/token"


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def compact(value: dict) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def clipped(value: str, maximum: int) -> str:
    encoded = value.encode("utf-8")
    if len(encoded) <= maximum:
        return value
    return encoded[:maximum - 3].decode("utf-8", errors="ignore") + "…"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


class HuaweiPush:
    def __init__(self, settings: dict, *, openssl="/usr/bin/openssl", opener=None):
        path = Path(settings["serviceAccount"])
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
            raise ValueError("service account must be a private regular file")
        if info.st_size > 65536:
            raise ValueError("service account too large")
        account = json.loads(path.read_text())
        for field in ("project_id", "key_id", "sub_account", "private_key"):
            if not isinstance(account.get(field), str) or not account[field]:
                raise ValueError("invalid Huawei service account")
        if re.fullmatch(r"[A-Za-z0-9_-]{1,128}", account["project_id"]) is None:
            raise ValueError("invalid Huawei project ID")
        self.account = account
        self.category = settings["category"]
        self.test_message = settings["testMessage"]
        self.openssl = openssl
        self.opener = opener or build_opener(ProxyHandler({}), HTTPSHandler(), NoRedirect())
        self.cached_jwt = ""
        self.cached_until = 0
        # Validate PS256 support/key immediately, without network or persistent key copies.
        self.sign(b"screenlink-push-key-check")

    def sign(self, message: bytes) -> bytes:
        descriptor, filename = tempfile.mkstemp(prefix="screenlink-push-key-", suffix=".pem")
        try:
            with os.fdopen(descriptor, "w") as handle:
                handle.write(self.account["private_key"])
            result = subprocess.run(
                [self.openssl, "dgst", "-sha256", "-sign", filename,
                 "-sigopt", "rsa_padding_mode:pss", "-sigopt", "rsa_pss_saltlen:32"],
                input=message, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10, check=False)
            if result.returncode or len(result.stdout) < 256:
                raise ValueError("PS256 signing requires an RSA key of at least 2048 bits")
            return result.stdout
        finally:
            os.unlink(filename)

    def jwt(self, now_seconds: int) -> str:
        if self.cached_jwt and now_seconds < self.cached_until:
            return self.cached_jwt
        header = {"alg": "PS256", "typ": "JWT", "kid": self.account["key_id"]}
        claims = {"iss": self.account["sub_account"], "aud": AUDIENCE,
                  "iat": now_seconds, "exp": now_seconds + 3600}
        signing_input = (b64(compact(header)) + "." + b64(compact(claims))).encode("ascii")
        token = signing_input.decode() + "." + b64(self.sign(signing_input))
        self.cached_jwt, self.cached_until = token, now_seconds + 3300
        return token

    def payload(self, event: dict, registration: dict, nonce: str, now: int) -> dict:
        title = clipped(event["deviceName"] + " · " + event["appName"], 200)
        body = "收到一条电脑通知，点击查看" if registration["previewMode"] == "source" else \
            clipped("\n".join(part for part in (event["title"], event["body"]) if part), 1000)
        return {"payload": {"notification": {
                    "category": self.category, "title": title, "body": body,
                    "clickAction": {"actionType": 0, "data": {
                        "screenLinkPushNonce": nonce,
                        "screenLinkInstallationId": registration["installationId"]}},
                    "foregroundShow": False,
                    "notifyId": event["cursor"] % 2147483647}},
                "target": {"token": [registration["pushToken"]]},
                "pushOptions": {"testMessage": self.test_message,
                                "ttl": max(1, min(86400, (event["expiresAt"] - now) // 1000))}}

    def send(self, event: dict, registration: dict, nonce: str, now: int) -> bool:
        if event.get("appId") != "codex" or event.get("appName") != "Codex" or event["expiresAt"] <= now:
            return False
        payload = self.payload(event, registration, nonce, now)
        if len(compact({key: value for key, value in payload.items() if key != "target"})) > 4096:
            return False
        request = Request(ENDPOINT.format(project=self.account["project_id"]),
                          data=compact(payload), method="POST",
                          headers={"Authorization": "Bearer " + self.jwt(now // 1000),
                                   "Content-Type": "application/json", "push-type": "0"})
        try:
            with self.opener.open(request, timeout=10) as response:
                raw = response.read(65537)
                if len(raw) > 65536 or response.status != 200:
                    return False
                result = json.loads(raw)
                return isinstance(result, dict) and result.get("code") == "80000000" and \
                    isinstance(result.get("msg"), str) and isinstance(result.get("requestId"), str)
        except (ValueError, OSError, URLError):
            return False
