#!/bin/bash
###############################################################################
# SNOW_ALR_HostUnreachable_Trigger
#
# OEM OS Command notification method for Agent Unreachable / Host
# Unreachable alerts.
#
# UNLIKE the tablespace pipeline (oem_to_snow_webhook.sh), this script
# does NOT create a ServiceNow incident. It only drops a trigger file
# for the Ansible control node to pick up. Ansible attempts full
# remediation first; a ServiceNow incident is only opened by Ansible
# itself, and only if remediation fails. This keeps SNOW/L1 support
# from being paged for transient agent blips that self-heal.
#
# Deploy path (matches existing convention): /u01/app/oracle/emcli/
# Runs on the OMS host (lnx003) as oracle:oinstall, mode 700.
###############################################################################

LOGFILE=/tmp/oem_host_unreachable_trigger.log
QUEUE_HOST="hpsuperdome"          # Ansible control node
QUEUE_USER="ansible_admin"
QUEUE_DIR="/etc/ansible/OEM/host_unreachable_queue"

TS=$(date '+%Y-%m-%d %H:%M:%S')

{
  echo "=== Trigger fired: $TS ==="
  echo "TARGET_NAME=$TARGET_NAME"
  echo "HOST_NAME=$HOST_NAME"
  echo "KEY_VALUE=$KEY_VALUE"
  echo "METRIC_NAME=$METRIC_NAME"
  echo "SEVERITY_CODE=$SEVERITY_CODE"
  echo "NOTIF_TYPE=$NOTIF_TYPE"
  echo "ASSOC_INCIDENT_ID=$ASSOC_INCIDENT_ID"
  echo "EVENT_REPORTED_TIME=$EVENT_REPORTED_TIME"
} >> "$LOGFILE"

# Only act on Critical firings. Clear needs no action here since
# nothing is ever ticketed for this alert type unless Ansible itself
# escalates - there is no SNOW incident for a Clear event to resolve.
if [ "$SEVERITY_CODE" != "CRITICAL" ]; then
  echo "Ignoring non-critical severity ($SEVERITY_CODE)" >> "$LOGFILE"
  exit 0
fi

# Classify by metric name as a hint only - the resolver independently
# verifies via ping/SSH rather than trusting this classification.
case "$METRIC_NAME" in
  *[Aa]gent*[Uu]nreachable*|*[Aa]gent*[Rr]esponding*) ALERT_TYPE="agent_unreachable" ;;
  *[Ss]tatus*|*[Uu]p_[Dd]own*|*reachab*|*[Rr]esponse*) ALERT_TYPE="host_unreachable" ;;
  *) ALERT_TYPE="unknown" ;;
esac

HOST="${HOST_NAME:-$TARGET_NAME}"
QUEUE_FILE="${HOST}_${ALERT_TYPE}.json"

PAYLOAD=$(cat <<EOF
{
  "host": "${HOST}",
  "target_name": "${TARGET_NAME}",
  "alert_type": "${ALERT_TYPE}",
  "metric_name": "${METRIC_NAME}",
  "oem_incident_id": "${ASSOC_INCIDENT_ID}",
  "detected_time": "${EVENT_REPORTED_TIME}",
  "queued_time": "${TS}"
}
EOF
)

# Fire-and-forget: hand off to background and return immediately.
# Filename is keyed by host+alert_type (not timestamp) so a re-fire
# for the same host just refreshes the pending job instead of
# stacking a duplicate remediation run.
#
# NOTE: StrictHostKeyChecking=no (not accept-new) - accept-new requires
# OpenSSH 7.6+, and lnx003 runs 7.4p1. This still avoids interactive
# host-key prompts on new hosts, at the cost of not verifying the host
# key on first connect - acceptable for this internal, already-controlled
# host pair, but worth revisiting if this script is ever pointed at a
# host outside your own network.
#
# NOTE: the "Queued" log line is now conditional on the SSH call's own
# exit code (BatchMode=yes ensures it fails fast rather than hanging on
# a password prompt it can never answer) - previously this logged
# unconditionally, so a genuinely failed hand-off (e.g. no password-less
# key set up yet) looked identical to a success in the log.
(
  if echo "$PAYLOAD" | ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
       "${QUEUE_USER}@${QUEUE_HOST}" "cat > ${QUEUE_DIR}/${QUEUE_FILE}" \
       >> "$LOGFILE" 2>&1; then
    echo "Queued ${QUEUE_FILE} at $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOGFILE"
  else
    echo "FAILED to queue ${QUEUE_FILE} at $(date '+%Y-%m-%d %H:%M:%S') - SSH hand-off to ${QUEUE_USER}@${QUEUE_HOST} failed (see error above)" >> "$LOGFILE"
  fi
) &
disown

exit 0
