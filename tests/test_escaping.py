import re
import sys
from html.parser import HTMLParser
from pathlib import Path

import subrender

HERE = Path(__file__).resolve().parent
TEMPLATE = HERE.parent / "index.html"

ESCAPING_MACROS = ("httpurl", "appurl")

NUMERIC_FILTERS = ("int", "length", "round", "bytesformat", "datetime")

HOSTILE = [
    '"><img src=x onerror=alert(1)>',
    "</textarea><script>alert(2)</script>",
    "</script><script>alert(3)</script>",
    "' onmouseover='alert(5)",
    "</div><iframe src=//evil.invalid>",
    "‮RTL‬override",
]

DANGEROUS_URLS = [
    "javascript:alert(1)",
    "JaVaScRiPt:alert(2)",
    "  javascript:alert(3)",
    "data:text/html,<script>alert(4)</script>",
    "vbscript:msgbox(5)",
]


def jinja_escape(value):
    return (value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                 .replace("'", "&#39;").replace('"', "&#34;"))


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def literal_sets(text):
    names = set()
    for match in re.finditer(r"\{%-?\s*set\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([\[{'\"])", text):
        names.add(match.group(1))
    for match in re.finditer(r"\{%-?\s*set\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\[", text):
        if match.group(2) in names:
            names.add(match.group(1))
    for match in re.finditer(r"\{%-?\s*set\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\.get\(", text):
        if match.group(2) in names:
            names.add(match.group(1))
    return names


def macros_escape(text):
    missing = []
    for macro in ESCAPING_MACROS:
        pattern = r"\{%-?\s*macro\s+" + macro + r"\(.*?\{%-?\s*endmacro\s*-?%\}"
        match = re.search(pattern, text, re.S)
        if not match:
            missing.append("%s is referenced as a safe macro but is not defined" % macro)
            continue
        body = match.group(0)
        if not re.search(r"\|\s*e\b", body):
            missing.append("%s does not escape what it emits" % macro)
        if macro == "appurl" and "javascript" not in body:
            missing.append("appurl does not block a javascript scheme")
        if macro == "httpurl" and "http" not in body:
            missing.append("httpurl does not restrict the scheme")
    return missing


def lint(text):
    problems = []
    constants = literal_sets(text)
    minified = [m.span() for m in re.finditer(r"<script>var QRCode;.*?</script>", text, re.S)]

    def in_minified(offset):
        return any(a <= offset <= b for a, b in minified)

    total = 0
    for match in re.finditer(r"\{\{(.*?)\}\}", text, re.S):
        offset, expr = match.start(), match.group(1).strip()
        total += 1
        if re.search(r"\|\s*e\b", expr):
            continue
        if any(re.search(r"\|\s*%s\b" % f, expr) for f in NUMERIC_FILTERS):
            continue
        head = expr.split("|")[0].strip()
        if any(head.startswith(m + "(") for m in ESCAPING_MACROS):
            continue
        base = re.split(r"[.\[(]", head)[0]
        if base in constants or base.startswith("loop.") or base == "loop":
            continue
        if re.fullmatch(r"[0-9]+", head):
            continue
        if re.search(r"\|\s*safe\b", expr) and base in constants:
            continue
        problems.append("line %d: {{ %s }} reaches the page without escaping"
                        % (line_of(text, offset), expr[:70]))

    for match in re.finditer(r"\|\s*safe\b", text):
        segment = text[max(0, match.start() - 120):match.start()]
        holder = re.findall(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)", segment)
        if not holder or holder[-1] not in constants:
            problems.append("line %d: a | safe filter on something that is not a template constant"
                            % line_of(text, match.start()))

    for match in re.finditer(r"\.innerHTML\s*=\s*([^;]+);", text):
        if in_minified(match.start()):
            continue
        assigned = match.group(1).strip()
        if assigned in ('""', "''"):
            continue
        if re.fullmatch(r"(?:[A-Za-z0-9_ ?:.()]*\bI_[A-Z_]+\b[A-Za-z0-9_ ?:.()]*)", assigned):
            continue
        problems.append("line %d: innerHTML is assigned %s"
                        % (line_of(text, match.start()), assigned[:60]))
    return problems, total


def render_with(payload):
    links = ["vless://11111111-2222-3333-4444-555555555555@192.0.2.5:443?type=tcp#" + payload]
    ovpn = [{"protocol": payload, "filename": payload + ".ovpn", "content": "client\n" + payload}]
    l2tp = [{"remark": payload, "server": "192.0.2.4", "username": payload,
             "password": payload, "secret": payload}]
    return subrender.render(links, ovpn, l2tp, "active")


class TagCensus(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tags = set()
        self.handlers = set()
        self.text = []

    def handle_starttag(self, tag, attrs):
        self.tags.add(tag)
        for name, _ in attrs:
            if name.startswith("on"):
                self.handlers.add((tag, name))

    def handle_data(self, data):
        self.text.append(data)


def census(page):
    parser = TagCensus()
    parser.feed(page)
    return parser


def hostile_checks(payload, baseline_page):
    page = render_with(payload)
    before = census(baseline_page)
    after = census(page)
    problems = []

    new_tags = after.tags - before.tags
    if new_tags:
        problems.append("the payload introduced new elements: %s" % sorted(new_tags))
    new_handlers = after.handlers - before.handlers
    if new_handlers:
        problems.append("the payload introduced event handlers: %s" % sorted(new_handlers))

    if jinja_escape(payload) not in page:
        problems.append("the escaped payload is nowhere in the page - it may have been dropped silently")
    if re.search(r"[<>\"\']", payload) and payload in page:
        problems.append("the raw payload survives into the page")
    return problems


def url_checks(url):
    page = subrender.render(
        ["vless://11111111-2222-3333-4444-555555555555@192.0.2.5:443?type=tcp#node"],
        [], [], "active", announce_url=url, app_url=url)
    problems = []
    for attr in ("href", "src"):
        for match in re.finditer(r'%s\s*=\s*"([^"]*)"' % attr, page):
            value = match.group(1).strip().lower().replace(" ", "")
            if value.startswith(("javascript:", "data:text/html", "vbscript:")):
                problems.append("%s=%r reached the page" % (attr, match.group(1)[:50]))
    return problems


def main():
    text = TEMPLATE.read_text(encoding="utf-8")
    failures = []

    macro_problems = macros_escape(text)
    for item in macro_problems:
        print("  macro problem: %s" % item)
    failures.extend(macro_problems)

    static, total = lint(text)
    print("  interpolations checked : %d" % total)
    print("  unescaped or unsafe    : %d" % len(static))
    for item in static:
        print("    %s" % item)
    failures.extend(static)

    baseline_page = render_with("plain")
    for payload in HOSTILE:
        problems = hostile_checks(payload, baseline_page)
        print("  %-44s %s" % (repr(payload)[:44], "inert" if not problems else "LEAKED"))
        for item in problems:
            print("      %s" % item)
            failures.append("%r: %s" % (payload, item))

    for url in DANGEROUS_URLS:
        problems = url_checks(url)
        print("  %-44s %s" % (repr(url)[:44], "blocked" if not problems else "REACHED THE PAGE"))
        for item in problems:
            print("      %s" % item)
            failures.append("%r: %s" % (url, item))

    print("")
    if failures:
        print("  FAIL: %d problems" % len(failures))
        return 1
    print("  PASS: %d interpolations all escaped, %d hostile strings inert, %d dangerous urls blocked"
          % (total, len(HOSTILE), len(DANGEROUS_URLS)))
    return 0


sys.exit(main())
