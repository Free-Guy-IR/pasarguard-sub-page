import datetime, pathlib, types, sys, re
from jinja2 import Environment, FileSystemLoader

BASE = pathlib.Path(__file__).resolve().parent
NOW = datetime.datetime(2026, 9, 6, 6, 30)
ns = lambda **k: types.SimpleNamespace(**k)
GB = 1024**3

PAYLOADS = {
  "attr-breakout":   '"><script>window.PWNED=1</script><img src="',
  "onerror-override":'x" onerror="window.PWNED=1',
  "javascript-uri":  'javascript:window.PWNED=1',
  "js-comment-uri":  'javascript://x%0awindow.PWNED=1',
  "data-uri":        'data:text/html,<script>window.PWNED=1</script>',
  "html-text":       '<script>window.PWNED=1</script>',
  "quote-tag":       '"><svg onload=window.PWNED=1>',
}

env = Environment(loader=FileSystemLoader(str(BASE)))
env.filters["datetime"] = lambda d: d.strftime("%Y/%m/%d") if hasattr(d,"strftime") else str(d)
env.filters["bytesformat"] = lambda b: f"{(b or 0)/GB:.2f} GB"
env.globals["now"] = lambda: NOW
print("autoescape محیط تست:", env.autoescape, "(همان حالت پنل واقعی)\n")

fails = 0
for name, pay in PAYLOADS.items():
    user = ns(username=pay, status=ns(value="active"), used_traffic=int(37.4*GB),
              data_limit=60*GB, expire=NOW+datetime.timedelta(days=23), on_hold_expire_duration=0)
    apps = [ns(name=pay, platform=ns(value="android"), icon_url=pay, import_url=pay,
               download_links=[ns(url=pay)])]
    html = env.get_template("index.html").render(
        user=user, links=["vless://EXAMPLE#"+pay], apps=apps, announce_url=pay, has_openvpn=True)

    markup = re.sub(r'(?is)<script\b.*?</script>', '', html)
    bad = []
    if re.search(r"<script[^>]*>[^<]*PWNED", html, re.I): bad.append("تگ script اجراشدنی")
    if re.search(r"<svg[^>]*onload", markup, re.I):       bad.append("svg onload")
    if re.search(r'onerror\s*=\s*"[^"]*PWNED', markup, re.I):bad.append("onerror تزریقی")
    if re.search(r'href\s*=\s*"\s*javascript:', markup, re.I):bad.append("href جاوااسکریپتی")
    if re.search(r'src\s*=\s*"\s*(javascript|data):', markup, re.I):bad.append("src خطرناک")
    status = "❌ " + " و ".join(bad) if bad else "✅ خنثی"
    if bad: fails += 1
    print(f"  {name:18} {status}")

print(f"\nنتیجه: {len(PAYLOADS)-fails}/{len(PAYLOADS)} پیلود خنثی شد")

user = ns(username="demo", status=ns(value="active"), used_traffic=1, data_limit=60*GB,
          expire=NOW+datetime.timedelta(days=5), on_hold_expire_duration=0)
apps = [ns(name="Happ", platform=ns(value="android"), icon_url="",
           import_url="happ://add/SUB", download_links=[ns(url="https://example.com/happ")])]
clean = env.get_template("index.html").render(user=user, links=["vless://EXAMPLE#Node"],
        apps=apps, announce_url="https://t.me/example", has_openvpn=True)
print("\nرگرسیون محتوای سالم:")
regress = {
  "گلیف SVG هنوز خام رندر می‌شود (| safe نشکسته)": "<svg" in clean,
  "هیچ entity قابل‌مشاهده‌ای در متن نیست": "&amp;lt;" not in clean and "&amp;amp;" not in clean,
  "لینک اپ با طرح‌وارهٔ مجاز حفظ شد": "happ://add/SUB" in clean,
  "لینک دانلود https حفظ شد": "https://example.com/happ" in clean,
  "لینک اعلان https حفظ شد": "https://t.me/example" in clean,
}
for k, v in regress.items():
    print(("  ✅ " if v else "  ❌ ") + k)
    if not v: fails += 1
sys.exit(1 if fails else 0)
