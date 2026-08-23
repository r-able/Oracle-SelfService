#!/usr/bin/env bash
# SNOW_sync_oracle_schemas_cron_wrapper.sh
# Released under the MIT license. Copyright (c) 2026, Vlad von Grigorian <>
#
# Cron-safe wrapper for SNOW_sync_oracle_schemas.yml - keeps the ServiceNow
# u_oracle_schema table in sync with the real, live schemas found on each
# known host:PDB in u_oracle_target, so REF's cascading source_schema /
# target_schema Reference fields can only show real, currently-known
# schemas for whichever host:database was picked.
#
# Same PID-lock / trap-cleanup / log-rotation structure as
# SNOW_sync_oracle_targets_cron_wrapper.sh, adapted for this playbook.
#
# Suggested schedule: this scan is meaningfully heavier than the targets
# sync - it connects to every known PDB individually and runs a query in
# each (roughly 90 seconds - 2 minutes for 13 targets in testing), rather
# than one quick v$pdbs check per host. Every 15 minutes is a reasonable
# starting point; running this every single minute like some of the
# change-request wrappers would risk overlapping runs given the longer
# runtime, even with the PID lock below preventing actual double-execution.
#
# Crontab entry, as ansible_admin:
#   */15 * * * * /etc/ansible/SNOW_sync_oracle_schemas_cron_wrapper.sh >> /tmp/cron.sync_oracle_schemas.snow.log 2>&1

set -euo pipefail

# -- Configuration -------------------------------------------------------------

PLAYBOOK_DIR="/etc/ansible"
PLAYBOOK="SNOW_sync_oracle_schemas.yml"
VAULT_PASS_FILE="/etc/ansible/.vault_pass"

BASE_DIR="${HOME}/snow_sync_oracle_schemas"
LOCK_FILE="${BASE_DIR}/snow_sync_oracle_schemas.pid"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/run_$(date +%Y%m%d_%H%M%S).log"
LOG_RETENTION_DAYS=14

ANSIBLE_BIN="$(command -v ansible-playbook)"

mkdir -p "${LOG_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

log "========================================================"
log "ServiceNow oracle_schemas sync wrapper started (PID $$)"
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
