"""Build a separately permissioned local launcher. Does not start it or grant permissions."""
import argparse
import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--config", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--sign-identity", default="-", help="codesign identity; '-' creates a local ad-hoc signature")
args = parser.parse_args()
root = Path(__file__).resolve().parent
app = args.output.resolve()
if app.exists() or app.suffix != ".app":
    parser.error("output must be a new .app directory")
resources = app / "Contents/Resources"
macos = app / "Contents/MacOS"
resources.mkdir(parents=True)
macos.mkdir()
subprocess.run(["swiftc", str(root / "launcher/App.swift"), "-o", str(macos / "ScreenLinkWeChat"),
                "-framework", "AppKit"], check=True)
shutil.copy2(root / "wechat_listener.py", resources)
(resources / "notifications").mkdir()
for name in ("__init__.py", "codex_hook.py"):
    shutil.copy2(root.parent / "notifications" / name, resources / "notifications" / name)
(resources / "runtime.json").write_text(json.dumps({"python": sys.executable, "config": str(args.config.resolve())}))
with (app / "Contents/Info.plist").open("wb") as output:
    plistlib.dump({"CFBundleIdentifier": "io.screenlink.wechat-notifications",
                  "CFBundleName": "ScreenLink WeChat", "CFBundleDisplayName": "屏间微信通知助手",
                  "CFBundleExecutable": "ScreenLinkWeChat", "CFBundlePackageType": "APPL",
                  "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
                  "NSHighResolutionCapable": True, "LSMinimumSystemVersion": "13.0"}, output)
subprocess.run(["codesign", "--force", "--sign", args.sign_identity, str(app)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
print("Built and signed launcher; not started. Grant Full Disk Access only to this .app when ready.")
