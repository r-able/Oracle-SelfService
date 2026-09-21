#!/usr/bin/env bash
#
# run_dispatcher.sh — invoked by cron every few minutes. Polls ServiceNow
# for open capacity-alert CRs and fires off remediation for each one it
# finds. Same PID-lock idiom as run_playbook.sh/run_forecast.sh, mainly
# so two overlapping cron ticks can't both run the polling query at once
# — actual duplicate-remediation protection is run_playbook.sh's own
# per-CR-number lock, not this one.
#
set -uo pipefail

BASE_DIR="${DEMO_BASE_DIR:-/etc/ansible/OEM}"
PLAYBOOK="${DEMO_DISPATCH_PLAYBOOK:-$BASE_DIR/dispatch_remediation.yml}"
INVENTORY="${DEMO_INVENTORY:-$BASE_DIR/inventory.ini}"
LOCK_DIR="${DEMO_LOCK_DIR:-/tmp/tablespace-demo-locks}"
LOG_DIR="${DEMO_LOG_DIR:-$BASE_DIR/logs}"
COLLECTIONS_PATH="${ANSIBLE_COLLECTIONS_PATH:-/etc/ansible/collections}"

LOCK_FILE="$LOCK_DIR/dispatcher.lock"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/dispatcher_${TIMESTAMP}.log"

mkdir -p "$LOCK_DIR" "$LOG_DIR"

if [[ -f "$LOCK_FILE" ]]; then
  OLD_PID="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[dispatcher] already running as PID $OLD_PID — skipping" >&2
    exit 75
  fi
  rm -f "$LOCK_FILE"
fi

echo "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

{
  echo "=== $(date -Is) polling for open capacity-alert CRs ==="
  ANSIBLE_COLLECTIONS_PATH="$COLLECTIONS_PATH" ansible-playbook \
    -i "$INVENTORY" "$PLAYBOOK"
  RC=$?
  echo "=== $(date -Is) dispatch tick done, exit=$RC ==="
  exit $RC
} >> "$LOG_FILE" 2>&1
