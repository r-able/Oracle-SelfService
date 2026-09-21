#!/usr/bin/env bash
#
# run_forecast.sh — invoked by cron once per tracked tablespace.
# Same PID-lock idiom as run_playbook.sh, mainly to protect against manual
# re-runs overlapping a scheduled one rather than any real concurrency risk
# from cron itself (which won't overlap unless a run takes >24h).
#
# Usage: run_forecast.sh <TABLESPACE>
#
set -uo pipefail

TABLESPACE="${1:?Usage: run_forecast.sh <TABLESPACE>}"

BASE_DIR="${DEMO_BASE_DIR:-/etc/ansible/OEM}"
PLAYBOOK="${DEMO_FORECAST_PLAYBOOK:-$BASE_DIR/forecast_and_open_cr.yml}"
INVENTORY="${DEMO_INVENTORY:-$BASE_DIR/inventory.ini}"
LOCK_DIR="${DEMO_LOCK_DIR:-/tmp/tablespace-demo-locks}"
LOG_DIR="${DEMO_LOG_DIR:-$BASE_DIR/logs}"
COLLECTIONS_PATH="${ANSIBLE_COLLECTIONS_PATH:-/etc/ansible/collections}"

LOCK_FILE="$LOCK_DIR/forecast_${TABLESPACE}.lock"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/forecast_${TABLESPACE}_${TIMESTAMP}.log"

mkdir -p "$LOCK_DIR" "$LOG_DIR"

if [[ -f "$LOCK_FILE" ]]; then
  OLD_PID="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[$TABLESPACE forecast] already running as PID $OLD_PID — skipping" >&2
    exit 75
  fi
  rm -f "$LOCK_FILE"
fi

echo "$$" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

{
  echo "=== $(date -Is) forecasting $TABLESPACE ==="
  ANSIBLE_COLLECTIONS_PATH="$COLLECTIONS_PATH" ansible-playbook \
    -i "$INVENTORY" "$PLAYBOOK" --extra-vars "tablespace=${TABLESPACE}"
  RC=$?
  echo "=== $(date -Is) done, exit=$RC ==="
  exit $RC
} >> "$LOG_FILE" 2>&1
