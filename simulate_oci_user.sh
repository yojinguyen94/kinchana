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
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
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

# Tạo namespace auto nếu chưa có
TAG_NAMESPACE_ID=$(oci iam tag-namespace list --compartment-id "$TENANCY_OCID" \
  --query "data[?name=='auto'].id | [0]" --raw-output)

if [ -z "$TAG_NAMESPACE_ID" ]; then
  TAG_NAMESPACE_ID=$(oci iam tag-namespace create \
    --compartment-id "$TENANCY_OCID" \
    --name "auto" \
    --description "Auto delete simulation" \
    --query "data.id" --raw-output)
  log_action "$TIMESTAMP" "tag-namespace" "Created tag namespace auto" "success"
fi

ensure_tag() {
  local TAG_NAME="$1"
  local DESC="$2"
  EXISTS=$(oci iam tag list --tag-namespace-id "$TAG_NAMESPACE_ID" \
    --query "data[?name=='$TAG_NAME'].id | [0]" --raw-output)
  if [ -z "$EXISTS" ]; then
    oci iam tag create \
      --tag-namespace-id "$TAG_NAMESPACE_ID" \
      --name "$TAG_NAME" \
      --description "$DESC" \
      --is-cost-tracking false > /dev/null
    log_action "$TIMESTAMP" "tag" "Created tag $TAG_NAME" "success"
  fi
}

ensure_tag "auto-delete" "Mark for auto deletion"
ensure_tag "auto-delete-date" "Scheduled auto delete date"

# === Run a single job ===
run_job() {
  case "$1" in
    job1_list_iam)
      log_action "$TIMESTAMP" "info" "List IAM info" "start"
      sleep_random 1 10
      oci iam region-subscription list && log_action "$TIMESTAMP" "region" "List region subscription" "success"
      sleep_random 1 20
      oci iam availability-domain list && log_action "$TIMESTAMP" "availability-domain" "List availability domains" "success"
      ;;

    job2_check_quota)
      AD=$(oci iam availability-domain list --query "data[0].name" --raw-output)
      sleep_random 1 30
      oci limits resource-availability get --service-name compute \
        --limit-name standard-e2-core-count \
        --availability-domain "$AD" \
        --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "quota" "Get compute quota" "success"
      ;;

    job3_bucket_test)
      BUCKET="bucket-test-$DAY-$RANDOM"
      DELETE_DATE=$(date +%Y-%m-%d --date="+$((RANDOM % 7 + 3)) days")
      log_action "$TIMESTAMP" "bucket-create" "Creating bucket $BUCKET with auto-delete" "start"
      oci os bucket create \
        --name "$BUCKET" \
        --compartment-id "$TENANCY_OCID" \
        --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
        && log_action "$TIMESTAMP" "bucket-create" "Created $BUCKET with auto-delete-date=$DELETE_DATE" "success" \
        || log_action "$TIMESTAMP" "bucket-create" "Failed to create $BUCKET" "fail"
      filetest="test-$DAY-$RANDOM.txt"
      echo "test $(date)" > $filetest
      sleep_random 1 10
      oci os object put --bucket-name "$BUCKET" --file $filetest \
        && log_action "$TIMESTAMP" "upload" "Uploaded $filetest to $BUCKET" "success" \
        || log_action "$TIMESTAMP" "upload" "Failed to upload to $BUCKET" "fail"
      sleep_random 1 20
      oci os object delete --bucket-name "$BUCKET" --name $filetest --force \
        && log_action "$TIMESTAMP" "delete-object" "Deleted $filetest from $BUCKET" "success" \
        || log_action "$TIMESTAMP" "delete-object" "Failed to delete $filetest from $BUCKET" "fail"
      sleep_random 1 20
      if oci os bucket get --bucket-name "$BUCKET" &>/dev/null; then
        oci os bucket delete --bucket-name "$BUCKET" --force \
          && log_action "$TIMESTAMP" "bucket-delete" "Deleted bucket $BUCKET" "success" \
          || log_action "$TIMESTAMP" "bucket-delete" "Failed to delete bucket $BUCKET" "fail"
      else
        log_action "$TIMESTAMP" "bucket-delete" "Bucket $BUCKET does not exist" "fail"
      fi
      rm -f $filetest
      ;;

    job4_cleanup_auto_delete)
      log_action "$TIMESTAMP" "auto-delete-scan" "Scanning for expired buckets with auto-delete=true" "start"
      TODAY=$(date +%Y-%m-%d)
      BUCKETS=$(oci os bucket list --compartment-id "$TENANCY_OCID" \
        --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true'].name" \
        --raw-output)
      for b in $BUCKETS; do
        DELETE_DATE=$(oci os bucket get --bucket-name "$b" \
          --query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          --raw-output 2>/dev/null)
        sleep_random 1 10
        if [[ "$DELETE_DATE" < "$TODAY" ]]; then
          if oci os bucket get --bucket-name "$b" &>/dev/null; then
            oci os bucket delete --bucket-name "$b" --force \
              && log_action "$TIMESTAMP" "auto-delete" "Deleted expired bucket $b (expired: $DELETE_DATE)" "success" \
              || log_action "$TIMESTAMP" "auto-delete" "Failed to delete bucket $b (expired: $DELETE_DATE)" "fail"
          else
            log_action "$TIMESTAMP" "auto-delete" "Bucket $b not found for deletion" "fail"
          fi
        fi
      done
      ;;

    job5_list_resources)
      log_action "$TIMESTAMP" "resource-view" "List common resources" "start"
      sleep_random 1 30
      oci network vcn list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "vcn-list" "List VCNs" "success"
      sleep_random 1 90
      oci network subnet list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "subnet-list" "List subnets" "success"
      sleep_random 1 60
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
COUNT=$((RANDOM % TOTAL_JOBS + 1))
ALL_JOBS=(job1_list_iam job2_check_quota job3_bucket_test job4_cleanup_auto_delete job5_list_resources)
SHUFFLED=($(shuf -e "${ALL_JOBS[@]}"))

for i in $(seq 1 $COUNT); do
  run_job "${SHUFFLED[$((i-1))]}"
  sleep_random 3 20
done

echo "✅ OCI simulation done: $COUNT job(s) run"
echo "✅ Log saved to: $CSV_LOG and $JSON_LOG"
log_action "$TIMESTAMP" "✅ OCI simulation done: $COUNT job(s) run"
