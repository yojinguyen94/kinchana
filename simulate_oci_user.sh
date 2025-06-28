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
USERNAME=$(oci iam user get --user-id "$USER_ID" --query "data.name" --raw-output 2>/dev/null)
REGION=$(awk -F'=' '/^region=/{print $2}' ~/.oci/config)
HOME_REGION=$(oci iam region-subscription list \
  --tenancy-id "$TENANCY_OCID" \
  --query 'data[?"is-home-region"==`true`]."region-name" | [0]' \
  --raw-output 2>/dev/null)

if [[ -z "$HOME_REGION" ]]; then
  HOME_REGION="$REGION"
fi

# === Auto clean logs ===
RETENTION_DAYS=30
if [ -f "$CSV_LOG" ] && [ $(find "$CSV_LOG" -mtime +$RETENTION_DAYS) ]; then
  rm -f "$CSV_LOG"
  echo "timestamp,tenancy,username,region,action,description,status" > "$CSV_LOG"
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
  echo "$timestamp,$TENANCY_NAME,$USERNAME,$REGION,$action,$description,$status" >> "$CSV_LOG"
  echo "{\"timestamp\": \"$timestamp\", \"tenancy_name\": \"$TENANCY_NAME\", \"username\": \"$USERNAME\", \"region\": \"$REGION\", \"action\": \"$action\", \"description\": \"$description\", \"status\": \"$status\"}" >> "$JSON_LOG"
}

# === Random sleep between 2 jobs or inside jobs ===
sleep_random() {
  local min=${1:-3}
  local max=${2:-10}
  local sec=$((RANDOM % (max - min + 1) + min))
  sleep "$sec"
}

ensure_namespace_auto() {
  TAG_NAMESPACE_ID=$(oci iam tag-namespace list --compartment-id "$TENANCY_OCID" \
	--region "$HOME_REGION" \
    --query "data[?name=='auto'].id | [0]" --raw-output)
  
  if [ -z "$TAG_NAMESPACE_ID" ]; then
    TAG_NAMESPACE_ID=$(oci iam tag-namespace create \
      --compartment-id "$TENANCY_OCID" \
      --name "auto" \
      --description "Auto delete simulation" \
      --region "$HOME_REGION" \
      --query "data.id" --raw-output)
    log_action "$TIMESTAMP" "tag-namespace" "Created tag namespace auto" "success"
  fi
}

ensure_tag() {
  local TAG_NAME="$1"
  local DESC="$2"
  EXISTS=$(oci iam tag list --tag-namespace-id "$TAG_NAMESPACE_ID" \
	--region "$HOME_REGION" \
    --query "data[?name=='$TAG_NAME'].id | [0]" --raw-output)
  if [ -z "$EXISTS" ]; then
    oci iam tag create \
      --tag-namespace-id "$TAG_NAMESPACE_ID" \
      --name "$TAG_NAME" \
      --description "$DESC" \
      --region "$HOME_REGION" \
      --is-cost-tracking false > /dev/null
    log_action "$TIMESTAMP" "tag" "Created tag $TAG_NAME" "success"
  fi
}

parse_json_array_string() {
  local json_array_string="$1"
  echo "$json_array_string" | sed 's/^\[//;s/\]$//' | tr -d '"' | tr ',' '\n'
}

parse_json_array() {
  local json_input="$1"
  echo "$json_input" | tr -d '\n' | sed -E 's/^\[//; s/\]$//' | sed 's/},[[:space:]]*{/\}\n\{/g' | while IFS= read -r line || [[ -n "$line" ]]; do
    ID=$(echo "$line" | grep -oP '"id"\s*:\s*"\K[^"]+')
    NAME=$(echo "$line" | grep -oP '"name"\s*:\s*"\K[^"]+')
    if [[ -n "$ID" && -n "$NAME" ]]; then
      echo "$ID|$NAME"
    fi
  done
}

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
      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"
      BUCKET="bucket-test-$DAY-$RANDOM"
      DELETE_DATE=$(date +%Y-%m-%d --date="+$((RANDOM % 5)) days")
      log_action "$TIMESTAMP" "bucket-create" "Creating bucket $BUCKET with auto-delete" "start"
      oci os bucket create \
        --name "$BUCKET" \
        --compartment-id "$TENANCY_OCID" \
        --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
        && log_action "$TIMESTAMP" "bucket-create" "Created $BUCKET with auto-delete-date=$DELETE_DATE" "success" \
        || log_action "$TIMESTAMP" "bucket-create" "❌ Failed to create $BUCKET" "fail"
      filetest="test-$DAY-$RANDOM.txt"
      echo "test $(date)" > $filetest
      sleep_random 1 10
      oci os object put --bucket-name "$BUCKET" --file $filetest \
        && log_action "$TIMESTAMP" "upload" "Uploaded $filetest to $BUCKET" "success" \
        || log_action "$TIMESTAMP" "upload" "❌ Failed to upload to $BUCKET" "fail"
      sleep_random 1 10
      #oci os object delete --bucket-name "$BUCKET" --name $filetest --force \
      #  && log_action "$TIMESTAMP" "delete-object" "Deleted $filetest from $BUCKET" "success" \
      #  || log_action "$TIMESTAMP" "delete-object" "Failed to delete $filetest from $BUCKET" "fail"
      #sleep_random 1 20
      #if oci os bucket get --bucket-name "$BUCKET" &>/dev/null; then
      #  oci os bucket delete --bucket-name "$BUCKET" --force \
      #    && log_action "$TIMESTAMP" "bucket-delete" "Deleted bucket $BUCKET" "success" \
      #    || log_action "$TIMESTAMP" "bucket-delete" "Failed to delete bucket $BUCKET" "fail"
      #else
      #  log_action "$TIMESTAMP" "bucket-delete" "Bucket $BUCKET does not exist" "fail"
      #fi
      rm -f $filetest
      ;;

    job4_cleanup_auto_delete)
      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"
      log_action "$TIMESTAMP" "auto-delete-scan" "Scanning for expired buckets with auto-delete=true" "start"
      TODAY=$(date +%Y-%m-%d)
      BUCKETS=$(oci os bucket list --compartment-id "$TENANCY_OCID" \
                --query "data[].name" \
                --raw-output)
      
      if [[ -z "$BUCKETS" || "$BUCKETS" == "[]" ]]; then
        log_action "$TIMESTAMP" "auto-delete-bucket" "❌ No bucket found" "404"
      else
        for b in $(parse_json_array_string "$BUCKETS"); do
            DELETE_DATE=$(oci os bucket get --bucket-name "$b" \
                          --query 'data."defined-tags".auto."auto-delete-date"' \
                          --raw-output 2>/dev/null)
            log_action "$TIMESTAMP" "auto-delete-bucket" "Found auto-delete BUCKET: $b - DELETE_DATE: $DELETE_DATE" "info"
            sleep_random 1 10
            if [[ -n "$DELETE_DATE" && "$DELETE_DATE" < "$TODAY" ]]; then
              log_action "$TIMESTAMP" "delete-object" "🗑️ Deleting all objects in $b..." "start"
            
              OBJECTS=$(oci os object list --bucket-name "$b" --query "data[].name" --raw-output)
              for obj in $(parse_json_array_string "$OBJECTS"); do
                oci os object delete --bucket-name "$b" --name "$obj" --force \
                  && log_action "$TIMESTAMP" "delete-object" "Deleted "$obj" from $b" "success" \
                  || log_action "$TIMESTAMP" "delete-object" "❌ Failed to delete "$obj" from $b" "fail"
                sleep_random 2 5
              done
              sleep_random 2 10
              oci os bucket delete --bucket-name "$b" --force \
                && log_action "$TIMESTAMP" "auto-delete" "Deleted expired bucket $b (expired: $DELETE_DATE)" "success" \
                || log_action "$TIMESTAMP" "auto-delete" "❌ Failed to delete bucket $b (expired: $DELETE_DATE)" "fail"
            fi
        done
      fi
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
    
    job6_create_vcn)
      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"

      VCN_NAME="vcn-test-$DAY-$RANDOM"
      SUBNET_NAME="subnet-test-$DAY-$RANDOM"
      DELETE_DATE=$(date +%Y-%m-%d --date="+$((RANDOM % 3)) days")

      log_action "$TIMESTAMP" "vcn-create" "Creating VCN $VCN_NAME with auto-delete" "start"
      VCN_ID=$(oci network vcn create \
        --cidr-block "10.0.0.0/16" \
        --compartment-id "$TENANCY_OCID" \
        --display-name "$VCN_NAME" \
        --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
        --query "data.id" --raw-output 2>/dev/null)

      if [ -n "$VCN_ID" ]; then
        log_action "$TIMESTAMP" "vcn-create" "Created VCN $VCN_NAME ($VCN_ID)" "success"
        sleep_random 2 10

        SUBNET_ID=$(oci network subnet create \
          --vcn-id "$VCN_ID" \
          --cidr-block "10.0.1.0/24" \
          --compartment-id "$TENANCY_OCID" \
          --display-name "$SUBNET_NAME" \
          --availability-domain "$(oci iam availability-domain list --query "data[0].name" --raw-output)" \
          --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
          --query "data.id" --raw-output 2>/dev/null)

        if [ -n "$SUBNET_ID" ]; then
          log_action "$TIMESTAMP" "subnet-create" "Created Subnet $SUBNET_NAME" "success"
        else
          log_action "$TIMESTAMP" "subnet-create" "❌ Failed to create Subnet $SUBNET_NAME" "fail"
        fi
      else
        log_action "$TIMESTAMP" "vcn-create" "❌ Failed to create VCN $VCN_NAME" "fail"
      fi
      ;;

    job7_create_volume)
      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"
      VOL_NAME="volume-test-$DAY-$RANDOM"
      DELETE_DATE=$(date +%Y-%m-%d --date="+$((RANDOM % 3)) days")

      log_action "$TIMESTAMP" "volume-create" "Creating volume $VOL_NAME with auto-delete" "start"
      VOL_ID=$(oci bv volume create \
        --compartment-id "$TENANCY_OCID" \
        --display-name "$VOL_NAME" \
        --size-in-gbs 50 \
        --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
        --availability-domain "$(oci iam availability-domain list --query "data[0].name" --raw-output)" \
        --query "data.id" --raw-output 2>/dev/null)

      if [ -n "$VOL_ID" ]; then
        log_action "$TIMESTAMP" "volume-create" "Created volume $VOL_NAME ($VOL_ID)" "success"
      else
        log_action "$TIMESTAMP" "volume-create" "❌ Failed to create volume $VOL_NAME" "fail"
      fi
      ;;

    job8_check_public_ip)
      log_action "$TIMESTAMP" "network-info" "Checking public IPs" "start"
      sleep_random 2 8
      oci network public-ip list \
        --scope REGION \
        --compartment-id "$TENANCY_OCID" \
        --query "data[].\"ip-address\"" --raw-output \
        && log_action "$TIMESTAMP" "public-ip" "Listed public IPs" "success" \
        || log_action "$TIMESTAMP" "public-ip" "❌ Failed to list public IPs" "fail"
      ;;

    job9_scan_auto_delete_resources)
      ensure_namespace_auto
      log_action "$TIMESTAMP" "scan-auto-delete" "Scanning resources with auto-delete tag" "start"
      TAGGED_BUCKETS=$(oci os bucket list --compartment-id "$TENANCY_OCID" \
        --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true'].name" --raw-output)
      for v in $(parse_json_array_string "$TAGGED_BUCKETS"); do
        log_action "$TIMESTAMP" "scan" "Found auto-delete bucket: $b" "info"
      done
      
      TAGGED_VCNS=$(oci network vcn list --compartment-id "$TENANCY_OCID" \
        --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true'].\"display-name\"" --raw-output)
      for v in $(parse_json_array_string "$TAGGED_VCNS"); do
        log_action "$TIMESTAMP" "scan" "Found auto-delete VCN: $v" "info"
      done

      TAGGED_VOLS=$(oci bv volume list --compartment-id "$TENANCY_OCID" \
        --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true'].\"display-name\"" --raw-output)
      for v in $(parse_json_array_string "$TAGGED_VOLS"); do
        log_action "$TIMESTAMP" "scan" "Found auto-delete Volume: $v" "info"
      done
      ;;

    job10_cleanup_vcn_and_volumes)
      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"
      TODAY=$(date +%Y-%m-%d)

      log_action "$TIMESTAMP" "auto-delete-vcn" "🔍 Scanning for expired VCNs" "start"

      VCNs=$(oci network vcn list --compartment-id "$TENANCY_OCID" \
        --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true'].{name:\"display-name\",id:id}" \
        --raw-output)

      parse_json_array "$VCNs" | while IFS='|' read -r VCN_ID VCN_NAME; do
        DELETE_DATE=$(oci network vcn get --vcn-id "$VCN_ID" \
          --query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          --raw-output 2>/dev/null)
        log_action "$TIMESTAMP" "auto-delete-vcn" "Found auto-delete VCN: $VCN_NAME - DELETE_DATE: $DELETE_DATE" "info"
        if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) ]]; then
          log_action "$TIMESTAMP" "auto-delete-vcn" "Preparing to delete VCN $VCN_NAME" "start"
          SUBNETS=$(oci network subnet list --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" \
            --query "data[].id" --raw-output)
          for subnet_id in $(parse_json_array_string "$SUBNETS"); do
            oci network subnet delete --subnet-id "$subnet_id" --force \
              && log_action "$TIMESTAMP" "delete-subnet" "Deleted subnet $subnet_id in $VCN_NAME" "success" \
              || log_action "$TIMESTAMP" "delete-subnet" "❌ Failed to delete subnet $subnet_id" "fail"
            sleep_random 2 10
          done

          
          IGWS=$(oci network internet-gateway list --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" \
            --query "data[].id" --raw-output)
          for igw_id in $(parse_json_array_string "$IGWS"); do
            oci network internet-gateway delete --ig-id "$igw_id" --force \
              && log_action "$TIMESTAMP" "delete-igw" "Deleted IGW $igw_id in $VCN_NAME" "success" \
              || log_action "$TIMESTAMP" "delete-igw" "❌ Failed to delete IGW $igw_id" "fail"
          done
	  sleep_random 2 10
          
          ROUTES=$(oci network route-table list --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" \
            --query "data[].id" --raw-output)
          for route_id in $(parse_json_array_string "$ROUTES"); do
            oci network route-table delete --rt-id "$route_id" --force \
              && log_action "$TIMESTAMP" "delete-route" "Deleted Route Table $route_id" "success" \
              || log_action "$TIMESTAMP" "delete-route" "❌ Failed to delete Route Table $route_id" "fail"
          done

          sleep_random 2 10
          oci network vcn delete --vcn-id "$VCN_ID" --force \
            && log_action "$TIMESTAMP" "auto-delete-vcn" "Deleted VCN $VCN_NAME (expired: $DELETE_DATE)" "success" \
            || log_action "$TIMESTAMP" "auto-delete-vcn" "❌ Failed to delete VCN $VCN_NAME" "fail"
        fi
      done

      sleep_random 2 10
      log_action "$TIMESTAMP" "auto-delete-volume" "🔍 Scanning for expired block volumes" "start"

      VOLUMES=$(oci bv volume list --compartment-id "$TENANCY_OCID" \
        --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true'].{name:\"display-name\",id:id}" \
        --raw-output)

      parse_json_array "$VOLUMES" | while IFS='|' read -r VOL_ID VOL_NAME; do
        DELETE_DATE=$(oci bv volume get --volume-id "$VOL_ID" \
          --query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          --raw-output 2>/dev/null)
        log_action "$TIMESTAMP" "auto-delete-volume" "Found auto-delete VOLUME: $VOL_NAME - DELETE_DATE: $DELETE_DATE" "info"
        if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) ]]; then
          sleep_random 1 10
          oci bv volume delete --volume-id "$VOL_ID" --force \
            && log_action "$TIMESTAMP" "auto-delete-volume" "Deleted volume $VOL_NAME (expired: $DELETE_DATE)" "success" \
            || log_action "$TIMESTAMP" "auto-delete-volume" "❌ Failed to delete volume $VOL_NAME" "fail"
        fi
      done
      ;;
  esac
}

# === Session Check ===
if oci iam user get --user-id "$USER_ID" &> /dev/null; then
  log_action "$TIMESTAMP" "session" "Get user info" "success"
else
  log_action "$TIMESTAMP" "session" "❌ Get user info" "fail"
fi

# === Randomly select number of jobs to run ===
TOTAL_JOBS=10
COUNT=$((RANDOM % TOTAL_JOBS + 1))
ALL_JOBS=(job1_list_iam job2_check_quota job3_bucket_test job4_cleanup_auto_delete job5_list_resources job6_create_vcn job7_create_volume job8_check_public_ip job9_scan_auto_delete_resources job10_cleanup_vcn_and_volumes)
SHUFFLED=($(shuf -e "${ALL_JOBS[@]}"))

for i in $(seq 1 $COUNT); do
  run_job "${SHUFFLED[$((i-1))]}"
  sleep_random 3 20
done

echo "✅ OCI simulation done: $COUNT job(s) run"
echo "✅ Log saved to: $CSV_LOG and $JSON_LOG"
log_action "$TIMESTAMP" "simulate" "✅ OCI simulation done: $COUNT job(s) run" "done"
