import base64
import json
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import urlsplit

WHITESPACE = re.compile(r"\s+")

CHROME_COMMANDS = (
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser",
    "chrome",
)

CHROME_PATHS = (
    Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    Path("/Applications/Chromium.app/Contents/MacOS/Chromium"),
    Path("/usr/bin/google-chrome"),
    Path("/usr/bin/google-chrome-stable"),
    Path("/usr/bin/chromium"),
    Path("/usr/bin/chromium-browser"),
    Path("/snap/bin/chromium"),
)

CHROME_GLOBS = (
    ("/opt/hostedtoolcache/chrome", "*/chrome-linux64/chrome"),
    ("/opt/hostedtoolcache/chromium", "*/chrome-linux/chrome"),
    ("/opt/hostedtoolcache/setup-chrome/chromium", "*/x64/chrome"),
)


def report(line):
    print(line, flush=True)


def find_chrome():
    environment = os.environ.get("CHROME_BIN") or os.environ.get("CHROME_PATH")
    if environment and Path(environment).is_file():
        return environment
    for command in CHROME_COMMANDS:
        found = shutil.which(command)
        if found:
            return found
    for candidate in CHROME_PATHS:
        if candidate.is_file():
            return str(candidate)
    for root, pattern in CHROME_GLOBS:
        base = Path(root)
        if not base.is_dir():
            continue
        for candidate in sorted(base.glob(pattern), reverse=True):
            if candidate.is_file():
                return str(candidate)
    return None


class WebSocketError(Exception):
    pass


class WebSocketConnection:
    def __init__(self, url, connect_timeout):
        parts = urlsplit(url)
        host = parts.hostname or "127.0.0.1"
        port = parts.port or 80
        path = parts.path or "/"
        if parts.query:
            path = "%s?%s" % (path, parts.query)
        self._socket = socket.create_connection((host, port), timeout=connect_timeout)
        self._socket.settimeout(1.0)
        self._receive_buffer = bytearray()
        self._send_lock = threading.Lock()
        self._handshake(host, port, path)

    def _handshake(self, host, port, path):
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            "GET %s HTTP/1.1\r\n"
            "Host: %s:%s\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n" % (path, host, port, key)
        )
        self._socket.sendall(request.encode("ascii"))
        deadline = time.monotonic() + 10
        while b"\r\n\r\n" not in self._receive_buffer:
            if time.monotonic() > deadline:
                raise WebSocketError("timed out waiting for the websocket handshake response")
            self._fill()
        header_end = self._receive_buffer.index(b"\r\n\r\n") + 4
        header = bytes(self._receive_buffer[:header_end]).decode("latin-1")
        del self._receive_buffer[:header_end]
        if "101" not in header.split("\r\n", 1)[0]:
            first_line = header.splitlines()[0] if header else header
            raise WebSocketError("websocket upgrade refused: %r" % (first_line,))

    def _fill(self):
        try:
            chunk = self._socket.recv(65536)
        except TimeoutError:
            return
        if not chunk:
            raise WebSocketError("websocket closed by the peer")
        self._receive_buffer.extend(chunk)

    def _read_exactly(self, count):
        while len(self._receive_buffer) < count:
            self._fill()
        payload = bytes(self._receive_buffer[:count])
        del self._receive_buffer[:count]
        return payload

    def _send_frame(self, opcode, payload):
        header = bytearray()
        header.append(0x80 | opcode)
        length = len(payload)
        if length < 126:
            header.append(0x80 | length)
        elif length < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", length))
        mask = os.urandom(4)
        header.extend(mask)
        masked = bytes(byte ^ mask[position % 4] for position, byte in enumerate(payload))
        with self._send_lock:
            self._socket.sendall(bytes(header) + masked)

    def send_text(self, text):
        self._send_frame(0x1, text.encode("utf-8"))

    def receive_text(self):
        message = bytearray()
        message_opcode = None
        while True:
            first, second = self._read_exactly(2)
            final = bool(first & 0x80)
            opcode = first & 0x0F
            length = second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read_exactly(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read_exactly(8))[0]
            payload = self._read_exactly(length) if length else b""
            if opcode == 0x8:
                raise WebSocketError("websocket close frame received")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            if opcode in (0x1, 0x2):
                message_opcode = opcode
                message = bytearray(payload)
            else:
                message.extend(payload)
            if final:
                if message_opcode == 0x1:
                    return message.decode("utf-8", errors="replace")
                message = bytearray()
                message_opcode = None

    def close(self):
        try:
            self._socket.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._socket.close()
        except OSError:
            pass


class CdpClient:
    def __init__(self, websocket_url, connect_timeout=30):
        self._connection = WebSocketConnection(websocket_url, connect_timeout)
        self._next_id = 0
        self._id_lock = threading.Lock()
        self._responses = {}
        self._response_event = threading.Condition()
        self._event_handlers = []
        self._stopped = threading.Event()
        self._failure = None
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def add_event_handler(self, handler):
        self._event_handlers.append(handler)

    def _read_loop(self):
        while not self._stopped.is_set():
            try:
                raw = self._connection.receive_text()
            except WebSocketError as error:
                self._failure = str(error)
                break
            except OSError as error:
                self._failure = str(error)
                break
            try:
                message = json.loads(raw)
            except ValueError:
                continue
            if "id" in message:
                with self._response_event:
                    self._responses[message["id"]] = message
                    self._response_event.notify_all()
                continue
            for handler in list(self._event_handlers):
                handler(message)
        with self._response_event:
            self._response_event.notify_all()

    def call(self, method, params=None, session_id=None, timeout=20):
        with self._id_lock:
            self._next_id += 1
            message_id = self._next_id
        payload = {"id": message_id, "method": method, "params": params or {}}
        if session_id:
            payload["sessionId"] = session_id
        self._connection.send_text(json.dumps(payload))
        deadline = time.monotonic() + timeout
        with self._response_event:
            while message_id not in self._responses:
                if self._failure:
                    raise WebSocketError("devtools connection lost: %s" % self._failure)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise WebSocketError(
                        "timed out after %ss waiting for the %s response" % (timeout, method)
                    )
                self._response_event.wait(min(remaining, 0.5))
            message = self._responses.pop(message_id)
        if "error" in message:
            raise WebSocketError("%s failed: %s" % (method, message["error"]))
        return message.get("result", {})

    def close(self):
        self._stopped.set()
        self._connection.close()
        self._reader.join(timeout=5)


class ChromeProcess:
    def __init__(self, binary):
        self.profile_dir = tempfile.mkdtemp(prefix="subpage-cdp-")
        command = [
            binary,
            "--headless=new",
            "--disable-gpu",
            "--no-sandbox",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions",
            "--disable-dev-shm-usage",
            "--disable-background-timer-throttling",
            "--disable-renderer-backgrounding",
            "--disable-backgrounding-occluded-windows",
            "--remote-allow-origins=*",
            "--remote-debugging-port=0",
            "--user-data-dir=%s" % self.profile_dir,
            "about:blank",
        ]
        self.stderr_path = Path(self.profile_dir) / "chrome-stderr.log"
        self._stderr_handle = self.stderr_path.open("wb")
        try:
            self.process = subprocess.Popen(
                command,
                stdout=subprocess.DEVNULL,
                stderr=self._stderr_handle,
                start_new_session=True,
            )
        except OSError:
            self._stderr_handle.close()
            shutil.rmtree(self.profile_dir, ignore_errors=True)
            raise
        self.process_group = self.process.pid
        self.cleanup_error = None
        self.probe_error = None

    def wait_for_devtools(self, timeout=30):
        port_file = Path(self.profile_dir) / "DevToolsActivePort"
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise WebSocketError(
                    "chrome exited early with code %s: %s"
                    % (self.process.returncode, self.stderr_tail())
                )
            if port_file.is_file():
                content = port_file.read_text(encoding="utf-8", errors="replace").splitlines()
                if len(content) >= 2 and content[0].strip().isdigit():
                    return "ws://127.0.0.1:%s%s" % (content[0].strip(), content[1].strip())
            time.sleep(0.1)
        raise WebSocketError(
            "chrome never published a devtools endpoint within %ss: %s" % (timeout, self.stderr_tail())
        )

    def stderr_tail(self, limit=600):
        try:
            self._stderr_handle.flush()
            return self.stderr_path.read_text(encoding="utf-8", errors="replace")[-limit:]
        except OSError:
            return ""

    def terminate(self):
        self._signal_group(signal.SIGTERM)
        if self.process.poll() is None:
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
        deadline = time.monotonic() + 10
        while self._group_is_alive() and time.monotonic() < deadline:
            time.sleep(0.2)
        if self._group_is_alive():
            self._signal_group(signal.SIGKILL)
            deadline = time.monotonic() + 10
            while self._group_is_alive() and time.monotonic() < deadline:
                time.sleep(0.2)
        if self.process.poll() is None:
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        if self._group_is_alive():
            detail = " (%s)" % self.probe_error if self.probe_error else ""
            self.cleanup_error = (
                "chrome process group %s was still alive after SIGKILL%s"
                % (self.process_group, detail)
            )
            report(self.cleanup_error)
        try:
            self._stderr_handle.close()
        except OSError:
            pass
        shutil.rmtree(self.profile_dir, ignore_errors=True)

    def _group_is_alive(self):
        try:
            os.killpg(self.process_group, 0)
        except ProcessLookupError:
            self.probe_error = None
            return False
        except OSError as error:
            self.probe_error = str(error)
            return True
        self.probe_error = None
        return True

    def _signal_group(self, which):
        try:
            os.killpg(self.process_group, which)
            return
        except ProcessLookupError:
            return
        except OSError as error:
            report("could not signal chrome process group %s: %s" % (self.process_group, error))
        try:
            if which == signal.SIGKILL:
                self.process.kill()
            else:
                self.process.terminate()
        except OSError as error:
            report("could not signal the chrome leader process: %s" % error)


class NetworkRecorder:
    def __init__(self):
        self.entries = []
        self.active = {}
        self.page_errors = []
        self.console_errors = []
        self.lock = threading.Lock()

    def handle(self, message):
        method = message.get("method", "")
        params = message.get("params", {})
        with self.lock:
            if method == "Network.requestWillBeSent":
                request_id = params.get("requestId")
                redirect = params.get("redirectResponse")
                previous = self.active.get(request_id)
                if redirect is not None and previous is not None:
                    previous["status"] = redirect.get("status")
                request = params.get("request", {})
                entry = {
                    "url": request.get("url", ""),
                    "status": None,
                    "error": None,
                }
                self.entries.append(entry)
                self.active[request_id] = entry
            elif method == "Network.responseReceived":
                entry = self.active.get(params.get("requestId"))
                if entry is not None:
                    entry["status"] = params.get("response", {}).get("status")
            elif method == "Network.loadingFailed":
                entry = self.active.get(params.get("requestId"))
                if entry is not None:
                    entry["error"] = params.get("errorText")
            elif method == "Runtime.exceptionThrown":
                details = params.get("exceptionDetails", {})
                text = (
                    details.get("exception", {}).get("description")
                    or details.get("text")
                    or "uncaught error"
                )
                self.page_errors.append(WHITESPACE.sub(" ", str(text))[:300])
            elif method == "Log.entryAdded":
                entry = params.get("entry", {})
                if entry.get("level") == "error":
                    self.console_errors.append(
                        WHITESPACE.sub(" ", str(entry.get("text", "")))[:300]
                    )

    def snapshot(self):
        with self.lock:
            return [dict(entry) for entry in self.entries]
