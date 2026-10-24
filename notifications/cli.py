"""Check local configuration or explicitly submit one synthetic notification."""
from __future__ import annotations

import argparse
import json
import ssl
import time
import uuid
from pathlib import Path
from urllib.error import URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, HTTPSHandler, ProxyHandler, Request, build_opener

from .server import load_config, tls_context


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        # A redirected credential must never reach another service.
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="Validate configuration and TLS key pair locally; no network")
    publish = commands.add_parser("syntheticpublish", help="Explicitly publish a fixed synthetic test event")
    publish.add_argument("--device-id", required=True)
    publish.add_argument("--app-id", required=True)
    publish.add_argument("--url", required=True, help="HTTPS service origin matching certificate identity")
    publish.add_argument("--ca", type=Path, required=True, help="Trusted CA certificate; TLS is always verified")
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        if args.command == "check":
            tls_context(config)
            if config.push is not None:
                from .huawei_push import HuaweiPush
                HuaweiPush(config.push)
            print("Configuration, TLS and any configured push signing key valid. No listener started; no notification sent.")
            return
        device = next((d for d in config.devices if d.device_id == args.device_id), None)
        if device is None or args.app_id not in device.apps:
            raise ValueError("unknown device or app")
        url = urlsplit(args.url)
        if url.scheme != "https" or not url.hostname or url.username or url.password or \
                url.query or url.fragment or url.path not in ("", "/"):
            raise ValueError("HTTPS service origin required")
        now = int(time.time() * 1000)
        payload = {
            "eventId": "synthetic-" + str(uuid.uuid4()),
            "appId": args.app_id, "appName": device.apps[args.app_id],
            "title": "屏间通知通道测试（合成样例）",
            "body": "这是一条手动生成的测试内容，不代表已采集任何应用通知。",
            "createdAt": now, "expiresAt": now + 300000, "contentState": "complete"
        }
        context = ssl.create_default_context(cafile=str(args.ca))
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        request = Request(args.url.rstrip("/") + "/v1/events",
                          data=json.dumps(payload, ensure_ascii=False).encode(),
                          headers={"Authorization": "Bearer " + device.token, "Content-Type": "application/json"},
                          method="POST")
        opener = build_opener(ProxyHandler({}), HTTPSHandler(context=context), NoRedirect())
        with opener.open(request, timeout=10) as response:
            result = json.loads(response.read(4096))
            if result.get("accepted") is not True:
                raise ValueError("event not accepted")
            print("Synthetic event accepted by relay. TV delivery and real capture are not verified.")
    except (ValueError, OSError, URLError, ssl.SSLError):
        parser.exit(1, "Check failed or synthetic event was not accepted; no secrets are printed.\n")


if __name__ == "__main__":
    main()
