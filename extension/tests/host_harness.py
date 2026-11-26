#!/usr/bin/env python3
"""Speaks native messaging to the built ParabolicHost using the exact shapes the extension sends.

Usage: python3 -I extension/tests/host_harness.py [path/to/ParabolicHost]
(default: .build/debug/ParabolicHost; build it with `swift build --product ParabolicHost`).

Never sends a real download: the only `download` requests use URLs the host rejects before it
touches the app's inbox.
"""
import json
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOST = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / ".build/debug/ParabolicHost"


class HostSession:
    def __init__(self, path):
        self.proc = subprocess.Popen([str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.next_id = 1

    def request(self, message):
        # Same envelope as extension/src/host.js: {...message, requestId: "r<base36>-<n>"}.
        request_id = f"rtest-{self.next_id}"
        self.next_id += 1
        body = json.dumps({**message, "requestId": request_id}).encode()
        self.proc.stdin.write(struct.pack("<I", len(body)) + body)
        self.proc.stdin.flush()
        header = self.proc.stdout.read(4)
        assert len(header) == 4, "host closed the pipe"
        (length,) = struct.unpack("<I", header)
        reply = json.loads(self.proc.stdout.read(length))
        assert reply.get("requestId") == request_id, f"requestId not echoed: {reply}"
        return reply

    def close(self):
        self.proc.stdin.close()
        code = self.proc.wait(timeout=5)
        assert code == 0, f"host exited with {code}"


def check(name, condition, detail=""):
    print(f"{'PASS' if condition else 'FAIL'}  {name}{('  ' + detail) if detail else ''}")
    return bool(condition)


def main():
    if not HOST.exists():
        sys.exit(f"Host not built: {HOST}")
    host = HostSession(HOST)
    results = []

    reply = host.request({"type": "handshake"})
    results.append(check("handshake", reply.get("ok") is True and reply.get("app") == "Parabolic"
                         and isinstance(reply.get("hostVersion"), int), json.dumps(reply)))

    reply = host.request({"type": "settings"})
    shape = (reply.get("ok") is True and isinstance(reply.get("catchDownloads"), bool)
             and isinstance(reply.get("catchExtensions"), str) and isinstance(reply.get("minSizeMB"), int)
             and isinstance(reply.get("skipHosts"), str) and isinstance(reply.get("presets"), list))
    results.append(check("settings shape (Settings.normalise inputs)", shape,
                         f"presets={reply.get('presets')} exts={str(reply.get('catchExtensions'))[:40]}…"))
    results.append(check("settings has catchEverything + showCatchWindow (bool)",
                         isinstance(reply.get("catchEverything"), bool) and isinstance(reply.get("showCatchWindow"), bool),
                         f"catchEverything={reply.get('catchEverything')} showCatchWindow={reply.get('showCatchWindow')}"))

    reply = host.request({"type": "status"})
    items = reply.get("items")
    ok = reply.get("ok") is True and isinstance(items, list) and all(
        {"title", "status", "url", "thumbnail"} <= set(item) for item in items)
    results.append(check("status shape (popup Recent list)", ok, f"{len(items or [])} items"))

    # Rejected before the inbox is written: a blob: URL (what the catcher must never forward).
    reply = host.request({"type": "download", "action": "quick",
                          "items": [{"url": "blob:https://example.com/abc", "pageURL": "https://example.com/",
                                     "referrer": "https://example.com/", "cookies": "a=b",
                                     "userAgent": "Mozilla/5.0", "filename": "x.zip"}]})
    results.append(check("download rejects non-http(s)", reply.get("ok") is False
                         and "No downloadable links" in reply.get("error", ""), json.dumps(reply)))

    reply = host.request({"type": "download", "action": "batch", "preset": "MP3 320", "items": []})
    results.append(check("download rejects empty batch", reply.get("ok") is False, json.dumps(reply)))

    reply = host.request({"type": "download", "action": "nope", "items": [{"url": "https://example.com/"}]})
    results.append(check("download rejects unknown action", reply.get("ok") is False, json.dumps(reply)))

    reply = host.request({"type": "bogus"})
    results.append(check("unknown request type", reply.get("ok") is False, json.dumps(reply)))

    host.close()
    results.append(check("host exits cleanly on EOF (port disconnect)", True))
    failed = results.count(False)
    print(f"\n{len(results) - failed}/{len(results)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
