#!/usr/bin/env bash
#
# run_playbook.sh — invoked by webhook_receiver.py, one process per CR.
# Same safety idiom as the DCR cron wrapper: a PID-based lock file with
# `kill -0` liveness checking, so a second webhook call for the same CR
# (e.g. a retried Business Rule call) can't launch a duplicate remediation
# run, and a stale lock from a crashed run doesn't block anything forever.
#
# Usage: run_playbook.sh <CHANGE_NUMBER> <TABLESPACE>
#
set -uo pipefail

CHANGE_NUMBER="${1:?Usage: run_playbook.sh <CHANGE_NUMBER> <TABLESPACE>}"
TABLESPACE="${2:?Usage: run_playbook.sh <CHANGE_NUMBER> <TABLESPACE>}"

# ---- paths (override via environment if you relocate things) ----
BASE_DIR="${DEMO_BASE_DIR:-/etc/ansible/OEM}"
PLAYBOOK="${DEMO_PLAYBOOK:-$BASE_DIR/remediate_tablespace.yml}"
INVENTORY="${DEMO_INVENTORY:-$BASE_DIR/inventory.ini}"
LOCK_DIR="${DEMO_LOCK_DIR:-/tmp/tablespace-demo-locks}"
LOG_DIR="${DEMO_LOG_DIR:-$BASE_DIR/logs}"
COLLECTIONS_PATH="${ANSIBLE_COLLECTIONS_PATH:-/etc/ansible/collections}"

LOCK_FILE="$LOCK_DIR/${CHANGE_NUMBER}.lock"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/${CHANGE_NUMBER}_${TIMESTAMP}.log"

mkdir -p "$LOCK_DIR" "$LOG_DIR"

# ---- lock check: is a run for this exact CR already in flight? ----
if [[ -f "$LOCK_FILE" ]]; then
  OLD_PID="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[$CHANGE_NUMBER] already running as PID $OLD_PID — skipping duplicate trigger" >&2
    exit 75  # EX_TEMPFAIL — webhook_receiver.py treats this as "already running"
  fi
  echo "[$CHANGE_NUMBER] found stale lock (PID $OLD_PID not alive) — clearing it" >&2
  rm -f "$LOCK_FILE"
fi

echo "$$" > "$LOCK_FILE"
cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT INT TERM

{
  echo "=== $(date -Is) starting remediation for $CHANGE_NUMBER (tablespace=$TABLESPACE) ==="
  ANSIBLE_COLLECTIONS_PATH="$COLLECTIONS_PATH" ansible-playbook -i "$INVENTORY" "$PLAYBOOK" \
    --extra-vars "change_number=${CHANGE_NUMBER} tablespace=${TABLESPACE}"
  RC=$?
  echo "=== $(date -Is) finished remediation for $CHANGE_NUMBER, ansible-playbook exit=$RC ==="
} >> "$LOG_FILE" 2>&1

# The log above is now complete and closed — safe to attach it to the CR.
# This MUST run as a separate step after the redirect block above closes:
# the block writes $LOG_FILE via its own redirect the whole time it runs,
# so if the attach happened from INSIDE that block (or from inside the
# remediation playbook itself), the uploaded copy would be missing
# everything written after the upload point, including this very
# completion line. Runs as its own playbook, output goes to a companion
# file rather than $LOG_FILE itself (appending there would mean the
# attachment is always missing its own final "uploaded" line — chasing
# its own tail), and deliberately doesn't affect $RC: a log-attachment
# hiccup isn't a remediation failure — the remediation's own success or
# failure was already fully recorded on the CR before this ever runs.
ATTACH_PLAYBOOK="${DEMO_ATTACH_PLAYBOOK:-$BASE_DIR/attach_run_log.yml}"
ANSIBLE_COLLECTIONS_PATH="$COLLECTIONS_PATH" ansible-playbook -i "$INVENTORY" "$ATTACH_PLAYBOOK" \
  --extra-vars "change_number=${CHANGE_NUMBER} log_file_path=${LOG_FILE}" \
  >> "${LOG_FILE}.attach.log" 2>&1 || true

exit "$RC"
