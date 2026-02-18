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
BACKUP_CFG="${STATE_DIR}/xray-config.logctl.backup.json"
CFG_PATH_FILE="${STATE_DIR}/xray-config.logctl.path"
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
