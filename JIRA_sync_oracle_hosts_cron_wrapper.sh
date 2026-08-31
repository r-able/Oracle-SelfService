#!/usr/bin/env bash
# JIRA_sync_oracle_hosts_cron_wrapper.sh
# Released under the MIT license. Copyright (c) 2026, Vlad von Grigorian <
#
# Cron-safe wrapper for JIRA_sync_oracle_hosts.yml - keeps PDB's "Target
# Host & Container (CDB)" field options in sync with oracle_instance_map,
# so the PDB creation form only ever offers real, currently-known hosts.
#
# Same PID-lock / trap-cleanup / log-rotation structure as every other
# wrapper in this suite - see JIRA_sync_oracle_targets_cron_wrapper.sh for
# the original pattern this is copied from.
#
# Suggested schedule: every 30 minutes, matching the cadence of the
# ServiceNow-side equivalent (SNOW_sync_oracle_hosts_cron_wrapper.sh, also
# */30) - this dataset is static (reflects oracle_instance_map directly, no
# live SQL), so there's no infrastructure state to fall behind on; a light
# schedule (or even a manual run after editing oracle_instance_map) is
# genuinely enough.
#
# Crontab entry, as ansible_admin:
#   */30 * * * * /etc/ansible/JIRA_sync_oracle_hosts_cron_wrapper.sh >> /tmp/cron.sync_oracle_hosts.jira.log 2>&1

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

PLAYBOOK_DIR="/etc/ansible"
PLAYBOOK="JIRA_sync_oracle_hosts.yml"
VAULT_PASS_FILE="/etc/ansible/.vault_pass"     # file containing the vault password

BASE_DIR="${HOME}/jira_sync_oracle_hosts"      # user-owned; survives reboots
LOCK_FILE="${BASE_DIR}/jira_sync_oracle_hosts.pid"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/run_$(date +%Y%m%d_%H%M%S).log"
LOG_RETENTION_DAYS=14

ANSIBLE_BIN="$(command -v ansible-playbook)"

# ── Setup (before any logging — the log dir must exist first) ─────────────────

mkdir -p "${LOG_DIR}"

# ── Logging helper ────────────────────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

log "========================================================"
log "Jira oracle_hosts sync wrapper started (PID $$)"
log "Playbook : ${PLAYBOOK_DIR}/${PLAYBOOK}"
log "Lock file: ${LOCK_FILE}"

# ── Lock file check ───────────────────────────────────────────────────────────

if [[ -f "${LOCK_FILE}" ]]; then
    EXISTING_PID=$(cat "${LOCK_FILE}" 2>/dev/null || true)

    if [[ -n "${EXISTING_PID}" ]] && kill -0 "${EXISTING_PID}" 2>/dev/null; then
        log "Previous run is still active (PID ${EXISTING_PID}). Exiting — will retry next cron slot."
        exit 0
    else
        log "Stale lock file found (PID ${EXISTING_PID} no longer exists). Removing and proceeding."
        rm -f "${LOCK_FILE}"
    fi
fi

# ── Acquire lock ──────────────────────────────────────────────────────────────

echo $$ > "${LOCK_FILE}"
log "Lock acquired (PID $$)."

# ── Ensure lock is always released on exit ────────────────────────────────────

cleanup() {
    local exit_code=$?
    log "Releasing lock file ${LOCK_FILE}."
    rm -f "${LOCK_FILE}"
    log "Wrapper finished with exit code ${exit_code}."
    log "========================================================"
}
trap cleanup EXIT INT TERM

# ── Validate environment ──────────────────────────────────────────────────────

if [[ ! -f "${PLAYBOOK_DIR}/${PLAYBOOK}" ]]; then
    log "ERROR: Playbook not found: ${PLAYBOOK_DIR}/${PLAYBOOK}"
    exit 1
fi

if [[ ! -f "${VAULT_PASS_FILE}" ]]; then
    log "ERROR: Vault password file not found: ${VAULT_PASS_FILE}"
    exit 1
fi

chmod 600 "${VAULT_PASS_FILE}"

# ── Run the playbook ──────────────────────────────────────────────────────────

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

# ── Log rotation ──────────────────────────────────────────────────────────────

find "${LOG_DIR}" -name 'run_*.log' -type f -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true

exit ${ANSIBLE_RC}
