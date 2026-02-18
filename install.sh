#!/usr/bin/env bash
set -euo pipefail
umask 027

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash install.sh"
  exit 1
fi

APP_DIR="/opt/google-egress-check"
APP_FILE="${APP_DIR}/app.py"
SERVICE_FILE="/etc/systemd/system/google-egress-check.service"
APP_USER="googleegress"
APP_GROUP="googleegress"
STATE_DIR="/var/lib/google-egress-check"
LOG_DIR="/var/log/google-egress-check"
HELPER_FILE="/usr/local/sbin/google-egress-xray-logctl"
SUDOERS_FILE="/etc/sudoers.d/google-egress-check"

detect_xray_config_path() {
  local p
  for p in /usr/local/etc/xray/config.json /etc/xray/config.json; do
    if [[ -f "${p}" ]]; then
      echo "${p}"
      return 0
    fi
  done
  return 1
}

install_xray_if_missing() {
  if command -v xray >/dev/null 2>&1; then
    echo "[3/10] Xray already installed"
    return 0
  fi

  echo "[3/10] Installing Xray"
  local tmp_script
  tmp_script="$(mktemp)"
  curl -fsSL "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" -o "${tmp_script}"
  bash "${tmp_script}" install
  rm -f "${tmp_script}"

  if ! command -v xray >/dev/null 2>&1; then
    echo "Xray installation failed"
    exit 1
  fi
}

ensure_xray_config() {
  echo "[4/10] Ensuring Xray config and SOCKS inbound 127.0.0.1:10808"
  local cfg_path
  if ! cfg_path="$(detect_xray_config_path)"; then
    mkdir -p /usr/local/etc/xray
    cfg_path="/usr/local/etc/xray/config.json"
    cat > "${cfg_path}" <<'JSON'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "google-egress-socks",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
JSON
    chmod 0600 "${cfg_path}"
  fi

  mkdir -p "${STATE_DIR}"
  chmod 0750 "${STATE_DIR}"
  chown root:"${APP_GROUP}" "${STATE_DIR}" || true

  local install_backup="${STATE_DIR}/xray-config.preinstall.$(date +%s).json"
  cp -f "${cfg_path}" "${install_backup}"
  chmod 0600 "${install_backup}"

  if ! jq empty "${cfg_path}" >/dev/null 2>&1; then
    echo "Invalid Xray config JSON: ${cfg_path}"
    exit 1
  fi

  local tmp_cfg
  tmp_cfg="$(mktemp)"
  jq \
    '(.inbounds //= []) |
     (.outbounds //= []) |
     (if any(.inbounds[]?; (.protocol == "socks") and (((.port | tonumber?) // -1) == 10808)) then . else .inbounds += [{"tag":"google-egress-socks","listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":true}}] end) |
     (if (.outbounds | length) == 0 then .outbounds = [{"tag":"direct","protocol":"freedom","settings":{}}] else . end)' \
    "${cfg_path}" > "${tmp_cfg}"
  install -m 0600 -o root -g root "${tmp_cfg}" "${cfg_path}"
  rm -f "${tmp_cfg}"
}

echo "[1/10] Installing dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv curl jq dnsutils sudo

echo "[2/10] Creating application user and directories"
if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
  groupadd --system "${APP_GROUP}"
fi
if ! id -u "${APP_USER}" >/dev/null 2>&1; then
  useradd --system --gid "${APP_GROUP}" --home-dir "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
fi

mkdir -p "${APP_DIR}" "${STATE_DIR}" "${LOG_DIR}"
chown root:"${APP_GROUP}" "${APP_DIR}" "${STATE_DIR}" "${LOG_DIR}"
chmod 0750 "${APP_DIR}" "${STATE_DIR}" "${LOG_DIR}"

install_xray_if_missing
ensure_xray_config

echo "[5/10] Enabling Xray service"
systemctl daemon-reload
systemctl enable --now xray
systemctl restart xray

echo "[6/10] Installing Xray log helper"
cat > "${HELPER_FILE}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
umask 027

ACTION="${1:-}"
if [[ "${ACTION}" != "enable" && "${ACTION}" != "disable" ]]; then
  echo "Usage: $0 {enable|disable}" >&2
  exit 1
fi

APP_GROUP="googleegress"
STATE_DIR="/var/lib/google-egress-check"
LOG_DIR="/var/log/google-egress-check"
ACCESS_LOG="${LOG_DIR}/xray-access.log"
ERROR_LOG="${LOG_DIR}/xray-error.log"
BACKUP_CFG="${STATE_DIR}/xray-config.backup.json"
CFG_PATH_FILE="${STATE_DIR}/xray-config.path"
LOCK_FILE="${STATE_DIR}/xray-logctl.lock"

detect_xray_config_path() {
  local p
  for p in /usr/local/etc/xray/config.json /etc/xray/config.json; do
    if [[ -f "${p}" ]]; then
      echo "${p}"
      return 0
    fi
  done
  return 1
}

mkdir -p "${STATE_DIR}" "${LOG_DIR}"
chown root:"${APP_GROUP}" "${STATE_DIR}" "${LOG_DIR}"
chmod 0750 "${STATE_DIR}" "${LOG_DIR}"
touch "${ACCESS_LOG}" "${ERROR_LOG}"
chown root:"${APP_GROUP}" "${ACCESS_LOG}" "${ERROR_LOG}"
chmod 0640 "${ACCESS_LOG}" "${ERROR_LOG}"

exec 9>"${LOCK_FILE}"
flock -w 20 9

if [[ "${ACTION}" == "enable" ]]; then
  CFG_PATH="$(detect_xray_config_path)"
  if [[ -f "${BACKUP_CFG}" && -f "${CFG_PATH_FILE}" ]]; then
    PREV_CFG_PATH="$(cat "${CFG_PATH_FILE}")"
    if [[ -f "${PREV_CFG_PATH}" ]]; then
      install -m 0600 -o root -g root "${BACKUP_CFG}" "${PREV_CFG_PATH}" || true
      systemctl restart xray || true
    fi
    rm -f "${BACKUP_CFG}" "${CFG_PATH_FILE}"
  fi

  cp -f "${CFG_PATH}" "${BACKUP_CFG}"
  chmod 0600 "${BACKUP_CFG}"
  echo "${CFG_PATH}" > "${CFG_PATH_FILE}"
  chmod 0600 "${CFG_PATH_FILE}"

  TMP_CFG="$(mktemp)"
  jq --arg access "${ACCESS_LOG}" --arg error "${ERROR_LOG}" \
    '.log = (.log // {}) | .log.access = $access | .log.error = $error | .log.loglevel = "info"' \
    "${CFG_PATH}" > "${TMP_CFG}"
  install -m 0600 -o root -g root "${TMP_CFG}" "${CFG_PATH}"
  rm -f "${TMP_CFG}"

  : > "${ACCESS_LOG}"
  : > "${ERROR_LOG}"

  if ! systemctl restart xray; then
    install -m 0600 -o root -g root "${BACKUP_CFG}" "${CFG_PATH}" || true
    systemctl restart xray || true
    rm -f "${BACKUP_CFG}" "${CFG_PATH_FILE}"
    echo "Failed to restart xray with temporary access log config" >&2
    exit 1
  fi
fi

if [[ "${ACTION}" == "disable" ]]; then
  if [[ -f "${BACKUP_CFG}" && -f "${CFG_PATH_FILE}" ]]; then
    CFG_PATH="$(cat "${CFG_PATH_FILE}")"
    if [[ -f "${CFG_PATH}" ]]; then
      install -m 0600 -o root -g root "${BACKUP_CFG}" "${CFG_PATH}" || true
      systemctl restart xray || true
    fi
    rm -f "${BACKUP_CFG}" "${CFG_PATH_FILE}"
  fi
fi
BASH
chmod 0750 "${HELPER_FILE}"
chown root:root "${HELPER_FILE}"

echo "[7/10] Configuring sudoers for controlled helper access"
cat > "${SUDOERS_FILE}" <<'SUDO'
Defaults:googleegress !requiretty
googleegress ALL=(root) NOPASSWD: /usr/local/sbin/google-egress-xray-logctl enable, /usr/local/sbin/google-egress-xray-logctl disable
SUDO
chmod 0440 "${SUDOERS_FILE}"

echo "[8/10] Writing web application"
cat > "${APP_FILE}" <<'PYTHON'
#!/usr/bin/env python3
from __future__ import annotations

import ipaddress
import json
import logging
import re
import subprocess
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Optional
from urllib.parse import parse_qs, urlparse

PROXY = "socks5h://127.0.0.1:10808"
GOOGLE_MYADDR_DOH = "https://dns.google/resolve?name=o-o.myaddr.l.google.com&type=TXT"
GOOGLE_DNS_A_DOH = "https://dns.google/resolve?name=www.google.com&type=A"
GENERIC_IP_ENDPOINT = "https://api.ipify.org"
IPV6_ENDPOINT = "https://api64.ipify.org"
IP_API_TEMPLATE = "http://ip-api.com/json/{ip}?fields=status,message,country,isp,as,org,asname,query"
XRAY_ACCESS_LOG = "/var/log/google-egress-check/xray-access.log"
XRAY_HELPER = "/usr/local/sbin/google-egress-xray-logctl"

ANALYSIS_LOCK = threading.Lock()
CACHE_LOCK = threading.Lock()
CACHE_TTL_SECONDS = 30
STATUS_CACHE: dict[str, Any] = {"payload": None, "ts": 0.0}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
LOGGER = logging.getLogger("google-egress-check")

IP_RE = re.compile(r"\b(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9A-Fa-f:]{2,})\b")
OUTBOUND_PATTERNS = [
    r"\[[^\]]*->\s*([A-Za-z0-9._-]+)\]",
    r"outboundTag[=: ]\"?([A-Za-z0-9._-]+)\"?",
    r"\"outboundTag\"\s*:\s*\"([A-Za-z0-9._-]+)\"",
]

HTML_PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Google Egress Monitor</title>
  <style>
    :root {
      --bg-a: #081425;
      --bg-b: #12314f;
      --panel: #f4f7fb;
      --ink: #122338;
      --muted: #4f647a;
      --safe: #0f766e;
      --warn: #b45309;
      --danger: #b91c1c;
      --accent: #0ea5e9;
      --accent-2: #22c55e;
      --shadow: 0 20px 50px rgba(3, 18, 36, 0.22);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "IBM Plex Sans", "Source Sans 3", "Noto Sans", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at 15% 20%, rgba(34, 197, 94, 0.25), transparent 35%),
        radial-gradient(circle at 80% 0%, rgba(14, 165, 233, 0.35), transparent 40%),
        linear-gradient(150deg, var(--bg-a), var(--bg-b));
      min-height: 100vh;
    }
    .shell {
      max-width: 1100px;
      margin: 22px auto;
      padding: 24px;
      position: relative;
    }
    .hero {
      color: #e8f4ff;
      margin-bottom: 20px;
      animation: rise .45s ease;
    }
    .hero h1 {
      margin: 0;
      font-size: clamp(1.6rem, 2.8vw, 2.35rem);
      letter-spacing: .01em;
      font-weight: 700;
    }
    .hero p {
      margin: 8px 0 0;
      color: #b8d6ef;
      font-size: .98rem;
    }
    .panel {
      background: var(--panel);
      border-radius: 18px;
      box-shadow: var(--shadow);
      overflow: hidden;
      animation: rise .55s ease;
    }
    .topbar {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: center;
      justify-content: space-between;
      padding: 16px 20px;
      border-bottom: 1px solid #dce5ef;
      background:
        linear-gradient(100deg, rgba(14,165,233,.12), rgba(34,197,94,.09));
    }
    .status {
      display: inline-flex;
      align-items: center;
      gap: 9px;
      padding: 8px 13px;
      border-radius: 999px;
      font-weight: 650;
      font-size: .9rem;
      letter-spacing: .015em;
      border: 1px solid transparent;
    }
    .status.secure { color: #065f46; background: #d1fae5; border-color: #6ee7b7; }
    .status.warning { color: #9a3412; background: #ffedd5; border-color: #fdba74; }
    .status.error { color: #991b1b; background: #fee2e2; border-color: #fca5a5; }
    .actions { display: flex; gap: 10px; }
    button {
      border: 0;
      border-radius: 11px;
      padding: 9px 14px;
      font-weight: 650;
      font-family: inherit;
      cursor: pointer;
      transition: transform .18s ease, filter .18s ease;
    }
    button.primary {
      color: #fff;
      background: linear-gradient(135deg, #0284c7, #0ea5e9);
    }
    button.ghost {
      color: #0b3b62;
      background: #dbeafe;
    }
    button:hover { transform: translateY(-1px); filter: brightness(1.04); }
    .grid {
      padding: 20px;
      display: grid;
      grid-template-columns: repeat(12, 1fr);
      gap: 14px;
    }
    .card {
      background: #ffffff;
      border: 1px solid #e2e8f0;
      border-radius: 14px;
      padding: 14px;
      min-height: 112px;
    }
    .card h3 {
      margin: 0 0 8px;
      font-size: .87rem;
      color: var(--muted);
      font-weight: 650;
      text-transform: uppercase;
      letter-spacing: .045em;
    }
    .v {
      font-size: 1.18rem;
      font-weight: 700;
      line-height: 1.34;
      word-break: break-word;
    }
    .big { grid-column: span 6; }
    .small { grid-column: span 3; }
    .wide { grid-column: span 12; }
    .kicker {
      font-size: .8rem;
      color: var(--muted);
      margin-top: 7px;
    }
    .kv {
      display: grid;
      grid-template-columns: 190px 1fr;
      gap: 7px 12px;
      font-size: .95rem;
      align-items: baseline;
    }
    .kv .k { color: #4b6077; font-weight: 620; }
    .badge {
      display: inline-block;
      border-radius: 999px;
      padding: 4px 10px;
      font-size: .82rem;
      font-weight: 650;
      margin-right: 8px;
      margin-top: 6px;
    }
    .badge.ok { color: #065f46; background: #d1fae5; }
    .badge.no { color: #b45309; background: #ffedd5; }
    .mono { font-family: "JetBrains Mono", "Fira Code", "Consolas", monospace; }
    .foot {
      color: #5c7187;
      font-size: .83rem;
      padding: 0 20px 20px;
    }
    .warnline {
      margin-top: 8px;
      padding: 9px 12px;
      border-radius: 10px;
      font-weight: 600;
      color: #9a3412;
      background: #fff7ed;
      border: 1px solid #fed7aa;
      display: none;
    }
    @media (max-width: 900px) {
      .big, .small { grid-column: span 12; }
      .kv { grid-template-columns: 1fr; gap: 3px; }
    }
    @keyframes rise {
      from { opacity: 0; transform: translateY(8px); }
      to { opacity: 1; transform: translateY(0); }
    }
  </style>
</head>
<body>
  <div class="shell">
    <section class="hero">
      <h1>Google Egress Verification Dashboard</h1>
      <p>Authoritative check via Google DoH: o-o.myaddr.l.google.com (through Xray SOCKS proxy)</p>
    </section>

    <section class="panel">
      <div class="topbar">
        <div id="statusChip" class="status warning">Status: loading</div>
        <div class="actions">
          <button class="ghost" id="refreshBtn">Refresh</button>
          <button class="primary" id="copyBtn">Copy JSON</button>
        </div>
      </div>

      <div class="grid">
        <article class="card big">
          <h3>Google-Seen Egress IP</h3>
          <div class="v mono" id="googleIp">-</div>
          <div class="kicker">Most critical result from Google's own infrastructure</div>
        </article>
        <article class="card big">
          <h3>Generic Public Egress IP</h3>
          <div class="v mono" id="genericIp">-</div>
          <div class="kicker">api.ipify.org through same Xray proxy path</div>
        </article>

        <article class="card small">
          <h3>Google Outbound Tag</h3>
          <div class="v mono" id="outboundTag">-</div>
        </article>
        <article class="card small">
          <h3>Routing Split</h3>
          <div class="v" id="routingSplit">-</div>
        </article>
        <article class="card small">
          <h3>DNS Leak</h3>
          <div class="v" id="dnsLeak">-</div>
        </article>
        <article class="card small">
          <h3>IPv6 Leak</h3>
          <div class="v" id="ipv6Leak">-</div>
        </article>

        <article class="card wide">
          <h3>Geo / ASN Intelligence</h3>
          <div class="kv">
            <div class="k">Country</div><div id="country">-</div>
            <div class="k">ISP</div><div id="isp">-</div>
            <div class="k">ASN</div><div id="asn">-</div>
            <div class="k">Checked At (UTC)</div><div id="checkedAt">-</div>
          </div>
          <div id="splitWarning" class="warnline">Routing split detected</div>
          <span id="badgeSecure" class="badge ok">Secure path: pending</span>
          <span id="badgeProxy" class="badge no">Proxy verification: pending</span>
        </article>
      </div>

      <div class="foot">
        API endpoint: <span class="mono">/api/status</span> | Health: <span class="mono">/healthz</span>
      </div>
    </section>
  </div>

  <script>
    const state = { last: null };
    const byId = (id) => document.getElementById(id);

    function showStatus(status, txt) {
      const chip = byId("statusChip");
      chip.className = "status " + status;
      chip.textContent = txt;
    }

    function yn(v) {
      return v ? "Yes" : "No";
    }

    function apply(data) {
      state.last = data;
      byId("googleIp").textContent = data.google_seen_ip || "-";
      byId("genericIp").textContent = data.generic_ip || "-";
      byId("outboundTag").textContent = data.google_outbound_tag || "-";
      byId("routingSplit").textContent = yn(!!data.routing_split);
      byId("dnsLeak").textContent = yn(!!data.dns_leak);
      byId("ipv6Leak").textContent = yn(!!data.ipv6_leak);
      byId("country").textContent = data.country || "-";
      byId("isp").textContent = data.isp || "-";
      byId("asn").textContent = data.asn || "-";
      byId("checkedAt").textContent = data.checked_at || "-";

      const secure = !data.dns_leak && !data.ipv6_leak;
      byId("badgeSecure").textContent = secure ? "Secure path: yes" : "Secure path: warning";
      byId("badgeSecure").className = secure ? "badge ok" : "badge no";
      const proxyOk = Boolean(data.google_seen_ip && data.google_outbound_tag);
      byId("badgeProxy").textContent = proxyOk ? "Proxy verification: confirmed" : "Proxy verification: partial";
      byId("badgeProxy").className = proxyOk ? "badge ok" : "badge no";

      const warn = byId("splitWarning");
      if (data.routing_split) {
        warn.style.display = "block";
        warn.textContent = data.warning || "Routing split detected";
      } else {
        warn.style.display = "none";
      }

      if (data.status === "secure") {
        showStatus("secure", "Status: secure");
      } else if (data.status === "warning") {
        showStatus("warning", "Status: warning");
      } else {
        showStatus("error", "Status: error");
      }
    }

    async function load(refresh=false) {
      showStatus("warning", "Status: checking");
      try {
        const url = refresh ? "/api/status?refresh=1" : "/api/status";
        const res = await fetch(url, { cache: "no-store" });
        if (!res.ok) throw new Error("HTTP " + res.status);
        const data = await res.json();
        apply(data);
      } catch (err) {
        showStatus("error", "Status: error");
      }
    }

    byId("refreshBtn").addEventListener("click", () => load(true));
    byId("copyBtn").addEventListener("click", async () => {
      if (!state.last) return;
      const txt = JSON.stringify(state.last, null, 2);
      try { await navigator.clipboard.writeText(txt); } catch (e) {}
    });

    load(true);
    setInterval(() => load(false), 30000);
  </script>
</body>
</html>"""


def run_cmd(args: list[str], timeout: int = 20) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=timeout,
        shell=False,
    )


def sanitize_str(value: Any, max_len: int = 256) -> str:
    if value is None:
        return ""
    text = str(value)
    text = "".join(ch for ch in text if ch.isprintable())
    return text[:max_len]


def is_valid_ip(value: str) -> bool:
    try:
        ipaddress.ip_address(value.strip())
        return True
    except ValueError:
        return False


def extract_ips(text: str) -> list[str]:
    ips: list[str] = []
    for token in IP_RE.findall(text):
        if is_valid_ip(token) and token not in ips:
            ips.append(token)
    return ips


def majority(values: list[str]) -> Optional[str]:
    if not values:
        return None
    counts: dict[str, int] = {}
    best = values[0]
    best_count = 0
    for v in values:
        counts[v] = counts.get(v, 0) + 1
        if counts[v] > best_count:
            best = v
            best_count = counts[v]
    return best


def curl_text(url: str, use_proxy: bool = False, timeout: int = 20, ipv6: bool = False, head: bool = False) -> tuple[bool, str]:
    args = [
        "curl",
        "-sS",
        "-L",
        "--max-time",
        str(timeout),
        "--connect-timeout",
        "8",
    ]
    if use_proxy:
        args += ["--proxy", PROXY]
    if ipv6:
        args += ["-6"]
    if head:
        args.append("-I")
    args.append(url)
    proc = run_cmd(args, timeout=timeout + 5)
    if proc.returncode != 0:
        return False, sanitize_str(proc.stderr or proc.stdout, max_len=512)
    return True, proc.stdout.strip()


def parse_google_myaddr_ip(payload: str) -> Optional[str]:
    try:
        data = json.loads(payload)
    except json.JSONDecodeError:
        for ip in extract_ips(payload):
            return ip
        return None

    answers = data.get("Answer")
    if not isinstance(answers, list):
        return None
    for item in answers:
        if not isinstance(item, dict):
            continue
        txt = str(item.get("data", "")).replace('"', "").strip()
        if is_valid_ip(txt):
            return txt
        for ip in extract_ips(txt):
            return ip
    return None


def get_google_seen_ip() -> Optional[str]:
    observed: list[str] = []
    for _ in range(2):
        ok, body = curl_text(GOOGLE_MYADDR_DOH, use_proxy=True, timeout=20)
        if not ok:
            continue
        ip = parse_google_myaddr_ip(body)
        if ip:
            observed.append(ip)
    return majority(observed)


def get_generic_ip() -> Optional[str]:
    observed: list[str] = []
    for _ in range(2):
        ok, body = curl_text(GENERIC_IP_ENDPOINT, use_proxy=True, timeout=15)
        if not ok:
            continue
        ips = extract_ips(body)
        if ips:
            observed.append(ips[0])
    return majority(observed)


def geo_lookup(ip: Optional[str]) -> dict[str, str]:
    if not ip:
        return {"country": "", "isp": "", "asn": ""}
    url = IP_API_TEMPLATE.format(ip=ip)
    ok, body = curl_text(url, use_proxy=False, timeout=10)
    if not ok:
        return {"country": "", "isp": "", "asn": ""}
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        return {"country": "", "isp": "", "asn": ""}
    if not isinstance(data, dict):
        return {"country": "", "isp": "", "asn": ""}
    if data.get("status") != "success":
        return {"country": "", "isp": "", "asn": ""}
    return {
        "country": sanitize_str(data.get("country", "")),
        "isp": sanitize_str(data.get("isp", "")),
        "asn": sanitize_str(data.get("as", "")),
    }


def parse_google_dns_a(payload: str) -> set[str]:
    try:
        data = json.loads(payload)
    except json.JSONDecodeError:
        return set(extract_ips(payload))
    answers = data.get("Answer")
    if not isinstance(answers, list):
        return set()
    out: set[str] = set()
    for item in answers:
        if not isinstance(item, dict):
            continue
        d = str(item.get("data", "")).replace('"', "").strip()
        if is_valid_ip(d):
            out.add(d)
    return out


def detect_dns_leak() -> bool:
    direct_proc = run_cmd(["dig", "+short", "www.google.com"], timeout=10)
    direct_ips = set(extract_ips(direct_proc.stdout)) if direct_proc.returncode == 0 else set()
    ok, payload = curl_text(GOOGLE_DNS_A_DOH, use_proxy=True, timeout=15)
    proxy_ips = parse_google_dns_a(payload) if ok else set()
    return bool(direct_ips and proxy_ips and direct_ips != proxy_ips)


def has_ipv6_default_route() -> bool:
    proc = run_cmd(["ip", "-6", "route", "show", "default"], timeout=8)
    return proc.returncode == 0 and bool(proc.stdout.strip())


def get_ipv6_ip(use_proxy: bool) -> Optional[str]:
    ok, body = curl_text(IPV6_ENDPOINT, use_proxy=use_proxy, timeout=12, ipv6=True)
    if not ok:
        return None
    ips = extract_ips(body)
    return ips[0] if ips else None


def detect_ipv6_leak() -> bool:
    if not has_ipv6_default_route():
        return False
    direct_ipv6 = get_ipv6_ip(use_proxy=False)
    proxy_ipv6 = get_ipv6_ip(use_proxy=True)
    return bool(direct_ipv6 and not proxy_ipv6)


def parse_outbound_tag(log_text: str) -> str:
    selected = ""
    for line in log_text.splitlines():
        line_l = line.lower()
        if "google" not in line_l and "dns.google" not in line_l:
            continue
        for pattern in OUTBOUND_PATTERNS:
            m = re.search(pattern, line)
            if m:
                selected = m.group(1)
    return sanitize_str(selected, max_len=64)


def read_log_since(path: str, marker: int) -> str:
    try:
        with open(path, "rb") as f:
            f.seek(marker, 0)
            data = f.read()
        return data.decode("utf-8", errors="replace")
    except OSError:
        return ""


def get_google_outbound_tag() -> str:
    enabled = False
    try:
        enable = run_cmd(["sudo", "-n", XRAY_HELPER, "enable"], timeout=45)
        if enable.returncode != 0:
            LOGGER.warning("Unable to enable temporary Xray access logging")
            return ""
        enabled = True

        marker = 0
        try:
            with open(XRAY_ACCESS_LOG, "rb") as f:
                f.seek(0, 2)
                marker = f.tell()
        except OSError:
            marker = 0

        curl_text("https://www.google.com", use_proxy=True, timeout=20)
        time.sleep(0.6)
        log_chunk = read_log_since(XRAY_ACCESS_LOG, marker)
        return parse_outbound_tag(log_chunk)
    finally:
        if enabled:
            run_cmd(["sudo", "-n", XRAY_HELPER, "disable"], timeout=45)


def compute_status() -> dict[str, Any]:
    google_ip = get_google_seen_ip()
    generic_ip = get_generic_ip()
    outbound_tag = get_google_outbound_tag()

    routing_split = bool(google_ip and generic_ip and google_ip != generic_ip)
    dns_leak = detect_dns_leak()
    ipv6_leak = detect_ipv6_leak()

    intel = geo_lookup(google_ip or generic_ip)

    payload = {
        "google_seen_ip": sanitize_str(google_ip or ""),
        "google_outbound_tag": sanitize_str(outbound_tag or "", max_len=64),
        "generic_ip": sanitize_str(generic_ip or ""),
        "routing_split": routing_split,
        "country": sanitize_str(intel.get("country", "")),
        "isp": sanitize_str(intel.get("isp", "")),
        "asn": sanitize_str(intel.get("asn", "")),
        "dns_leak": dns_leak,
        "ipv6_leak": ipv6_leak,
        "status": "secure" if not dns_leak and not ipv6_leak else "warning",
        "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if routing_split:
        payload["warning"] = "Routing split detected"
    return payload


def get_status_cached(force_refresh: bool = False) -> dict[str, Any]:
    now = time.time()
    with CACHE_LOCK:
        cached = STATUS_CACHE.get("payload")
        ts = float(STATUS_CACHE.get("ts", 0.0))
        if not force_refresh and isinstance(cached, dict) and (now - ts) < CACHE_TTL_SECONDS:
            return cached

    with ANALYSIS_LOCK:
        payload = compute_status()

    with CACHE_LOCK:
        STATUS_CACHE["payload"] = payload
        STATUS_CACHE["ts"] = time.time()
    return payload


class Handler(BaseHTTPRequestHandler):
    server_version = "GoogleEgressCheck/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        LOGGER.info("%s - %s", self.address_string(), sanitize_str(fmt % args, max_len=300))

    def _send_json(self, code: int, obj: dict[str, Any]) -> None:
        body = json.dumps(obj, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, code: int, html_text: str) -> None:
        body = html_text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/healthz":
            self._send_json(HTTPStatus.OK, {"status": "ok"})
            return

        if path == "/" and query.get("format", [""])[0] == "json":
            path = "/api/status"

        if path in ("/", "/index.html"):
            self._send_html(HTTPStatus.OK, HTML_PAGE)
            return

        if path in ("/api/status", "/json"):
            force_refresh = query.get("refresh", [""])[0] in {"1", "true", "yes"}
            try:
                result = get_status_cached(force_refresh=force_refresh)
                self._send_json(HTTPStatus.OK, result)
            except Exception:
                LOGGER.exception("Unhandled error while processing request")
                self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"status": "error"})
            return

        if path == "/favicon.ico":
            self.send_response(HTTPStatus.NO_CONTENT)
            self.end_headers()
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_POST(self) -> None:
        if urlparse(self.path).path == "/api/status":
            try:
                result = get_status_cached(force_refresh=True)
                self._send_json(HTTPStatus.OK, result)
            except Exception:
                LOGGER.exception("Unhandled error while processing request")
                self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"status": "error"})
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})


def warmup() -> None:
    try:
        get_status_cached(force_refresh=True)
    except Exception:
        LOGGER.exception("Initial warmup failed")


def main() -> None:
    warmup()
    server = ThreadingHTTPServer(("0.0.0.0", 80), Handler)
    server.daemon_threads = True
    LOGGER.info("Listening on port 80")
    server.serve_forever()


if __name__ == "__main__":
    main()
PYTHON
chmod 0640 "${APP_FILE}"
chown root:"${APP_GROUP}" "${APP_FILE}"

echo "[9/10] Creating systemd service"
cat > "${SERVICE_FILE}" <<'SERVICE'
[Unit]
Description=Google Egress Check Web Service
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=simple
User=googleegress
Group=googleegress
WorkingDirectory=/opt/google-egress-check
ExecStart=/usr/bin/python3 /opt/google-egress-check/app.py
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/google-egress-check /var/lib/google-egress-check
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
SERVICE

echo "[10/10] Enabling and starting web service"
systemctl daemon-reload
systemctl enable --now google-egress-check.service
systemctl restart google-egress-check.service

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
fi
if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="SERVER_IP"
fi

echo "Installation complete. Visit http://${SERVER_IP}/"
