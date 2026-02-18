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
    chmod 0600 "${cfg_path}"
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
  install -m 0600 -o root -g root "${tmp_cfg}" "${cfg_path}"
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
    curl -fsSL "${RAW_BASE_URL}/${remote_name}" -o "${tmp}"
  fi

  install -m "${mode}" -o "${owner}" -g "${group}" "${tmp}" "${dest}"
  rm -f "${tmp}"
}

echo "[1/11] Installing OS dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 curl jq dnsutils sudo

echo "[2/11] Creating service user and directories"
if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
  groupadd --system "${APP_GROUP}"
fi
if ! id -u "${APP_USER}" >/dev/null 2>&1; then
  useradd --system --gid "${APP_GROUP}" --home-dir "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
fi

mkdir -p "${APP_DIR}" "${STATE_DIR}" "${UPLOAD_DIR}" "${LOG_DIR}"
chown root:"${APP_GROUP}" "${APP_DIR}"
chown "${APP_USER}:${APP_GROUP}" "${STATE_DIR}" "${UPLOAD_DIR}" "${LOG_DIR}"
chmod 0750 "${APP_DIR}" "${STATE_DIR}" "${UPLOAD_DIR}" "${LOG_DIR}"

if [[ ! -f "${STATE_DIR}/latest_status.json" ]]; then
  cat > "${STATE_DIR}/latest_status.json" <<'JSON'
{"status":"idle","message":"Upload config.json to run Google egress validation","checked_at":""}
JSON
fi
chown "${APP_USER}:${APP_GROUP}" "${STATE_DIR}/latest_status.json"
chmod 0640 "${STATE_DIR}/latest_status.json"

install_xray_if_missing
ensure_xray_config

echo "[5/11] Enabling Xray service"
systemctl daemon-reload
systemctl enable --now xray
systemctl restart xray

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
if ! systemctl is-active --quiet google-egress-check.service; then
  echo "google-egress-check.service failed to start"
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
