#!/bin/bash
###############################################################################
# oem_host_unreachable_poller.sh
#
# FALLBACK PATH - independent of OEM's notification/incident-rule dispatch
# entirely. Added 2026-09-13 after confirming, via emoms.log, that OMS's
# internal notification queue (EMPbsServer / NotificationMgrThread) can
# silently stop dispatching real-time notifications ("QUEUE_READY execution
# timed out after 200 seconds") even when:
#   - the incident rule and notification method are both confirmed correctly
#     configured and enabled
#   - OEM's own event detection and incident creation continue working
#     normally (incidents were created on time every single occurrence)
#   - the notification method's own "Test OS Command" still succeeds on demand
#   - a full `emctl stop oms -all` / `emctl start oms` did not reliably clear
#     the underlying condition
#
# This script does not depend on any of that. It polls emcli directly, on
# its own schedule, and queues a job itself if a target has been in a bad
# state longer than a grace period - regardless of whether a notification
# ever fired. This turns the pipeline from purely event-driven into
# event-driven-with-a-safety-net.
#
# Deploy path (same convention as the trigger script): /u01/app/oracle/emcli/
# Runs on lnx003 as oracle:oinstall, mode 700, via cron (see bottom of file
# for the recommended entry).
#
# Scope for this version: Linux/Exadata Agent targets only (anything with an
# oracle_emd target, i.e. anywhere the existing SSH+emctl ladder applies).
# RDS has no oracle_emd target and would need a separate poller built against
# the AWS API instead - out of scope for this version.
###############################################################################

EMCLI_BIN="/u01/app/oracle/product/19.3/middleware/bin/emcli"
LOGFILE="/tmp/oem_host_unreachable_poller.log"
STATE_DIR="/tmp/oem_poller_state"
QUEUE_HOST="hpsuperdome"
QUEUE_USER="ansible_admin"
QUEUE_DIR="/etc/ansible/OEM/host_unreachable_queue"

# emcli's own CLI session (stored per-OS-user under ~/.emcli/) expires after
# a period of inactivity - confirmed during this same troubleshooting session
# ("Error: Session expired. Run emcli login to establish a session."). An
# interactive user can just re-run `emcli login`, but this script runs
# unattended via cron and cannot type a password when that happens - so it
# re-authenticates at the start of every single poll cycle instead of
# assuming the prior session is still valid. Re-logging in when a session is
# already valid is harmless (emcli just reports "already logged in" and
# continues), so this is safe to do unconditionally every run.
#
# SECURITY: the credentials file below must be mode 600, owned by oracle,
# and should hold a dedicated EM user scoped to read-only target-status
# privileges - NOT the SYSMAN superuser - if your OEM setup allows creating
# one. Using SYSMAN here works but is broader access than this script needs.
EMCLI_USER_FILE="/home/oracle/.oem_poller/emcli_user"
EMCLI_PASS_FILE="/home/oracle/.oem_poller/emcli_pass"

# How long a target must be continuously non-Up before the poller queues a
# job. Deliberately longer than the notification path's typical near-instant
# detection - this is a safety net for when that path has already failed to
# produce a queued job, not a faster duplicate of it.
GRACE_SECONDS=300

# Never poll-remediate the OMS host itself.
SELF_HOST="lnx003"

mkdir -p "$STATE_DIR"

TS=$(date '+%Y-%m-%d %H:%M:%S')
echo "=== Poll run: $TS ===" >> "$LOGFILE"

if [ ! -f "$EMCLI_USER_FILE" ] || [ ! -f "$EMCLI_PASS_FILE" ]; then
  echo "FATAL: credentials files not found at $EMCLI_USER_FILE / $EMCLI_PASS_FILE - see deployment instructions. Skipping this poll cycle." >> "$LOGFILE"
  exit 1
fi
EMCLI_USER=$(cat "$EMCLI_USER_FILE")
EMCLI_PASS=$(cat "$EMCLI_PASS_FILE")

LOGIN_OUTPUT=$("$EMCLI_BIN" login -username="$EMCLI_USER" -password="$EMCLI_PASS" 2>&1)
if echo "$LOGIN_OUTPUT" | grep -qi "already logged in\|Login successful"; then
  : # fine either way - proceed
else
  echo "emcli login did not clearly succeed - output was: $LOGIN_OUTPUT" >> "$LOGFILE"
  echo "Attempting the query anyway in case this is just an unrecognized-but-harmless message" >> "$LOGFILE"
fi

# Pull every oracle_emd (Agent) target's current status in one call.
STATUS_OUTPUT=$("$EMCLI_BIN" get_targets -targets="oracle_emd" -script 2>>"$LOGFILE")

if [ -z "$STATUS_OUTPUT" ]; then
  echo "emcli get_targets returned nothing - skipping this poll cycle" >> "$LOGFILE"
  exit 0
fi

# Skip the header line, then process each data row.
echo "$STATUS_OUTPUT" | tail -n +2 | while IFS=$'\t' read -r STATUS_ID STATUS TARGET_TYPE TARGET_NAME; do
  [ -z "$TARGET_NAME" ] && continue

  HOST=$(echo "$TARGET_NAME" | cut -d: -f1)
  [ "$HOST" = "$SELF_HOST" ] && continue

  STATE_FILE="${STATE_DIR}/${HOST}.firstseen"
  QUEUED_MARKER="${STATE_DIR}/${HOST}.queued"

  if [ "$STATUS" = "Up" ]; then
    # Recovered (or was never down) - clear any tracking so a future
    # occurrence starts a fresh grace period rather than reusing stale state.
    if [ -f "$STATE_FILE" ] || [ -f "$QUEUED_MARKER" ]; then
      echo "$HOST ($TARGET_NAME) is Up - clearing tracking state" >> "$LOGFILE"
      rm -f "$STATE_FILE" "$QUEUED_MARKER"
    fi
    continue
  fi

  # Non-Up status observed.
  if [ ! -f "$STATE_FILE" ]; then
    echo "$(date +%s)" > "$STATE_FILE"
    echo "$HOST ($TARGET_NAME) first observed non-Up (status=$STATUS) - starting grace period" >> "$LOGFILE"
    continue
  fi

  FIRST_SEEN=$(cat "$STATE_FILE")
  NOW=$(date +%s)
  ELAPSED=$((NOW - FIRST_SEEN))

  if [ "$ELAPSED" -lt "$GRACE_SECONDS" ]; then
    echo "$HOST ($TARGET_NAME) still within grace period (${ELAPSED}s / ${GRACE_SECONDS}s)" >> "$LOGFILE"
    continue
  fi

  if [ -f "$QUEUED_MARKER" ]; then
    echo "$HOST ($TARGET_NAME) already queued by poller (marker exists) - not re-queuing" >> "$LOGFILE"
    continue
  fi

  # Don't queue if the notification path already has a job in flight or
  # pending for this host under ANY alert_type - avoid two parallel
  # remediation attempts against the same target from two different triggers.
  EXISTING=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
    "${QUEUE_USER}@${QUEUE_HOST}" "ls ${QUEUE_DIR}/${HOST}_*.json ${QUEUE_DIR}/${HOST}_*.processing 2>/dev/null" 2>>"$LOGFILE")

  if [ -n "$EXISTING" ]; then
    echo "$HOST ($TARGET_NAME) already has a pending/in-flight job on the queue (notification path likely handling it) - not duplicating" >> "$LOGFILE"
    touch "$QUEUED_MARKER"
    continue
  fi

  echo "$HOST ($TARGET_NAME) exceeded grace period (${ELAPSED}s) with no existing queue entry - poller is queuing a job" >> "$LOGFILE"

  PAYLOAD=$(cat <<EOF
{
  "host": "${HOST}",
  "target_name": "${TARGET_NAME}",
  "alert_type": "polling_fallback",
  "metric_name": "Agent Unreachable (detected by polling fallback, not OEM notification)",
  "oem_incident_id": "unknown",
  "detected_time": "${TS} (first observed non-Up at $(date -d @${FIRST_SEEN} '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r ${FIRST_SEEN} '+%Y-%m-%d %H:%M:%S'))",
  "queued_time": "${TS}"
}
EOF
  )

  echo "$PAYLOAD" | ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
    "${QUEUE_USER}@${QUEUE_HOST}" "cat > ${QUEUE_DIR}/${HOST}_polling_fallback.json" >> "$LOGFILE" 2>&1

  if [ $? -eq 0 ]; then
    touch "$QUEUED_MARKER"
    echo "Queued ${HOST}_polling_fallback.json via poller fallback" >> "$LOGFILE"
  else
    echo "FAILED to queue ${HOST}_polling_fallback.json - SSH hand-off to ${QUEUE_USER}@${QUEUE_HOST} failed" >> "$LOGFILE"
  fi
done

exit 0

###############################################################################
# Recommended cron entry (as oracle, on lnx003):
#
#   */5 * * * * /u01/app/oracle/emcli/oem_host_unreachable_poller.sh
#
# 5-minute polling interval + 300s (5 min) grace period means a genuinely
# stuck notification path is caught within roughly 5-10 minutes worst case -
# slower than the notification path's typical near-instant detection, but a
# real, working safety net rather than an indefinite silent failure.
###############################################################################
