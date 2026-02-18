# Xray Google Egress (Upload + Safe Test)

سرویس وب Production برای Ubuntu 22.04+ که:

- فایل `config.json` سفارشی Xray را آپلود می‌گیرد
- به‌صورت امن تست می‌کند (Google + Generic + Routing/Leak checks)
- نتیجه را در داشبورد و API نشان می‌دهد
- بعد از هر تست، **کانفیگ قبلی Xray را restore می‌کند**

---

## One-Click Install

```bash
curl -fsSL -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/zahedoo/XrayGoogleEgress/main/install.sh?ts=$(date +%s)" | sudo bash
```

## Troubleshooting

If you see `open /usr/local/etc/xray/config.json: permission denied` or `Permission denied creating runtime directories`, run installer again from latest `main`:

```bash
curl -fsSL -H 'Cache-Control: no-cache' "https://raw.githubusercontent.com/zahedoo/XrayGoogleEgress/main/install.sh?ts=$(date +%s)" | sudo bash
```

بعد از نصب:

- Dashboard: `http://SERVER_IP/`
- API Status: `http://SERVER_IP/api/status`
- Health: `http://SERVER_IP/healthz`

---

## User Flow

1. وارد `http://SERVER_IP/` شوید  
2. فایل `config.json` را انتخاب کنید  
3. روی Submit بزنید  
4. سرور این کارها را انجام می‌دهد:
   - JSON validation
   - Apply امن روی Xray
   - Restart + health check
   - Google-seen IP (authoritative via Google DoH through proxy)
   - Generic IP (ipify via proxy)
   - outboundTag از access log
   - DNS leak / IPv6 leak
   - Geo/ISP/ASN
   - Restore کانفیگ قبلی

---

## Success JSON

```json
{
  "status": "success",
  "google_seen_ip": "x.x.x.x",
  "google_outbound_tag": "tag",
  "generic_ip": "x.x.x.x",
  "routing_split": true,
  "country": "...",
  "isp": "...",
  "asn": "...",
  "dns_leak": false,
  "ipv6_leak": false,
  "checked_at": "ISO8601 UTC"
}
```

## Invalid JSON

```json
{
  "status": "invalid_config",
  "error": "human readable error",
  "xray_journal_tail": "last 80 lines"
}
```

---

## Security

- dedicated system user بدون login shell
- file upload limit: `1MB`
- no external Python dependency (standard library only)
- subprocess calls بدون `shell=True`
- secret masking در خروجی‌ها و لاگ‌ها
- lock برای جلوگیری از race در آپلود همزمان
- backup/restore کانفیگ Xray در هر تست

---

## Repository Files

- `install.sh`
- `app.py`
- `google-egress-xray-test.sh`
- `google-egress-xray-logctl.sh`
- `google-egress-check.service`

---

## Push to GitHub

```bash
git add .
git commit -m "Production upload-based Google egress validator"
git push -u origin main
```
