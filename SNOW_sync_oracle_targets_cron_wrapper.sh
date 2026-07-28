#!/usr/bin/env bash
# SNOW_sync_oracle_targets_cron_wrapper.sh
# Released under the MIT license. Copyright (c) 2026, Vlad von Grigorian <>
#
# Cron-safe wrapper for SNOW_sync_oracle_targets.yml - keeps the ServiceNow
# u_oracle_target table in sync with oracle_instance_map, so record producer
# Reference fields (PRF's "Database" field, and any others wired the same
# way later) can only show real, currently-known host:SID combinations.
#
# Same PID-lock / trap-cleanup / log-rotation structure as every other SNOW
# wrapper in this suite - see PDB_snow_cron_wrapper.sh / DDP_snow_cron_
# wrapper.sh for the original pattern this is copied from.
#
# Suggested schedule: every 15 minutes is plenty for a list of hosts that
# changes rarely - no need to run this as often as the change-request
# processing wrappers.
#
# Crontab entry, as ansible_admin:
#   */15 * * * * /etc/ansible/SNOW_sync_oracle_targets_cron_wrapper.sh >> /tmp/cron.sync_oracle_targets.snow.log 2>&1

set -euo pipefail

# -- Configuration -------------------------------------------------------------

PLAYBOOK_DIR="/etc/ansible"
PLAYBOOK="SNOW_sync_oracle_targets.yml"
VAULT_PASS_FILE="/etc/ansible/.vault_pass"

BASE_DIR="${HOME}/snow_sync_oracle_targets"
LOCK_FILE="${BASE_DIR}/snow_sync_oracle_targets.pid"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/run_$(date +%Y%m%d_%H%M%S).log"
LOG_RETENTION_DAYS=14

ANSIBLE_BIN="$(command -v ansible-playbook)"

mkdir -p "${LOG_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

log "========================================================"
log "ServiceNow oracle_targets sync wrapper started (PID $$)"
log "Playbook : ${PLAYBOOK_DIR}/${PLAYBOOK}"
log "Lock file: ${LOCK_FILE}"

if [[ -f "${LOCK_FILE}" ]]; then
    EXISTING_PID=$(cat "${LOCK_FILE}" 2>/dev/null || true)

    if [[ -n "${EXISTING_PID}" ]] && kill -0 "${EXISTING_PID}" 2>/dev/null; then
        log "Previous run is still active (PID ${EXISTING_PID}). Exiting -- will retry next slot."
        exit 0
    else
        log "Stale lock file found (PID ${EXISTING_PID} no longer exists). Removing and proceeding."
        rm -f "${LOCK_FILE}"
    fi
fi

echo $$ > "${LOCK_FILE}"
log "Lock acquired (PID $$)."

cleanup() {
    local exit_code=$?
    log "Releasing lock file ${LOCK_FILE}."
    rm -f "${LOCK_FILE}"
    log "Wrapper finished with exit code ${exit_code}."
    log "========================================================"
}
trap cleanup EXIT INT TERM

if [[ ! -f "${PLAYBOOK_DIR}/${PLAYBOOK}" ]]; then
    log "ERROR: Playbook not found: ${PLAYBOOK_DIR}/${PLAYBOOK}"
    exit 1
fi

if [[ ! -f "${VAULT_PASS_FILE}" ]]; then
    log "ERROR: Vault password file not found: ${VAULT_PASS_FILE}"
    exit 1
fi

chmod 600 "${VAULT_PASS_FILE}"

log "Launching: ansible-playbook ${PLAYBOOK}"

cd "${PLAYBOOK_DIR}"

ANSIBLE_RC=0
"${ANSIBLE_BIN}" "${PLAYBOOK}" \
    --vault-password-file "${VAULT_PASS_FILE}" \
    >> "${LOG_FILE}" 2>&1 || ANSIBLE_RC=$?

if [[ ${ANSIBLE_RC} -eq 0 ]]; then
    log "Playbook completed successfully (rc=0)."
else
    log "Playbook finished with errors (rc=${ANSIBLE_RC}). Check ${LOG_FILE}."
fi

find "${LOG_DIR}" -name 'run_*.log' -type f -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true

exit ${ANSIBLE_RC}
