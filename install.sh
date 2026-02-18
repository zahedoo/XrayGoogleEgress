#!/usr/bin/env bash
set -euo pipefail
umask 027

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash install.sh"
  exit 1
fi

APP_NAME="google-egress-check"
APP_USER="googleegress"
APP_GROUP="googleegress"
APP_DIR="/opt/${APP_NAME}"
STATE_DIR="/var/lib/${APP_NAME}"
UPLOAD_DIR="${STATE_DIR}/uploads"
LOG_DIR="/var/log/${APP_NAME}"
APP_FILE="${APP_DIR}/app.py"
TEST_HELPER_DST="/usr/local/sbin/google-egress-xray-test"
LOGCTL_HELPER_DST="/usr/local/sbin/google-egress-xray-logctl"
SERVICE_DST="/etc/systemd/system/google-egress-check.service"
SUDOERS_FILE="/etc/sudoers.d/google-egress-check"
RAW_BASE_URL="https://raw.githubusercontent.com/zahedoo/XrayGoogleEgress/main"
SKIP_APT="${SKIP_APT:-0}"

pre_clean_previous_state() {
  echo "[0/11] Cleaning previous ${APP_NAME} state"
  systemctl stop google-egress-check.service >/dev/null 2>&1 || true
  pkill -f "/opt/${APP_NAME}/app.py" >/dev/null 2>&1 || true
  pkill -f "${TEST_HELPER_DST}" >/dev/null 2>&1 || true
  pkill -f "${LOGCTL_HELPER_DST}" >/dev/null 2>&1 || true

  rm -f "${STATE_DIR}/xray-test.lock" \
        "${STATE_DIR}/xray-logctl.lock" \
        "${STATE_DIR}/xray-config.logctl.backup.json" \
        "${STATE_DIR}/xray-config.logctl.path"

  if [[ -d "${UPLOAD_DIR}" ]]; then
    find "${UPLOAD_DIR}" -maxdepth 1 -type f -name 'upload_*.json' -delete || true
  fi

  if [[ -d "${LOG_DIR}" ]]; then
    : > "${LOG_DIR}/xray-access.log" 2>/dev/null || true
    : > "${LOG_DIR}/xray-error.log" 2>/dev/null || true
  fi
}

deps_ready() {
  command -v python3 >/dev/null 2>&1 \
    && command -v curl >/dev/null 2>&1 \
    && command -v jq >/dev/null 2>&1 \
    && command -v dig >/dev/null 2>&1 \
    && command -v sudo >/dev/null 2>&1
}

wait_for_pkg_manager() {
  local timeout=900
  local waited=0
  while pgrep -x unattended-upgr >/dev/null 2>&1 \
      || pgrep -x apt >/dev/null 2>&1 \
      || pgrep -x apt-get >/dev/null 2>&1 \
      || pgrep -x dpkg >/dev/null 2>&1; do
    if (( waited >= timeout )); then
      echo "Timed out waiting for package manager locks to clear"
      return 1
    fi
    echo "Waiting for package manager lock... ${waited}/${timeout}s"
    sleep 5
    waited=$((waited + 5))
  done
  return 0
}

get_xray_runtime_user() {
  local user
  user="$(systemctl show -p User --value xray 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "${user}" ]]; then
    user="root"
  fi
  echo "${user}"
}

get_xray_runtime_group() {
  local group
  group="$(systemctl show -p Group --value xray 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "${group}" ]]; then
    local user
    user="$(get_xray_runtime_user)"
    if id -u "${user}" >/dev/null 2>&1; then
      group="$(id -gn "${user}" 2>/dev/null || true)"
    fi
  fi
  if [[ -z "${group}" ]]; then
    group="root"
  fi
  echo "${group}"
}

apply_xray_config_perms() {
  local cfg_path="$1"
  local user group
  user="$(get_xray_runtime_user)"
  group="$(get_xray_runtime_group)"
  local cfg_dir
  cfg_dir="$(dirname "${cfg_path}")"

  if [[ "${user}" == "root" ]]; then
    chown root:root "${cfg_dir}" 2>/dev/null || true
    chmod 0750 "${cfg_dir}" 2>/dev/null || true
    chown root:root "${cfg_path}"
    chmod 0600 "${cfg_path}"
    return 0
  fi

  if ! getent group "${group}" >/dev/null 2>&1; then
    group="root"
  fi
  chown root:"${group}" "${cfg_dir}" 2>/dev/null || true
  chmod 0750 "${cfg_dir}" 2>/dev/null || true
  chown root:"${group}" "${cfg_path}" || chown root:root "${cfg_path}"
  chmod 0640 "${cfg_path}"
}

ensure_xray_runtime_identity() {
  if ! getent group xray >/dev/null 2>&1; then
    groupadd --system xray
  fi
  if ! id -u xray >/dev/null 2>&1; then
    useradd --system --gid xray --home-dir /nonexistent --shell /usr/sbin/nologin xray
  fi

  mkdir -p /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/10-runtime-user.conf <<'EOF'
[Service]
User=xray
Group=xray
EOF
}

normalize_xray_unit_user() {
  local unit_file
  unit_file="$(systemctl show -p FragmentPath --value xray 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "${unit_file}" || ! -f "${unit_file}" ]]; then
    return 0
  fi

  if grep -Eq '^User=nobody$' "${unit_file}" || grep -Eq '^Group=nogroup$' "${unit_file}"; then
    cp -f "${unit_file}" "${unit_file}.bak.$(date +%s)" || true
    sed -i -E \
      -e 's/^User=nobody$/User=xray/' \
      -e 's/^Group=nogroup$/Group=xray/' \
      "${unit_file}" || true
  fi
}

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
    echo "[3/11] Xray already installed"
    return 0
  fi

  echo "[3/11] Installing Xray"
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

recover_xray_if_inactive() {
  if systemctl is-active --quiet xray; then
    return 0
  fi

  echo "Xray is inactive; attempting emergency config recovery"
  local cfg_path
  cfg_path="$(detect_xray_config_path)" || return 1

  mkdir -p "${STATE_DIR}"
  cp -f "${cfg_path}" "${STATE_DIR}/xray-broken-$(date +%s).json" 2>/dev/null || true

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
  apply_xray_config_perms "${cfg_path}"

  systemctl restart xray >/dev/null 2>&1 || true
  systemctl is-active --quiet xray
}

ensure_xray_config() {
  echo "[4/11] Ensuring Xray config and SOCKS inbound 127.0.0.1:10808"
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
    apply_xray_config_perms "${cfg_path}"
  fi

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
  install -m 0640 -o root -g xray "${tmp_cfg}" "${cfg_path}"
  apply_xray_config_perms "${cfg_path}"
  rm -f "${tmp_cfg}"
}

install_asset() {
  local local_name="$1"
  local remote_name="$2"
  local dest="$3"
  local mode="$4"
  local owner="$5"
  local group="$6"
  local tmp
  tmp="$(mktemp)"

  if [[ -f "./${local_name}" ]]; then
    cp -f "./${local_name}" "${tmp}"
  else
    curl -fsSL \
      -H "Cache-Control: no-cache, no-store, must-revalidate" \
      "${RAW_BASE_URL}/${remote_name}?ts=$(date +%s)" \
      -o "${tmp}"
  fi

  install -m "${mode}" -o "${owner}" -g "${group}" "${tmp}" "${dest}"
  rm -f "${tmp}"
}

echo "[1/11] Installing OS dependencies"
export DEBIAN_FRONTEND=noninteractive
pre_clean_previous_state
if [[ "${SKIP_APT}" == "1" ]]; then
  echo "SKIP_APT=1 set; skipping apt dependency installation"
elif deps_ready; then
  echo "Dependencies already installed; skipping apt"
else
  wait_for_pkg_manager || true
  apt-get -o DPkg::Lock::Timeout=1200 update -y
  apt-get -o DPkg::Lock::Timeout=1200 install -y python3 curl jq dnsutils sudo
fi

echo "[2/11] Creating service user and directories"
if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
  groupadd --system "${APP_GROUP}"
fi
if ! id -u "${APP_USER}" >/dev/null 2>&1; then
  useradd --system --gid "${APP_GROUP}" --home-dir "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
fi

mkdir -p "${APP_DIR}" "${STATE_DIR}" "${UPLOAD_DIR}" "${LOG_DIR}"
chown root:"${APP_GROUP}" "${APP_DIR}"
chown "${APP_USER}:${APP_GROUP}" "${STATE_DIR}" "${UPLOAD_DIR}"
chown root:"${APP_GROUP}" "${LOG_DIR}"
chmod 0750 "${APP_DIR}" "${STATE_DIR}" "${UPLOAD_DIR}" "${LOG_DIR}"

if [[ ! -f "${STATE_DIR}/latest_status.json" ]]; then
  cat > "${STATE_DIR}/latest_status.json" <<'JSON'
{"status":"idle","message":"Upload config.json to run Google egress validation","checked_at":""}
JSON
fi
chown "${APP_USER}:${APP_GROUP}" "${STATE_DIR}/latest_status.json"
chmod 0640 "${STATE_DIR}/latest_status.json"

install_xray_if_missing
ensure_xray_runtime_identity
normalize_xray_unit_user
systemctl daemon-reload
chown root:xray "${LOG_DIR}" 2>/dev/null || true
chmod 0750 "${LOG_DIR}" 2>/dev/null || true
touch "${LOG_DIR}/xray-access.log" "${LOG_DIR}/xray-error.log"
chown xray:xray "${LOG_DIR}/xray-access.log" "${LOG_DIR}/xray-error.log" 2>/dev/null || true
chmod 0640 "${LOG_DIR}/xray-access.log" "${LOG_DIR}/xray-error.log" 2>/dev/null || true
ensure_xray_config

echo "[5/11] Enabling Xray service"
systemctl daemon-reload
systemctl enable --now xray
systemctl restart xray
if ! recover_xray_if_inactive; then
  echo "Failed to recover xray service"
  journalctl -u xray -n 80 --no-pager || true
  exit 1
fi

echo "[6/11] Installing root helper scripts"
install_asset "google-egress-xray-logctl.sh" "google-egress-xray-logctl.sh" "${LOGCTL_HELPER_DST}" "0750" "root" "root"
install_asset "google-egress-xray-test.sh" "google-egress-xray-test.sh" "${TEST_HELPER_DST}" "0750" "root" "root"

echo "[7/11] Installing Python web app"
install_asset "app.py" "app.py" "${APP_FILE}" "0640" "root" "${APP_GROUP}"

echo "[8/11] Installing systemd unit"
install_asset "google-egress-check.service" "google-egress-check.service" "${SERVICE_DST}" "0644" "root" "root"

echo "[9/11] Configuring sudoers"
cat > "${SUDOERS_FILE}" <<'SUDO'
Defaults:googleegress !requiretty
Defaults:googleegress !authenticate
Defaults:googleegress timestamp_timeout=0
googleegress ALL=(root) NOPASSWD: /usr/local/sbin/google-egress-xray-test *
SUDO
chmod 0440 "${SUDOERS_FILE}"

echo "[10/11] Reloading and starting web service"
systemctl daemon-reload
systemctl enable --now google-egress-check.service
systemctl restart google-egress-check.service

echo "[11/11] Final checks"
if ! recover_xray_if_inactive; then
  echo "xray service is not active"
  journalctl -u xray -n 80 --no-pager || true
  exit 1
fi
if ! systemctl is-active --quiet google-egress-check.service; then
  echo "google-egress-check.service failed to start"
  exit 1
fi

health_ok=0
for _ in 1 2 3 4 5; do
  health="$(curl -fsS --max-time 5 http://127.0.0.1/healthz 2>/dev/null || true)"
  if echo "${health}" | jq -e '.status=="ok"' >/dev/null 2>&1; then
    health_ok=1
    break
  fi
  sleep 1
done
if [[ "${health_ok}" != "1" ]]; then
  echo "Web health check failed on http://127.0.0.1/healthz"
  exit 1
fi

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
fi
if [[ -z "${SERVER_IP}" ]]; then
  SERVER_IP="SERVER_IP"
fi

echo "Install complete. Visit http://${SERVER_IP}/"
