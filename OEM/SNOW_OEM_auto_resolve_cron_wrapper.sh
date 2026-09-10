#!/bin/bash
# SNOW_OEM_auto_resolve_cron_wrapper.sh
# Cron-safe wrapper: prevents overlapping runs via a PID lock file.
# Suggested schedule: every 2-5 minutes.

LOCKFILE="/tmp/SNOW_OEM_auto_resolve.lock"
PLAYBOOK="/etc/ansible/OEM/SNOW_OEM_oracle_auto_resolve.yml"
LOGFILE="/var/log/ansible/SNOW_OEM_auto_resolve.log"

cleanup() {
    rm -f "$LOCKFILE"
}
trap cleanup EXIT INT TERM

if [ -f "$LOCKFILE" ]; then
    OLD_PID=$(cat "$LOCKFILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Previous run (PID $OLD_PID) still active, skipping." >> "$LOGFILE"
        exit 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Stale lock file found (PID $OLD_PID not running), removing." >> "$LOGFILE"
        rm -f "$LOCKFILE"
    fi
fi

echo $$ > "$LOCKFILE"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting OEM auto-resolve run (PID $$)." >> "$LOGFILE"
ansible-playbook "$PLAYBOOK" >> "$LOGFILE" 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') - Run complete, exit code $?." >> "$LOGFILE"
