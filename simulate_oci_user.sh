#!/bin/bash

# === CONFIG ===
TENANCY_OCID=$(awk -F'=' '/^tenancy=/{print $2}' ~/.oci/config)
DAY=$(date +%d)
LOG_DIR="$HOME/oci-activity-logs"
CSV_LOG="$LOG_DIR/oci_activity_log.csv"
JSON_LOG="$LOG_DIR/oci_activity_log.json"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# === AUTO-CLEAN OLD LOG FILES ===
# === CONFIGURE RETENTION PERIOD (DAYS) ===
RETENTION_DAYS=30  # change to 7 if you prefer

# === DELETE LOG FILES IF OLDER THAN RETENTION PERIOD ===
if [ -f "$CSV_LOG" ] && [ $(find "$CSV_LOG" -mtime +$RETENTION_DAYS) ]; then
    echo "🗑 Deleting old CSV_LOG older than $RETENTION_DAYS days: $CSV_LOG"
    rm -f "$CSV_LOG"
    echo "timestamp,action,description,status" > "$CSV_LOG"
fi

if [ -f "$JSON_LOG" ] && [ $(find "$JSON_LOG" -mtime +$RETENTION_DAYS) ]; then
    echo "🗑 Deleting old JSON_LOG older than $RETENTION_DAYS days: $JSON_LOG"
    rm -f "$JSON_LOG"
    touch "$JSON_LOG"
fi

# === FUNCTION: Log activity ===
log_action() {
  local timestamp="$1"
  local action="$2"
  local description="$3"
  local status="$4"

  echo "$timestamp,$action,$description,$status" >> "$CSV_LOG"
  echo "{\"timestamp\": \"$timestamp\", \"action\": \"$action\", \"description\": \"$description\", \"status\": \"$status\"}" >> "$JSON_LOG"
}

# === INIT ===
mkdir -p "$LOG_DIR"
if [ ! -f "$CSV_LOG" ]; then
  echo "timestamp,action,description,status" > "$CSV_LOG"
fi

echo "🟢 Starting OCI simulation: $TIMESTAMP"

# === Step 1: session ===
if oci iam user get --user-id "$(awk -F'=' '/^user=/{print $2}' ~/.oci/config)" &> /dev/null; then
  log_action "$TIMESTAMP" "session" "Get current user info" "success"
else
  log_action "$TIMESTAMP" "session" "Get current user info" "fail"
fi

# === Step 2: varies by day ===
if (( $DAY % 2 == 0 )); then
  log_action "$TIMESTAMP" "info" "List IAM and region info" "start"

  oci iam tenancy get --tenancy-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "tenancy" "Get tenancy info" "success"
  oci iam region-subscription list && log_action "$TIMESTAMP" "region" "List region subscription" "success"
  oci iam availability-domain list && log_action "$TIMESTAMP" "availability-domain" "List availability domains" "success"

  AD=$(oci iam availability-domain list --query "data[0].name" --raw-output)
  oci limits resource-availability get \
    --service-name compute \
    --limit-name standard-e2-core-count \
    --availability-domain "$AD" \
    --compartment-id "$TENANCY_OCID" \
    && log_action "$TIMESTAMP" "quota" "Get compute quota" "success"

  oci os bucket list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "bucket-list" "List buckets" "success"

elif (( $DAY % 3 == 0 )); then
  BUCKET="bucket-day$DAY-$RANDOM"
  echo "📁 Creating bucket: $BUCKET"
  log_action "$TIMESTAMP" "bucket-create" "Creating bucket $BUCKET" "start"
  oci os bucket create --name "$BUCKET" --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "bucket-create" "Created $BUCKET" "success"

  echo "Creating test.txt"
  echo "oracle test $(date)" > test.txt

  oci os object put --bucket-name "$BUCKET" --file test.txt && log_action "$TIMESTAMP" "upload" "Upload test.txt to $BUCKET" "success"
  oci os object delete --bucket-name "$BUCKET" --name test.txt --force && log_action "$TIMESTAMP" "delete-object" "Delete test.txt" "success"
  oci os bucket delete --bucket-name "$BUCKET" --force && log_action "$TIMESTAMP" "bucket-delete" "Delete $BUCKET" "success"

  rm -f test.txt

else
  oci network vcn list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "vcn-list" "List VCN" "success"
  oci network subnet list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "subnet-list" "List subnet" "success"
  oci compute image list --compartment-id "$TENANCY_OCID" --all --query 'data[0:5].{name: "display-name"}' && log_action "$TIMESTAMP" "image-list" "List compute images" "success"
fi

echo "✅ Log saved to: $CSV_LOG and $JSON_LOG"
