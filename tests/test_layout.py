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
LOCALES = ["fa", "en", "ru"]
EXPECTED_ACTIONS = 5

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

READY = """(function () {
  var cards = document.querySelectorAll(".cfg");
  var built = 0;
  Array.prototype.forEach.call(cards, function (c) { if (c.querySelector(".mini")) built++; });
  var cfgList = document.getElementById("cfgList");
  return JSON.stringify({
    ready: document.readyState === "complete" &&
      (cards.length > 0 ? built === cards.length
                        : !!cfgList && !!cfgList.querySelector(".empty")),
    actions: document.querySelectorAll(".action:not([hidden])").length
  });
})()"""

FONTS_READY = """(function () {
  if (!document.fonts || !document.fonts.ready) return Promise.resolve("no-font-api");
  return document.fonts.ready.then(function () { return "fonts-ready"; });
})()"""

SET_LANG = """(function () {
  var b = document.querySelector('.lang-btn[data-lang="%s"]');
  if (!b) return "missing";
  b.click();
  return document.documentElement.getAttribute("lang") || "clicked";
})()"""

PROBE = """(function () {
  var out = {
    overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
    docScroll: document.documentElement.scrollWidth,
    docClient: document.documentElement.clientWidth,
    labels: []
  };
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
      tileWidth: Math.round(tile.width)
    });
  });
  return JSON.stringify(out);
})()"""


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class Page:
    def __init__(self, client, session):
        self.client = client
        self.session = session

    def evaluate(self, expression, await_promise=False, timeout=20):
        result = self.client.call(
            "Runtime.evaluate",
            {"expression": expression, "returnByValue": True, "awaitPromise": await_promise},
            session_id=self.session,
            timeout=timeout,
        )
        if "exceptionDetails" in result:
            raise RuntimeError(result["exceptionDetails"].get("text"))
        return result.get("result", {}).get("value")

    def wait_ready(self, deadline=40):
        end = time.monotonic() + deadline
        previous = None
        stable = 0
        while time.monotonic() < end:
            try:
                state = json.loads(self.evaluate(READY))
            except Exception:
                state = None
            if state and state.get("ready"):
                if state["actions"] == previous:
                    stable += 1
                    if stable >= 2:
                        return state
                else:
                    stable = 0
                previous = state["actions"]
            time.sleep(0.15)
        raise RuntimeError("the page never settled")

    def wait_fonts(self):
        return self.evaluate(FONTS_READY, await_promise=True, timeout=30)


def main():
    OUT.mkdir(exist_ok=True)
    (OUT / "layout.html").write_text(subrender.render(LINKS, OVPN, L2TP, "active"), encoding="utf-8")
    handler = functools.partial(QuietHandler, directory=str(OUT))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:%d/layout.html" % server.server_address[1]

    binary = cdp.find_chrome()
    if not binary:
        print("  no chrome or chromium binary on this machine")
        return 2
    chrome = cdp.ChromeProcess(binary)
    client = None
    failures = []
    try:
        client = cdp.CdpClient(chrome.wait_for_devtools(30), connect_timeout=30)
        target = client.call("Target.createTarget", {"url": "about:blank"})
        sid = client.call("Target.attachToTarget",
                          {"targetId": target["targetId"], "flatten": True})["sessionId"]
        for domain in ("Page", "Runtime"):
            client.call(domain + ".enable", {}, session_id=sid)
        client.call("Page.navigate", {"url": url}, session_id=sid)
        page = Page(client, sid)
        state = page.wait_ready()
        print("  fonts: %s" % page.wait_fonts())

        if state["actions"] != EXPECTED_ACTIONS:
            failures.append("expected %d visible action buttons, found %d - a hidden button would "
                            "make every width below pass for the wrong reason"
                            % (EXPECTED_ACTIONS, state["actions"]))

        for locale in LOCALES:
            applied = page.evaluate(SET_LANG % locale)
            if applied == "missing":
                failures.append("no language button for %r" % locale)
                continue
            page.wait_ready()
            page.wait_fonts()
            for width in WIDTHS:
                client.call("Emulation.setDeviceMetricsOverride",
                            {"width": width, "height": 900, "deviceScaleFactor": 2, "mobile": True},
                            session_id=sid)
                page.wait_fonts()
                data = json.loads(page.evaluate(PROBE))
                widest = max((l["textWidth"] for l in data["labels"]), default=0)
                print("  %s %dpx  buttons=%d  widest label=%dpx  tile=%dpx  overflow=%s"
                      % (locale, width, len(data["labels"]), widest,
                         max((l["tileWidth"] for l in data["labels"]), default=0), data["overflow"]))
                if len(data["labels"]) != EXPECTED_ACTIONS:
                    failures.append("%s %dpx: measured %d buttons, expected %d"
                                    % (locale, width, len(data["labels"]), EXPECTED_ACTIONS))
                for label in data["labels"]:
                    if label["lines"] > 1:
                        failures.append("%s %dpx: %r wraps onto %d lines"
                                        % (locale, width, label["text"], label["lines"]))
                    if label["textWidth"] > label["tileWidth"] - 20:
                        failures.append("%s %dpx: %r needs %dpx but its tile offers %dpx"
                                        % (locale, width, label["text"], label["textWidth"],
                                           label["tileWidth"] - 20))
                if data["overflow"]:
                    failures.append("%s %dpx: the page scrolls sideways (%d > %d)"
                                    % (locale, width, data["docScroll"], data["docClient"]))
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
    print("  PASS: %d buttons keep one-line labels inside their tiles at %s, in %s, with no sideways scroll"
          % (EXPECTED_ACTIONS, ", ".join("%dpx" % w for w in WIDTHS), "/".join(LOCALES)))
    return 0


sys.exit(main())
