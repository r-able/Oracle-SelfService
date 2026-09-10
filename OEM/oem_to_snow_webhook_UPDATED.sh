#!/bin/bash
# /u01/app/oracle/emcli/oem_to_snow_webhook.sh
# Invoked by OEM as an OS Command notification method.
# Variable mapping confirmed via real OEM env dump captured 2026-09-06
# (see /tmp/oem_webhook_debug.log) - do not revert to guessed variable names.

LOGFILE=/tmp/oem_webhook_debug.log
SNOW_URL="https://dev204190.service-now.com/api/2177274/oem_alr_webhook"
SNOW_USER="hyperautomation.platform"
SNOW_CRED_FILE="/home/oracle/.oem_snow/snow_cred"

# Always capture the full environment OEM passed us, so any future
# unconfirmed cases can be inspected later.
echo "=== $(date) === env dump ===" >> "$LOGFILE"
env >> "$LOGFILE"
echo "=== end env dump ===" >> "$LOGFILE"

if [ ! -r "$SNOW_CRED_FILE" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Cannot read credential file $SNOW_CRED_FILE" >> "$LOGFILE"
    exit 1
fi

SNOW_PASS=$(cat "$SNOW_CRED_FILE")

# RULE_NAME arrives as "url,name" - keep just the name.
RULE_NAME_ONLY=$(echo "$RULE_NAME" | awk -F',' '{print $NF}')

# SEVERITY_CODE=CLEAR is the real, confirmed clear indicator (verified
# against an actual OEM clear event 2026-09-07). NOTIF_TYPE does NOT
# change on clear - it stays NOTIF_NORMAL for both firing and clear,
# so it cannot be used to distinguish them.
if [ "$SEVERITY_CODE" = "CLEAR" ]; then
    EVENT_TYPE="CLEAR"
else
    EVENT_TYPE="FIRING"
fi

# KEY_VALUE is only populated for keyed (per-resource) metrics such as
# Tablespace Space Used (%), where it holds the tablespace name. Host-level
# metrics such as CPU Utilization have no key - KEY_VALUE arrives empty in
# that case. Fall back to METRIC_COLUMN_NLS (OEM's human-readable metric
# name) so metric_name is never blank for a keyless alert type.
if [ -n "$KEY_VALUE" ]; then
    METRIC_NAME_VALUE="$KEY_VALUE"
else
    METRIC_NAME_VALUE="$METRIC_COLUMN_NLS"
fi

HTTP_CODE=$(curl -s -o /tmp/oem_snow_response.log -w "%{http_code}" -X POST "$SNOW_URL" \
  -u "${SNOW_USER}:${SNOW_PASS}" \
  -H "Content-Type: application/json" \
  -d @- <<EOF
{
  "target_name": "$TARGET_NAME",
  "target_type": "$TARGET_TYPE",
  "host": "$HOST_NAME",
  "metric_name": "$METRIC_NAME_VALUE",
  "metric_group": "$METRIC_GROUP",
  "metric_value": "$VALUE",
  "severity": "$SEVERITY_CODE",
  "message": "$MESSAGE",
  "rule_name": "$RULE_NAME_ONLY",
  "event_type": "$EVENT_TYPE",
  "collection_time": "$EVENT_REPORTED_TIME",
  "notification_id": "$ASSOC_INCIDENT_ID"
}
EOF
)

echo "$(date '+%Y-%m-%d %H:%M:%S') - Webhook call completed, HTTP status: $HTTP_CODE, event_type=$EVENT_TYPE, metric_group=$METRIC_GROUP, response saved to /tmp/oem_snow_response.log" >> "$LOGFILE"

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    exit 0
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Non-2xx response ($HTTP_CODE)" >> "$LOGFILE"
    exit 1
fi
