#!/bin/bash

ZONE="$1"
BOT_TOKEN="$2"
CHAT_ID="$3"
LOG="/home/ubuntu/oci-activity-logs/run_random_time.log"
JSON_LOG="/home/ubuntu/oci-activity-logs/oci_activity_log.json"
UTC_NOW=$(date -u '+%F %T')
STATE_FILE="/tmp/oci_random_state_$ZONE"
RANDOM_CHANCE=$(( RANDOM % 3 ))

# Fetch public IP and ISP info from ip-api
max_ip_retries=20
ip_attempt=0

while (( ip_attempt < max_ip_retries )); do
    response=$(curl -s --fail http://ip-api.com/json)
    
    if [[ $? -eq 0 ]]; then
       break  # Exit script if successful
    fi

    ((ip_attempt++))
    echo "Attempt $ip_attempt/$max_ip_retries failed to fetch public IP and ISP info from ip-api. Retrying in 2 seconds..."
    sleep 2
done

PUBLIC_IP=$(echo "$response" | grep -oP '"query":\s*"\K[^"]+')

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
    local msg="$1"
    local logcontent="$2"
    local max_retries=30
    local retry_delay=3  # seconds
    local attempt=1
    local response

    while (( attempt <= max_retries )); do
        # If the log is too long, send it as a file
        if [ ${#MSG} -gt 4096 ]; then
          echo "$logcontent" > /tmp/log_output.json
          response=$(curl -F chat_id="$CHAT_ID" \
               -F document=@/tmp/log_output.json \
               -F caption="📝 *OCI Activity Simulation*\nLog is too long, sending as a file instead." \
               "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument")
          rm -f /tmp/log_output.json
        else
          response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            -d parse_mode="Markdown" \
            -d text="$msg")
        fi

        # Check if the response contains "ok":true
        if [[ "$response" == *'"ok":true'* ]]; then
            echo "$UTC_NOW [$ZONE - $HOUR] ✅ Telegram message sent successfully." >> "$LOG"
            break  # success
        fi
        echo "$UTC_NOW [$ZONE - $HOUR] ❌ Attempt $attempt failed to send Telegram notification. Retrying in $retry_delay seconds..." >> "$LOG"
        echo "$response" >> "$LOG"
        sleep "$retry_delay"
        ((attempt++))
    done
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
      echo "$LOG"
      exit 0
    fi
  fi

  echo "$UTC_NOW [$ZONE - $HOUR] ✅ Running simulate_oci_user.sh" >> "$LOG"
  bash /home/ubuntu/simulate_oci_user.sh
  echo "$UTC_NOW [$ZONE - $HOUR] ✅ Done simulate_oci_user.sh" >> "$LOG"
  LOG_CONTENT=$(awk -v d="$(date -d '-30 minutes' '+%Y-%m-%d %H:%M:%S')" '$0 > d' "$JSON_LOG" | tail -n 15)

  MSG="🟢 *OCI Activity Simulation Triggered*
  ----------------------------
  *Zone:* $ZONE
  *Local Hour:* $HOUR
  *UTC:* $UTC_NOW
  *IP:* $PUBLIC_IP
  ----------------------------
📋 *Recent Log (last 5m):*
\`\`\`json
$LOG_CONTENT
\`\`\`"

  send_telegram "$MSG" "$LOG_CONTENT"

  # Update state file
  RUN_COUNT=$((RUN_COUNT + 1))
  echo "LAST_RUN_DATE=\"$DATE\"" > "$STATE_FILE"
  echo "RUN_COUNT=$RUN_COUNT" >> "$STATE_FILE"
else
  echo "$UTC_NOW [$ZONE - $HOUR] ⏭ Skipped (outside working hours or limit reached)" >> "$LOG"
  echo "$LOG"
fi
