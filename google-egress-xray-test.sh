#!/usr/bin/env bash
set -euo pipefail
umask 027

CANDIDATE_PATH="${1:-}"

APP_GROUP="googleegress"
APP_STATE_DIR="/var/lib/google-egress-check"
UPLOAD_DIR="${APP_STATE_DIR}/uploads"
LOG_DIR="/var/log/google-egress-check"
LOCK_FILE="${APP_STATE_DIR}/xray-test.lock"
ACCESS_LOG="${LOG_DIR}/xray-access.log"
LOGCTL="/usr/local/sbin/google-egress-xray-logctl"

PROXY="socks5h://127.0.0.1:10808"
GOOGLE_DOH_TXT="https://dns.google/resolve?name=o-o.myaddr.l.google.com&type=TXT"
GOOGLE_DOH_A="https://dns.google/resolve?name=www.google.com&type=A"

CFG_PATH=""
BACKUP_CFG=""
TMP_CFG=""
LOG_ENABLED=0
ERR_HANDLING=0
XRAY_USER=""
XRAY_GROUP=""

mask_text() {
  sed -E \
    -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/***UUID***/g' \
    -e 's/("?(id|uuid|password|pass|privateKey|private_key|shortId|short_id|token|secret)"?[[:space:]]*:[[:space:]]*")([^"]+)"/\1***MASKED***"/Ig' \
    -e 's/[A-Za-z0-9+=_-]{28,}/***TOKEN***/g'
}

journal_tail() {
  journalctl -u xray -n 80 --no-pager 2>/dev/null | mask_text || true
}

json_invalid() {
  local err="${1:-unknown error}"
  local tail
  tail="$(journal_tail)"
  err="$(printf '%s' "${err}" | mask_text)"
  jq -n \
    --arg error "${err}" \
    --arg tail "${tail}" \
    '{"status":"invalid_config","error":$error,"xray_journal_tail":$tail}'
  exit 2
}

on_unexpected_error() {
  local line="${BASH_LINENO[0]:-0}"
  local cmd="${BASH_COMMAND:-unknown}"
  if [[ "${ERR_HANDLING}" == "1" ]]; then
    exit 2
  fi
  ERR_HANDLING=1
  json_invalid "Unexpected failure at line ${line}: ${cmd}"
}
trap on_unexpected_error ERR

ensure_runtime_dirs() {
  if [[ ! -d "${APP_STATE_DIR}" || ! -d "${UPLOAD_DIR}" || ! -d "${LOG_DIR}" ]]; then
    json_invalid "Runtime directories missing. Re-run installer."
  fi
  if [[ ! -w "${APP_STATE_DIR}" || ! -w "${LOG_DIR}" ]]; then
    json_invalid "Permission denied creating runtime directories"
  fi
  chmod 0750 "${APP_STATE_DIR}" "${UPLOAD_DIR}" "${LOG_DIR}" || true
}

detect_xray_runtime_identity() {
  XRAY_USER="$(systemctl show -p User --value xray 2>/dev/null | tr -d '\r' || true)"
  XRAY_GROUP="$(systemctl show -p Group --value xray 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "${XRAY_USER}" ]]; then
    XRAY_USER="root"
  fi
  if [[ -z "${XRAY_GROUP}" ]]; then
    if id -u "${XRAY_USER}" >/dev/null 2>&1; then
      XRAY_GROUP="$(id -gn "${XRAY_USER}" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "${XRAY_GROUP}" ]]; then
    XRAY_GROUP="root"
  fi
  if ! getent group "${XRAY_GROUP}" >/dev/null 2>&1; then
    XRAY_GROUP="root"
  fi
}

apply_cfg_permissions() {
  local target="$1"
  local cfg_dir
  cfg_dir="$(dirname "${target}")"
  if [[ "${XRAY_USER}" == "root" ]]; then
    chown root:root "${cfg_dir}" 2>/dev/null || true
    chmod 0750 "${cfg_dir}" 2>/dev/null || true
    chown root:root "${target}"
    chmod 0600 "${target}"
    return 0
  fi
  chown root:"${XRAY_GROUP}" "${cfg_dir}" 2>/dev/null || true
  chmod 0750 "${cfg_dir}" 2>/dev/null || true
  chown root:"${XRAY_GROUP}" "${target}" || chown root:root "${target}"
  chmod 0640 "${target}"
}

cleanup() {
  set +e
  if [[ "${LOG_ENABLED}" == "1" ]]; then
    "${LOGCTL}" disable >/dev/null 2>&1 || true
    LOG_ENABLED=0
  fi

  if [[ -n "${CFG_PATH}" && -f "${BACKUP_CFG}" ]]; then
    cp -f "${BACKUP_CFG}" "${CFG_PATH}" >/dev/null 2>&1 || true
    apply_cfg_permissions "${CFG_PATH}" >/dev/null 2>&1 || true
    systemctl restart xray >/dev/null 2>&1 || true
  fi

  [[ -n "${BACKUP_CFG}" && -f "${BACKUP_CFG}" ]] && rm -f "${BACKUP_CFG}"
  [[ -n "${TMP_CFG}" && -f "${TMP_CFG}" ]] && rm -f "${TMP_CFG}"
}
trap cleanup EXIT

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

extract_google_ip() {
  python3 -c 'import ipaddress,json,re,sys
payload=sys.stdin.read()
def is_ip(v):
  try:
    ipaddress.ip_address(v.strip()); return True
  except Exception:
    return False
def first_ip(txt):
  for t in re.findall(r"\b(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9A-Fa-f:]{2,})\b", txt):
    if is_ip(t):
      return t
  return ""
try:
  data=json.loads(payload)
except Exception:
  val=first_ip(payload)
  print(val)
  raise SystemExit(0)
ans=data.get("Answer", [])
if isinstance(ans, list):
  for r in ans:
    if isinstance(r, dict):
      d=str(r.get("data","")).replace("\"","").strip()
      if is_ip(d):
        print(d); raise SystemExit(0)
      val=first_ip(d)
      if val:
        print(val); raise SystemExit(0)
print("")'
}

extract_any_ip() {
  python3 -c 'import ipaddress,re,sys
txt=sys.stdin.read()
for t in re.findall(r"\b(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9A-Fa-f:]{2,})\b", txt):
  try:
    ipaddress.ip_address(t.strip()); print(t.strip()); raise SystemExit(0)
  except Exception:
    pass
print("")'
}

majority_ip() {
  python3 - "$@" <<'PY'
import collections, sys
vals=[x for x in sys.argv[1:] if x]
if not vals:
    print("")
else:
    print(collections.Counter(vals).most_common(1)[0][0])
PY
}

canonical_space_list() {
  sort -u | tr '\n' ' ' | xargs || true
}

if [[ "${EUID}" -ne 0 ]]; then
  json_invalid "Helper must run as root via sudo"
fi

ensure_runtime_dirs
detect_xray_runtime_identity

if [[ -z "${CANDIDATE_PATH}" ]]; then
  json_invalid "Missing uploaded config path"
fi

if [[ ! -f "${CANDIDATE_PATH}" ]]; then
  json_invalid "Uploaded config file not found"
fi

CANDIDATE_REAL="$(readlink -f "${CANDIDATE_PATH}" 2>/dev/null || true)"
if [[ -z "${CANDIDATE_REAL}" || "${CANDIDATE_REAL}" != "${UPLOAD_DIR}"/* ]]; then
  json_invalid "Invalid upload path"
fi

size="$(stat -c%s "${CANDIDATE_REAL}" 2>/dev/null || echo 0)"
if (( size <= 0 || size > 1000000 )); then
  json_invalid "Uploaded file exceeds 1MB limit"
fi

if ! jq empty "${CANDIDATE_REAL}" >/dev/null 2>&1; then
  json_invalid "Invalid JSON in uploaded config"
fi

if [[ "$(jq -r 'type' "${CANDIDATE_REAL}" 2>/dev/null)" != "object" ]]; then
  json_invalid "Xray config root must be JSON object"
fi

if ! exec 9>"${LOCK_FILE}"; then
  json_invalid "Permission denied opening lock file"
fi
if ! flock -w 180 9; then
  json_invalid "Another config test is in progress"
fi

CFG_PATH="$(detect_xray_config_path)" || json_invalid "Xray config path not found"
BACKUP_CFG="$(mktemp "${APP_STATE_DIR}/xray-original.XXXXXX.json")"
TMP_CFG="$(mktemp "${APP_STATE_DIR}/xray-test.XXXXXX.json")"

cp -f "${CFG_PATH}" "${BACKUP_CFG}"
chmod 0600 "${BACKUP_CFG}"

# Ensure test config always exposes a local SOCKS inbound and at least one outbound.
jq \
  '(.inbounds //= []) |
   (.outbounds //= []) |
   (.log = (.log // {})) |
   (.log.loglevel = (.log.loglevel // "warning")) |
   (del(.log.access, .log.error)) |
   (if any(.inbounds[]?; (.protocol == "socks") and (((.port | tonumber?) // -1) == 10808)) then . else .inbounds += [{"tag":"google-egress-socks","listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"udp":true}}] end) |
   (if (.outbounds | length) == 0 then .outbounds = [{"tag":"direct","protocol":"freedom","settings":{}}] else . end)' \
  "${CANDIDATE_REAL}" > "${TMP_CFG}" || json_invalid "Failed to prepare uploaded config"

cp -f "${TMP_CFG}" "${CFG_PATH}" || json_invalid "Failed to apply uploaded config"
apply_cfg_permissions "${CFG_PATH}" || json_invalid "Failed to set config permissions"

if ! systemctl restart xray >/dev/null 2>&1; then
  json_invalid "Xray failed to restart with uploaded config"
fi

if ! systemctl is-active --quiet xray; then
  json_invalid "Xray service is not active"
fi

http_code="$(curl -sS -L -o /dev/null -w '%{http_code}' --max-time 20 --connect-timeout 8 --proxy "${PROXY}" https://www.google.com || true)"
if [[ ! "${http_code}" =~ ^[0-9]{3}$ ]]; then
  json_invalid "Proxied request to Google failed"
fi

declare -a google_candidates
google_candidates=()
for _ in 1 2; do
  body="$(curl -sS -L --max-time 20 --connect-timeout 8 --proxy "${PROXY}" "${GOOGLE_DOH_TXT}" || true)"
  ip="$(printf '%s' "${body}" | extract_google_ip | tr -d '\r' | head -n1)"
  if [[ -n "${ip}" ]]; then
    google_candidates+=("${ip}")
  fi
done

GOOGLE_IP="$(majority_ip "${google_candidates[@]}")"
if [[ -z "${GOOGLE_IP}" ]]; then
  json_invalid "Google DoH did not return a valid google_seen_ip"
fi

declare -a generic_candidates
generic_candidates=()
for _ in 1 2; do
  gbody="$(curl -sS -L --max-time 15 --connect-timeout 8 --proxy "${PROXY}" https://api.ipify.org || true)"
  gip="$(printf '%s' "${gbody}" | extract_any_ip | tr -d '\r' | head -n1)"
  if [[ -n "${gip}" ]]; then
    generic_candidates+=("${gip}")
  fi
done
GENERIC_IP="$(majority_ip "${generic_candidates[@]}")"

if ! "${LOGCTL}" enable >/dev/null 2>&1; then
  json_invalid "Failed to enable temporary Xray access log"
fi
LOG_ENABLED=1

marker="$(stat -c%s "${ACCESS_LOG}" 2>/dev/null || echo 0)"
curl -sS -L --max-time 20 --connect-timeout 8 --proxy "${PROXY}" -o /dev/null https://www.google.com || true
sleep 1

chunk=""
if [[ -f "${ACCESS_LOG}" ]]; then
  if (( marker > 0 )); then
    chunk="$(tail -c +"$((marker + 1))" "${ACCESS_LOG}" 2>/dev/null || true)"
  else
    chunk="$(cat "${ACCESS_LOG}" 2>/dev/null || true)"
  fi
fi

GOOGLE_OUTBOUND_TAG="$(
  printf '%s\n' "${chunk}" | python3 -c 'import re,sys
tag=""
patterns=[
 re.compile(r"\[[^\]]*->\s*([A-Za-z0-9._-]+)\]"),
 re.compile(r"outboundTag[=: ]\"?([A-Za-z0-9._-]+)\"?"),
 re.compile(r"\"outboundTag\"\s*:\s*\"([A-Za-z0-9._-]+)\""),
]
for line in sys.stdin:
  lower=line.lower()
  if "google" not in lower and "dns.google" not in lower:
    continue
  for p in patterns:
    m=p.search(line)
    if m:
      tag=m.group(1)
print(tag)'
)"

"${LOGCTL}" disable >/dev/null 2>&1 || true
LOG_ENABLED=0

if [[ -z "${GOOGLE_OUTBOUND_TAG}" ]]; then
  GOOGLE_OUTBOUND_TAG="unknown"
fi

direct_dns="$(dig +short A www.google.com 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | canonical_space_list || true)"
proxy_dns="$(curl -sS -L --max-time 15 --connect-timeout 8 --proxy "${PROXY}" "${GOOGLE_DOH_A}" 2>/dev/null | jq -r '.Answer[]?.data // empty' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | canonical_space_list || true)"

DNS_LEAK=false
if [[ -n "${direct_dns}" && -n "${proxy_dns}" && "${direct_dns}" != "${proxy_dns}" ]]; then
  DNS_LEAK=true
fi

IPV6_LEAK=false
if ip -6 route show default 2>/dev/null | grep -q .; then
  direct_v6="$(curl -sS -6 --max-time 12 --connect-timeout 6 https://api64.ipify.org 2>/dev/null | extract_any_ip | tr -d '\r' | head -n1)"
  proxy_v6="$(curl -sS -6 --max-time 12 --connect-timeout 6 --proxy "${PROXY}" https://api64.ipify.org 2>/dev/null | extract_any_ip | tr -d '\r' | head -n1)"
  if [[ -n "${direct_v6}" && -z "${proxy_v6}" ]]; then
    IPV6_LEAK=true
  fi
fi

INTEL_IP="${GOOGLE_IP}"
if [[ -z "${INTEL_IP}" ]]; then
  INTEL_IP="${GENERIC_IP}"
fi

country=""
isp=""
asn=""
if [[ -n "${INTEL_IP}" ]]; then
  intel="$(curl -sS -L --max-time 12 --connect-timeout 6 "http://ip-api.com/json/${INTEL_IP}?fields=status,country,isp,as" || true)"
  country="$(printf '%s' "${intel}" | jq -r 'if .status=="success" then .country // "" else "" end' 2>/dev/null || true)"
  isp="$(printf '%s' "${intel}" | jq -r 'if .status=="success" then .isp // "" else "" end' 2>/dev/null || true)"
  asn="$(printf '%s' "${intel}" | jq -r 'if .status=="success" then .as // "" else "" end' 2>/dev/null || true)"
fi

ROUTING_SPLIT=false
if [[ -n "${GOOGLE_IP}" && -n "${GENERIC_IP}" && "${GOOGLE_IP}" != "${GENERIC_IP}" ]]; then
  ROUTING_SPLIT=true
fi

CHECKED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

jq -n \
  --arg status "success" \
  --arg google_seen_ip "${GOOGLE_IP}" \
  --arg google_outbound_tag "${GOOGLE_OUTBOUND_TAG}" \
  --arg generic_ip "${GENERIC_IP}" \
  --arg country "$(printf '%s' "${country}" | mask_text)" \
  --arg isp "$(printf '%s' "${isp}" | mask_text)" \
  --arg asn "$(printf '%s' "${asn}" | mask_text)" \
  --arg checked_at "${CHECKED_AT}" \
  --argjson routing_split "${ROUTING_SPLIT}" \
  --argjson dns_leak "${DNS_LEAK}" \
  --argjson ipv6_leak "${IPV6_LEAK}" \
  '{
    status: $status,
    google_seen_ip: $google_seen_ip,
    google_outbound_tag: $google_outbound_tag,
    generic_ip: $generic_ip,
    routing_split: $routing_split,
    country: $country,
    isp: $isp,
    asn: $asn,
    dns_leak: $dns_leak,
    ipv6_leak: $ipv6_leak,
    checked_at: $checked_at
  }'
