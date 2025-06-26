#!/bin/bash

# === CONFIG ===
TENANCY_OCID=$(awk -F'=' '/^tenancy=/{print $2}' ~/.oci/config)
DAY=$(date +%d)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_DIR="$HOME/oci-activity-logs"
CSV_LOG="$LOG_DIR/oci_activity_log.csv"
JSON_LOG="$LOG_DIR/oci_activity_log.json"

mkdir -p "$LOG_DIR"

# === Get info ===
TENANCY_NAME=$(oci iam tenancy get --tenancy-id "$TENANCY_OCID" --query "data.name" --raw-output 2>/dev/null)
USER_ID=$(oci iam user list --query "data[0].id" --raw-output 2>/dev/null)
USER_EMAIL=$(oci iam user get --user-id "$USER_ID" --query "data.email" --raw-output 2>/dev/null)

# === Auto clean logs ===
RETENTION_DAYS=30
if [ -f "$CSV_LOG" ] && [ $(find "$CSV_LOG" -mtime +$RETENTION_DAYS) ]; then
  rm -f "$CSV_LOG"
  echo "timestamp,tenancy,user_email,action,description,status" > "$CSV_LOG"
fi
if [ -f "$JSON_LOG" ] && [ $(find "$JSON_LOG" -mtime +$RETENTION_DAYS) ]; then
  rm -f "$JSON_LOG"
  touch "$JSON_LOG"
fi

# === Logging ===
log_action() {
  local timestamp="$1"
  local action="$2"
  local description="$3"
  local status="$4"
  echo "$timestamp,$TENANCY_NAME,$USER_EMAIL,$action,$description,$status" >> "$CSV_LOG"
  echo "{\"timestamp\": \"$timestamp\", \"tenancy_name\": \"$TENANCY_NAME\", \"user_email\": \"$USER_EMAIL\", \"action\": \"$action\", \"description\": \"$description\", \"status\": \"$status\"}" >> "$JSON_LOG"
}

# === Random sleep between 2 jobs or inside jobs ===
sleep_random() {
  local min=${1:-3}
  local max=${2:-10}
  local sec=$((RANDOM % (max - min + 1) + min))
  sleep "$sec"
}

# === Run a single job ===
run_job() {
  case "$1" in
    job1_list_iam)
      log_action "$TIMESTAMP" "info" "List IAM info" "start"
      sleep_random 1 2
      oci iam region-subscription list && log_action "$TIMESTAMP" "region" "List region subscription" "success"
      sleep_random 1 2
      oci iam availability-domain list && log_action "$TIMESTAMP" "availability-domain" "List availability domains" "success"
      ;;

    job2_check_quota)
      AD=$(oci iam availability-domain list --query "data[0].name" --raw-output)
      sleep_random 1 2
      oci limits resource-availability get --service-name compute \
        --limit-name standard-e2-core-count \
        --availability-domain "$AD" \
        --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "quota" "Get compute quota" "success"
      ;;

    job3_bucket_test)
      BUCKET="bucket-test-$DAY-$RANDOM"
      log_action "$TIMESTAMP" "bucket-create" "Creating bucket $BUCKET" "start"
      EXP_DATE=$(date +%Y-%m-%d --date="+$((RANDOM % 5 + 3)) days")
      sleep_random 1 2
      oci os bucket create --name "$BUCKET" --compartment-id "$TENANCY_OCID" \
        --defined-tags "{\"auto\":{\"auto-delete\":\"true\",\"auto-delete-date\":\"$EXP_DATE\"}}" \
        && log_action "$TIMESTAMP" "bucket-create" "Created bucket with auto-delete" "success"

      echo "hello world $(date)" > test.txt
      sleep_random 1 2
      oci os object put --bucket-name "$BUCKET" --file test.txt && log_action "$TIMESTAMP" "upload" "Uploaded test.txt" "success"
      sleep_random 1 2
      oci os object delete --bucket-name "$BUCKET" --name test.txt --force && log_action "$TIMESTAMP" "delete-object" "Deleted test.txt" "success"
      sleep_random 1 2
      oci os bucket delete --bucket-name "$BUCKET" --force && log_action "$TIMESTAMP" "bucket-delete" "Deleted bucket" "success"
      rm -f test.txt
      ;;

    job4_cleanup_auto_delete)
      log_action "$TIMESTAMP" "auto-clean" "Scanning buckets with auto-delete=true" "start"
      NOW_DATE=$(date +%Y-%m-%d)
      BUCKETS=$(oci os bucket list --compartment-id "$TENANCY_OCID" \
        --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true']" --raw-output)

      for BUCKET_JSON in $BUCKETS; do
        NAME=$(echo "$BUCKET_JSON" | jq -r '.name')
        DELETE_DATE=$(echo "$BUCKET_JSON" | jq -r '."defined-tags".auto."auto-delete-date"')
        if [[ "$DELETE_DATE" < "$NOW_DATE" ]]; then
          oci os bucket delete --bucket-name "$NAME" --force
          log_action "$TIMESTAMP" "auto-delete" "Deleted bucket $NAME expired on $DELETE_DATE" "success"
          sleep_random 1 2
        fi
      done
      ;;

    job5_list_resources)
      log_action "$TIMESTAMP" "resource-view" "List common resources" "start"
      sleep_random 1 2
      oci network vcn list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "vcn-list" "List VCNs" "success"
      sleep_random 1 2
      oci network subnet list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "subnet-list" "List subnets" "success"
      sleep_random 1 2
      oci compute image list --compartment-id "$TENANCY_OCID" --all --query 'data[0:3].{name:"display-name"}' && log_action "$TIMESTAMP" "image-list" "List images" "success"
      ;;
  esac
}

# === Session Check ===
if oci iam user get --user-id "$USER_ID" &> /dev/null; then
  log_action "$TIMESTAMP" "session" "Get user info" "success"
else
  log_action "$TIMESTAMP" "session" "Get user info" "fail"
fi

# === Randomly select number of jobs to run ===
TOTAL_JOBS=5
COUNT=$((RANDOM % 5 + 1))  # 1–5 jobs per day

ALL_JOBS=(job1_list_iam job2_check_quota job3_bucket_test job4_cleanup_auto_delete job5_list_resources)

# Shuffle jobs
SHUFFLED=($(shuf -e "${ALL_JOBS[@]}"))

for i in $(seq 1 $COUNT); do
  run_job "${SHUFFLED[$((i-1))]}"
  sleep_random 3 10
done

echo "✅ OCI simulation done: $COUNT job(s) run"
echo "✅ Log saved to: $CSV_LOG and $JSON_LOG"
