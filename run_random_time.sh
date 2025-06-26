#!/bin/bash

ZONE="$1"
BOT_TOKEN="$2"
CHAT_ID="$3"
LOG="/home/ubuntu/oci-activity-logs/run_random_time.log"
JSON_LOG="/home/ubuntu/oci-activity-logs/oci_activity_log.json"
UTC_NOW=$(date -u '+%F %T')
HOSTNAME=$(hostname)
STATE_FILE="/tmp/oci_random_state_$ZONE"

get_hour_by_zone() {
  case "$ZONE" in
    vn)       date -u -d '+7 hour' +%H ;;
    fr)       date -u -d '+2 hour' +%H ;;
    us_east)  date -u -d '-4 hour' +%H ;;
    us_west)  date -u -d '-7 hour' +%H ;;
    *)        echo "❌ Invalid time zone: $ZONE" >&2; exit 1 ;;
  esac
}

send_telegram() {
  local msg=$1
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$msg"
}

# Get local hour and date
HOUR=$(get_hour_by_zone)
DATE=$(date +%Y-%m-%d)

# Load previous state
if [ -f "$STATE_FILE" ]; then
  source "$STATE_FILE"
fi

# Reset counter if new day
if [ "$LAST_RUN_DATE" != "$DATE" ]; then
  RUN_COUNT=0
fi

if [[ "$HOUR" -ge 9 && "$HOUR" -le 18 && "$RUN_COUNT" -lt 5 ]]; then
  # Enforce 1-hour cooldown
  if [ -f "$STATE_FILE" ]; then
    LAST_RUN_TS=$(stat -c %Y "$STATE_FILE")
    NOW_TS=$(date +%s)
    if (( NOW_TS - LAST_RUN_TS < 3600 )); then
      echo "$UTC_NOW [$ZONE - $HOUR] ⏭ Skipped (cooldown < 1h)" >> "$LOG"
      exit 0
    fi
  fi

  echo "$UTC_NOW [$ZONE - $HOUR] ✅ Running simulate_oci_user.sh" >> "$LOG"
  bash /home/ubuntu/simulate_oci_user.sh

  LOG_CONTENT=$(awk -v d="$(date -d '-5 minutes' '+%Y-%m-%d %H:%M:%S')" '$0 > d' "$JSON_LOG" | tail -n 20)

  MSG="\U0001F7E2 *OCI Activity Simulation Triggered*
*Zone:* $ZONE
*Local Hour:* $HOUR
*UTC:* $UTC_NOW
*Host:* $HOSTNAME

\U0001F4CB *Recent Log (last 5m):*
\`\`\`json
$LOG_CONTENT
\`\`\`"

  send_telegram "$MSG"

  # Update state file
  RUN_COUNT=$((RUN_COUNT + 1))
  echo "LAST_RUN_DATE=\"$DATE\"" > "$STATE_FILE"
  echo "RUN_COUNT=$RUN_COUNT" >> "$STATE_FILE"
else
  echo "$UTC_NOW [$ZONE - $HOUR] ⏭ Skipped (outside working hours or limit reached)" >> "$LOG"
fi
