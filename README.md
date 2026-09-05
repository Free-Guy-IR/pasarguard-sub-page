# PasarGuard Sub Page

A Persian, right-to-left subscription page for the PasarGuard panel. One file, no outside requests.

[فارسی](README.fa.md)

---

## Why one file

The subscription page is the one page your users **must** be able to open. A page that reaches out to a CDN for its font, its icons or its CSS breaks wherever that CDN is blocked, which for this audience is most of the time. Everything here ships inside the file: the styles, the script, and the QR encoder. The only thing loaded from elsewhere is the app icons, whose URLs the panel itself supplies, and a row whose icon fails to load still renders correctly.

## What it shows

- A **usage ring** with the percentage, turning amber past 75% and red past 90%
- Used, total and remaining traffic
- Expiry date and days left, or the plan length for a user who has not started yet
- Status: active, on hold, expired, out of data, disabled
- The panel's announcement, when one is set
- **Apps**, grouped into tabs by platform, with the visitor's own platform selected
- **Configs** with a protocol badge, copy, copy-all and a QR code
- An **OpenVPN download** button for users who have it
- WireGuard, VLESS, VMess, Trojan, Shadowsocks, Hysteria2, TUIC, MTProto, and anything else the panel emits
- Dark and light themes with a toggle that remembers the choice

## Install

### Automatic

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Free-Guy-IR/pasarguard-sub-page/main/install.sh)
```

It writes the template to `/var/lib/pasarguard/templates/subscription/index.html`, sets `CUSTOM_TEMPLATES_DIRECTORY` in the panel's `.env`, and restarts the panel.

### By hand

```bash
mkdir -p /var/lib/pasarguard/templates/subscription
curl -fsSL -o /var/lib/pasarguard/templates/subscription/index.html \
  https://raw.githubusercontent.com/Free-Guy-IR/pasarguard-sub-page/main/index.html
```

Then in the panel's `.env`:

```ini
CUSTOM_TEMPLATES_DIRECTORY=/var/lib/pasarguard/templates/
SUBSCRIPTION_PAGE_TEMPLATE=subscription/index.html
```

Restart the panel:

```bash
cd /opt/pasarguard && docker compose restart pasarguard
```

If the panel runs in Docker, make sure the templates directory is mounted into the container:

```yaml
services:
  pasarguard:
    volumes:
      - /var/lib/pasarguard/templates:/var/lib/pasarguard/templates
```

---

## A different page for each admin

The panel already supports this; no code change is needed. When a subscription link is opened, the panel looks at the `sub_template` of the user's own admin first, and falls back to the global template when it is empty.

**1. Copy the template for that admin**

```bash
mkdir -p /var/lib/pasarguard/templates/reseller_ali
cp /var/lib/pasarguard/templates/subscription/index.html \
   /var/lib/pasarguard/templates/reseller_ali/index.html
```

**2. Make it theirs.** The whole palette derives from one line near the top:

```css
--hue: 250;
```

`210` is blue, `160` green, `20` orange, `340` pink. The `<title>` and the header text are in the same file.

**3. Point the admin at it.** In the dashboard: **Admins** → the admin → **Subscription Template** → enter the path *relative to the templates directory*:

```
reseller_ali/index.html
```

Or through the API:

```bash
curl -X PUT "https://panel.example.com/api/admin/reseller_ali" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sub_template": "reseller_ali/index.html"}'
```

**4. Check it** by opening the subscription link of one of that admin's users. Everyone else keeps the default page. Clear the field to put an admin back on the default.

Editing a template file takes effect on the next page load; no restart. A path that does not exist raises an error, so try it on a test user first. An admin cannot use this field to read other files on the server: Jinja rejects paths outside the templates directory.

---

## What the panel passes to the template

| Variable | Meaning |
|---|---|
| `user.username` | the username |
| `user.status.value` | `active` / `on_hold` / `expired` / `limited` / `disabled` |
| `user.used_traffic` | bytes used |
| `user.data_limit` | bytes allowed; `0` or empty means unlimited |
| `user.expire` | expiry date |
| `user.on_hold_expire_duration` | seconds, for a user who has not started |
| `links` | the config strings |
| `apps` | each with `name`, `icon_url`, `import_url`, `platform.value`, `description` |
| `announce` / `announce_url` | the announcement |
| `has_openvpn` | whether to offer the OpenVPN download |

Filters: `bytesformat`, `datetime`, `yaml`, `only`, `except`. The `now()` global is available too.

---

## Compatibility

Tested against PasarGuard v5. It works with forks that have not changed the subscription template contract.

## License

MIT
