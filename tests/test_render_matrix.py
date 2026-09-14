import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from subrender import render

OVPN = [
    {"protocol": "udp", "filename": "node-udp.ovpn", "content": "client\ndev tun\n"},
    {"protocol": "tcp", "filename": "node-tcp.ovpn", "content": "client\ndev tun\n"},
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
WG = [
    "wireguard://cHJpdmF0ZWtleTE%3D@1.2.3.4:51820/?publickey=cHVia2V5MQ%3D%3D&address=10.0.0.2%2F32",
    "wireguard://cHJpdmF0ZWtleTI%3D@1.2.3.4:51821/?publickey=cHVia2V5Mg%3D%3D&address=10.0.0.3%2F32",
]
VLESS = ["vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?type=tcp#node-a"]

CASES = [
    ("both protocols, active", VLESS + WG, OVPN, L2TP, "active"),
    ("openvpn only, active", VLESS, OVPN, [], "active"),
    ("l2tp only, active", VLESS, [], L2TP, "active"),
    ("neither, active", VLESS, [], [], "active"),
    ("both, expired", VLESS, OVPN, L2TP, "expired"),
    ("both, on_hold", VLESS + WG, OVPN, L2TP, "on_hold"),
    ("wireguard only, active", WG, [], [], "active"),
    ("no links at all, active", [], [], [], "active"),
]


def has(html, ident):
    return re.search(r'id="%s"' % re.escape(ident), html) is not None


def main():
    failures = []
    for name, links, ovpn, l2tp, status in CASES:
        try:
            html = render(links, ovpn, l2tp, status)
        except Exception as error:
            failures.append("%s -> render raised %s: %s" % (name, type(error).__name__, error))
            print("  %-26s RENDER FAILED  %s" % (name, error))
            continue

        ob, om = has(html, "ovpnBtn"), has(html, "ovpnModal")
        lb, lm = has(html, "l2tpBtn"), has(html, "l2tpModal")
        wb, wm = has(html, "wgBtn"), has(html, "wgModal")
        print(
            "  %-26s ovpn btn=%-5s modal=%-5s | l2tp btn=%-5s modal=%-5s | "
            "wg btn=%-5s modal=%-5s | %6d B"
            % (name, ob, om, lb, lm, wb, wm, len(html))
        )

        if ob != om:
            failures.append("%s -> OpenVPN button/modal mismatch (btn=%s modal=%s)" % (name, ob, om))
        if lb != lm:
            failures.append("%s -> L2TP button/modal mismatch (btn=%s modal=%s)" % (name, lb, lm))

        cb, cm, tm = has(html, "cfgList"), has(html, "cfgModal"), has(html, "tgModal")
        if wb and not wm:
            failures.append("%s -> WireGuard button without its modal" % name)
        if (wm, cm, tm) != (True, True, True):
            failures.append(
                "%s -> shell modals out of step: wg=%s cfg=%s tg=%s" % (name, wm, cm, tm)
            )
        if wb != (status in ("active", "on_hold")):
            failures.append(
                "%s -> WireGuard button present=%s, expected %s"
                % (name, wb, status in ("active", "on_hold"))
            )
        if not cb:
            failures.append("%s -> cfgList missing, the WireGuard move has nothing to read" % name)

        wants_ovpn = bool(ovpn) and status in ("active", "on_hold")
        if ob != wants_ovpn:
            failures.append("%s -> OpenVPN section present=%s, expected %s" % (name, ob, wants_ovpn))
        wants_l2tp = bool(l2tp) and status in ("active", "on_hold")
        if lb != wants_l2tp:
            failures.append("%s -> L2TP section present=%s, expected %s" % (name, lb, wants_l2tp))

    print("")
    if failures:
        for item in failures:
            print("  FAIL: %s" % item)
        return 1
    print("  PASS: %d scenarios rendered, every button has its modal" % len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
