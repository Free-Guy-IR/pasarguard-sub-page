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

VISIBLE_ACTIONS = """
  function boxIsRendered(el) {
    var rect = el.getBoundingClientRect();
    if (!(rect.width > 0 && rect.height > 0)) return false;
    var style = window.getComputedStyle(el);
    if (style.display === "none") return false;
    if (style.visibility === "hidden" || style.visibility === "collapse") return false;
    if (el.offsetParent === null && style.position !== "fixed") return false;
    for (var node = el.parentElement; node; node = node.parentElement) {
      var parentStyle = window.getComputedStyle(node);
      if (parentStyle.display === "none") return false;
      if (parentStyle.visibility === "hidden" || parentStyle.visibility === "collapse") return false;
      if (parentStyle.contentVisibility === "hidden") return false;
    }
    return true;
  }

  function visibleActions() {
    return Array.prototype.filter.call(document.querySelectorAll(".action"), boxIsRendered);
  }
"""

READY = """(function () {
  %s
  var cards = document.querySelectorAll(".cfg");
  var built = 0;
  Array.prototype.forEach.call(cards, function (c) { if (c.querySelector(".mini")) built++; });
  var cfgList = document.getElementById("cfgList");
  return JSON.stringify({
    ready: document.readyState === "complete" &&
      (cards.length > 0 ? built === cards.length
                        : !!cfgList && !!cfgList.querySelector(".empty")),
    actions: visibleActions().length,
    present: document.querySelectorAll(".action").length
  });
})()""" % VISIBLE_ACTIONS

FONTS_READY = """(function () {
  if (!document.fonts || !document.fonts.ready) return Promise.resolve("no-font-api");
  return document.fonts.ready.then(function () { return "fonts-ready"; });
})()"""

SET_LANG = """(function () {
  var b = document.querySelector('.lang-btn[data-lang="%s"]');
  if (!b) return JSON.stringify({ ok: false, why: "missing" });
  b.click();
  var probe = document.querySelector('#cfgBtn span') ||
              document.querySelector('.action span');
  return JSON.stringify({
    ok: true,
    lang: document.documentElement.getAttribute("lang"),
    dir: document.documentElement.getAttribute("dir"),
    sample: probe ? probe.textContent.trim() : null,
    pressed: b.getAttribute("aria-pressed")
  });
})()"""

PROBE = """(function () {
  %s
  var out = {
    overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
    docScroll: document.documentElement.scrollWidth,
    docClient: document.documentElement.clientWidth,
    present: document.querySelectorAll(".action").length,
    labels: []
  };
  var shown = visibleActions();
  out.visible = shown.length;
  shown.forEach(function (b) {
    var span = b.querySelector("span");
    if (!span || !boxIsRendered(span)) {
      out.labels.push({
        text: b.id || b.className,
        lines: 0,
        textWidth: 0,
        tileWidth: Math.round(b.getBoundingClientRect().width),
        unlabelled: true
      });
      return;
    }
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
      unlabelled: false
    });
  });
  return JSON.stringify(out);
})()""" % VISIBLE_ACTIONS


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
        print("  actions in the markup: %d, actually rendered: %d"
              % (state["present"], state["actions"]))

        if state["actions"] != EXPECTED_ACTIONS:
            failures.append("expected %d rendered action buttons, found %d of the %d in the markup "
                            "- a button the user cannot see would make every width below pass for "
                            "the wrong reason"
                            % (EXPECTED_ACTIONS, state["actions"], state["present"]))

        samples = {}
        for locale in LOCALES:
            applied = json.loads(page.evaluate(SET_LANG % locale))
            if not applied.get("ok"):
                failures.append("no language button for %r" % locale)
                continue
            page.wait_ready()
            page.wait_fonts()
            applied = json.loads(page.evaluate(SET_LANG % locale))
            if applied.get("lang") != locale:
                failures.append("asked for %r but the page reports lang=%r - the switcher did "
                                "nothing, so every measurement below would be one locale three times"
                                % (locale, applied.get("lang")))
            if applied.get("pressed") != "true":
                failures.append("the %r language button never became the pressed one" % locale)
            samples[locale] = applied.get("sample")
            for width in WIDTHS:
                client.call("Emulation.setDeviceMetricsOverride",
                            {"width": width, "height": 900, "deviceScaleFactor": 2, "mobile": True},
                            session_id=sid)
                page.wait_fonts()
                data = json.loads(page.evaluate(PROBE))
                widest = max((l["textWidth"] for l in data["labels"]), default=0)
                print("  %s measured=%dpx (asked %dpx)  buttons=%d/%d  widest label=%dpx  tile=%dpx  overflow=%s"
                      % (locale, data["docClient"], width, data["visible"], data["present"], widest,
                         max((l["tileWidth"] for l in data["labels"]), default=0), data["overflow"]))
                if data["docClient"] != width:
                    failures.append("%s: asked for a %dpx viewport but the page laid out at %dpx - "
                                    "every width in this run measured the wrong thing"
                                    % (locale, width, data["docClient"]))
                if data["visible"] != EXPECTED_ACTIONS:
                    failures.append("%s %dpx: measured %d rendered buttons of the %d in the markup, "
                                    "expected %d"
                                    % (locale, width, data["visible"], data["present"],
                                       EXPECTED_ACTIONS))
                for label in data["labels"]:
                    if label["unlabelled"]:
                        failures.append("%s %dpx: %r is rendered with no visible label"
                                        % (locale, width, label["text"]))
                        continue
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

    distinct = {k: v for k, v in samples.items() if v}
    if len(distinct) == len(LOCALES) and len(set(distinct.values())) == 1:
        failures.append("every locale rendered the same label %r - the language buttons change the "
                        "lang attribute without applying the string table"
                        % next(iter(distinct.values())))

    print("")
    if failures:
        for item in failures:
            print("  FAIL: %s" % item)
        return 1
    print("  PASS: %d rendered buttons keep one-line labels inside their tiles at %s, in %s, with no sideways scroll"
          % (EXPECTED_ACTIONS, ", ".join("%dpx" % w for w in WIDTHS), "/".join(LOCALES)))
    return 0


sys.exit(main())
