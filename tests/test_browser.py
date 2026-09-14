import base64
import functools
import io
import json
import re
import shutil
import sys
import tempfile
import threading
import time
import zipfile
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import subrender
from cdp import CdpClient, ChromeProcess, NetworkRecorder, find_chrome

VLESS = [
    "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?type=tcp#node-a",
    "vless://11111111-2222-3333-4444-666666666666@5.6.7.8:443?type=ws#node-b",
]


def wg(private, host, public, address, tag):
    return "wireguard://%s@%s/?publickey=%s&address=%s#%s" % (private, host, public, address, tag)


WG_OK = [
    wg("cHJpdmF0ZWtleTE%3D", "1.2.3.4:51820", "cHVia2V5MQ%3D%3D", "10.0.0.2%2F32", "wg-one"),
    wg("cHJpdmF0ZWtleTI%3D", "5.6.7.8:51820", "cHVia2V5Mg%3D%3D", "10.0.0.3%2F32", "wg-two"),
    wg("cHJpdmF0ZWtleTM%3D", "1.2.3.5:51820", "cHVia2V5Mw%3D%3D", "10.0.0.4%2F32", "wg-three"),
]

WG_BAD = [
    "wireguard://%ZZ@1.2.3.4:51820/?publickey=cHVia2V5#bad-percent-private",
    "wireguard://cHJpdmF0ZQ%3D%3D@1.2.3.4:51820/?address=10.0.0.9%2F32#missing-publickey",
    "wireguard://cHJpdmF0ZQ%3D%3D@/?publickey=cHVia2V5#missing-endpoint",
    "wireguard://cHJpdmF0ZQ%3D%3D@1.2.3.4:51820/?publickey=%GG#bad-percent-public",
]

WG_BROKEN_LABEL = "wireguard://cHJpdmF0ZQ%3D%3D@1.2.3.4:51820/?publickey=cHVia2V5#%ZZ"

WG_DUPE = [
    wg("a%3D", "abcdefghijkl.example.com:51820", "pk1", "10.0.0.2%2F32", "first"),
    wg("b%3D", "abcdefghijkl.example.com:51821", "pk2", "10.0.0.3%2F32", "second"),
    wg("c%3D", "abcdefghijkl.example.com:51822", "pk3", "10.0.0.4%2F32", "third"),
]

WG_HASH = [
    wg(
        "cHJpdg%3D%3D",
        "1.2.3.4:51820",
        "cHVia2V5",
        "10.0.0.0%2F8%23%2C192.168.0.0%2F16",
        "hash-in-value",
    ),
]

INJECTED_DIRECTIVE = "AllowedIPs = 5.6.7.8/32"

WG_INJECT = [
    wg(
        "cHJpdg%3D%3D",
        "1.2.3.4:51820",
        "cHVia2V5",
        "10.0.0.2%2F32%0AAllowedIPs%20%3D%205.6.7.8%2F32",
        "injected",
    ),
]

OVPN = [
    {"protocol": "udp", "filename": "node-udp.ovpn", "content": "client\ndev tun\nproto udp\n"},
    {"protocol": "tcp", "filename": "node-tcp.ovpn", "content": "client\ndev tun\nproto tcp\n"},
]

L2TP = [
    {
        "remark": "L2TP EXAMPLE",
        "server": "1.2.3.4",
        "username": "exampleuser",
        "password": "examplepass",  # pragma: allowlist secret
        "secret": "examplesecret",  # pragma: allowlist secret
    },
]

INSTRUMENT = """
window.__blobParts = [];
window.__downloads = [];
(function () {
  var NativeBlob = window.Blob;
  function TrackedBlob(parts, options) {
    try { window.__blobParts.push(String(parts && parts[0])); } catch (e) { window.__blobParts.push(""); }
    return new NativeBlob(parts, options);
  }
  TrackedBlob.prototype = NativeBlob.prototype;
  window.Blob = TrackedBlob;
  var nativeCreate = URL.createObjectURL;
  URL.createObjectURL = function (b) { window.__lastBlob = b; return nativeCreate.call(URL, b); };
  window.__readLastBlob = function () {
    return new Promise(function (resolve) {
      if (!window.__lastBlob) { resolve(""); return; }
      var r = new FileReader();
      r.onload = function () { resolve(String(r.result).split(",").pop()); };
      r.onerror = function () { resolve(""); };
      r.readAsDataURL(window.__lastBlob);
    });
  };
  var nativeClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    if (this.hasAttribute("download")) { window.__downloads.push(this.download); return; }
    return nativeClick.apply(this, arguments);
  };
})();
"""

SNAPSHOT = """(function () {
  function has(id) { return !!document.getElementById(id); }
  function hidden(id) { var e = document.getElementById(id); return e ? !!e.hidden : null; }
  function shown(id) {
    var e = document.getElementById(id);
    if (!e) return null;
    var s = window.getComputedStyle(e);
    return s.display !== "none" && s.visibility !== "hidden";
  }
  var out = {};
  var cfgList = document.getElementById("cfgList");
  var wgList = document.getElementById("wgList");
  out.ready = !!cfgList && !!cfgList.querySelector(".cfg, .empty");
  out.cfgCards = cfgList ? cfgList.querySelectorAll(".cfg").length : -1;
  out.wgCards = wgList ? wgList.querySelectorAll(".cfg").length : -1;
  var leaked = [];
  if (cfgList) {
    Array.prototype.forEach.call(cfgList.querySelectorAll(".cfg"), function (el) {
      var u = (el.getAttribute("data-uri") || "").toLowerCase();
      if (u.indexOf("wireguard:") === 0 || u.indexOf("wg:") === 0) leaked.push(u.slice(0, 40));
    });
  }
  out.wgLeftInConfigs = leaked.length;
  out.wgLeaked = leaked;
  out.cfgEmptyShown = cfgList ? !!cfgList.querySelector(".empty") : null;
  out.cfgListChildren = cfgList ? cfgList.children.length : -1;
  out.copyAllShown = shown("copyAll");
  out.wgBtn = has("wgBtn");
  out.wgBtnHidden = hidden("wgBtn");
  out.wgBtnShown = shown("wgBtn");
  out.wgModal = has("wgModal");
  out.wgModalOpen = has("wgModal") && document.getElementById("wgModal").hasAttribute("open");
  out.wgAll = has("wgDownloadAll");
  out.wgAllShown = shown("wgDownloadAll");
  out.ovpnBtn = has("ovpnBtn");
  out.ovpnModal = has("ovpnModal");
  out.ovpnModalOpen = has("ovpnModal") && document.getElementById("ovpnModal").hasAttribute("open");
  out.l2tpBtn = has("l2tpBtn");
  out.l2tpModal = has("l2tpModal");
  out.l2tpModalOpen = has("l2tpModal") && document.getElementById("l2tpModal").hasAttribute("open");
  out.blobs = (window.__blobParts || []).length;
  out.blobHeads = (window.__blobParts || []).map(function (b) { return b.slice(0, 11); });
  out.blobBodies = window.__blobParts || [];
  out.downloads = window.__downloads || [];
  out.bodyOverflow = document.body.style.overflow;
  return JSON.stringify(out);
})()"""


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class Page:
    def __init__(self, client, session):
        self.client = client
        self.session = session
        self.wants_request_suffix = None

    def evaluate(self, expression, timeout=15):
        result = self.client.call(
            "Runtime.evaluate",
            {"expression": expression, "returnByValue": True, "awaitPromise": False},
            session_id=self.session,
            timeout=timeout,
        )
        if "exceptionDetails" in result:
            details = result["exceptionDetails"]
            raise RuntimeError(
                details.get("exception", {}).get("description") or details.get("text")
            )
        return result.get("result", {}).get("value")

    def snapshot(self):
        return json.loads(self.evaluate(SNAPSHOT))

    def click(self, selector):
        self.evaluate(
            'var e = document.querySelector(%s); if (!e) throw new Error("no element " + %s); e.click();'
            % (json.dumps(selector), json.dumps(selector))
        )

    def last_blob(self):
        result = self.client.call(
            "Runtime.evaluate",
            {"expression": "window.__readLastBlob()", "returnByValue": True, "awaitPromise": True},
            session_id=self.session,
            timeout=20,
        )
        return base64.b64decode(result.get("result", {}).get("value") or "")

    def escape(self):
        self.evaluate(
            'document.dispatchEvent(new KeyboardEvent("keydown", {key: "Escape", bubbles: true}));'
        )

    def wait_ready(self, deadline=20):
        end = time.monotonic() + deadline
        while time.monotonic() < end:
            try:
                state = self.snapshot()
            except Exception:
                state = None
            if state and state.get("ready"):
                return state
            time.sleep(0.2)
        raise RuntimeError("page never finished rendering its config list")


def check(results, name, condition, message):
    if not condition:
        results.append("%s -> %s" % (name, message))


def fixture_none(page, results, name, out_dir):
    state = page.wait_ready()
    check(results, name, state["wgCards"] == 0,
          "expected no WireGuard cards, got %s" % state["wgCards"])
    check(results, name, state["wgBtnHidden"] is True, "WireGuard button should stay hidden")
    check(results, name, state["wgBtnShown"] is False, "hidden WireGuard button is still painted")
    check(results, name, state["wgModal"], "the WireGuard sheet is missing from the page")
    check(results, name, state["cfgCards"] == 2,
          "expected the 2 vless cards, got %s" % state["cfgCards"])
    return state


def fixture_one(page, results, name, out_dir):
    state = page.wait_ready()
    check(results, name, state["wgCards"] == 1,
          "expected 1 WireGuard card, got %s" % state["wgCards"])
    check(results, name, state["wgLeftInConfigs"] == 0,
          "WireGuard left in the configs list: %s" % state["wgLeaked"])
    check(results, name, state["cfgCards"] == 2,
          "expected 2 remaining cards, got %s" % state["cfgCards"])
    check(results, name, state["wgBtnHidden"] is False, "WireGuard button should be visible")
    check(results, name, state["wgBtnShown"] is True, "visible WireGuard button is not painted")
    check(results, name, state["wgAllShown"] is False,
          "download-all should hide for a single file")

    page.click("#wgBtn")
    time.sleep(0.3)
    opened = page.snapshot()
    check(results, name, opened["wgModalOpen"], "clicking the button did not open the sheet")
    check(results, name, opened["bodyOverflow"] == "hidden",
          "the page behind the sheet still scrolls")

    page.escape()
    time.sleep(0.3)
    escaped = page.snapshot()
    check(results, name, not escaped["wgModalOpen"], "Escape did not close the WireGuard sheet")
    check(results, name, escaped["bodyOverflow"] != "hidden",
          "the page stays frozen after Escape")

    page.click("#wgBtn")
    time.sleep(0.3)

    page.click("#wgList .cfg .mini")
    time.sleep(0.5)
    downloaded = page.snapshot()
    check(results, name, downloaded["blobs"] == 1,
          "expected 1 file, got %s" % downloaded["blobs"])
    check(results, name,
          downloaded["downloads"] and downloaded["downloads"][0].endswith(".conf"),
          "download name is not a .conf: %s" % downloaded["downloads"])
    body = (downloaded["blobBodies"] or [""])[0]
    check(results, name, body.startswith("[Interface]"), "file does not start with [Interface]")
    for field in ("PrivateKey", "Address", "[Peer]", "PublicKey", "Endpoint"):
        check(results, name, field in body, "file is missing %s" % field)

    page.click("#wgClose")
    time.sleep(0.3)
    closed = page.snapshot()
    check(results, name, not closed["wgModalOpen"], "the close button did not shut the sheet")
    check(results, name, closed["bodyOverflow"] != "hidden",
          "the page is still frozen after closing")
    return closed


def check_zip(page, results, name, expected, out_dir):
    after = page.snapshot()
    check(results, name, after["downloads"] == ["wireguard.zip"],
          "download-all should produce one wireguard.zip, got %s" % after["downloads"])
    raw = page.last_blob()
    check(results, name, raw[:2] == b"PK", "the downloaded file is not a zip archive")
    (out_dir / (name.replace(" ", "-") + ".zip")).write_bytes(raw)
    try:
        archive = zipfile.ZipFile(io.BytesIO(raw))
    except Exception as error:
        check(results, name, False, "the zip does not open: %s" % error)
        return after
    bad = archive.testzip()
    check(results, name, bad is None, "a zip entry is corrupt: %s" % bad)
    names = archive.namelist()
    check(results, name, len(names) == expected,
          "expected %d files in the zip, got %d %s" % (expected, len(names), names))
    check(results, name, len(set(names)) == len(names),
          "duplicate names inside the zip: %s" % names)
    check(results, name, all(n.endswith(".conf") for n in names),
          "a zip entry is not a .conf: %s" % names)
    for entry in names:
        body = archive.read(entry).decode("utf-8")
        check(results, name, body.startswith("[Interface]"),
              "%s does not start with [Interface]" % entry)
        for field in ("PrivateKey", "[Peer]", "PublicKey", "Endpoint"):
            check(results, name, field in body, "%s is missing %s" % (entry, field))
    return after


def fixture_many(page, results, name, out_dir):
    state = page.wait_ready()
    check(results, name, state["wgCards"] == 3,
          "expected 3 WireGuard cards, got %s" % state["wgCards"])
    check(results, name, state["wgLeftInConfigs"] == 0,
          "WireGuard left in the configs list: %s" % state["wgLeaked"])
    check(results, name, state["wgAllShown"] is True, "download-all should show for 3 files")

    page.click("#wgBtn")
    time.sleep(0.2)
    page.click("#wgDownloadAll")
    time.sleep(1.2)
    return check_zip(page, results, name, 3, out_dir)


def fixture_malformed(page, results, name, out_dir):
    state = page.wait_ready()
    check(results, name, state["wgCards"] == 7,
          "every WireGuard link belongs in the sheet, got %s" % state["wgCards"])
    check(results, name, state["wgLeftInConfigs"] == 0,
          "no WireGuard link should stay in the configs list, found %s" % state["wgLeftInConfigs"])
    check(results, name, state["wgBtnHidden"] is False, "WireGuard button should be visible")
    check(results, name, state["wgAllShown"] is True,
          "download-all should show for 3 usable files")

    page.click("#wgBtn")
    time.sleep(0.2)
    page.click("#wgDownloadAll")
    time.sleep(1.2)
    return check_zip(page, results, name, 3, out_dir)


def fixture_dupes(page, results, name, out_dir):
    state = page.wait_ready()
    check(results, name, state["wgCards"] == 3,
          "expected 3 WireGuard cards, got %s" % state["wgCards"])
    page.click("#wgBtn")
    time.sleep(0.2)
    page.click("#wgDownloadAll")
    time.sleep(1.2)
    after = check_zip(page, results, name, 3, out_dir)
    raw = page.last_blob()
    try:
        names = zipfile.ZipFile(io.BytesIO(raw)).namelist()
    except Exception:
        return after
    for entry in names:
        base = entry[:-5]
        check(results, name, 1 <= len(base) <= 15,
              "%r is %d characters, wg-quick only accepts 1-15" % (base, len(base)))
        check(results, name, re.match(r"^[A-Za-z0-9_=+.-]+$", base),
              "%r is not a valid wg-quick interface name" % base)
    return after


def fixture_hash(page, results, name, out_dir):
    state = page.wait_ready()
    check(results, name, state["wgCards"] == 1,
          "the link still belongs in the sheet, got %s" % state["wgCards"])
    page.click("#wgBtn")
    time.sleep(0.2)
    page.click("#wgList .cfg .mini")
    time.sleep(0.5)
    after = page.snapshot()
    check(results, name, after["blobs"] == 0,
          "a value carrying # would be truncated as a comment and must be refused, got %s file(s)"
          % after["blobs"])
    return after


def fixture_unconvertible_card(page, results, name, out_dir):
    state = page.wait_ready()
    check(results, name, state["wgCards"] == 2,
          "both links belong in the sheet, got %s" % state["wgCards"])
    check(results, name, state["wgLeftInConfigs"] == 0, "nothing should be left behind")
    check(results, name, state["wgAllShown"] is False,
          "only one link is usable, so download-all must stay hidden")
    page.click("#wgBtn")
    time.sleep(0.2)
    cards = page.evaluate(
        "JSON.stringify(Array.prototype.map.call("
        "document.querySelectorAll('#wgList .cfg'), function (c) {"
        "  var b = c.querySelector('.mini');"
        "  return { uri: c.getAttribute('data-uri').slice(0, 30),"
        "           label: b ? b.getAttribute('aria-label') : null,"
        "           qr: !!c.querySelector('button:nth-child(2)') };"
        "}))"
    )
    cards = json.loads(cards)
    check(results, name, len(cards) == 2, "expected 2 cards in the sheet, got %d" % len(cards))
    labels = [c["label"] for c in cards]
    check(results, name, len(set(labels)) == 2,
          "the usable and unusable cards should offer different actions, got %s" % labels)
    page.click("#wgList .cfg:last-child .mini")
    time.sleep(0.5)
    after = page.snapshot()
    check(results, name, after["blobs"] == 0,
          "the unusable card must fall back to copying, not produce a file")
    return after


def fixture_injection(page, results, name, out_dir):
    state = page.wait_ready()
    check(results, name, state["wgCards"] == 1,
          "the link still belongs in the sheet, got %s" % state["wgCards"])
    check(results, name, state["wgAllShown"] is False,
          "download-all must stay hidden for one file")
    page.click("#wgBtn")
    time.sleep(0.2)
    page.click("#wgList .cfg .mini")
    time.sleep(0.5)
    after = page.snapshot()
    for body in after["blobBodies"]:
        check(results, name, INJECTED_DIRECTIVE not in body,
              "a newline in a link injected an extra directive into the config file")
    check(results, name, after["blobs"] == 0,
          "a link carrying a newline should be refused, but %s file(s) were produced"
          % after["blobs"])
    return after


def fixture_wg_only(page, results, name, out_dir):
    state = page.wait_ready()
    check(results, name, state["wgCards"] == 3,
          "all 3 links belong in the sheet, got %s" % state["wgCards"])
    check(results, name, state["cfgCards"] == 0,
          "the configs list should be empty, got %s" % state["cfgCards"])
    check(results, name, state["wgBtnHidden"] is False, "WireGuard button should be visible")
    check(results, name, state["cfgListChildren"] == 0 or state["cfgEmptyShown"],
          "the emptied configs list shows %d leftover children and no empty state"
          % state["cfgListChildren"])
    page.click("#wgBtn")
    time.sleep(0.2)
    page.click("#wgDownloadAll")
    time.sleep(1.2)
    return check_zip(page, results, name, 3, out_dir)


def fixture_ovpn_only(page, results, name, out_dir):
    state = page.wait_ready()
    check(results, name, state["ovpnBtn"] and state["ovpnModal"],
          "an OpenVPN-only page must have both the button and the sheet")
    check(results, name, not state["l2tpBtn"] and not state["l2tpModal"],
          "L2TP must not appear without L2TP servers")
    check(results, name, state["wgBtnHidden"] is True, "WireGuard button should stay hidden")

    page.click("#ovpnBtn")
    time.sleep(0.3)
    opened = page.snapshot()
    check(results, name, opened["ovpnModalOpen"], "clicking OpenVPN did not open its sheet")

    page.click("#ovpnList .ovpn-card .ovpn-dl")
    time.sleep(0.5)
    after = page.snapshot()
    check(results, name, after["blobs"] == 1, "expected 1 OpenVPN file, got %s" % after["blobs"])
    check(results, name, after["downloads"] and after["downloads"][0].endswith(".ovpn"),
          "OpenVPN download is not an .ovpn: %s" % after["downloads"])
    check(results, name, (after["blobBodies"] or [""])[0].startswith("client"),
          "the OpenVPN file body is not the config")

    page.escape()
    time.sleep(0.3)
    check(results, name, not page.snapshot()["ovpnModalOpen"],
          "Escape did not close the OpenVPN sheet")

    page.click("#ovpnBtn")
    time.sleep(0.2)
    page.click("#ovpnClose")
    time.sleep(0.3)
    closed = page.snapshot()
    check(results, name, not closed["ovpnModalOpen"], "the OpenVPN sheet did not close")

    page.click("#ovpnBtn")
    time.sleep(0.2)
    page.evaluate("document.getElementById('ovpnDownloadAll').click();")
    time.sleep(1.5)
    page.wants_request_suffix = "/openvpn"
    return closed


def fixture_l2tp_only(page, results, name, out_dir):
    state = page.wait_ready()
    check(results, name, state["l2tpBtn"] and state["l2tpModal"],
          "an L2TP-only page must have both the button and the sheet")
    check(results, name, not state["ovpnBtn"] and not state["ovpnModal"],
          "OpenVPN must not appear without OpenVPN configs")
    page.click("#l2tpBtn")
    time.sleep(0.3)
    opened = page.snapshot()
    check(results, name, opened["l2tpModalOpen"], "clicking L2TP did not open its sheet")
    page.click("#l2tpClose")
    time.sleep(0.3)
    closed = page.snapshot()
    check(results, name, not closed["l2tpModalOpen"], "the L2TP sheet did not close")
    return closed


FIXTURES = [
    ("no wireguard", VLESS, [], [], "active", fixture_none),
    ("one wireguard", VLESS + WG_OK[:1], [], [], "active", fixture_one),
    ("three wireguard", WG_OK, [], [], "active", fixture_many),
    ("malformed wireguard", WG_OK[:2] + WG_BAD + [WG_BROKEN_LABEL], [], [], "active",
     fixture_malformed),
    ("duplicate wireguard hosts", WG_DUPE, [], [], "active", fixture_dupes),
    ("newline injection", WG_INJECT, [], [], "active", fixture_injection),
    ("hash in a value", WG_HASH, [], [], "active", fixture_hash),
    ("usable + unusable card", WG_OK[:1] + WG_BAD[:1], [], [], "active",
     fixture_unconvertible_card),
    ("wireguard only", WG_OK, [], [], "active", fixture_wg_only),
    ("openvpn only", VLESS, OVPN, [], "active", fixture_ovpn_only),
    ("l2tp only", VLESS, [], L2TP, "active", fixture_l2tp_only),
]


def start_server(directory):
    handler = functools.partial(QuietHandler, directory=str(directory))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def run_one(binary, base_url, filename, runner, name, results, out_dir):
    recorder = NetworkRecorder()
    chrome = ChromeProcess(binary)
    client = None
    page = None
    try:
        websocket = chrome.wait_for_devtools(30)
        client = CdpClient(websocket, connect_timeout=30)
        client.add_event_handler(recorder.handle)
        target = client.call("Target.createTarget", {"url": "about:blank"})
        session = client.call(
            "Target.attachToTarget", {"targetId": target["targetId"], "flatten": True}
        )["sessionId"]
        for domain in ("Page", "Runtime", "Log", "Network"):
            client.call(domain + ".enable", {}, session_id=session)
        client.call(
            "Page.addScriptToEvaluateOnNewDocument", {"source": INSTRUMENT}, session_id=session
        )
        page = Page(client, session)
        client.call("Page.navigate", {"url": base_url + filename}, session_id=session)
        state = runner(page, results, name, out_dir)
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

    suffix = page.wants_request_suffix if page is not None else None
    if suffix:
        expected = base_url + filename + suffix
        hit = [e for e in recorder.snapshot() if e["url"].split("?")[0] == expected]
        check(results, name, hit,
              "download-all should derive its url from the page it is on and ask for %s, "
              "instead it asked for %s"
              % (expected, [e["url"] for e in recorder.snapshot()]))

    for error in recorder.page_errors:
        results.append("%s -> uncaught javascript error: %s" % (name, error))

    allowed = ("/favicon.ico",) + ((suffix,) if suffix else ())
    for entry in recorder.snapshot():
        status = entry.get("status")
        path = entry["url"].split("?")[0]
        if status is not None and status >= 400 and not path.endswith(allowed):
            results.append("%s -> %s for %s" % (name, status, path))
        if entry.get("error") and not path.endswith(allowed):
            results.append("%s -> request failed (%s) for %s" % (name, entry["error"], path))

    for error in recorder.console_errors:
        if "Failed to load resource" in error:
            continue
        results.append("%s -> console error: %s" % (name, error))
    return state


def main():
    binary = find_chrome()
    if not binary:
        print("  FAIL: no chrome or chromium binary found; set CHROME_BIN to one")
        return 2
    print("  chrome: %s" % binary)
    print("  template: %s" % subrender.TEMPLATE)

    out_dir = Path(tempfile.mkdtemp(prefix="subpage-fixtures-"))
    results = []
    server = start_server(out_dir)
    base_url = "http://127.0.0.1:%d/" % server.server_address[1]
    try:
        for name, links, ovpn, l2tp, status, runner in FIXTURES:
            filename = name.replace(" ", "-") + ".html"
            (out_dir / filename).write_text(
                subrender.render(links, ovpn, l2tp, status), encoding="utf-8"
            )
            before = len(results)
            try:
                state = run_one(binary, base_url, filename, runner, name, results, out_dir)
            except Exception as error:
                results.append(
                    "%s -> harness failed: %s: %s" % (name, type(error).__name__, error)
                )
                state = None
            verdict = "PASS" if len(results) == before else "FAIL"
            summary = ""
            if state:
                summary = "wg=%s cfg=%s left=%s blobs=%s" % (
                    state.get("wgCards"),
                    state.get("cfgCards"),
                    state.get("wgLeftInConfigs"),
                    state.get("blobs"),
                )
            print("  %-26s %-4s  %s" % (name, verdict, summary))
    finally:
        server.shutdown()

    print("")
    if results:
        for item in results:
            print("  FAIL: %s" % item)
        print("")
        print("  rendered pages and downloaded archives kept in %s" % out_dir)
        return 1
    shutil.rmtree(out_dir, ignore_errors=True)
    print("  PASS: %d browser fixtures, every assertion held" % len(FIXTURES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
