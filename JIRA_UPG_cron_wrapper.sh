#!/usr/bin/env bash
# JIRA_UPG_cron_wrapper.sh
# Released under the MIT license. Copyright (c) 2026, Vlad von Grigorian <
#
# Cron-safe wrapper for the DCR playbook (JIRA_DCR_data_change.yml).
#
# Uses a PID-based lock file to guarantee only one instance runs at a time.
# If a previous run is still active when cron fires again, this script exits
# immediately and waits for the next cron slot.
#
# CHANGES (July 2026 — rebuilt controller):
#   * Lock and log paths moved out of /var/run and /var/log into the invoking
#     user's home directory. Those system trees are root-owned (and /run is a
#     tmpfs recreated empty at every boot), so an unprivileged cron user can
#     never rely on them without root-side setup that a rebuild silently loses.
#     Everything this script touches is now self-created and user-owned.
#   * Fixed exit-code capture: under `set -e`, a non-zero ansible-playbook rc
#     aborted the script before ANSIBLE_RC=$? could run, so the error branch
#     was unreachable. The call is now wrapped so the rc is always captured.
#   * Added simple log rotation (per-run logs older than 14 days are pruned).
#
# Crontab entry (every 5 minutes), as ansible_admin:
#   */5 * * * * /etc/ansible/JIRA_UPG_cron_wrapper.sh >> /tmp/cron.UPG.log 2>&1

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

PLAYBOOK_DIR="/etc/ansible"
PLAYBOOK="JIRA_UPG_oracle_upgrade.yml"
VAULT_PASS_FILE="/etc/ansible/.vault_pass"     # file containing the vault password

BASE_DIR="${HOME}/jira_upg"                    # user-owned; survives reboots
LOCK_FILE="${BASE_DIR}/jira_upg.pid"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/run_$(date +%Y%m%d_%H%M%S).log"
LOG_RETENTION_DAYS=14

ANSIBLE_BIN="$(command -v ansible-playbook)"

# ── Setup (before any logging — the log dir must exist first) ─────────────────

mkdir -p "${LOG_DIR}"

# ── Logging helper ────────────────────────────────────────────────────────────

log() {
    # Writes to both the per-run log file and stdout (captured by cron)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

log "========================================================"
log "Jira DCR wrapper started (PID $$)"
log "Playbook : ${PLAYBOOK_DIR}/${PLAYBOOK}"
log "Lock file: ${LOCK_FILE}"

# ── Lock file check ───────────────────────────────────────────────────────────
#
# Strategy: write our own PID into the lock file, but first check whether
# the PID stored in an existing lock file belongs to a process that is
# still alive.
#
# This is safer than a plain "file exists" check because it self-heals after
# a crash — a stale lock file whose PID no longer exists is removed and the
# new run proceeds normally.

if [[ -f "${LOCK_FILE}" ]]; then
    EXISTING_PID=$(cat "${LOCK_FILE}" 2>/dev/null || true)

    if [[ -n "${EXISTING_PID}" ]] && kill -0 "${EXISTING_PID}" 2>/dev/null; then
        # Process is genuinely still running
        log "Previous run is still active (PID ${EXISTING_PID}). Exiting — will retry in 5 minutes."
        exit 0
    else
        # Lock file is stale (crash / OOM kill / manual stop / reboot)
        log "Stale lock file found (PID ${EXISTING_PID} no longer exists). Removing and proceeding."
        rm -f "${LOCK_FILE}"
    fi
fi

# ── Acquire lock ──────────────────────────────────────────────────────────────

echo $$ > "${LOCK_FILE}"
log "Lock acquired (PID $$)."

# ── Ensure lock is always released on exit ────────────────────────────────────
#
# The trap fires on: normal exit (EXIT), Ctrl-C (INT), kill (TERM),
# and script errors (via set -e -> EXIT). This guarantees the lock file is
# never left behind regardless of how the script ends.

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

# Vault password file must be readable only by this user
chmod 600 "${VAULT_PASS_FILE}"

# ── Run the playbook ──────────────────────────────────────────────────────────

log "Launching: ansible-playbook ${PLAYBOOK}"

cd "${PLAYBOOK_DIR}"

# The `|| ANSIBLE_RC=$?` guard keeps `set -e` from aborting the script on a
# non-zero playbook rc, so the outcome is always logged and the lock released
# through the normal path.
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
# A 5-minute cron produces ~288 log files/day; prune anything older than the
# retention window so the log dir does not grow unbounded.

find "${LOG_DIR}" -name 'run_*.log' -type f -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true

exit ${ANSIBLE_RC}