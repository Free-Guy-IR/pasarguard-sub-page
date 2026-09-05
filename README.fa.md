# صفحهٔ اشتراک برای PasarGuard

یک صفحهٔ اشتراک فارسی و راست‌چین برای پنل PasarGuard. یک فایل، بدون هیچ درخواست بیرونی.

---

## چرا یک فایل

صفحهٔ اشتراک تنها صفحه‌ای است که کاربر شما **باید** بتواند بازش کند. اگر برای فونت یا آیکون یا Tailwind به CDN وصل شود، هر جایی که آن CDN بسته باشد صفحه خراب بالا می‌آید. اینجا همه‌چیز داخل خود فایل است: CSS، جاوااسکریپت، و کتابخانهٔ تولید بارکد. تنها چیزی که از بیرون می‌آید آیکون برنامه‌هاست که آدرسش را خود پنل می‌دهد، و اگر نیامد ردیف برنامه بدون آیکون درست نمایش داده می‌شود.

## چه چیزی نمایش می‌دهد

- **حلقهٔ مصرف** با درصد، که بالای ۷۵٪ نارنجی و بالای ۹۰٪ قرمز می‌شود
- حجم مصرف‌شده، کل و باقی‌مانده
- تاریخ انقضا و روزهای باقی‌مانده (برای کاربر `on_hold` مدت اشتراک را می‌گوید)
- وضعیت: فعال، در انتظار شروع، منقضی، حجم تمام‌شده، غیرفعال
- اطلاعیهٔ پنل، اگر تنظیم شده باشد
- **برنامه‌ها** با تب سیستم‌عامل؛ تب سیستم کاربر خودکار انتخاب می‌شود
- **کانفیگ‌ها** با برچسب پروتکل، کپی تکی، کپی همه، و بارکد
- **دانلود OpenVPN** وقتی کاربر دسترسی دارد
- WireGuard, VLESS, VMess, Trojan, Shadowsocks, Hysteria2, TUIC, MTProto و هر پروتکل دیگری که پنل بدهد
- پوستهٔ تیره و روشن با کلید تغییر، که انتخاب کاربر را به یاد می‌سپارد

## نصب

### روش یک: نصب خودکار

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Free-Guy-IR/pasarguard-sub-page/main/install.sh)
```

اسکریپت فایل را در `/var/lib/pasarguard/templates/subscription/index.html` می‌گذارد، مقدار `CUSTOM_TEMPLATES_DIRECTORY` را در `.env` تنظیم می‌کند و پنل را ری‌استارت می‌کند.

### روش دو: دستی

```bash
mkdir -p /var/lib/pasarguard/templates/subscription
curl -fsSL -o /var/lib/pasarguard/templates/subscription/index.html \
  https://raw.githubusercontent.com/Free-Guy-IR/pasarguard-sub-page/main/index.html
```

سپس در فایل `.env` پنل:

```ini
CUSTOM_TEMPLATES_DIRECTORY=/var/lib/pasarguard/templates/
SUBSCRIPTION_PAGE_TEMPLATE=subscription/index.html
```

و پنل را ری‌استارت کنید:

```bash
cd /opt/pasarguard && docker compose restart pasarguard
```

اگر پنل را با داکر بالا می‌آورید، مطمئن شوید پوشهٔ قالب‌ها داخل کانتینر mount شده باشد:

```yaml
services:
  pasarguard:
    volumes:
      - /var/lib/pasarguard/templates:/var/lib/pasarguard/templates
```

---

## صفحهٔ اشتراک اختصاصی برای هر ادمین

پنل از این پشتیبانی می‌کند و نیازی به تغییر کد ندارد. هر ادمین می‌تواند صفحهٔ خودش را داشته باشد؛ وقتی کاربرِ آن ادمین لینک اشتراکش را باز کند، صفحهٔ همان ادمین را می‌بیند.

پنل هنگام باز شدن لینک، اول `sub_template` مالکِ کاربر را نگاه می‌کند و اگر خالی بود سراغ قالب پیش‌فرض می‌رود.

### گام یک: یک کپی از قالب برای آن ادمین بسازید

نام پوشه را هرچه می‌خواهید بگذارید؛ اینجا نام ادمین را گذاشته‌ایم:

```bash
mkdir -p /var/lib/pasarguard/templates/reseller_ali
cp /var/lib/pasarguard/templates/subscription/index.html \
   /var/lib/pasarguard/templates/reseller_ali/index.html
```

### گام دو: قالب را به سلیقهٔ آن ادمین دربیاورید

ساده‌ترین تغییر، رنگ است. در بالای فایل یک خط هست:

```css
--hue: 250;
```

عدد را عوض کنید و تمام رنگ‌های صفحه با هم عوض می‌شوند. چند نمونه:

| عدد | رنگ |
|---|---|
| `250` | بنفش (پیش‌فرض) |
| `210` | آبی |
| `160` | سبز |
| `20` | نارنجی |
| `340` | صورتی |

عنوان بالای صفحه هم در همان فایل، در تگ `<title>` و در بخش هدر قابل تغییر است.

### گام سه: در پنل، مسیر را به آن ادمین بدهید

از داشبورد: **مدیران** ← روی ادمین کلیک کنید ← فیلد **Subscription Template** ← این مقدار را بنویسید:

```
reseller_ali/index.html
```

توجه: مسیر **نسبت به پوشهٔ قالب‌ها** است، نه مسیر کامل. یعنی `reseller_ali/index.html` نه `/var/lib/pasarguard/templates/reseller_ali/index.html`.

اگر ترجیح می‌دهید با API انجام دهید:

```bash
curl -X PUT "https://panel.example.com/api/admin/reseller_ali" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sub_template": "reseller_ali/index.html"}'
```

### گام چهار: امتحان کنید

لینک اشتراک یکی از کاربرانِ همان ادمین را در مرورگر باز کنید. باید صفحهٔ اختصاصی را ببینید. کاربران بقیهٔ ادمین‌ها همچنان صفحهٔ پیش‌فرض را می‌بینند.

برای برگرداندن یک ادمین به صفحهٔ پیش‌فرض، فیلد `sub_template` را خالی کنید.

### نکات

- بعد از ویرایش فایل قالب، نیازی به ری‌استارت پنل نیست؛ فقط صفحه را نو کنید.
- اگر مسیری بدهید که فایلش نیست، پنل خطا می‌دهد. اول با یک کاربر تستی امتحان کنید.
- ادمین‌ها نمی‌توانند با این فیلد فایل‌های دیگر سرور را بخوانند؛ Jinja مسیرهای بیرون از پوشهٔ قالب‌ها را رد می‌کند.

---

## متغیرهایی که پنل به قالب می‌دهد

اگر خواستید قالب را عوض کنید، این‌ها در دسترس‌اند:

| متغیر | چیست |
|---|---|
| `user.username` | نام کاربری |
| `user.status.value` | `active` / `on_hold` / `expired` / `limited` / `disabled` |
| `user.used_traffic` | بایت مصرف‌شده |
| `user.data_limit` | بایت کل؛ `0` یا خالی یعنی نامحدود |
| `user.expire` | تاریخ انقضا |
| `user.on_hold_expire_duration` | ثانیه، برای کاربر در انتظار شروع |
| `links` | فهرست رشته‌های کانفیگ |
| `apps` | برنامه‌ها با `name`، `icon_url`، `import_url`، `platform.value`، `description` |
| `announce` / `announce_url` | اطلاعیه |
| `has_openvpn` | آیا دکمهٔ OpenVPN نمایش داده شود |

فیلترهای موجود: `bytesformat`، `datetime`، `yaml`، `only`، `except`. تابع `now()` هم هست.

---

## سازگاری

روی PasarGuard نسخهٔ ۵ آزمایش شده. با فورک‌هایی که ساختار قالب اشتراک را عوض نکرده‌اند هم کار می‌کند.

## مجوز

MIT
