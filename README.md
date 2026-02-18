# Xray Google Egress

سرویس وب امن برای Ubuntu 22.04+ که با Xray، دقیقاً مشخص می‌کند Google چه IPی از شما می‌بیند.

## یک‌کلیک نصب

بعد از اینکه فایل‌ها را روی شاخه `main` ریپو گذاشتی، فقط این یک خط را اجرا کن:

```bash
curl -fsSL https://raw.githubusercontent.com/zahedoo/XrayGoogleEgress/main/install.sh | sudo bash
```

بعد از نصب:

- داشبورد: `http://SERVER_IP/`
- JSON API: `http://SERVER_IP/api/status`
- Health: `http://SERVER_IP/healthz`

## چه چیزی نمایش می‌دهد

- `google_seen_ip`: IP واقعی که Google از طریق Xray می‌بیند
- `google_outbound_tag`: outboundTag واقعی برای ترافیک Google (از access log)
- `generic_ip`: IP عمومی مسیر عمومی
- `routing_split`: اگر Google و Generic متفاوت باشند `true`
- `country`, `isp`, `asn`
- `dns_leak`
- `ipv6_leak`
- `status`

نمونه خروجی API:

```json
{
  "google_seen_ip": "x.x.x.x",
  "google_outbound_tag": "proxy-out",
  "generic_ip": "x.x.x.x",
  "routing_split": true,
  "country": "...",
  "isp": "...",
  "asn": "...",
  "dns_leak": false,
  "ipv6_leak": false,
  "status": "secure"
}
```

## امنیت

- نصب فقط با root
- کاربر سیستمی جداگانه بدون login shell
- سرویس systemd با auto-restart
- استفاده امن از subprocess (بدون `shell=True`)
- لاگ موقت Xray فقط زمان تحلیل outboundTag فعال می‌شود و بعد restore می‌شود

## فایل‌های ریپو

- `install.sh` ← نصب کامل و خودکار
- `README.md` ← راهنمای اجرا

## انتشار روی GitHub

در همین پوشه:

```bash
git init
git add .
git commit -m "Production installer + dashboard"
git branch -M main
git remote add origin https://github.com/zahedoo/XrayGoogleEgress.git
git push -u origin main
```

بعد از push، دستور یک‌خطی نصب بالا فعال می‌شود.
