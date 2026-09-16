#!/bin/bash
###############################################################################
# SNOW_OEM_host_unreachable_cron_wrapper.sh
#
# Runs on HPsuperdome (Ansible control node) via cron, e.g. every 1-2
# minutes:
#   */2 * * * * /etc/ansible/OEM/SNOW_OEM_host_unreachable_cron_wrapper.sh
#
# Polls /etc/ansible/OEM/host_unreachable_queue for trigger files
# dropped by oem_host_unreachable_trigger.sh, claims each one (rename
# to .processing so a concurrent tick or a re-fire can't double-run
# it), and dispatches the remediation playbook.
###############################################################################

QUEUE_DIR="/etc/ansible/OEM/host_unreachable_queue"
PLAYBOOK_DIR="/etc/ansible/OEM"
LOGDIR="/var/log/ansible"

mkdir -p "$QUEUE_DIR" "$LOGDIR"

shopt -s nullglob
for TRIGGER in "$QUEUE_DIR"/*.json; do
  [ -f "$TRIGGER" ] || continue

  BASENAME=$(basename "$TRIGGER" .json)
  PROCESSING="${QUEUE_DIR}/${BASENAME}.processing"

  # Claim. If the rename fails, another tick (or a still-running prior
  # attempt) already owns this one - skip it this cycle.
  mv "$TRIGGER" "$PROCESSING" 2>/dev/null || continue

  HOST=$(python3 -c "import json;print(json.load(open('$PROCESSING'))['host'])" 2>/dev/null)
  ALERT_TYPE=$(python3 -c "import json;print(json.load(open('$PROCESSING'))['alert_type'])" 2>/dev/null)
  OEM_INC=$(python3 -c "import json;print(json.load(open('$PROCESSING'))['oem_incident_id'])" 2>/dev/null)

  if [ -z "$HOST" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') Malformed trigger file ${PROCESSING}, leaving for manual review" >> "${LOGDIR}/host_unreachable_errors.log"
    continue
  fi

  RUNLOG="${LOGDIR}/host_unreachable_${BASENAME}_$(date +%Y%m%d_%H%M%S).log"

  ansible-playbook "${PLAYBOOK_DIR}/SNOW_OEM_resolve_host_unreachable.yml" \
    -e "target_host=${HOST}" \
    -e "alert_type=${ALERT_TYPE}" \
    -e "oem_incident_id=${OEM_INC}" \
    > "$RUNLOG" 2>&1

  RC=$?

  if [ $RC -eq 0 ]; then
    rm -f "$PROCESSING"
  else
    # Don't silently re-queue a failed playbook run (would risk a
    # retry storm on a genuinely broken run) - flag it for review.
    mv "$PROCESSING" "${PROCESSING}.failed" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') Playbook run failed (rc=$RC) for ${BASENAME}, see ${RUNLOG}" >> "${LOGDIR}/host_unreachable_errors.log"
  fi
done
