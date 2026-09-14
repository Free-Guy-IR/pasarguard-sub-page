import functools
import importlib.util
import json
import shutil
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import subrender

HERE = Path(__file__).resolve().parent
OUT = HERE / "_layout"
WIDTHS = [320, 360, 390, 414, 430]

spec = importlib.util.spec_from_file_location("cdp", HERE / "cdp.py")
cdp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cdp)


def wg(private, host, public, address, tag):
    return "wireguard://%s@%s/?publickey=%s&address=%s#%s" % (private, host, public, address, tag)


LINKS = [
    "vless://11111111-2222-3333-4444-555555555555@192.0.2.5:443?type=tcp#node-a",
    "https://t.me/proxy?server=192.0.2.4&port=443&secret=dd00112233445566778899aabbccddeeff",
    wg("cHJpdmF0ZWtleTE%3D", "192.0.2.4:51820", "cHVia2V5MQ%3D%3D", "10.0.0.2%2F32", "wg-one"),
    wg("cHJpdmF0ZWtleTI%3D", "198.51.100.8:51820", "cHVia2V5Mg%3D%3D", "10.0.0.3%2F32", "wg-two"),
]
OVPN = [{"protocol": "udp", "filename": "a.ovpn", "content": "client\n"}]
L2TP = [{"remark": "L2TP", "server": "192.0.2.4", "username": "u", "password": "p", "secret": "s"}]

PROBE = """(function () {
  var out = {overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
             docScroll: document.documentElement.scrollWidth,
             docClient: document.documentElement.clientWidth,
             labels: []};
  Array.prototype.forEach.call(document.querySelectorAll(".action"), function (b) {
    if (b.hidden) return;
    var span = b.querySelector("span");
    if (!span) return;
    var style = window.getComputedStyle(span);
    var lineHeight = parseFloat(style.lineHeight);
    if (!lineHeight || isNaN(lineHeight)) lineHeight = parseFloat(style.fontSize) * 1.2;
    var rect = span.getBoundingClientRect();
    var tile = b.getBoundingClientRect();
    out.labels.push({
      text: span.textContent.trim(),
      lines: Math.round(rect.height / lineHeight),
      textWidth: Math.round(rect.width),
      tileWidth: Math.round(tile.width),
      clipped: span.scrollWidth > Math.ceil(rect.width) + 1
    });
  });
  return JSON.stringify(out);
})()"""


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    OUT.mkdir(exist_ok=True)
    (OUT / "layout.html").write_text(subrender.render(LINKS, OVPN, L2TP, "active"), encoding="utf-8")
    handler = functools.partial(QuietHandler, directory=str(OUT))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:%d/layout.html" % server.server_address[1]

    binary = cdp.find_chrome()
    chrome = cdp.ChromeProcess(binary)
    client = None
    failures = []
    try:
        client = cdp.CdpClient(chrome.wait_for_devtools(30), connect_timeout=30)
        target = client.call("Target.createTarget", {"url": "about:blank"})
        sid = client.call("Target.attachToTarget", {"targetId": target["targetId"], "flatten": True})["sessionId"]
        for domain in ("Page", "Runtime"):
            client.call(domain + ".enable", {}, session_id=sid)
        client.call("Page.navigate", {"url": url}, session_id=sid)
        time.sleep(3.0)

        for width in WIDTHS:
            client.call("Emulation.setDeviceMetricsOverride",
                        {"width": width, "height": 900, "deviceScaleFactor": 2, "mobile": True},
                        session_id=sid)
            time.sleep(0.6)
            raw = client.call(
                "Runtime.evaluate",
                {"expression": PROBE, "returnByValue": True},
                session_id=sid, timeout=15,
            )["result"]["value"]
            data = json.loads(raw)
            worst = max((l["lines"] for l in data["labels"]), default=0)
            print("  %dpx  tiles=%d  widest label=%dpx  tile=%dpx  max lines=%d  h-overflow=%s"
                  % (width, len(data["labels"]),
                     max((l["textWidth"] for l in data["labels"]), default=0),
                     max((l["tileWidth"] for l in data["labels"]), default=0),
                     worst, data["overflow"]))
            for label in data["labels"]:
                if label["lines"] > 1:
                    failures.append("%dpx: %r wraps onto %d lines" % (width, label["text"], label["lines"]))
                if label["clipped"]:
                    failures.append("%dpx: %r is clipped (%dpx of text in a %dpx tile)"
                                    % (width, label["text"], label["textWidth"], label["tileWidth"]))
                if label["textWidth"] > label["tileWidth"] - 20:
                    failures.append("%dpx: %r needs %dpx but its tile only offers %dpx of room"
                                    % (width, label["text"], label["textWidth"], label["tileWidth"] - 20))
            if data["overflow"]:
                failures.append("%dpx: the page scrolls sideways (%d > %d)"
                                % (width, data["docScroll"], data["docClient"]))
    finally:
        try:
            if client is not None:
                client.close()
        except Exception:
            pass
        try:
            chrome.terminate()
        except Exception:
            pass
        shutil.rmtree(chrome.profile_dir, ignore_errors=True)
        server.shutdown()

    print("")
    if failures:
        for item in failures:
            print("  FAIL: %s" % item)
        return 1
    print("  PASS: every action label stays on one line at %s and nothing scrolls sideways"
          % ", ".join("%dpx" % w for w in WIDTHS))
    return 0


sys.exit(main())
