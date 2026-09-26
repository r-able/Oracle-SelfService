#!/bin/bash
# Runs SNOW_UNR_dispatcher.yml; one run at a time.
LOG=/var/log/ansible/SNOW_UNR_dispatcher.log
exec 9>/tmp/snow_unr_dispatcher.lock
flock -n 9 || { echo "$(date '+%F %T') previous run still active - skipping" >> "$LOG"; exit 0; }
cd /etc/ansible/OEM || exit 1
echo "=== $(date '+%F %T') run start ===" >> "$LOG"
ANSIBLE_COLLECTIONS_PATH=/etc/ansible/collections ansible-playbook SNOW_UNR_dispatcher.yml >> "$LOG" 2>&1
RC=$?
echo "=== $(date '+%F %T') run end rc=$RC ===" >> "$LOG"
