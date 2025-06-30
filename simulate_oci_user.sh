#!/bin/bash

# === CONFIG ===
START_TIME=$(date +%s.%N)
TENANCY_OCID=$(awk -F'=' '/^tenancy=/{print $2}' ~/.oci/config)
DAY=$(date +%d)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
LOG_DIR="$HOME/oci-activity-logs"
CSV_LOG="$LOG_DIR/oci_activity_log.csv"
JSON_LOG="$LOG_DIR/oci_activity_log.json"
ACTION_LOG_FILE="/tmp/oci_adb_action_log.txt"
NOTES=(
  "backup-required"
  "migrated-from-vm"
  "user-tagged"
  "important-bucket"
  "temp-data"
  "attached-to-db"
  "daily-check"
  "bucket-active"
  "test-note"
  "deprecated"
  "do-not-delete"
  "auto-created"
  "manual-review-needed"
  "high-priority"
  "compliance-checked"
  "pci-audit"
  "shared-resource"
  "project-alpha"
  "project-beta"
  "monthly-report"
  "archive-in-progress"
  "security-reviewed"
  "owner-john"
  "owner-anna"
  "training-purpose"
  "qa-verified"
  "staging-env"
  "production-env"
  "dev-env"
  "snapshot-present"
  "billing-tracked"
  "critical-system"
  "waiting-cleanup"
  "monitor-enabled"
  "network-attached"
  "iam-linked"
  "old-version"
  "v2-updated"
  "for-disaster-recovery"
  "temp-migration"
  "resource-locked"
  "customer-data"
  "internal-use-only"
  "sandbox-env"
  "devops-managed"
  "test-suite"
  "performance-benchmark"
  "restored-from-backup"
  "cross-region"
  "test-run-2025"
  "dr-environment"
)

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
      --description "Auto delete tag" \
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
  echo "$json_input" | tr -d '\n' | \
    sed -E 's/^\[//; s/\]$//' | \
    sed 's/},[[:space:]]*{/\}\n\{/g' | \
  while IFS= read -r line || [[ -n "$line" ]]; do
    ID=$(echo "$line" | grep -oP '"id"\s*:\s*"\K[^"]+')
    NAME=$(echo "$line" | grep -oP '"name"\s*:\s*"\K[^"]+')
    STATE=$(echo "$line" | grep -oP '"state"\s*:\s*"\K[^"]+')

    if [[ -n "$ID" && -n "$NAME" ]]; then
      if [[ -n "$STATE" ]]; then
        echo "$ID|$NAME|$STATE"
      else
        echo "$ID|$NAME"
      fi
    fi
  done
}

remove_note_from_freeform_tags() {
  echo "$1" | tr -d '\n' |
    sed -E 's/"note"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*//g' |
    sed -E 's/,[[:space:]]*}/}/g' |
    sed -E 's/\{[[:space:]]*,/\{/g'
}

generate_fake_project_files() {
  mkdir -p deploy_tmp
  FILE_POOL=("main.py" "config.yaml" "requirements.txt" "Dockerfile" ".env.example" "README.md" ".gitignore" "deploy.sh")
  CONTENT_POOL=(
    'def handler(event, context):\n  return f"Hello, {event.get(\"user\", \"guest\")}"'
    'app:\n  name: user-service\n  version: 1.0.0\n  debug: false'
    'requests\nflask\npydantic'
    'FROM python:3.9\nWORKDIR /app\nCOPY . .\nRUN pip install -r requirements.txt\nCMD ["python", "main.py"]'
    'APP_ENV=production\nDB_URI=sqlite:///tmp.db\nSECRET_KEY=demo123'
    '# Project Title\nThis is a demo deployment package for OCI simulation.'
    '.env\n__pycache__/\n*.tar.gz\ndeploy_tmp/'
    '#!/bin/bash\necho "Deploying..."\ntar -czf build.tar.gz .\noci os object put --bucket-name "$DEPLOY_BUCKET" --name "$FOLDER/build.tar.gz" --file build.tar.gz'
  )

  COUNT=$((RANDOM % 5 + 3))  # Random 3–7 files
  USED_INDEXES=()

  for ((i = 0; i < COUNT; i++)); do
    while :; do
      IDX=$((RANDOM % ${#FILE_POOL[@]}))
      if [[ ! " ${USED_INDEXES[@]} " =~ " ${IDX} " ]]; then
        USED_INDEXES+=("$IDX")
        FILENAME=${FILE_POOL[$IDX]}
        CONTENT=${CONTENT_POOL[$IDX]}
        echo -e "$CONTENT" > "deploy_tmp/$FILENAME"
        echo "📝 Created $FILENAME"
        break
      fi
    done
  done
}

random_password() {
  local LENGTH=${1:-16}
  tr -dc 'A-Za-z0-9!@#$%^&*_=+-' </dev/urandom | head -c "$LENGTH"
  echo
}

# === Run a single job ===
run_job() {
  case "$1" in
    job1_list_iam)
      log_action "$TIMESTAMP" "info" "List IAM info" "start"
      sleep_random 1 10
      oci iam region-subscription list && log_action "$TIMESTAMP" "region" "✅ List region subscription" "success"
      sleep_random 1 20
      oci iam availability-domain list && log_action "$TIMESTAMP" "availability-domain" "✅ List availability domains" "success"
      ;;

    job2_check_quota)
      AD=$(oci iam availability-domain list --query "data[0].name" --raw-output)
      sleep_random 1 30
      oci limits resource-availability get --service-name compute \
        --limit-name standard-e2-core-count \
        --availability-domain "$AD" \
        --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "quota" "✅ Get compute quota" "success"
      ;;

    job3_upload_random_files_to_bucket)
      BUCKETS=$(oci os bucket list --compartment-id "$TENANCY_OCID" \
	    --query "data[].name" --raw-output)

      local ACTION=$((RANDOM % 2))
      BUCKET_COUNT=$(echo "$BUCKETS" | grep -c '"')
      
      if [[ "$ACTION" -eq 0 && -n "$BUCKETS" && "$BUCKET_COUNT" -gt 0 ]]; then
	ITEMS=$(echo "$BUCKETS" | grep -o '".*"' | tr -d '"')
	readarray -t BUCKET_ARRAY <<< "$ITEMS"
	RANDOM_INDEX=$(( RANDOM % ${#BUCKET_ARRAY[@]} ))
	BUCKET_NAME="${BUCKET_ARRAY[$RANDOM_INDEX]}"
        log_action "$TIMESTAMP" "select-bucket" "🎯 Selected 1 random bucket out of $BUCKET_COUNT: $BUCKET_NAME" "info"
      else
	ensure_namespace_auto
	ensure_tag "auto-delete" "Mark for auto deletion"
	ensure_tag "auto-delete-date" "Scheduled auto delete date"
	BUCKET_NAME="$(shuf -n 1 -e app-logs media-assets db-backup invoice-data user-files)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
	DELETE_DATE=$(date +%Y-%m-%d --date="+$((2 + RANDOM % 9)) days") # 2-10d
	log_action "$TIMESTAMP" "bucket-create" "🎯 Creating bucket $BUCKET_NAME with auto-delete" "start"
	oci os bucket create \
	        --name "$BUCKET_NAME" \
	        --compartment-id "$TENANCY_OCID" \
	        --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
	        && log_action "$TIMESTAMP" "bucket-create" "✅ Created $BUCKET_NAME with auto-delete-date=$DELETE_DATE" "success" \
	        || log_action "$TIMESTAMP" "bucket-create" "❌ Failed to create $BUCKET_NAME" "fail"
      fi
      
      local FILENAME_PATTERNS=(
	  "system_log_%Y%m%d_%H%M%S_$RANDOM.log"
	  "user_activity_%Y-%m-%d_$RANDOM.txt"
	  "data_export_%Y%m%d_$RANDOM.csv"
	  "backup_snapshot_%Y%m%d.tar.gz"
	  "report_summary_%Y%m%d.doc"
	  "volume_info_%Y%m%d_$RANDOM.json"
	  "task_notes_%Y%m%d.txt"
	  "daily_run_%Y%m%d_%H%M.txt"
	  "upload_test_$RANDOM.txt"
	  "resource_tags_$RANDOM.yaml"
	  "audit_event_%Y%m%d_%H%M.json"
	  "config_dump_$RANDOM_$(date +%H%M).conf"
	  "debug_output_$(date +%s).log"
	  "metric_graph_%Y%m%d.png"
	  "usage_report_%Y%m%d.xls"
	  "disk_status_$RANDOM_$REGION.txt"
	  "tempfile_$RANDOM.tmp"
	  "restore_plan_$(date +%Y%m%d).md"
	  "traffic_log_%H%M%S.json"
	  "vpn_config_export_$RANDOM.ovpn"
      )

	
      local CONTENTS=(
	  "### System Log Start ###
	$(date) - Service initialized
	$(date) - User session started
	$(date) - No errors reported
	### End of Log ###"
	
	  "User Activity Summary - $(date '+%Y-%m-%d')
	Total logins: $((RANDOM % 50))
	Failed logins: $((RANDOM % 5))
	Active sessions: $((RANDOM % 20))
	System health: OK"
	
	  "Report generated by automated task runner.
	This report includes summary of operations:
	- Created 2 buckets
	- Deleted 1 VCN
	- Uploaded backup file
	
	Timestamp: $(date)
	Session ID: $RANDOM"
	
	  "Temporary testing file.
	Region: $REGION
	Generated at: $(date)
	Notes: For simulation only."
	
	  "{
	\"event\": \"volume-check\",
	\"timestamp\": \"$(date -u +%FT%TZ)\",
	\"status\": \"healthy\",
	\"note\": \"automated scan\"
	}"
	
	  "--- Tags Applied ---
	resource: ocid1.bucket.oc1..xxxx
	tags:
	  auto-delete: true
	  auto-delete-date: $(date -d '+7 days' +%F)
	  env: simulation"
	
	  "# Restore Plan
	Date: $(date +%F)
	Files to restore:
	- snapshot.tar.gz
	- config.json
	Estimated time: 15 mins
	"
	
	  "==== DEBUG START ====
	$(date) - Testing network connectivity
	Ping to gateway: SUCCESS
	Curl to Oracle: SUCCESS
	Latency: $((RANDOM % 100))ms
	==== DEBUG END ===="
	
	  "[Audit Log Entry]
	Time: $(date -u)
	Action: delete_instance
	User: sim-user-$(($RANDOM % 100))
	Result: success
	"
	
	  "VPN CONFIG FILE
	client
	dev tun
	proto udp
	remote vpn.simulator.local 1194
	resolv-retry infinite
	nobind
	persist-key
	persist-tun
	<key>
	[PRIVATE_KEY]
	</key>"
      )

	
      local NUM_UPLOADS=$((RANDOM % 5 + 1)) # 1–5 files
	
      for ((i = 1; i <= NUM_UPLOADS; i++)); do
	local FILE_TEMPLATE=${FILENAME_PATTERNS[$((RANDOM % ${#FILENAME_PATTERNS[@]}))]}
	local FILE_NAME=$(date +"$FILE_TEMPLATE")
	local FILE_CONTENT="${CONTENTS[$((RANDOM % ${#CONTENTS[@]}))]}"
	
	echo "$FILE_CONTENT" > "$FILE_NAME"
	
	if oci os object put --bucket-name "$BUCKET_NAME" --file "$FILE_NAME" --force; then
	   log_action "$TIMESTAMP" "bucket-upload" "✅ Uploaded $FILE_NAME to $BUCKET_NAME" "success"
	else
	   log_action "$TIMESTAMP" "bucket-upload" "❌ Failed to upload $FILE_NAME to $BUCKET_NAME" "fail"
	fi
	
	rm -f "$FILE_NAME"
	sleep_random 2 8
      done
      ;;

    job4_cleanup_bucket)
      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"
      log_action "$TIMESTAMP" "auto-delete-scan" "🔍 Scanning for expired buckets with auto-delete=true" "start"
      TODAY=$(date +%Y-%m-%d)
      BUCKETS=$(oci os bucket list --compartment-id "$TENANCY_OCID" \
                --query "data[].name" \
                --raw-output)

      for b in $(parse_json_array_string "$BUCKETS"); do
            DELETE_DATE=$(oci os bucket get --bucket-name "$b" \
                          --query 'data."defined-tags".auto."auto-delete-date"' \
                          --raw-output 2>/dev/null)
            sleep_random 1 10
            if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) ]]; then
              log_action "$TIMESTAMP" "bucket-delete-object" "🗑️ Deleting all objects in $b..." "start"
            
              OBJECTS=$(oci os object list --bucket-name "$b" --query "data[].name" --raw-output)
              for obj in $(parse_json_array_string "$OBJECTS"); do
                oci os object delete --bucket-name "$b" --name "$obj" --force \
                  && log_action "$TIMESTAMP" "bucket-delete-object" "✅ Deleted "$obj" from $b" "success" \
                  || log_action "$TIMESTAMP" "bucket-delete-object" "❌ Failed to delete "$obj" from $b" "fail"
                sleep_random 2 5
              done
              sleep_random 2 10
              oci os bucket delete --bucket-name "$b" --force \
                && log_action "$TIMESTAMP" "bucket-delete" "✅ Deleted expired bucket $b (expired: $DELETE_DATE)" "success" \
                || log_action "$TIMESTAMP" "bucket-delete" "❌ Failed to delete bucket $b (expired: $DELETE_DATE)" "fail"
            fi
      done
      ;;

    job5_list_resources)
      log_action "$TIMESTAMP" "resource-view" "🔍 List common resources" "start"
      sleep_random 1 30
      oci network vcn list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "vcn-list" "✅ List VCNs" "success"
      sleep_random 1 90
      oci network subnet list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "subnet-list" "✅ List subnets" "success"
      sleep_random 1 60
      oci compute image list --compartment-id "$TENANCY_OCID" --all --query 'data[0:3].{name:"display-name"}' && log_action "$TIMESTAMP" "image-list" "✅ List images" "success"
      ;;
    
    job6_create_vcn)
      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"

      VCN_NAME="$(shuf -n 1 -e app-vcn dev-network internal-net prod-backbone staging-vcn)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
      SUBNET_NAME="$(shuf -n 1 -e frontend-subnet backend-subnet db-subnet app-subnet mgmt-subnet)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
      DELETE_DATE=$(date +%Y-%m-%d --date="+$((RANDOM % 7)) days") # 0-7d

      log_action "$TIMESTAMP" "vcn-create" "🎯 Creating VCN $VCN_NAME with auto-delete" "start"
      VCN_ID=$(oci network vcn create \
	  --cidr-block "10.0.0.0/16" \
	  --compartment-id "$TENANCY_OCID" \
	  --display-name "$VCN_NAME" \
	  --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
	  --query "data.id" --raw-output 2> vcn_error.log)
      if [[ -n "$VCN_ID" ]]; then
        log_action "$TIMESTAMP" "vcn-create" "✅ Created VCN $VCN_NAME ($VCN_ID) with auto-delete-date=$DELETE_DATE" "success"
        sleep_random 2 10

        SUBNET_ID=$(oci network subnet create \
          --vcn-id "$VCN_ID" \
          --cidr-block "10.0.1.0/24" \
          --compartment-id "$TENANCY_OCID" \
          --display-name "$SUBNET_NAME" \
          --availability-domain "$(oci iam availability-domain list --query "data[0].name" --raw-output)" \
          --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
          --query "data.id" --raw-output 2> vcn_subnet_error.log)

        if [ -n "$SUBNET_ID" ]; then
          log_action "$TIMESTAMP" "vcn-subnet-create" "✅ Created Subnet $SUBNET_NAME" "success"
        else
          log_action "$TIMESTAMP" "vcn-subnet-create" "❌ Failed to create Subnet $SUBNET_NAME" "fail"
        fi
      else
        log_action "$TIMESTAMP" "vcn-create" "❌ Failed to create VCN $VCN_NAME" "fail"
      fi
      #rm -f vcn_error.log
      ;;

    job7_create_volume)
      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"
      local VOL_NAME="$(shuf -n 1 -e data-volume backup-volume log-volume db-volume test-volume)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
      local DELETE_DATE=$(date +%Y-%m-%d --date="+$((RANDOM % 5)) days") # 0-5d
      local AD=$(oci iam availability-domain list --query "data[0].name" --raw-output)
      
      local AVAILABLE_STORAGE=$(oci limits resource-availability get \
	  --service-name block-storage \
	  --limit-name total-storage-gb \
	  --compartment-id "$TENANCY_OCID" \
	  --availability-domain "$AD" \
	  --query "data.available" \
	  --raw-output)
      
      log_action "$TIMESTAMP" "volume-create" "📦 Available Block Volume Storage: ${AVAILABLE_STORAGE} GB" "info"

      if [[ "$AVAILABLE_STORAGE" -lt 50 ]]; then
	  log_action "$TIMESTAMP" "volume-create" "⚠️ Skipped: only $AVAILABLE_STORAGE GB left" "skipped"
	  return
      fi

      log_action "$TIMESTAMP" "volume-create" "🎯 Creating volume $VOL_NAME with auto-delete" "start"
      local VOL_ID=$(oci bv volume create \
        --compartment-id "$TENANCY_OCID" \
        --display-name "$VOL_NAME" \
        --size-in-gbs 50 \
        --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
        --availability-domain "$AD" \
        --query "data.id" --raw-output 2> vol_error.log)
      if [ -n "$VOL_ID" ]; then
        log_action "$TIMESTAMP" "volume-create" "✅ Created volume $VOL_NAME ($VOL_ID) with auto-delete-date=$DELETE_DATE" "success"
      else
        log_action "$TIMESTAMP" "volume-create" "❌ Failed to create volume $VOL_NAME" "fail"
      fi
      #rm -f vol_error.log
      ;;

    job8_check_public_ip)
      log_action "$TIMESTAMP" "network-info" "🎯 Checking public IPs" "start"
      sleep_random 2 8
      oci network public-ip list \
        --scope REGION \
        --compartment-id "$TENANCY_OCID" \
        --query "data[].\"ip-address\"" --raw-output \
        && log_action "$TIMESTAMP" "public-ip" "✅ Listed public IPs" "success" \
        || log_action "$TIMESTAMP" "public-ip" "❌ Failed to list public IPs" "fail"
      ;;

    job9_scan_auto_delete_resources)
      ensure_namespace_auto
      log_action "$TIMESTAMP" "scan-auto-delete" "🔍 Scanning resources with auto-delete tag" "start"
      TAGGED_BUCKETS=$(oci os bucket list --compartment-id "$TENANCY_OCID" \
        --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true'].name" --raw-output)
      for v in $(parse_json_array_string "$TAGGED_BUCKETS"); do
        log_action "$TIMESTAMP" "scan" "✅ Found auto-delete bucket: $b" "info"
      done
      
      TAGGED_VCNS=$(oci network vcn list --compartment-id "$TENANCY_OCID" \
        --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true'].\"display-name\"" --raw-output)
      for v in $(parse_json_array_string "$TAGGED_VCNS"); do
        log_action "$TIMESTAMP" "scan" "✅ Found auto-delete VCN: $v" "info"
      done

      TAGGED_VOLS=$(oci bv volume list --compartment-id "$TENANCY_OCID" --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true' && \"lifecycle-state\"!='TERMINATED'].\"display-name\"" --raw-output)
      for v in $(parse_json_array_string "$TAGGED_VOLS"); do
        log_action "$TIMESTAMP" "scan" "✅ Found auto-delete Volume: $v" "info"
      done
      ;;

    job10_cleanup_vcn_and_volumes)
      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"
      TODAY=$(date +%Y-%m-%d)

      log_action "$TIMESTAMP" "delete-vcn" "🔍 Scanning for expired VCNs" "start"

      VCNs=$(oci network vcn list --compartment-id "$TENANCY_OCID" \
        --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true'].{name:\"display-name\",id:id}" \
        --raw-output)

      parse_json_array "$VCNs" | while IFS='|' read -r VCN_ID VCN_NAME; do
        DELETE_DATE=$(oci network vcn get --vcn-id "$VCN_ID" \
          --query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          --raw-output 2>/dev/null)
        if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) ]]; then
          log_action "$TIMESTAMP" "auto-delete-vcn" "🎯 Preparing to delete VCN $VCN_NAME" "start"
          SUBNETS=$(oci network subnet list --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" \
            --query "data[].id" --raw-output)
          for subnet_id in $(parse_json_array_string "$SUBNETS"); do
            oci network subnet delete --subnet-id "$subnet_id" --force \
              && log_action "$TIMESTAMP" "delete-subnet" "✅ Deleted subnet $subnet_id in $VCN_NAME" "success" \
              || log_action "$TIMESTAMP" "delete-subnet" "❌ Failed to delete subnet $subnet_id" "fail"
            sleep_random 2 10
          done

          
          IGWS=$(oci network internet-gateway list --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" \
            --query "data[].id" --raw-output)
          for igw_id in $(parse_json_array_string "$IGWS"); do
            oci network internet-gateway delete --ig-id "$igw_id" --force \
              && log_action "$TIMESTAMP" "delete-igw" "✅ Deleted IGW $igw_id in $VCN_NAME" "success" \
              || log_action "$TIMESTAMP" "delete-igw" "❌ Failed to delete IGW $igw_id" "fail"
          done
	  sleep_random 2 10
          
          #ROUTES=$(oci network route-table list --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" \
          #  --query "data[].id" --raw-output)
          #for route_id in $(parse_json_array_string "$ROUTES"); do
          #  oci network route-table delete --rt-id "$route_id" --force \
          #    && log_action "$TIMESTAMP" "delete-route" "Deleted Route Table $route_id" "success" \
          #    || log_action "$TIMESTAMP" "delete-route" "❌ Failed to delete Route Table $route_id" "fail"
          #done

          #sleep_random 2 10
          oci network vcn delete --vcn-id "$VCN_ID" --force \
            && log_action "$TIMESTAMP" "delete-vcn" "✅ Deleted VCN $VCN_NAME (expired: $DELETE_DATE)" "success" \
            || log_action "$TIMESTAMP" "delete-vcn" "❌ Failed to delete VCN $VCN_NAME" "fail"
        fi
      done

      sleep_random 2 10
      log_action "$TIMESTAMP" "delete-volume" "🔍 Scanning for expired block volumes" "start"

      VOLUMES=$(oci bv volume list --compartment-id "$TENANCY_OCID" --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true' && \"lifecycle-state\"!='TERMINATED'].{name:\"display-name\",id:id}" --raw-output)

      parse_json_array "$VOLUMES" | while IFS='|' read -r VOL_ID VOL_NAME; do
        DELETE_DATE=$(oci bv volume get --volume-id "$VOL_ID" \
          --query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          --raw-output 2>/dev/null)
        if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) ]]; then
          sleep_random 1 10
          oci bv volume delete --volume-id "$VOL_ID" --force \
            && log_action "$TIMESTAMP" "delete-volume" "✅ Deleted volume $VOL_NAME (expired: $DELETE_DATE)" "success" \
            || log_action "$TIMESTAMP" "delete-volume" "❌ Failed to delete volume $VOL_NAME" "fail"
        fi
      done
      ;;
      
      job11_deploy_bucket)
      	ensure_namespace_auto
        ensure_tag "auto-delete" "Mark for auto deletion"
	ensure_tag "auto-delete-date" "Scheduled auto delete date"
 	DEPLOY_BUCKET="$(shuf -n 1 -e deploy-artifacts deployment-store deploy-backup pipeline-output release-bucket)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
      	BUCKET_EXISTS=$(oci os bucket get --bucket-name "$DEPLOY_BUCKET" --query 'data.name' --raw-output 2>/dev/null)

	if [ -z "$BUCKET_EXISTS" ]; then
	  DELETE_DATE=$(date +%Y-%m-%d --date="+$((1 + RANDOM % 7 + 2)) days") # 3-9d
	  oci os bucket create \
	    --name "$DEPLOY_BUCKET" \
	    --compartment-id "$TENANCY_OCID" \
	    --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
	    && log_action "$TIMESTAMP" "bucket-create" "✅ Created bucket $DEPLOY_BUCKET - DELETE_DATE: $DELETE_DATE for deployment" "success" \
	    || log_action "$TIMESTAMP" "bucket-create" "❌ Failed to create deployment bucket $DEPLOY_BUCKET" "fail"
	fi
 	# Create simulated project files
 	generate_fake_project_files
 	# Archive it
 	DEPLOY_FILE="code-$(date +%Y%m%d%H%M)-$RANDOM.tar.gz"
 	tar -czf "$DEPLOY_FILE" -C deploy_tmp .
  	# Upload to selected bucket
  	FOLDER="deploy/$(date +%Y-%m-%d)"
	
  	oci os object put --bucket-name "$DEPLOY_BUCKET" --name "$FOLDER/$DEPLOY_FILE" --file "$DEPLOY_FILE" --force && \
    		log_action "$TIMESTAMP" "bucket-deploy" "✅ Uploaded $DEPLOY_FILE to $DEPLOY_BUCKET/$FOLDER" "success" || \
    		log_action "$TIMESTAMP" "bucket-deploy" "❌ Failed to upload $DEPLOY_FILE to $DEPLOY_BUCKET" "fail"
	
	rm -rf deploy_tmp "$DEPLOY_FILE"
      ;;

      job12_update_volume_resource_tag)
	log_action "$TIMESTAMP" "update-volume-tag" "🔍 Scanning volumes for tagging..." "start"

	VOLS=$(oci bv volume list --compartment-id "$TENANCY_OCID" --query "data[?\"lifecycle-state\"!='TERMINATED'].{id:id, name:\"display-name\"}" --raw-output)
	
	VOL_COUNT=$(echo "$VOLS" | grep -c '"id"')
	if [[ -z "$VOLS" || "$VOL_COUNT" -eq 0 ]]; then
	    log_action "$TIMESTAMP" "update-volume-tag" "❌ No volumes found to tag" "skip"
     	else
	    SELECTED_LINE=$((RANDOM % VOL_COUNT + 1))
	    SELECTED=$(parse_json_array "$VOLS" | sed -n "${SELECTED_LINE}p")
	    VOL_ID="${SELECTED%%|*}"
	    VOL_NAME="${SELECTED##*|}"
		
	    CURRENT_TAGS=$(oci bv volume get --volume-id "$VOL_ID" \
		    --query "data.\"freeform-tags\"" --raw-output 2>/dev/null)
	 
	    OLD_NOTE=$(echo "$CURRENT_TAGS" | grep -o '"note"[[:space:]]*:[[:space:]]*"[^"]*"' | \
		            sed -E 's/.*"note"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
		
	    RANDOM_NOTE=""
	    attempts=0
	    while [[ -z "$RANDOM_NOTE" || "$RANDOM_NOTE" == "$OLD_NOTE" ]]; do
		  RANDOM_NOTE=${NOTES[$((RANDOM % ${#NOTES[@]}))]}
		  ((attempts++))
		 
		  if [[ $attempts -ge 20 ]]; then
		    break
		  fi
	    done
	 
	    if [[ "$RANDOM_NOTE" == "$OLD_NOTE" ]]; then
		  RANDOM_NOTE="test-note-$(date +%s)-$RANDOM"
	    fi
		
		
	    if [[ -z "$CURRENT_TAGS" || "$CURRENT_TAGS" == "null" ]]; then
		  FINAL_TAGS="{\"note\":\"$RANDOM_NOTE\"}"
	    else
		  CLEANED=$(remove_note_from_freeform_tags "$CURRENT_TAGS")
		  if [[ "$CLEANED" =~ ^\{[[:space:]]*\}$ ]]; then
		    FINAL_TAGS="{\"note\":\"$RANDOM_NOTE\"}"
		  else
		    FINAL_TAGS=$(echo "$CLEANED" | sed -E "s/}[[:space:]]*\$/,\"note\":\"$RANDOM_NOTE\"}/")
		  fi
	    fi
		
	    log_action "$TIMESTAMP" "update-volume-tag" "🎯 Updating volume $VOL_NAME with note=$RANDOM_NOTE (preserve tags)" "start"
		
	    oci bv volume update \
		    --volume-id "$VOL_ID" \
		    --freeform-tags "$FINAL_TAGS" \
		    --force \
		    && log_action "$TIMESTAMP" "update-volume-tag" "✅ Updated tag for $VOL_NAME with note=$RANDOM_NOTE" "success" \
		    || log_action "$TIMESTAMP" "update-volume-tag" "❌ Failed to update tag for $VOL_NAME" "fail"
	fi
      ;;

      job13_update_bucket_resource_tag)
	log_action "$TIMESTAMP" "update-bucket-tag" "🔍 Scanning bucket for tagging..." "start"

	BUCKETS=$(oci os bucket list --compartment-id "$TENANCY_OCID" \
	    --query "data[].name" --raw-output)
	
	BUCKET_COUNT=$(echo "$BUCKETS" | grep -c '"')
	if [[ -z "$BUCKETS" || "$BUCKET_COUNT" -eq 0 ]]; then
	   log_action "$TIMESTAMP" "update-bucket-tag" "❌ No buckets found to tag" "skip"
     	else
      	   ITEMS=$(echo "$BUCKETS" | grep -o '".*"' | tr -d '"')
           readarray -t BUCKET_ARRAY <<< "$ITEMS"
           RANDOM_INDEX=$(( RANDOM % ${#BUCKET_ARRAY[@]} ))
           BUCKET_NAME="${BUCKET_ARRAY[$RANDOM_INDEX]}"
		
           CURRENT_TAGS=$(oci os bucket get --bucket-name "$BUCKET_NAME" \
		    --query "data.\"freeform-tags\"" --raw-output 2>/dev/null)
	 	
           OLD_NOTE=$(echo "$CURRENT_TAGS" | grep -o '"note"[[:space:]]*:[[:space:]]*"[^"]*"' | \
		            sed -E 's/.*"note"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
		
           RANDOM_NOTE=""
           attempts=0
           while [[ -z "$RANDOM_NOTE" || "$RANDOM_NOTE" == "$OLD_NOTE" ]]; do
	       RANDOM_NOTE=${NOTES[$((RANDOM % ${#NOTES[@]}))]}
	       ((attempts++))
		 
	       if [[ $attempts -ge 20 ]]; then
		    break
	       fi
           done
	 
           if [[ "$RANDOM_NOTE" == "$OLD_NOTE" ]]; then
	       RANDOM_NOTE="test-note-$(date +%s)-$RANDOM"
           fi
		
		
           if [[ -z "$CURRENT_TAGS" || "$CURRENT_TAGS" == "null" ]]; then
	       FINAL_TAGS="{\"note\":\"$RANDOM_NOTE\"}"
           else
	       CLEANED=$(remove_note_from_freeform_tags "$CURRENT_TAGS")
	       if [[ "$CLEANED" =~ ^\{[[:space:]]*\}$ ]]; then
		    FINAL_TAGS="{\"note\":\"$RANDOM_NOTE\"}"
	       else
		    FINAL_TAGS=$(echo "$CLEANED" | sed -E "s/}[[:space:]]*\$/,\"note\":\"$RANDOM_NOTE\"}/")
	       fi
           fi
		
           log_action "$TIMESTAMP" "update-bucket-tag" "🎯 Updating bucket $BUCKET_NAME with note=$RANDOM_NOTE (preserve tags)" "start"
		
           oci os bucket update \
	  	    --bucket-name "$BUCKET_NAME" \
		    --freeform-tags "$FINAL_TAGS" \
		    && log_action "$TIMESTAMP" "update-bucket-tag" "✅ Updated tag for $BUCKET_NAME with note=$RANDOM_NOTE" "success" \
		    || log_action "$TIMESTAMP" "update-bucket-tag" "❌ Failed to update tag for $BUCKET_NAME" "fail"
	fi
      ;;

      job14_edit_volume)
	log_action "$TIMESTAMP" "edit-volume-size" "🔍 Scanning volumes with auto-delete=true for edit size..." "start"
	
	local VOLS=$(oci bv volume list --compartment-id "$TENANCY_OCID" \
	  --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true' && \"lifecycle-state\"!='TERMINATED'].{id:id, name:\"display-name\"}" \
	  --raw-output)
	
	local VOL_COUNT=$(echo "$VOLS" | grep -c '"id"')
	
	if [[ -z "$VOLS" || "$VOL_COUNT" -eq 0 ]]; then
	  log_action "$TIMESTAMP" "edit-volume-size" "❌ No volumes with auto-delete=true found to edit size" "skip"
	else
	  local AD=$(oci iam availability-domain list --query "data[0].name" --raw-output)
	
	  local AVAILABLE_STORAGE=$(oci limits resource-availability get \
	    --service-name block-storage \
	    --limit-name total-storage-gb \
	    --compartment-id "$TENANCY_OCID" \
	    --availability-domain "$AD" \
	    --query "data.available" \
	    --raw-output)
	
	  log_action "$TIMESTAMP" "edit-volume-size" "📦 Available Block Volume Storage: ${AVAILABLE_STORAGE} GB" "info"
	
	  if [[ "$AVAILABLE_STORAGE" -lt 60 ]]; then
	    log_action "$TIMESTAMP" "edit-volume-size" "⚠️ Skipped: not enough storage (need ≥60 GB, available: $AVAILABLE_STORAGE)" "skipped"
	    return
	  fi
	
	  local SELECTED_LINE=$((RANDOM % VOL_COUNT + 1))
	  local SELECTED=$(parse_json_array "$VOLS" | sed -n "${SELECTED_LINE}p")
	  local VOL_ID="${SELECTED%%|*}"
	  local VOL_NAME="${SELECTED##*|}"
	
	  local MAX_SIZE=100
	
	  local CURRENT_SIZE=$(oci bv volume get --volume-id "$VOL_ID" --query 'data."size-in-gbs"' --raw-output)
	  local MIN_SIZE=$CURRENT_SIZE
	
	  local LIMIT_MAX=$(( AVAILABLE_STORAGE - 1 ))
	  if [[ "$LIMIT_MAX" -gt "$MAX_SIZE" ]]; then
	  	LIMIT_MAX=$MAX_SIZE
	  fi
	
	  if [[ "$CURRENT_SIZE" -ge "$LIMIT_MAX" ]]; then
	  	log_action "$TIMESTAMP" "edit-volume-size" "⚠️ Skipped: $VOL_NAME already at ${CURRENT_SIZE}GB ≥ allowed max ${LIMIT_MAX}GB" "skipped"
	  	return
	  fi
	
	  local LOWER_BOUND=$(( CURRENT_SIZE + 1 > MIN_SIZE ? CURRENT_SIZE + 1 : MIN_SIZE ))

	  if [[ "$LIMIT_MAX" -lt "$LOWER_BOUND" ]]; then
	  	log_action "$TIMESTAMP" "edit-volume-size" "⚠️ Skipped: Not enough room to resize $VOL_NAME (current: $CURRENT_SIZE GB)" "skipped"
	  	return
	  fi
	
	  local SIZE_GB=$(( LOWER_BOUND + RANDOM % (LIMIT_MAX - LOWER_BOUND + 1) ))
	
	  # Proceed with resize
	  oci bv volume update --volume-id "$VOL_ID" --size-in-gbs "$SIZE_GB" \
	    && log_action "$TIMESTAMP" "edit-volume-size" "✅ Volume $VOL_NAME resized from ${CURRENT_SIZE}GB to ${SIZE_GB}GB" "success" \
	    || log_action "$TIMESTAMP" "edit-volume-size" "❌ Failed to resize $VOL_NAME to ${SIZE_GB}GB" "fail"
	fi
      ;;
      
      job15_create_dynamic_group)
	  ensure_namespace_auto
	  ensure_tag "auto-delete" "Mark for auto deletion"
	  ensure_tag "auto-delete-date" "Scheduled auto delete date"
	  local JOB_NAME="create-dynamic-group"

	  local USERS=(
	    "alice" "bob" "charlie" "david" "eva" "frank" "grace" "henry" "ivy" "jack"
	    "karen" "leo" "mia" "nathan" "olivia" "peter" "quinn" "rachel" "sam" "tina"
	    "ursula" "victor" "will" "xander" "yuri" "zoe"
	    "team-alpha" "team-beta" "ops-core" "batch-team" "fintech-dev" "ml-lab"
	  )
	
	  local PURPOSES=(
	    "devops" "batch-jobs" "analytics" "autoscale" "monitoring" "ai-inference"
	    "image-processing" "log-ingestion" "internal-api" "customer-reporting"
	    "vpn-access" "db-backup" "event-stream" "data-export" "incident-response"
	    "terraform-ci" "cloud-health" "hpc-burst" "data-labeling" "iot-agent"
	    "threat-detection" "compliance-check" "cost-analysis" "zero-trust-policy"
	  )
	
	  local MATCH_RULES=(
	    "ALL {resource.type = 'instance', instance.compartment.id = '$TENANCY_OCID'}"
	    "ALL {resource.type = 'volume', volume.compartment.id = '$TENANCY_OCID'}"
	    "ANY {resource.type = 'autonomous-database'}"
	    "ALL {resource.compartment.id = '$TENANCY_OCID'}"
	    "ALL {resource.type = 'bootvolume'}"
	  )
	
	  local USER="${USERS[RANDOM % ${#USERS[@]}]}"
	  local PURPOSE="${PURPOSES[RANDOM % ${#PURPOSES[@]}]}"
	  local RULE="${MATCH_RULES[RANDOM % ${#MATCH_RULES[@]}]}"
	
	  local DG_NAME="dg-${USER}-${PURPOSE}-$((100 + RANDOM % 900))"
	  local DESCRIPTION="Dynamic group for ${USER}'s ${PURPOSE} tasks"
	  DELETE_DATE=$(date +%Y-%m-%d --date="+$((1 + RANDOM % 15)) days") #1 - 15d
	  if oci iam dynamic-group create \
	    --name "$DG_NAME" \
	    --description "$DESCRIPTION" \
     	    --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
	    --matching-rule "$RULE"; then
	    log_action "$TIMESTAMP" "$JOB_NAME" "✅ Created dynamic group '$DG_NAME' with purpose '$PURPOSE'" "success"
	  else
	    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to create dynamic group '$DG_NAME'" "error"
	  fi
      ;;

      job16_delete_dynamic_group)
	log_action "$TIMESTAMP" "delete-dynamic-group" "🔍 Scanning for expired dynamic group" "start"
	local TODAY=$(date +%Y-%m-%d)
	local ITEMS=$(oci iam dynamic-group list --compartment-id "$TENANCY_OCID" --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true' && \"lifecycle-state\"!='TERMINATED'].{name:\"name\",id:id}" --raw-output)

      	parse_json_array "$ITEMS" | while IFS='|' read -r ITEM_ID ITEM_NAME; do
        	DELETE_DATE=$(oci iam dynamic-group get --dynamic-group-id "$ITEM_ID" \
          	--query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          	--raw-output 2>/dev/null)
        	if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) ]]; then
          		sleep_random 1 10
          		oci iam dynamic-group delete --dynamic-group-id "$ITEM_ID" --force \
            		&& log_action "$TIMESTAMP" "delete-dynamic-group" "✅ Deleted dynamic group $ITEM_NAME (expired: $DELETE_DATE)" "success" \
            		|| log_action "$TIMESTAMP" "delete-dynamic-group" "❌ Failed to delete dynamic group $ITEM_NAME" "fail"
        	fi
        done
      ;;
      
      job17_create_autonomous_db)
	ensure_namespace_auto
	ensure_tag "auto-delete" "Mark for auto deletion"
	ensure_tag "auto-delete-date" "Scheduled auto delete date"
	local JOB_NAME="create-paid-autonomous-db"

	local PREFIXES=("sales" "ml" "analytics" "prod" "test" "hr" "finance" "dev" "backup" "log" "data" "staging" "ops")
	local FUNCTIONS=("db" "data" "store" "system" "core" "service" "report" "etl" "dash")
	local SUFFIXES=("01" "2025" "$((RANDOM % 100))" "$(date +%y)" "$(date +%m%d)")
	local DB_NAME_PART="${PREFIXES[RANDOM % ${#PREFIXES[@]}]}-${FUNCTIONS[RANDOM % ${#FUNCTIONS[@]}]}-${SUFFIXES[RANDOM % ${#SUFFIXES[@]}]}-$(uuidgen | cut -c1-6)"
	local DB_NAME=$(echo "$DB_NAME_PART" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c1-30)
	local DISPLAY_NAME="${DB_NAME_PART^}"
	local ADMIN_PASSWORD=$(random_password 20)

	# Check available eCPU quota for Paid Autonomous Database
	local ECPU_AVAILABLE=$(oci limits resource-availability get \
	  --service-name database \
	  --limit-name adw-ecpu-count \
	  --compartment-id "$TENANCY_OCID" \
	  --query "data.available" \
	  --raw-output)
	if [[ "$ECPU_AVAILABLE" -eq 0 ]]; then
		  log_action "$TIMESTAMP" "create-free-autonomous-db" "⚠️ No remaining eCPU quota → attempting to create an Always Free Autonomous DB..." "info"
		  # Count existing Free Autonomous Databases
		  local FREE_DB_COUNT=$(oci db autonomous-database list \
		    --compartment-id "$TENANCY_OCID" \
		    --query "length(data[?\"is-free-tier\"==\`true\`])" \
		    --all --raw-output)
		
		  if [[ "$FREE_DB_COUNT" -lt 2 ]]; then
      		    log_action "$TIMESTAMP" "create-free-autonomous-db" "✅ $FREE_DB_COUNT Free ADB(s) detected → proceeding to create a new Free ADB" "info"
		    local RANDOM_HOURS=$((24 + RANDOM % 97))  # 24 ≤ H ≤ 120
		    local DELETE_DATE=$(date -u -d "+$RANDOM_HOURS hours" '+%Y-%m-%dT%H:%M:%SZ')
		    # Create the Always Free Autonomous Database
		    oci db autonomous-database create \
			--compartment-id "$TENANCY_OCID" \
			--db-name "$DB_NAME" \
			--display-name "$DISPLAY_NAME" \
			--admin-password "$ADMIN_PASSWORD" \
			--db-workload DW \
			--license-model LICENSE_INCLUDED \
			--is-free-tier true \
			--defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
		    && log_action "$TIMESTAMP" "create-free-autonomous-db" "✅ Created Free ADB: $DISPLAY_NAME" "success" \
		    || log_action "$TIMESTAMP" "create-free-autonomous-db" "❌ Failed to create Free ADB" "fail"
		
		  else
		    log_action "$TIMESTAMP" "create-free-autonomous-db" "⚠️ Skipped: already have $FREE_DB_COUNT Free ADBs" "skipped"
		  fi
	else
    		log_action "$TIMESTAMP" "$JOB_NAME" "✅ Sufficient eCPU quota ($ECPU_AVAILABLE) → creating Paid Autonomous DB..." "info"
	  	local CPU_COUNT=$((2 + RANDOM % 2))  # 2–3 ECPU
		local STORAGE_TB=$((1 + RANDOM % 2))  # 1–2 TB
  		local RANDOM_HOURS=$((12 + RANDOM % 37))  # 12 ≤ H ≤ 48
		local DELETE_DATE=$(date -u -d "+$RANDOM_HOURS hours" '+%Y-%m-%dT%H:%M:%SZ')
		if oci db autonomous-database create \
		    --compartment-id "$TENANCY_OCID" \
		    --db-name "$DB_NAME" \
		    --display-name "$DISPLAY_NAME" \
		    --admin-password "$ADMIN_PASSWORD" \
		    --compute-count "$CPU_COUNT" \
		    --compute-model ECPU \
		    --data-storage-size-in-tbs "$STORAGE_TB" \
		    --db-workload DW \
		    --license-model LICENSE_INCLUDED \
		    --is-free-tier false \
		    --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}'; then
		    log_action "$TIMESTAMP" "$JOB_NAME" "✅ Created paid DB '$DISPLAY_NAME' (${CPU_COUNT} ECPU, ${STORAGE_TB}TB), auto-delete at $DELETE_DATE" "success"
		else
		    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to create paid DB '$DISPLAY_NAME'" "error"
		fi
	fi
      ;;
      
      job18_delete_autonomous_db)
	log_action "$TIMESTAMP" "delete-autonomous-db" "🔍 Scanning for expired autonomous db" "start"
	local NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	local ITEMS=$(oci db autonomous-database list --compartment-id "$TENANCY_OCID" --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true' && \"lifecycle-state\"!='TERMINATED'].{name:\"display-name\",id:id}" --raw-output)

      	parse_json_array "$ITEMS" | while IFS='|' read -r ITEM_ID ITEM_NAME; do
        	DELETE_DATE=$(oci db autonomous-database get --autonomous-database-id "$ITEM_ID" \
          	--query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          	--raw-output 2>/dev/null)
        	if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$NOW" +%s) ]]; then
          		sleep_random 1 10
			oci db autonomous-database delete --autonomous-database-id "$ITEM_ID" --force && {
			    log_action "$TIMESTAMP" "delete-autonomous-db" "✅ Deleted autonomous db $ITEM_NAME (expired: $DELETE_DATE)" "success"
			    sed -i "/^$ITEM_ID|/d" "$ACTION_LOG_FILE" 2>/dev/null
			} || {
			    log_action "$TIMESTAMP" "delete-autonomous-db" "❌ Failed to delete autonomous db $ITEM_NAME" "fail"
			}
        	fi
        done
      ;;

      job19_toggle_autonomous_db)
	  local JOB_NAME="toggle_autonomous_db"
	
	  local DBS=$(oci db autonomous-database list \
	    --compartment-id "$TENANCY_OCID" \
	    --query "data[?\"lifecycle-state\"=='AVAILABLE' || \"lifecycle-state\"=='STOPPED'].{id:id, name:\"display-name\", state:\"lifecycle-state\"}" \
	    --raw-output)

	  local DB_COUNT=$(echo "$DBS" | grep -c '"id"')
	  if [[ -z "$DBS" || "$DB_COUNT" -eq 0 ]]; then
		  log_action "$TIMESTAMP" "$JOB_NAME" "❌ No DB found to toggle" "skip"
	  else
		  local SELECTED_LINE=$((RANDOM % DB_COUNT + 1))
		  local SELECTED=$(parse_json_array "$DBS" | sed -n "${SELECTED_LINE}p")
		  IFS='|' read -r DB_OCID DB_NAME DB_STATE <<< "$SELECTED"
		
		  local LAST_TIME_LINE=$(grep "^$DB_OCID|" "$ACTION_LOG_FILE" 2>/dev/null)
		  local LAST_TS=$(echo "$LAST_TIME_LINE" | cut -d'|' -f2)
		
		  local NOW_EPOCH=$(date -u +%s)
		  local LAST_EPOCH=0
		
		  if [[ -n "$LAST_TS" ]]; then
		    LAST_EPOCH=$(date -d "$LAST_TS" +%s)
		  fi
		
		  local HOURS_DIFF=$(( (NOW_EPOCH - LAST_EPOCH) / 3600 ))
		
		  if [[ "$HOURS_DIFF" -lt 4 ]]; then
		    log_action "$TIMESTAMP" "$JOB_NAME" "⏱ DB '$DB_NAME' last toggled $HOURS_DIFF hour(s) ago < 4h — skip" "skipped"
		    return
		  fi
		
		  if [[ "$HOURS_DIFF" -lt 10 && $((RANDOM % 2)) -eq 0 ]]; then
		    log_action "$TIMESTAMP" "$JOB_NAME" "🤏 Waiting for more time before toggling '$DB_NAME' ($HOURS_DIFF hours)" "delayed"
		    return
		  fi
		
		  local ACTION=$((RANDOM % 2))
		
		  if [[ "$ACTION" -eq 0 && "$DB_STATE" == "AVAILABLE" ]]; then
			  if oci db autonomous-database stop --autonomous-database-id "$DB_OCID" --wait-for-state STOPPED; then
			    log_action "$TIMESTAMP" "$JOB_NAME" "🛑 Stopped Autonomous DB '$DB_NAME'" "success"
			  else
			    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to stop Autonomous DB '$DB_NAME'" "fail"
			  fi
		
		  elif [[ "$ACTION" -eq 1 && "$DB_STATE" == "STOPPED" ]]; then
			  if oci db autonomous-database start --autonomous-database-id "$DB_OCID" --wait-for-state AVAILABLE; then
			    log_action "$TIMESTAMP" "$JOB_NAME" "▶️ Started Autonomous DB '$DB_NAME'" "success"
			  else
			    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to start Autonomous DB '$DB_NAME'" "fail"
			  fi
		  else
			  log_action "$TIMESTAMP" "$JOB_NAME" "⏩ DB '$DB_NAME' already in desired state" "skipped"
			  return
		  fi
		
		  sed -i "/^$DB_OCID|/d" "$ACTION_LOG_FILE" 2>/dev/null
		  echo "$DB_OCID|$TIMESTAMP" >> "$ACTION_LOG_FILE"
	  fi
      ;;
  esac
}

# === Session Check ===
if oci iam user get --user-id "$USER_ID" &> /dev/null; then
  log_action "$TIMESTAMP" "session" "✅ Get user info" "success"
else
  log_action "$TIMESTAMP" "session" "❌ Get user info" "fail"
fi

# === Randomly select number of jobs to run ===
TOTAL_JOBS=19
COUNT=$((RANDOM % TOTAL_JOBS + 1))
ALL_JOBS=(job1_list_iam job2_check_quota job3_upload_random_files_to_bucket job4_cleanup_bucket job5_list_resources job6_create_vcn job7_create_volume job8_check_public_ip job9_scan_auto_delete_resources job10_cleanup_vcn_and_volumes job11_deploy_bucket job12_update_volume_resource_tag job13_update_bucket_resource_tag job14_edit_volume job15_create_dynamic_group job16_delete_dynamic_group job17_create_autonomous_db job18_delete_autonomous_db job19_toggle_autonomous_db)
SHUFFLED=($(shuf -e "${ALL_JOBS[@]}"))

for i in $(seq 1 $COUNT); do
  run_job "${SHUFFLED[$((i-1))]}"
  sleep_random 3 20
done

RAN_JOBS=("${SHUFFLED[@]:0:$COUNT}")
LOG_JOBS=$(printf "%s, " "${RAN_JOBS[@]}")
LOG_JOBS=${LOG_JOBS%, }  # remove trailing comma

echo "✅ OCI simulation done: $COUNT job(s) run"
echo "✅ Log saved to: $CSV_LOG and $JSON_LOG"
END_TIME=$(date +%s.%N)
TOTAL_TIME=$(echo "$END_TIME - $START_TIME" | bc)
if (( $(echo "$TOTAL_TIME >= 60" | bc -l) )); then
  MINUTES=$(echo "$TOTAL_TIME / 60" | bc)
  SECONDS=$(echo "$TOTAL_TIME - ($MINUTES * 60)" | bc)
  TOTAL_TIME_FORMATTED="${MINUTES}m $(printf '%.2f' "$SECONDS")s"
else
  TOTAL_TIME_FORMATTED="$(printf '%.2f' "$TOTAL_TIME")s"
fi
log_action "$TIMESTAMP" "simulate" "✅ OCI simulation done: $COUNT job(s) run: $LOG_JOBS in $TOTAL_TIME_FORMATTED" "done"
