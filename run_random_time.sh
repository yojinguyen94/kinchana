#!/bin/bash

ZONE="$1"
BOT_TOKEN="$2"
CHAT_ID="$3"
LOG_DIR="$HOME/oci-activity-logs"
LOG="$LOG_DIR/run_random_time.log"
JSON_LOG="$LOG_DIR/oci_activity_log.json"
UTC_NOW=$(date -u '+%F %T')
STATE_FILE="/tmp/oci_random_state_$ZONE"
RANDOM_CHANCE=$(( RANDOM % 10 ))

mkdir -p "$LOG_DIR"

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

ISP=$(echo "$response" | grep -oP '"isp":\s*"\K[^"]+')
ORG=$(echo "$response" | grep -oP '"org":\s*"\K[^"]+')
REGION=$(echo "$response" | grep -oP '"regionName":\s*"\K[^"]+')
CITY=$(echo "$response" | grep -oP '"city":\s*"\K[^"]+')
COUNTRY=$(echo "$response" | grep -oP '"country":\s*"\K[^"]+')
PUBLIC_IP=$(echo "$response" | grep -oP '"query":\s*"\K[^"]+')

get_hour_by_zone() {
  case "$ZONE" in
    vn)       date -u -d '+7 hour' +%H ;;
    fr)       date -u -d '+2 hour' +%H ;;
    us_east)  date -u -d '-4 hour' +%H ;;
    us_west)  date -u -d '-7 hour' +%H ;;
    uae)      date -u -d '+4 hour' +%H ;;
    br)       date -u -d '-3 hour' +%H ;;
    ma)       date -u -d '+1 hour' +%H ;;
    *)        echo "❌ Invalid time zone: $ZONE" >&2; exit 1 ;;
  esac
}

escape_markdown() {
  echo "$1" | sed -e 's/\\/\\\\/g' \
                  -e 's/\*/\\*/g' \
                  -e 's/_/\\_/g' \
                  -e 's/\[/\\[/g' \
                  -e 's/\]/\\]/g' \
                  -e 's/(/\\(/g' \
                  -e 's/)/\\)/g' \
                  -e 's/`/\\`/g' \
                  -e 's/>/\\>/g' \
                  -e 's/#/\\#/g' \
                  -e 's/\+/\\+/g' \
                  -e 's/-/\\-/g' \
                  -e 's/=/\\=/g' \
                  -e 's/!/\\!/g' \
                  -e 's/\./\\./g'
}

send_telegram() {
    local logcontent="$1"
    local max_retries=30
    local retry_delay=3  # seconds
    local attempt=1
    local response
    ZONE_ESC=$(escape_markdown "$ZONE")
    local MSG="🟢 *OCI Activity Simulation Triggered*
----------------------------
 *Zone:* $ZONE_ESC
 *Working Hours:* $HOUR
 *UTC:* $UTC_NOW
 *Run Count:* $RUN_COUNT
 *IP:* $PUBLIC_IP
 *ISP:* $ISP
 *Org:* $ORG
 *Region:* $REGION
 *City:* $CITY
 *Country:* $COUNTRY
----------------------------"
    while (( attempt <= max_retries )); do
        # If the log is too long, send it as a file
        if [ ${#logcontent} -gt 4096 ]; then
          echo "$logcontent" > /tmp/log_output.json
          local CAPTION="$MSG
📄 Log is too long, sending as a file instead.
"
          response=$(curl -F chat_id="$CHAT_ID" \
               -F document=@/tmp/log_output.json \
               -F caption="$CAPTION" \
               "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument")
          rm -f /tmp/log_output.json
        else
          local text_send="$MSG
📋 *Recent Log (last 30m):*
\`\`\`json
$logcontent
\`\`\`
"
          response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            -d parse_mode="Markdown" \
            -d text="$text_send")
        fi

        # Check if the response contains "ok":true
        if [[ "$response" == *'"ok":true'* ]]; then
            echo "$UTC_NOW [$ZONE - $HOUR - $RUN_COUNT - $RANDOM_CHANCE] ✅ Telegram message sent successfully." >> "$LOG"
            break  # success
        fi
        echo "$UTC_NOW [$ZONE - $HOUR - $RUN_COUNT - $RANDOM_CHANCE] ❌ Attempt $attempt failed to send Telegram notification. Retrying in $retry_delay seconds..." >> "$LOG"
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

if [[ "$HOUR" -ge 9 && "$HOUR" -le 18 && "$RUN_COUNT" -lt 5 && "$RANDOM_CHANCE" -eq 0 ]]; then
  if [ -f "$STATE_FILE" ]; then
    LAST_RUN_TS=$(stat -c %Y "$STATE_FILE")
    NOW_TS=$(date +%s)
    COOLDOWN=$(( RANDOM % 3601 + 7200 ))
    if (( NOW_TS - LAST_RUN_TS < COOLDOWN )); then
      COOLDOWN_MIN=$(( COOLDOWN / 60 ))
      echo "$UTC_NOW [$ZONE - $HOUR - $RUN_COUNT - $RANDOM_CHANCE] ⏭ Skipped (cooldown < ${COOLDOWN_MIN} min)" >> "$LOG"
      echo "$LOG"
      exit 0
    fi
  fi

  echo "$UTC_NOW [$ZONE - $HOUR - $RUN_COUNT - $RANDOM_CHANCE] ✅ Running simulate_oci_user.sh" >> "$LOG"
  bash /home/ubuntu/simulate_oci_user.sh
  echo "$UTC_NOW [$ZONE - $HOUR - $RUN_COUNT - $RANDOM_CHANCE] ✅ Done simulate_oci_user.sh" >> "$LOG"
  LOG_CONTENT=$(awk -v d="$(date -d '-30 minutes' '+%Y-%m-%d %H:%M:%S')" '$0 > d' "$JSON_LOG" | tail -n 12)

  # Update state file
  RUN_COUNT=$((RUN_COUNT + 1))
  echo "LAST_RUN_DATE=\"$DATE\"" > "$STATE_FILE"
  echo "RUN_COUNT=$RUN_COUNT" >> "$STATE_FILE"

  send_telegram "$LOG_CONTENT"
else
  echo "$UTC_NOW [$ZONE - $HOUR - $RUN_COUNT - $RANDOM_CHANCE] ⏭ Skipped (outside working hours or limit reached)" >> "$LOG"
  echo "$LOG"
fi
