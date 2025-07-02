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

  local COUNT_FILE=$((RANDOM % 5 + 3))  # Random 3–7 files
  USED_INDEXES=()

  for ((i = 0; i < COUNT_FILE; i++)); do
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
  local UPPER=$(tr -dc 'A-Z' </dev/urandom | head -c1)
  local LOWER=$(tr -dc 'a-z' </dev/urandom | head -c1)
  local DIGIT=$(tr -dc '0-9' </dev/urandom | head -c1)
  local SPECIAL=$(tr -dc '!@#%^_+=-' </dev/urandom | head -c1)
  local REST_LENGTH=$((16 - 4))

  local REST=$(tr -dc 'A-Za-z0-9!@#%^_+=-' </dev/urandom | head -c"$REST_LENGTH")
  local RAW="${UPPER}${LOWER}${DIGIT}${SPECIAL}${REST}"

  echo "$(echo "$RAW" | fold -w1 | shuf | tr -d '\n')"
}

generate_realistic_value() {
  local col_name="$1"
  local col_type="$2"

  # Normalize col_type to uppercase (in case it's lowercase)
  col_type=$(echo "$col_type" | tr '[:lower:]' '[:upper:]')

  # Try override based on col_name (regardless of type)
  case "$col_name" in
    email) echo "\"user$(shuf -i 1000-9999 -n1)@gmail.com\"" && return ;;
    ip) echo "\"192.168.$((RANDOM % 255)).$((RANDOM % 255))\"" && return ;;
    name|username) echo "\"$(tr -dc a-z0-9 </dev/urandom | head -c 6)\"" && return ;;
    status) echo "\"$(shuf -e ACTIVE INACTIVE PENDING DELETED -n1)\"" && return ;;
    city) echo "\"$(shuf -e Hanoi Saigon Tokyo Paris NewYork -n1)\"" && return ;;
    country) echo "\"$(shuf -e US VN JP FR DE -n1)\"" && return ;;
    created_at|updated_at|timestamp|time)
      echo $(date +%s000) && return ;;
    age) echo $((RANDOM % 70 + 18)) && return ;;
    price|amount|total) echo "$(shuf -i 10-500 -n1).$(shuf -i 0-99 -n1 | xargs printf "%02d")" && return ;;
  esac

  # If col_name is not special → fallback by col_type
  case "$col_type" in
    STRING)
      echo "\"$(tr -dc a-z0-9 </dev/urandom | head -c 10)\""
      ;;
    INT|INTEGER)
      echo $((RANDOM % 1000))
      ;;
    FLOAT|DOUBLE|NUMBER)
      echo "$(shuf -i 5-200 -n1).$(shuf -i 0-99 -n1 | xargs printf "%02d")"
      ;;
    LONG)
      echo $(date +%s000)
      ;;
    BOOLEAN)
      echo $([[ $((RANDOM % 2)) -eq 0 ]] && echo "true" || echo "false")
      ;;
    JSON)
      echo "{\"lat\": $(awk 'BEGIN{print 10 + rand()}'), \"lon\": $(awk 'BEGIN{print 106 + rand()}')}"
      ;;
    *)
      # Unknown type → randomly choose a format
      case $((RANDOM % 5)) in
        0) echo "\"$(tr -dc a-z </dev/urandom | head -c 5)\"" ;;
        1) echo $((RANDOM % 500)) ;;
        2) echo "$(awk 'BEGIN{ printf("%.1f", rand()*50) }')" ;;
        3) echo $(date +%s000) ;;
        4) echo "true" ;;
      esac
      ;;
  esac
}


job1_list_iam() {
      log_action "$TIMESTAMP" "info" "List IAM info" "start"
      sleep_random 1 10
      oci iam region-subscription list && log_action "$TIMESTAMP" "region" "✅ List region subscription" "success"
      sleep_random 1 20
      oci iam availability-domain list && log_action "$TIMESTAMP" "availability-domain" "✅ List availability domains" "success"
}

job2_check_quota() {
      AD=$(oci iam availability-domain list --query "data[0].name" --raw-output)
      sleep_random 1 30
      oci limits resource-availability get --service-name compute \
        --limit-name standard-e2-core-count \
        --availability-domain "$AD" \
        --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "quota" "✅ Get compute quota" "success"
}

job3_upload_random_files_to_bucket() {
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
	DELETE_DATE=$(date +%Y-%m-%d --date="+$((5 + RANDOM % 11)) days") # 5-15d
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
}

job4_cleanup_bucket() {
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
            if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
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
}

job5_list_resources() {
      log_action "$TIMESTAMP" "resource-view" "🔍 List common resources" "start"
      sleep_random 1 30
      oci network vcn list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "vcn-list" "✅ List VCNs" "success"
      sleep_random 1 90
      oci network subnet list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "subnet-list" "✅ List subnets" "success"
      sleep_random 1 60
      oci compute image list --compartment-id "$TENANCY_OCID" --all --query 'data[0:3].{name:"display-name"}' && log_action "$TIMESTAMP" "image-list" "✅ List images" "success"
 
}

job6_create_vcn() {
      local VCN_AVAILABLE=$(oci limits resource-availability get \
    	--service-name vcn \
    	--limit-name vcn-count \
    	--compartment-id "$TENANCY_OCID" \
    	--query "data.available" \
    	--raw-output)

      if [[ -z "$VCN_AVAILABLE" || "$VCN_AVAILABLE" -le 0 ]]; then
      	log_action "$TIMESTAMP" "vcn-create" "❌ VCN quota reached: $VCN_AVAILABLE available" "skipped"
    	return;
      fi
      
      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"

      VCN_NAME="$(shuf -n 1 -e app-vcn dev-network internal-net prod-backbone staging-vcn test-vcn core-net secure-vcn infra-net shared-vcn analytics-vcn sandbox-vcn external-net mobile-backend edge-vcn netzone control-plane service-mesh)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
      SUBNET_NAME="$(shuf -n 1 -e frontend-subnet backend-subnet db-subnet app-subnet mgmt-subnet internal-subnet public-subnet private-subnet web-subnet cache-subnet logging-subnet monitor-subnet proxy-subnet gateway-subnet storage-subnet analytics-subnet sandbox-subnet control-subnet user-subnet)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
      DELETE_DATE=$(date +%Y-%m-%d --date="+$((5 + RANDOM % 11)) days") # 5-10d

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
}

job7_create_volume() {
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

      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"
      local VOL_NAME="$(shuf -n 1 -e data-volume backup-volume log-volume db-volume test-volume data log backup db temp cache analytics archive test prod dev staging media files secure audit sys user project export import storage fast)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
      local DELETE_DATE=$(date +%Y-%m-%d --date="+$((5 + RANDOM % 11)) days") # 5-15d

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
}

job8_check_public_ip() {
      log_action "$TIMESTAMP" "network-info" "🎯 Checking public IPs" "start"
      sleep_random 2 8
      oci network public-ip list \
        --scope REGION \
        --compartment-id "$TENANCY_OCID" \
        --query "data[].\"ip-address\"" --raw-output \
        && log_action "$TIMESTAMP" "public-ip" "✅ Listed public IPs" "success" \
        || log_action "$TIMESTAMP" "public-ip" "❌ Failed to list public IPs" "fail"
}

job9_scan_auto_delete_resources(){
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
}

job10_cleanup_vcn_and_volumes() {
      local TODAY=$(date +%Y-%m-%d)

      log_action "$TIMESTAMP" "delete-vcn" "🔍 Scanning for expired VCNs" "start"

      VCNs=$(oci network vcn list --compartment-id "$TENANCY_OCID" \
        --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true'].{name:\"display-name\",id:id}" \
        --raw-output)

      parse_json_array "$VCNs" | while IFS='|' read -r VCN_ID VCN_NAME; do
        DELETE_DATE=$(oci network vcn get --vcn-id "$VCN_ID" \
          --query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          --raw-output 2>/dev/null)
        if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
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
        if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
          sleep_random 1 10
          oci bv volume delete --volume-id "$VOL_ID" --force \
            && log_action "$TIMESTAMP" "delete-volume" "✅ Deleted volume $VOL_NAME (expired: $DELETE_DATE)" "success" \
            || log_action "$TIMESTAMP" "delete-volume" "❌ Failed to delete volume $VOL_NAME" "fail"
        fi
      done
}

job11_deploy_bucket() {
     	ensure_namespace_auto
        ensure_tag "auto-delete" "Mark for auto deletion"
	ensure_tag "auto-delete-date" "Scheduled auto delete date"
 	DEPLOY_BUCKET="$(shuf -n 1 -e deploy-artifacts deployment-store deploy-backup pipeline-output release-bucket release-artifacts staging-artifacts prod-deployments ci-output dev-pipeline test-release build-cache image-artifacts lambda-packages terraform-output cloud-functions deploy-packages versioned-deployments rollout-bucket rollout-stage canary-release bucket-publish)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
      	BUCKET_EXISTS=$(oci os bucket get --bucket-name "$DEPLOY_BUCKET" --query 'data.name' --raw-output 2>/dev/null)

	if [ -z "$BUCKET_EXISTS" ]; then
	  DELETE_DATE=$(date +%Y-%m-%d --date="+$((5 + RANDOM % 11)) days") # 5-15d
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
}

job12_update_volume_resource_tag() {
	log_action "$TIMESTAMP" "update-volume-tag" "🔍 Scanning volumes for tagging..." "start"

	VOLS=$(oci bv volume list --compartment-id "$TENANCY_OCID" --query "data[?\"lifecycle-state\"!='TERMINATED'].{id:id, name:\"display-name\"}" --raw-output)
	
	VOL_COUNT=$(echo "$VOLS" | grep -c '"id"')
	if [[ -z "$VOLS" || "$VOL_COUNT" -eq 0 ]]; then
	    log_action "$TIMESTAMP" "update-volume-tag" "❌ No volumes found to tag" "skipped"
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
}

job13_update_bucket_resource_tag() {
	log_action "$TIMESTAMP" "update-bucket-tag" "🔍 Scanning bucket for tagging..." "start"

	BUCKETS=$(oci os bucket list --compartment-id "$TENANCY_OCID" \
	    --query "data[].name" --raw-output)
	
	BUCKET_COUNT=$(echo "$BUCKETS" | grep -c '"')
	if [[ -z "$BUCKETS" || "$BUCKET_COUNT" -eq 0 ]]; then
	   log_action "$TIMESTAMP" "update-bucket-tag" "❌ No buckets found to tag" "skipped"
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
}

job14_edit_volume() {
	log_action "$TIMESTAMP" "edit-volume-size" "🔍 Scanning volumes with auto-delete=true for edit size..." "start"
	
	local VOLS=$(oci bv volume list --compartment-id "$TENANCY_OCID" \
	  --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true' && \"lifecycle-state\"!='TERMINATED'].{id:id, name:\"display-name\"}" \
	  --raw-output)
	
	local VOL_COUNT=$(echo "$VOLS" | grep -c '"id"')
	
	if [[ -z "$VOLS" || "$VOL_COUNT" -eq 0 ]]; then
	  log_action "$TIMESTAMP" "edit-volume-size" "❌ No volumes with auto-delete=true found to edit size" "skipped"
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
}

job15_create_dynamic_group() {
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
	  DELETE_DATE=$(date +%Y-%m-%d --date="+$((5 + RANDOM % 11)) days") #5 - 15d
	  if oci iam dynamic-group create \
	    --name "$DG_NAME" \
	    --description "$DESCRIPTION" \
     	    --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
	    --matching-rule "$RULE"; then
	    log_action "$TIMESTAMP" "$JOB_NAME" "✅ Created dynamic group '$DG_NAME' with purpose '$PURPOSE'" "success"
	  else
	    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to create dynamic group '$DG_NAME'" "error"
	  fi
}

job16_delete_dynamic_group() {
	log_action "$TIMESTAMP" "delete-dynamic-group" "🔍 Scanning for expired dynamic group" "start"
	local TODAY=$(date +%Y-%m-%d)
	local ITEMS=$(oci iam dynamic-group list --compartment-id "$TENANCY_OCID" --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true' && \"lifecycle-state\"!='TERMINATED'].{name:\"name\",id:id}" --raw-output)

      	parse_json_array "$ITEMS" | while IFS='|' read -r ITEM_ID ITEM_NAME; do
        	DELETE_DATE=$(oci iam dynamic-group get --dynamic-group-id "$ITEM_ID" \
          	--query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          	--raw-output 2>/dev/null)
        	if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
          		sleep_random 1 10
          		oci iam dynamic-group delete --dynamic-group-id "$ITEM_ID" --force \
            		&& log_action "$TIMESTAMP" "delete-dynamic-group" "✅ Deleted dynamic group $ITEM_NAME (expired: $DELETE_DATE)" "success" \
            		|| log_action "$TIMESTAMP" "delete-dynamic-group" "❌ Failed to delete dynamic group $ITEM_NAME" "fail"
        	fi
        done
}

job17_create_autonomous_db() {
	ensure_namespace_auto
	ensure_tag "auto-delete" "Mark for auto deletion"
	ensure_tag "auto-delete-date" "Scheduled auto delete date"
	local JOB_NAME="create-paid-autonomous-db"

	local PREFIXES=(sales marketing support ml ai analytics prod test hr finance dev backup log data staging ops infra core research it eng qa user admin security billing monitoring iot archive batch media internal external system network mobile api content insight reporting global region1 region2 cloud internaltool public edge compliance)
	local FUNCTIONS=(db data store system core service report etl dash pipeline api processor engine runner worker consumer sync fetcher collector ingester writer generator uploader model exporter deployer sink source controller frontend backend scheduler monitor)
	local SUFFIXES=("01" "2025" "$((RANDOM % 100))" "$(date +%y)" "$(date +%m%d)")
	local DB_NAME_PART="${PREFIXES[RANDOM % ${#PREFIXES[@]}]}-${FUNCTIONS[RANDOM % ${#FUNCTIONS[@]}]}-${SUFFIXES[RANDOM % ${#SUFFIXES[@]}]}-$(uuidgen | cut -c1-6)"
	local DB_NAME=$(echo "$DB_NAME_PART" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c1-30)
	local DISPLAY_NAME="${DB_NAME_PART^}"
	local ADMIN_PASSWORD=$(random_password)

	# Check available eCPU quota for Paid Autonomous Database
	local ECPU_AVAILABLE=$(oci limits resource-availability get \
	  --service-name database \
	  --limit-name adw-ecpu-count \
	  --compartment-id "$TENANCY_OCID" \
	  --query "data.available" \
	  --raw-output)
	if [[ $ECPU_AVAILABLE -le 0 ]]; then
		  log_action "$TIMESTAMP" "create-free-autonomous-db" "⚠️ No remaining eCPU quota → attempting to create an Always Free Autonomous DB..." "info"
		  # Count existing Free Autonomous Databases
		  local FREE_DB_COUNT=$(oci db autonomous-database list \
		    --compartment-id "$TENANCY_OCID" \
		    --query "length(data[?\"is-free-tier\"==\`true\`])" \
		    --all --raw-output)
		
		  if [[ "$FREE_DB_COUNT" -lt 2 ]]; then
      		    log_action "$TIMESTAMP" "create-free-autonomous-db" "✅ $FREE_DB_COUNT Free ADB(s) detected → proceeding to create a new Free ADB" "info"
		    local RANDOM_HOURS=$((RANDOM % 145 + 24))  # 24 ≤ H ≤ 168
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
  		local RANDOM_HOURS=$((RANDOM % 145 + 24))  # 24 ≤ H ≤ 168
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
}

job18_delete_autonomous_db() {
	log_action "$TIMESTAMP" "delete-autonomous-db" "🔍 Scanning for expired autonomous db" "start"
	local NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	local ITEMS=$(oci db autonomous-database list --compartment-id "$TENANCY_OCID" --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true' && \"lifecycle-state\"!='TERMINATED'].{name:\"display-name\",id:id}" --raw-output)

      	parse_json_array "$ITEMS" | while IFS='|' read -r ITEM_ID ITEM_NAME; do
        	DELETE_DATE=$(oci db autonomous-database get --autonomous-database-id "$ITEM_ID" \
          	--query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          	--raw-output 2>/dev/null)
        	if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$NOW" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
          		sleep_random 2 10
	    		if oci db autonomous-database delete --autonomous-database-id "$ITEM_ID" --force; then
			    log_action "$TIMESTAMP" "delete-autonomous-db" "✅ Deleted autonomous db $ITEM_NAME (expired: $DELETE_DATE)" "success"
			    sed -i "/^$ITEM_ID|/d" "$ACTION_LOG_FILE" 2>/dev/null
			else
			    log_action "$TIMESTAMP" "delete-autonomous-db" "❌ Failed to delete autonomous db $ITEM_NAME" "fail"
			fi
        	fi
        done
}

job19_toggle_autonomous_db() {
	  local JOB_NAME="toggle-autonomous-db"
	
	  local DBS=$(oci db autonomous-database list \
	    --compartment-id "$TENANCY_OCID" \
	    --query "data[?\"lifecycle-state\"=='AVAILABLE' || \"lifecycle-state\"=='STOPPED'].{id:id, name:\"display-name\", state:\"lifecycle-state\"}" \
	    --raw-output)

	  local DB_COUNT=$(echo "$DBS" | grep -c '"id"')
	  if [[ -z "$DBS" || "$DB_COUNT" -eq 0 ]]; then
		  log_action "$TIMESTAMP" "$JOB_NAME" "❌ No DB found to toggle" "skipped"
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
		    log_action "$TIMESTAMP" "$JOB_NAME" "⏱ DB '$DB_NAME' ($DB_STATE) last toggled $HOURS_DIFF hour(s) ago < 4h — skip" "skipped"
		    return
		  fi
		
		  if [[ "$HOURS_DIFF" -lt 10 && $((RANDOM % 2)) -eq 0 ]]; then
		    log_action "$TIMESTAMP" "$JOB_NAME" "🤏 Waiting for more time before toggling '$DB_NAME' ($DB_STATE) ($HOURS_DIFF hours)" "delayed"
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
			  log_action "$TIMESTAMP" "$JOB_NAME" "⏩ DB '$DB_NAME' ($DB_STATE) already in desired state" "skipped"
			  return
		  fi
		
		  sed -i "/^$DB_OCID|/d" "$ACTION_LOG_FILE" 2>/dev/null
		  echo "$DB_OCID|$TIMESTAMP" >> "$ACTION_LOG_FILE"
	  fi
}

job20_create_random_private_endpoint() {
  local JOB_NAME="create-private-endpoint"

  local MAX_PE_LIMIT=10
	
  local CURRENT_PE_COUNT=$(oci os private-endpoint list \
	  --compartment-id "$TENANCY_OCID" \
	  --query "length(data)" \
	  --raw-output)
   
  if [[ "$CURRENT_PE_COUNT" -ge "$MAX_PE_LIMIT" ]]; then
    log_action "$TIMESTAMP" "$JOB_NAME" \
	    "❌ PE limit reached: $CURRENT_PE_COUNT / $MAX_PE_LIMIT" "skipped"
    return;
  fi

  if [[ $((RANDOM % 10)) -eq 0 ]]; then
    log_action "$TIMESTAMP" "$JOB_NAME" "🤏 Waiting for more time" "delayed"
    return
  fi
  log_action "$TIMESTAMP" "$JOB_NAME" "✅ Sufficient Private Endpoint quota ($CURRENT_PE_COUNT / $MAX_PE_LIMIT) → creating Private Endpoint..." "info"
  ensure_namespace_auto
  ensure_tag "auto-delete" "Mark for auto deletion"
  ensure_tag "auto-delete-date" "Scheduled auto delete date"

  local VCN_LIST=$(oci network vcn list --compartment-id "$TENANCY_OCID" --query "data[].{id:id, name:\"display-name\"}" --raw-output)

  local VCN_COUNT=$(echo "$VCN_LIST" | grep -c '"id"')
  if [[ -z "$VCN_LIST" || "$VCN_COUNT" -eq 0 ]]; then
    log_action "$TIMESTAMP" "$JOB_NAME" "❌ No VCNs found in compartment" "skipped"
    return;
  fi

  local VCN_SELECTED_LINE=$((RANDOM % VCN_COUNT + 1))
  local VCN_SELECTED=$(parse_json_array "$VCN_LIST" | sed -n "${VCN_SELECTED_LINE}p")
  IFS='|' read -r VCN_ID VCN_NAME <<< "$VCN_SELECTED"

  local SUBNET_LIST=$(oci network subnet list --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" --query "data[].{id:id, name:\"display-name\"}" --raw-output)

  local SUBNET_COUNT=$(echo "$SUBNET_LIST" | grep -c '"id"')
  if [[ -z "$SUBNET_LIST" || "$SUBNET_COUNT" -eq 0 ]]; then
    log_action "$TIMESTAMP" "$JOB_NAME" "❌ No subnets found in VCN $VCN_NAME" "skipped"
    return;
  fi

  local SUBNET_SELECTED_LINE=$((RANDOM % SUBNET_COUNT + 1))
  local SUBNET_SELECTED=$(parse_json_array "$SUBNET_LIST" | sed -n "${SUBNET_SELECTED_LINE}p")
  IFS='|' read -r SUBNET_ID SUBNET_NAME <<< "$SUBNET_SELECTED"

  local NAME_PREFIXES=(pe-prod pe-dev pe-db pe-app pe-api pe-internal pe-staging pe-test pe-secure private-endpoint internal-access service-endpoint vcn-endpoint subnet-access backend-pe frontend-pe analytics-pe reporting-pe data-access endpoint-gateway db-endpoint log-endpoint app-endpoint monitoring-pe secure-channel edge-endpoint mgmt-pe internal-pe vpn-endpoint core-pe proxy-endpoint dashboard-pe vault-access tenant-pe customer-endpoint storage-endpoint private-comm tunnel-pe function-endpoint worker-pe system-pe compliance-endpoint external-access mesh-endpoint)
  local RANDOM_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)
  local RANDOM_PREFIX=${NAME_PREFIXES[$RANDOM % ${#NAME_PREFIXES[@]}]}
  local PE_NAME="${RANDOM_PREFIX}-${RANDOM_SUFFIX}"

  local DELETE_DATE=$(date +%Y-%m-%d --date="+$(( RANDOM % 26 + 5 )) days") #5 - 30d

  local NAMESPACE=$(oci os ns get \
	  --query "data" \
	  --raw-output)

  if oci os private-endpoint create \
    --compartment-id "$TENANCY_OCID" \
    --subnet-id "$SUBNET_ID" \
    --prefix "$RANDOM_PREFIX" \
    --access-targets '[{"namespace":"'${NAMESPACE}'", "compartmentId":"*", "bucket":"*"}]' \
    --name "$PE_NAME" \
    --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
    --wait-for-state COMPLETED; then
    log_action "$TIMESTAMP" "$JOB_NAME" "✅ Created Private Endpoint $PE_NAME in subnet $SUBNET_NAME" "success"
  else
    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to create Private Endpoint $PE_NAME" "fail"
  fi
}

job21_delete_private_endpoint() {
	log_action "$TIMESTAMP" "delete-private-endpoint" "🔍 Scanning for expired private endpoint" "start"
	local TODAY=$(date +%Y-%m-%d)
	local ITEMS=$(oci os private-endpoint list --compartment-id "$TENANCY_OCID" --query "data[].name" --raw-output)
	for ITEM_NAME in $(parse_json_array_string "$ITEMS"); do
		local DELETE_DATE=$(oci os private-endpoint get --pe-name "$ITEM_NAME" \
          	--query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          	--raw-output 2>/dev/null)
        	if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
          		sleep_random 1 10
	    		if oci os private-endpoint delete --pe-name "$ITEM_NAME" --force; then
			    log_action "$TIMESTAMP" "delete-private-endpoint" "✅ Deleted private endpoint $ITEM_NAME (expired: $DELETE_DATE)" "success"
			else
			    log_action "$TIMESTAMP" "delete-private-endpoint" "❌ Failed to delete private endpoint $ITEM_NAME" "fail"
			fi
        	fi
	done
}

job22_create_random_nosql_table() {
  local JOB_NAME="create-nosql-table"

  local AVAILABLE_GB=$(oci limits resource-availability get \
    --service-name nosql \
    --limit-name table-size-gb \
    --compartment-id "$TENANCY_OCID" \
    --query "data.available" \
    --raw-output 2>/dev/null)

  if [[ -z "$AVAILABLE_GB" || "$AVAILABLE_GB" -le 0 ]]; then
	log_action "$TIMESTAMP" "$JOB_NAME" "❌ NoSQL table storage quota reached: $AVAILABLE_GB available" "skipped"
	return;
  fi
  log_action "$TIMESTAMP" "$JOB_NAME" "✅ Sufficient NoSQL table size GB quota ($AVAILABLE_GB) → creating NoSQL table..." "info"
  ensure_namespace_auto
  ensure_tag "auto-delete" "Mark for auto deletion"
  ensure_tag "auto-delete-date" "Scheduled auto delete date"
  
  local READ_UNITS=$((RANDOM % 90 + 10))   # 10–99
  local WRITE_UNITS=$((RANDOM % 90 + 10))  # 10–99
  local STORAGE_GB=1

  local -a TABLE_NAMES=(
  	"user_profile" "user_activity" "session_tokens" "login_attempts" "audit_logs"
  	"sensor_data" "device_status" "iot_metrics" "location_updates" "alerts"
  	"orders" "order_items" "inventory" "product_catalog" "pricing"
  	"payment_logs" "invoices" "billing_events" "refund_requests" "cart_items"
  	"notifications" "messages" "email_queue" "sms_queue" "push_events"
  	"click_stream" "web_events" "page_views" "ab_tests" "feature_flags"
  	"support_tickets" "error_logs" "service_health" "deployment_events" "api_usage"
  )

  local -a DDL_LIST=(
	  "CREATE TABLE IF NOT EXISTS %s (user_id STRING, name STRING, email STRING, created_at LONG, PRIMARY KEY(user_id))"
	  "CREATE TABLE IF NOT EXISTS %s (user_id STRING, action STRING, ts LONG, PRIMARY KEY(user_id, ts))"
	  "CREATE TABLE IF NOT EXISTS %s (session_id STRING, user_id STRING, token STRING, expiry_ts LONG, PRIMARY KEY(session_id))"
	  "CREATE TABLE IF NOT EXISTS %s (username STRING, ip STRING, success BOOLEAN, ts LONG, PRIMARY KEY(username, ts))"
	  "CREATE TABLE IF NOT EXISTS %s (log_id STRING, level STRING, message STRING, ts LONG, PRIMARY KEY(log_id))"
	
	  "CREATE TABLE IF NOT EXISTS %s (device_id STRING, temp FLOAT, humidity FLOAT, ts LONG, PRIMARY KEY(device_id))"
	  "CREATE TABLE IF NOT EXISTS %s (device_id STRING, status STRING, last_seen LONG, battery INT, PRIMARY KEY(device_id))"
	  "CREATE TABLE IF NOT EXISTS %s (device_id STRING, metric STRING, value FLOAT, ts LONG, PRIMARY KEY(device_id, metric))"
	  "CREATE TABLE IF NOT EXISTS %s (user_id STRING, lat DOUBLE, lon DOUBLE, ts LONG, PRIMARY KEY(user_id, ts))"
	  "CREATE TABLE IF NOT EXISTS %s (alert_id STRING, type STRING, severity STRING, ts LONG, PRIMARY KEY(alert_id))"
	
	  "CREATE TABLE IF NOT EXISTS %s (order_id STRING, user_id STRING, status STRING, total DOUBLE, created_at LONG, PRIMARY KEY(order_id))"
	  "CREATE TABLE IF NOT EXISTS %s (item_id STRING, order_id STRING, product_id STRING, quantity INT, PRIMARY KEY(item_id))"
	  "CREATE TABLE IF NOT EXISTS %s (sku STRING, stock INT, updated_at LONG, PRIMARY KEY(sku))"
	  "CREATE TABLE IF NOT EXISTS %s (product_id STRING, name STRING, category STRING, price DOUBLE, PRIMARY KEY(product_id))"
	  "CREATE TABLE IF NOT EXISTS %s (sku STRING, base_price DOUBLE, discount DOUBLE, effective_date LONG, PRIMARY KEY(sku))"
	
	  "CREATE TABLE IF NOT EXISTS %s (payment_id STRING, user_id STRING, amount DOUBLE, status STRING, ts LONG, PRIMARY KEY(payment_id))"
	  "CREATE TABLE IF NOT EXISTS %s (invoice_id STRING, user_id STRING, total DOUBLE, due_date LONG, PRIMARY KEY(invoice_id))"
	  "CREATE TABLE IF NOT EXISTS %s (event_id STRING, event_type STRING, billing_group STRING, ts LONG, PRIMARY KEY(event_id))"
	  "CREATE TABLE IF NOT EXISTS %s (refund_id STRING, order_id STRING, reason STRING, status STRING, PRIMARY KEY(refund_id))"
	  "CREATE TABLE IF NOT EXISTS %s (cart_id STRING, user_id STRING, product_id STRING, qty INT, PRIMARY KEY(cart_id, product_id))"
	
	  "CREATE TABLE IF NOT EXISTS %s (notif_id STRING, user_id STRING, type STRING, sent_at LONG, PRIMARY KEY(notif_id))"
	  "CREATE TABLE IF NOT EXISTS %s (msg_id STRING, sender STRING, recipient STRING, body STRING, ts LONG, PRIMARY KEY(msg_id))"
	  "CREATE TABLE IF NOT EXISTS %s (email_id STRING, recipient STRING, subject STRING, queued_at LONG, PRIMARY KEY(email_id))"
	  "CREATE TABLE IF NOT EXISTS %s (sms_id STRING, phone STRING, content STRING, sent_at LONG, PRIMARY KEY(sms_id))"
	  "CREATE TABLE IF NOT EXISTS %s (push_id STRING, user_id STRING, platform STRING, ts LONG, PRIMARY KEY(push_id))"
	
	  "CREATE TABLE IF NOT EXISTS %s (click_id STRING, user_id STRING, element STRING, ts LONG, PRIMARY KEY(click_id))"
	  "CREATE TABLE IF NOT EXISTS %s (event_id STRING, event_name STRING, metadata JSON, ts LONG, PRIMARY KEY(event_id))"
	  "CREATE TABLE IF NOT EXISTS %s (view_id STRING, user_id STRING, page STRING, duration INT, ts LONG, PRIMARY KEY(view_id))"
	  "CREATE TABLE IF NOT EXISTS %s (test_id STRING, group STRING, variant STRING, PRIMARY KEY(test_id))"
	  "CREATE TABLE IF NOT EXISTS %s (flag STRING, enabled BOOLEAN, updated_at LONG, PRIMARY KEY(flag))"
	
	  "CREATE TABLE IF NOT EXISTS %s (ticket_id STRING, user_id STRING, status STRING, priority STRING, created_at LONG, PRIMARY KEY(ticket_id))"
	  "CREATE TABLE IF NOT EXISTS %s (error_id STRING, code STRING, msg STRING, ts LONG, PRIMARY KEY(error_id))"
	  "CREATE TABLE IF NOT EXISTS %s (service_id STRING, status STRING, updated_at LONG, PRIMARY KEY(service_id))"
	  "CREATE TABLE IF NOT EXISTS %s (deploy_id STRING, service STRING, version STRING, ts LONG, PRIMARY KEY(deploy_id))"
	  "CREATE TABLE IF NOT EXISTS %s (api_id STRING, user_id STRING, endpoint STRING, latency FLOAT, ts LONG, PRIMARY KEY(api_id))"
  )

  local IDX=$((RANDOM % ${#TABLE_NAMES[@]}))
  local BASE_NAME="${TABLE_NAMES[$IDX]}"
  local RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 5)
  local TABLE_NAME="${BASE_NAME}_${RANDOM_SUFFIX}"

  local DDL_TEMPLATE="${DDL_LIST[$IDX]}"
  local DDL=$(printf "$DDL_TEMPLATE" "$TABLE_NAME")
  local DELETE_DATE=$(date +%Y-%m-%d --date="+$(( RANDOM % 26 + 5 )) days") #5 - 30d
  if oci nosql table create \
    --compartment-id "$TENANCY_OCID" \
    --name "$TABLE_NAME" \
    --ddl-statement "$DDL" \
    --table-limits "{\"maxReadUnits\": $READ_UNITS, \"maxWriteUnits\": $WRITE_UNITS, \"maxStorageInGBs\": $STORAGE_GB}" \
    --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
    --wait-for-state SUCCEEDED; then
    log_action "$TIMESTAMP" "$JOB_NAME" "✅ Created NoSQL table $TABLE_NAME" "success"
  else
    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to create NoSQL table $TABLE_NAME" "fail"
  fi
}

job23_delete_nosql_table() {
	local JOB_NAME="delete-nosql-table"
	log_action "$TIMESTAMP" "$JOB_NAME" "🔍 Scanning for expired nosql table" "start"
	local TODAY=$(date +%Y-%m-%d)
	local ITEMS=$(oci nosql table list --compartment-id "$TENANCY_OCID" --query "data.items[?\"defined-tags\".auto.\"auto-delete\"=='true' && \"lifecycle-state\"!='DELETED'].name" --raw-output)
	for ITEM_NAME in $(parse_json_array_string "$ITEMS"); do
		local DELETE_DATE=$(oci nosql table get --table-name-or-id "$ITEM_NAME" \
          	--query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
	   	--compartment-id "$TENANCY_OCID" \
          	--raw-output 2>/dev/null)
        	if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
          		sleep_random 1 10
	    		if oci nosql table delete --table-name-or-id "$ITEM_NAME" --compartment-id "$TENANCY_OCID" --force; then
			    log_action "$TIMESTAMP" "$JOB_NAME" "✅ Deleted nosql table $ITEM_NAME (expired: $DELETE_DATE)" "success"
			else
			    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to delete nosql table $ITEM_NAME" "fail"
			fi
        	fi
	done
}

job24_upload_random_row_to_nosql_table() {
  local JOB_NAME="upload_random_row_to_nosql_table"
  log_action "$TIMESTAMP" "$JOB_NAME" "🔍 Scanning for nosql table" "start"
  local TABLES=$(oci nosql table list --compartment-id "$TENANCY_OCID" --query "data.items[?\"defined-tags\".auto.\"auto-delete\"=='true' && \"lifecycle-state\"!='DELETED'].name" --raw-output)
  local TABLE_COUNT=$(echo "$TABLES" | grep -c '"')
  
  if [[ -z "$TABLES" || "$TABLE_COUNT" -eq 0 ]]; then
    log_action "$TIMESTAMP" "$JOB_NAME" "❌ No nosql table" "skipped"
    return;
  fi
  
  local ITEMS=$(echo "$TABLES" | grep -o '".*"' | tr -d '"')
  readarray -t TABLE_ARRAY <<< "$ITEMS"
  local RANDOM_INDEX=$(( RANDOM % ${#TABLE_ARRAY[@]} ))
  local TABLE_NAME="${TABLE_ARRAY[$RANDOM_INDEX]}"
  
  local COLUMNS=$(oci nosql table get \
    --table-name-or-id "$TABLE_NAME" \
    --compartment-id "$TENANCY_OCID" \
    --query "data.schema.columns[*].{id:name, name:type}" \
    --raw-output)

  local COLUM_COUNT=$(echo "$COLUMNS" | grep -c '"id"')
  if [[ -z "$COLUMNS" || "$COLUM_COUNT" -eq 0 ]]; then
    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to get schema of $TABLE_NAME" "fail"
    return;
  fi
  
  local ROW_COUNT=$((RANDOM % 5 + 1))
  local PARSED_COLUMNS=$(parse_json_array "$COLUMNS")
  
  log_action "$TIMESTAMP" "$JOB_NAME" "⬆️ Starting to upload $ROW_COUNT row(s) into table '$TABLE_NAME'" "info"
  
  for ((i = 1; i <= ROW_COUNT; i++)); do
    local VALUE_JSON="{"
    local FIRST=true
    local PRIMARY_KEY=""

    while IFS='|' read -r COL_NAME COL_TYPE; do
      local RAND_VAL=$(generate_realistic_value "$COL_NAME" "$COL_TYPE")

      [[ "$FIRST" = false ]] && VALUE_JSON+=", "
      VALUE_JSON+="\"$COL_NAME\": $RAND_VAL"
      [[ -z "$PRIMARY_KEY" ]] && PRIMARY_KEY="$RAND_VAL"
      FIRST=false
    done <<< "$PARSED_COLUMNS"
    
    VALUE_JSON+="}"
    if oci nosql row update \
	    --table-name-or-id "$TABLE_NAME" \
	    --compartment-id "$TENANCY_OCID" \
	    --value "$VALUE_JSON" --force; then
	    log_action "$TIMESTAMP" "$JOB_NAME" "✅ Uploaded row: $VALUE_JSON" "success"
    else
	    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed insert into $TABLE_NAME: $OUTPUT" "fail"
    fi
    sleep_random 5 30
  done
}


# === Session Check ===
#if oci iam user get --user-id "$USER_ID" &> /dev/null; then
#  log_action "$TIMESTAMP" "session" "✅ Get user info" "success"
#else
#  log_action "$TIMESTAMP" "session" "❌ Get user info" "fail"
#fi

# === Randomly select number of jobs to run ===
JOB_COUNT=$((RANDOM % 3 + 1))  # 1–3 job

ALL_JOBS=(
  job1_list_iam
  job2_check_quota
  job3_upload_random_files_to_bucket
  job4_cleanup_bucket
  job5_list_resources
  job6_create_vcn
  job7_create_volume
  job8_check_public_ip
  job9_scan_auto_delete_resources
  job10_cleanup_vcn_and_volumes
  job11_deploy_bucket
  job12_update_volume_resource_tag
  job13_update_bucket_resource_tag
  job14_edit_volume
  job15_create_dynamic_group
  job16_delete_dynamic_group
  job17_create_autonomous_db
  job18_delete_autonomous_db
  job19_toggle_autonomous_db
  job20_create_random_private_endpoint
  job21_delete_private_endpoint
  job22_create_random_nosql_table
  job23_delete_nosql_table
  job24_upload_random_row_to_nosql_table
)

SHUFFLED=($(shuf -e "${ALL_JOBS[@]}"))
LOG_JOBS=()

for i in $(seq 1 $JOB_COUNT); do
  FUNC="${SHUFFLED[$((i-1))]}"
  echo "▶️ Running: $FUNC"
  LOG_JOBS+=("$FUNC")
  "$FUNC"
  sleep_random 30 60
done

echo "✅ OCI simulation done: $JOB_COUNT job(s) run"
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
log_action "$TIMESTAMP" "simulate" "✅ OCI simulation done: $JOB_COUNT job(s) run: $(printf "%s, " "${LOG_JOBS[@]}" | sed 's/, $//') in $TOTAL_TIME_FORMATTED" "done"
