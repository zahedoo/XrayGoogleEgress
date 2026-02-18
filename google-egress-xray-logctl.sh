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
XRAY_USER=""
XRAY_GROUP=""

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

ensure_runtime_dirs() {
  if [[ ! -d "${STATE_DIR}" || ! -d "${LOG_DIR}" ]]; then
    echo "Runtime directories missing. Re-run installer." >&2
    exit 1
  fi
  if [[ ! -w "${STATE_DIR}" || ! -w "${LOG_DIR}" ]]; then
    echo "Permission denied for runtime directories" >&2
    exit 1
  fi
  chown root:"${XRAY_GROUP}" "${LOG_DIR}" 2>/dev/null || true
  chmod 0750 "${STATE_DIR}" "${LOG_DIR}" || true
  touch "${ACCESS_LOG}" "${ERROR_LOG}"
  chown "${XRAY_USER}:${XRAY_GROUP}" "${ACCESS_LOG}" "${ERROR_LOG}" 2>/dev/null || chown root:"${APP_GROUP}" "${ACCESS_LOG}" "${ERROR_LOG}"
  chmod 0640 "${ACCESS_LOG}" "${ERROR_LOG}"
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

if [[ "${EUID}" -ne 0 ]]; then
  echo "This helper must run as root." >&2
  exit 1
fi

detect_xray_runtime_identity
ensure_runtime_dirs

exec 9>"${LOCK_FILE}"
flock -w 20 9

if [[ "${ACTION}" == "enable" ]]; then
  CFG_PATH="$(detect_xray_config_path)"

  if [[ -f "${BACKUP_CFG}" && -f "${CFG_PATH_FILE}" ]]; then
    PREV_CFG_PATH="$(cat "${CFG_PATH_FILE}")"
    if [[ -f "${PREV_CFG_PATH}" ]]; then
      cp -f "${BACKUP_CFG}" "${PREV_CFG_PATH}" || true
      apply_cfg_permissions "${PREV_CFG_PATH}" || true
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
  cp -f "${TMP_CFG}" "${CFG_PATH}"
  apply_cfg_permissions "${CFG_PATH}"
  rm -f "${TMP_CFG}"

  : > "${ACCESS_LOG}"
  : > "${ERROR_LOG}"

  if ! systemctl restart xray; then
    cp -f "${BACKUP_CFG}" "${CFG_PATH}" || true
    apply_cfg_permissions "${CFG_PATH}" || true
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
      cp -f "${BACKUP_CFG}" "${CFG_PATH}" || true
      apply_cfg_permissions "${CFG_PATH}" || true
      systemctl restart xray || true
    fi
    rm -f "${BACKUP_CFG}" "${CFG_PATH_FILE}"
  fi
fi
