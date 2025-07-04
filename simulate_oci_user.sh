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
OCI_BEHAVIOR_FILE="$LOG_DIR/oci_user_behavior.log"
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
    sleep_random 3 5
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
    sleep_random 3 5
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
  local BASE_DIR="deploy_tmp"
  rm -rf "$BASE_DIR"
  mkdir -p "$BASE_DIR"

  local DIR_POOL=(api assets config docs handlers lib scripts services src tests utils)
  local DIR_COUNT=$((RANDOM % 6 + 5))
  local SELECTED_DIRS=($(shuf -e "${DIR_POOL[@]}" -n "$DIR_COUNT"))

  for dir in "${SELECTED_DIRS[@]}"; do
    mkdir -p "$BASE_DIR/$dir"
  done

  local FILE_NAMES=(
    "main.py" "config.yaml" "requirements.txt" "Dockerfile" ".env.example" "README.md"
    ".gitignore" "deploy.sh" "test_main.py" "helpers.py" "logger.py"
    "migrate_db.sh" "seed_data.sh" "sample.json" "config.json"
    "test_utils.py" "test_integration.py" "usage.md" "api_reference.md"
    "deploy.yml" "terraform.tf" "variables.tf" "setup.cfg" "LICENSE" "CHANGELOG.md"
  )

  local CONTENT_LIST=(
    "def handler(event, context):\n    user = event.get(\"user\", \"guest\")\n    return f\"Hello, {user}\""
    "app:\n  name: user-service\n  version: 1.0.0\n  debug: false\n  log_level: INFO"
    "requests\nflask\npydantic\nsqlalchemy\npytest"
    "FROM python:3.9\nWORKDIR /app\nCOPY . .\nRUN pip install -r requirements.txt\nCMD [\"python\", \"main.py\"]"
    "APP_ENV=production\nDB_URI=sqlite:///tmp.db\nSECRET_KEY=demo123\nTIMEOUT=30"
    "# Project Title\n\nThis is a simulated project for OCI testing.\n\n## Features\n- Simple handler\n- Deployment ready"
    ".env\n__pycache__/\n*.tar.gz\ndeploy_tmp/\n.env.local\n.vscode/\nbuild.tar.gz"
    "#!/bin/bash\nset -e\necho \"Deploying...\"\ntar -czf build.tar.gz .\noci os object put --bucket-name \"\$DEPLOY_BUCKET\" --name \"\$FOLDER/build.tar.gz\" --file build.tar.gz"
    "import unittest\nfrom main import handler\n\nclass TestMain(unittest.TestCase):\n    def test_guest(self):\n        self.assertEqual(handler({}, {}), \"Hello, guest\")"
    "def greet(name):\n    return f\"Hello, {name}\"\n\ndef add(a, b):\n    return a + b"
    "import logging\n\ndef get_logger(name):\n    logger = logging.getLogger(name)\n    logger.setLevel(logging.INFO)\n    return logger"
    "#!/bin/bash\nsqlite3 tmp.db < migrations/init.sql\necho \"Migration done.\"\necho \"Tables created.\""
    "#!/bin/bash\necho \"Seeding data...\"\nsqlite3 tmp.db \"INSERT INTO users (id, name) VALUES (1, 'admin');\""
    "{\n  \"users\": [\n    {\"id\": 1, \"name\": \"Alice\"},\n    {\"id\": 2, \"name\": \"Bob\"}\n  ]\n}"
    "{\n  \"settings\": {\n    \"debug\": true,\n    \"theme\": \"dark\"\n  }\n}"
    "import unittest\nfrom utils.helpers import greet\n\nclass TestUtils(unittest.TestCase):\n    def test_greet(self):\n        self.assertIn(\"Hello\", greet(\"test\"))"
    "def test_api():\n    assert True\n\ndef test_db():\n    assert 1 + 1 == 2"
    "# Usage Guide\n\n1. Clone the repo\n2. Install deps\n3. Run \'python main.py\'\n\n## Environment\nEnsure .env is configured."
    "# API Reference\n\n### GET /health\nReturns status.\n\n### POST /login\nRequires JSON body."
    "name: Deploy\non:\n  push:\n    branches: [main]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v2\n      - run: echo \"Building...\""
    "resource \"null_resource\" \"example\" {\n  provisioner \"local-exec\" {\n    command = \"echo Deploying...\"\n  }\n}"
    "variable \"region\" {\n  type = string\n  default = \"us-ashburn-1\"\n}"
    "[flake8]\nmax-line-length = 88\nexclude = .git,__pycache__,build,dist\n\n[mypy]\nignore_missing_imports = true"
    "MIT License\n\nPermission is hereby granted..."
    "## Changelog\n\n- v1.0.0 - Initial release\n- v1.0.1 - Added seed script\n- v1.0.2 - Refactored handlers"
  )

  local TOTAL_FILES=${#FILE_NAMES[@]}
  local COUNT_FILE=$((RANDOM % 61 + 40))  # 40–100 files
  local USED_INDEXES=()

  for ((i = 0; i < COUNT_FILE; i++)); do
    local tries=0
    while (( tries < 100 )); do
      IDX=$((RANDOM % TOTAL_FILES))
      if [[ ! " ${USED_INDEXES[*]} " =~ " ${IDX} " ]]; then
        USED_INDEXES+=("$IDX")
        FILENAME=${FILE_NAMES[$IDX]}
        CONTENT=${CONTENT_LIST[$IDX]}
        DIR=${SELECTED_DIRS[$((RANDOM % ${#SELECTED_DIRS[@]}))]}
        FILE_PATH="$BASE_DIR/$DIR/$FILENAME"
        mkdir -p "$(dirname "$FILE_PATH")"
        echo -e "$CONTENT" > "$FILE_PATH"
        echo "📝 Created $DIR/$FILENAME"
        break
      fi
      ((tries++))
    done
  done

  echo "✅ Finished generating $COUNT_FILE fake project files under deploy_tmp/"
}

generate_deploy_filename() {
  local PREFIXES=("oci" "cloud" "sim" "deploy" "pkg" "infra" "release" "bundle" "codebase" "snapshot")
  local SEPARATORS=("-" "_" "")
  local EXTENSIONS=("tar.gz" "tgz")

  local prefix="${PREFIXES[$((RANDOM % ${#PREFIXES[@]}))]}"
  local sep="${SEPARATORS[$((RANDOM % ${#SEPARATORS[@]}))]}"
  local ext="${EXTENSIONS[$((RANDOM % ${#EXTENSIONS[@]}))]}"

  local ts="$(date +%Y%m%d%H%M%S)"
  local hash="$(head /dev/urandom | tr -dc a-z0-9 | head -c$((5 + RANDOM % 3)))"

  echo "${prefix}${sep}${ts}${sep}${hash}.${ext}"
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
  col_type=$(echo "$col_type" | tr '[:lower:]' '[:upper:]')

  # Helper: random string
  rand_string() {
    tr -dc a-z0-9 </dev/urandom | head -c "$1"
  }

  # Helper: fake UUID
  rand_id() {
    echo "\"$(cat /proc/sys/kernel/random/uuid | cut -d'-' -f1)$(rand_string 4)\""
  }

  # Override by column name
  case "$col_name" in
    email)
      local name_part=$(rand_string 6)
      local domain=$(shuf -e gmail.com yahoo.com hotmail.com protonmail.com -n1)
      echo "\"$name_part@$domain\"" && return ;;
    ip)
      echo "\"$((RANDOM % 223 + 1)).$((RANDOM % 255)).$((RANDOM % 255)).$((RANDOM % 255))\"" && return ;;
    name|username)
      echo "\"$(tr -dc 'a-zA-Z' </dev/urandom | fold -w 1 | head -n1 | tr '[:lower:]' '[:upper:]')$(rand_string $((RANDOM % 5 + 3)))\"" && return ;;
    status|type|level|flag|group|variant|priority|reason|city|country|category)
      echo "\"$(rand_string $((RANDOM % 5 + 5)))\"" && return ;;
    subject)
      echo "\"$(tr -dc 'a-zA-Z ' </dev/urandom | fold -w 1 | head -n10 | tr -d '\n')\"" && return ;;
    *_id|id|user_id|session_id|order_id|invoice_id|cart_id|msg_id|event_id|notif_id|sku|product_id|item_id|device_id|log_id|deploy_id|refund_id|payment_id|push_id|ticket_id)
      rand_id && return ;;
    phone)
      echo "\"+84$(shuf -i 100000000-999999999 -n1)\"" && return ;;
    lat|lon)
      awk 'BEGIN{srand(); print (rand()*180-90)}' && return ;;
    created_at|updated_at|queued_at|sent_at|ts|timestamp|time)
      echo $(( $(date +%s%3N) - (RANDOM % 2592000000) )) && return ;;
    amount|price|total|base_price|discount|latency)
      awk 'BEGIN{srand(); printf "%.2f", rand()*1000}' && return ;;
  esac

  case "$col_type" in
    STRING)
      echo "\"$(rand_string $((RANDOM % 6 + 5)))\"" ;;
    INT|INTEGER)
      echo $((RANDOM % 10000)) ;;
    FLOAT|DOUBLE|NUMBER)
      awk 'BEGIN{srand(); printf "%.2f", rand()*1000}' ;;
    LONG)
      echo $(( $(date +%s%3N) - (RANDOM % 2592000000) )) ;;
    BOOLEAN)
      echo $([[ $((RANDOM % 2)) -eq 0 ]] && echo "true" || echo "false") ;;
    JSON)
      local lat=$(awk 'BEGIN{srand(); printf "%.6f", 10 + rand()*5}')
      local lon=$(awk 'BEGIN{srand(); printf "%.6f", 106 + rand()*5}')
      echo "{\"lat\": $lat, \"lon\": $lon}" ;;
    *)
      echo "\"$(rand_string 6)\"" ;;
  esac
}

generate_file_upload(){
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
      local FILE_TEMPLATE=${FILENAME_PATTERNS[$((RANDOM % ${#FILENAME_PATTERNS[@]}))]}
      local FILE_NAME=$(date +"$FILE_TEMPLATE")
      local FILE_CONTENT="${CONTENTS[$((RANDOM % ${#CONTENTS[@]}))]}"
       
      echo "$FILE_CONTENT" > "$FILE_NAME"
      echo "$FILE_NAME"
}

job1_list_iam() {
      log_action "$TIMESTAMP" "info" "List IAM info" "start"
      sleep_random 10 20
      oci iam region-subscription list && log_action "$TIMESTAMP" "region" "✅ List region subscription" "success"
      sleep_random 10 20
      oci iam availability-domain list && log_action "$TIMESTAMP" "availability-domain" "✅ List availability domains" "success"
}

job2_check_quota() {
      AD=$(oci iam availability-domain list --query "data[0].name" --raw-output)
      sleep_random 5 30
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
	BUCKET_NAME="$(shuf -n 1 -e \
	  app-logs media-assets db-backup invoice-data user-files \
	  analytics-data web-uploads archive-files system-dumps temp-storage \
	  config-snapshots public-content internal-backups nightly-reports \
	  event-logs docker-images container-layers lambda-archives frontend-assets \
	  raw-data processed-data staging-bucket final-exports customer-uploads \
	  logs-central user-avatars thumbnails db-dumps prod-exports \
	  temp-cache build-artifacts static-files secure-storage upload-zone \
	  metrics-data test-exports webhooks-storage incoming-data mail-logs \
	  infra-logs api-gateway-logs cloudtrail-logs monitoring-events \
	  terraform-states git-repos nightly-dumps chatbot-logs system-audit \
	  vpn-keys server-snapshots postgres-exports mysql-dumps \
	  redis-backup kafka-logs billing-records security-events \
	  s3-mirror bucket-sandbox redshift-exports elastic-dumps \
	  web-assets admin-files encrypted-uploads crash-reports \
	  api-responses compressed-assets debug-dumps \
	)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
	DELETE_DATE=$(date +%Y-%m-%d --date="+$((5 + RANDOM % 11)) days") # 5-15d
	log_action "$TIMESTAMP" "bucket-create" "🎯 Creating bucket $BUCKET_NAME with auto-delete" "start"
	sleep_random 10 20
        oci os bucket create \
	        --name "$BUCKET_NAME" \
	        --compartment-id "$TENANCY_OCID" \
	        --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
	        && log_action "$TIMESTAMP" "bucket-create" "✅ Created $BUCKET_NAME with auto-delete-date=$DELETE_DATE" "success" \
	        || log_action "$TIMESTAMP" "bucket-create" "❌ Failed to create $BUCKET_NAME" "fail"
      fi
	
      local NUM_UPLOADS=$((RANDOM % 5 + 1)) # 1–5 files
	
      for ((i = 1; i <= NUM_UPLOADS; i++)); do
	local FILE_NAME=$(generate_file_upload)
	
	if oci os object put --bucket-name "$BUCKET_NAME" --file "$FILE_NAME" --force; then
	   log_action "$TIMESTAMP" "bucket-upload" "✅ Uploaded $FILE_NAME to $BUCKET_NAME" "success"
	else
	   log_action "$TIMESTAMP" "bucket-upload" "❌ Failed to upload $FILE_NAME to $BUCKET_NAME" "fail"
	fi
	
	rm -f "$FILE_NAME"
	sleep_random 10 20
      done
}

job4_cleanup_bucket() {
      log_action "$TIMESTAMP" "auto-delete-scan" "🔍 Scanning for expired buckets with auto-delete=true" "start"
      TODAY=$(date +%Y-%m-%d)
      BUCKETS=$(oci os bucket list --compartment-id "$TENANCY_OCID" \
                --query "data[].name" \
                --raw-output)
      sleep_random 10 20
      for b in $(parse_json_array_string "$BUCKETS"); do
            DELETE_DATE=$(oci os bucket get --bucket-name "$b" \
                          --query 'data."defined-tags".auto."auto-delete-date"' \
                          --raw-output 2>/dev/null)
            sleep_random 10 20
            if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
              log_action "$TIMESTAMP" "bucket-delete-object" "🗑️ Deleting all objects in $b..." "start"
            
              OBJECTS=$(oci os object list --bucket-name "$b" --query "data[].name" --raw-output)
              for obj in $(parse_json_array_string "$OBJECTS"); do
                oci os object delete --bucket-name "$b" --name "$obj" --force \
                  && log_action "$TIMESTAMP" "bucket-delete-object" "✅ Deleted "$obj" from $b" "success" \
                  || log_action "$TIMESTAMP" "bucket-delete-object" "❌ Failed to delete "$obj" from $b" "fail"
                sleep_random 10 20
              done
              sleep_random 10 20
              oci os bucket delete --bucket-name "$b" --force \
                && log_action "$TIMESTAMP" "bucket-delete" "✅ Deleted expired bucket $b (expired: $DELETE_DATE)" "success" \
                || log_action "$TIMESTAMP" "bucket-delete" "❌ Failed to delete bucket $b (expired: $DELETE_DATE)" "fail"
            fi
      done
}

job5_list_resources() {
      log_action "$TIMESTAMP" "resource-view" "🔍 List common resources" "start"
      sleep_random 10 20
      oci network vcn list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "vcn-list" "✅ List VCNs" "success"
      sleep_random 10 60
      oci network subnet list --compartment-id "$TENANCY_OCID" && log_action "$TIMESTAMP" "subnet-list" "✅ List subnets" "success"
      sleep_random 10 60
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
      	log_action "$TIMESTAMP" "vcn-create" "⚠️ VCN quota reached: $VCN_AVAILABLE available" "skipped"
    	return;
      fi
      sleep_random 10 20
      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"

      VCN_NAME="$(shuf -n 1 -e \
	  app-vcn dev-network internal-net prod-backbone staging-vcn test-vcn \
	  core-net secure-vcn infra-net shared-vcn analytics-vcn sandbox-vcn \
	  external-net mobile-backend edge-vcn netzone control-plane service-mesh \
	  production-vcn dev-vcn lab-network demo-backbone \
	  main-vcn central-network zone-a-vcn zone-b-vcn zone-c-vcn \
	  oci-core-net cluster-network private-mesh secure-backbone \
	  backup-network isolated-vcn system-network zero-trust-net \
	  red-team-vcn blue-team-vcn feature-vcn \
	  shared-infra-vcn mgmt-vcn platform-vcn service-vcn observability-net \
	  internal-core-net trusted-network hybrid-vcn local-vcn \
	  bastion-network appmesh-vcn datacenter-net internet-gateway-vcn \
	  enterprise-vcn disaster-recovery-vcn high-availability-net \
	  secure-app-vcn microservices-net financial-vcn \
	  customer-facing-net partner-integration-vcn \
	  internal-services-vcn iot-vcn devops-vcn gitlab-vcn \
	  ml-platform-vcn ai-lab-net bigdata-vcn kafka-vcn \
	  streaming-vcn logging-vcn api-management-net \
	  auth-vcn compliance-net audit-vcn \
	  staging-mesh edge-secure-net performance-net metrics-vcn \
	  vulnerability-net fraud-detection-net \
	  dev-x vcn-y net-z net1 net2 net3 project1-vcn project2-vcn \
	)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
      SUBNET_NAME="$(shuf -n 1 -e \
	  frontend-subnet backend-subnet db-subnet app-subnet mgmt-subnet \
	  internal-subnet public-subnet private-subnet web-subnet cache-subnet \
	  logging-subnet monitor-subnet proxy-subnet gateway-subnet \
	  storage-subnet analytics-subnet sandbox-subnet control-subnet \
	  user-subnet api-subnet bastion-subnet ingress-subnet egress-subnet \
	  loadbalancer-subnet messaging-subnet search-subnet function-subnet \
	  admin-subnet readonly-subnet vpn-subnet dev-subnet prod-subnet test-subnet \
	  isolated-subnet zero-trust-subnet debug-subnet \
	  mobile-subnet edge-subnet firewall-subnet \
	  backup-subnet telemetry-subnet collector-subnet router-subnet \
	  ha-subnet standby-subnet redis-subnet kafka-subnet elastic-subnet \
	  ai-subnet ml-subnet training-subnet pipeline-subnet batch-subnet \
	  report-subnet audit-subnet compliance-subnet \
	  gitlab-subnet cicd-subnet monitoring-subnet \
	  app1-subnet app2-subnet app3-subnet db1-subnet db2-subnet \
	  zone-a-subnet zone-b-subnet zone-c-subnet net1-subnet net2-subnet \
	  partner-subnet external-subnet intranet-subnet isolated-subnet \
	  vpn-access-subnet admin-zone-subnet legacy-app-subnet \
	  live-stream-subnet video-transcode-subnet session-cache-subnet \
	  payment-gateway-subnet risk-analysis-subnet fraud-engine-subnet \
	)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
      DELETE_DATE=$(date +%Y-%m-%d --date="+$((5 + RANDOM % 11)) days") # 5-10d
      sleep_random 10 20
      log_action "$TIMESTAMP" "vcn-create" "🎯 Creating VCN $VCN_NAME with auto-delete" "start"
      VCN_ID=$(oci network vcn create \
	  --cidr-block "10.0.0.0/16" \
	  --compartment-id "$TENANCY_OCID" \
	  --display-name "$VCN_NAME" \
	  --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
	  --query "data.id" --raw-output 2> vcn_error.log)
      if [[ -n "$VCN_ID" ]]; then
        log_action "$TIMESTAMP" "vcn-create" "✅ Created VCN $VCN_NAME ($VCN_ID) with auto-delete-date=$DELETE_DATE" "success"
        sleep_random 10 20

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
      sleep_random 10 20
      local AVAILABLE_STORAGE=$(oci limits resource-availability get \
	  --service-name block-storage \
	  --limit-name total-storage-gb \
	  --compartment-id "$TENANCY_OCID" \
	  --availability-domain "$AD" \
	  --query "data.available" \
	  --raw-output)
      
      log_action "$TIMESTAMP" "volume-create" "📦 Available Block Volume Storage: ${AVAILABLE_STORAGE} GB" "info"

      if [[ "$AVAILABLE_STORAGE" -lt 1000 ]]; then
	  log_action "$TIMESTAMP" "volume-create" "⚠️ Skipped: only $AVAILABLE_STORAGE GB left - Reason: Trial Expired" "skipped"
	  return
      fi
      sleep_random 10 20
      ensure_namespace_auto
      ensure_tag "auto-delete" "Mark for auto deletion"
      ensure_tag "auto-delete-date" "Scheduled auto delete date"
      local VOL_NAME="$(shuf -n 1 -e \
	  data-volume backup-volume log-volume db-volume test-volume \
	  cache-volume tmp-volume export-volume import-volume \
	  analytics-volume archive-volume report-volume snapshot-volume \
	  media-volume files-volume secure-volume audit-volume sys-volume \
	  user-volume app-volume system-volume project-volume build-volume \
	  runtime-volume docker-volume staging-volume prod-volume dev-volume \
	  metrics-volume events-volume error-volume access-volume crash-volume \
	  temp-files config-files scripts-files deploy-files static-assets \
	  compressed-assets raw-data processed-data temp-storage final-exports \
	  mysql-volume postgres-volume redis-volume kafka-volume \
	  mongo-volume elasticsearch-volume minio-volume influx-volume \
	  prometheus-volume grafana-volume traefik-volume \
	  zone-a-volume zone-b-volume zone-c-volume us-east-volume us-west-volume \
	  eu-central-volume ap-southeast-volume global-volume internal-volume \
	  shared-volume private-volume public-volume customer-volume team-volume \
	  user-data system-data api-data webhook-data image-cache video-cache \
	  audio-cache thumbnails backups-old backups-new \
	  frontend-volume backend-volume api-volume gateway-volume db-log-volume \
	  batch-job-volume job-result-volume lambda-temp-volume \
	  staging-tmp dev-tmp prod-tmp prod-final dev-preview user-temp \
	  data log backup db temp cache analytics archive test prod dev staging media files \
	  secure audit sys user project export import storage fast tmp snapshot report config \
	  images content bin etc conf cloud nightly archive2 object-store blob-store \
	)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
      local DELETE_DATE=$(date +%Y-%m-%d --date="+$((5 + RANDOM % 11)) days") # 5-15d
      sleep_random 10 20
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
      sleep_random 10 20
      TAGGED_VCNS=$(oci network vcn list --compartment-id "$TENANCY_OCID" \
        --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true'].\"display-name\"" --raw-output)
      for v in $(parse_json_array_string "$TAGGED_VCNS"); do
        log_action "$TIMESTAMP" "scan" "✅ Found auto-delete VCN: $v" "info"
      done
      sleep_random 10 20
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
      sleep_random 10 20
      parse_json_array "$VCNs" | while IFS='|' read -r VCN_ID VCN_NAME; do
        DELETE_DATE=$(oci network vcn get --vcn-id "$VCN_ID" \
          --query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          --raw-output 2>/dev/null)
        if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
          log_action "$TIMESTAMP" "auto-delete-vcn" "🎯 Preparing to delete VCN $VCN_NAME" "start"
          sleep_random 10 20
	  SUBNETS=$(oci network subnet list --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" \
            --query "data[].id" --raw-output)
          for subnet_id in $(parse_json_array_string "$SUBNETS"); do
            oci network subnet delete --subnet-id "$subnet_id" --force \
              && log_action "$TIMESTAMP" "delete-subnet" "✅ Deleted subnet $subnet_id in $VCN_NAME" "success" \
              || log_action "$TIMESTAMP" "delete-subnet" "❌ Failed to delete subnet $subnet_id" "fail"
            sleep_random 10 20
          done

          
          IGWS=$(oci network internet-gateway list --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" \
            --query "data[].id" --raw-output)
          for igw_id in $(parse_json_array_string "$IGWS"); do
            oci network internet-gateway delete --ig-id "$igw_id" --force \
              && log_action "$TIMESTAMP" "delete-igw" "✅ Deleted IGW $igw_id in $VCN_NAME" "success" \
              || log_action "$TIMESTAMP" "delete-igw" "❌ Failed to delete IGW $igw_id" "fail"
          done
	  sleep_random 10 20
   
          oci network vcn delete --vcn-id "$VCN_ID" --force \
            && log_action "$TIMESTAMP" "delete-vcn" "✅ Deleted VCN $VCN_NAME (expired: $DELETE_DATE)" "success" \
            || log_action "$TIMESTAMP" "delete-vcn" "❌ Failed to delete VCN $VCN_NAME" "fail"
        fi
      done

      sleep_random 10 20
      log_action "$TIMESTAMP" "delete-volume" "🔍 Scanning for expired block volumes" "start"

      VOLUMES=$(oci bv volume list --compartment-id "$TENANCY_OCID" --query "data[?\"defined-tags\".auto.\"auto-delete\"=='true' && \"lifecycle-state\"!='TERMINATED'].{name:\"display-name\",id:id}" --raw-output)

      parse_json_array "$VOLUMES" | while IFS='|' read -r VOL_ID VOL_NAME; do
        DELETE_DATE=$(oci bv volume get --volume-id "$VOL_ID" \
          --query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          --raw-output 2>/dev/null)
        if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
          sleep_random 10 20
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
 	DEPLOY_BUCKET="$(shuf -n 1 -e \
	  deploy-artifacts deployment-store deploy-backup pipeline-output \
	  release-bucket release-artifacts staging-artifacts prod-deployments \
	  ci-output dev-pipeline test-release build-cache image-artifacts \
	  lambda-packages terraform-output cloud-functions deploy-packages \
	  versioned-deployments rollout-bucket rollout-stage canary-release \
	  bucket-publish artifact-store artifact-cache pipeline-cache \
	  runner-output build-output compiled-assets serverless-artifacts \
	  docker-artifacts lambda-layers deploy-bundles snapshot-deployments \
	  build-assets frontend-deployments backend-deployments job-exports \
	  release-builds ci-cd-deployments test-results pre-release-assets \
	  app-deployments versioned-assets binary-packages packaged-artifacts \
	  auto-deploy-bucket update-channel main-release fallback-release \
	  qa-deployments nightly-builds weekly-rollouts docker-deploy-bucket \
	  hotfix-releases release-staging release-dev release-prod \
	  final-artifacts build-binaries compiled-code static-deploy \
	  public-deployments internal-deployments config-packages patch-deploy \
	  zero-downtime-deployments bucket-versioning beta-release \
	  ci-bucket test-bucket dev-bucket prod-bucket sandbox-deployments \
	  published-packages oci-deployments dist-folder dist-bucket \
	  npm-artifacts python-packages maven-deploys go-binaries \
	  helm-charts k8s-manifests manifests-bucket image-layers \
	  gitops-bucket registry-export terraform-state bucket-rollout \
	  changelog-storage changelog-releases milestone-artifacts \
	  deploy-metadata service-manifests update-pipeline release-summary \
	)-$(date +%Y%m%d)-$(openssl rand -hex 2)"
      	BUCKET_EXISTS=$(oci os bucket get --bucket-name "$DEPLOY_BUCKET" --query 'data.name' --raw-output 2>/dev/null)
        sleep_random 10 20
	if [ -z "$BUCKET_EXISTS" ]; then
	  DELETE_DATE=$(date +%Y-%m-%d --date="+$((5 + RANDOM % 11)) days") # 5-15d
	  oci os bucket create \
	    --name "$DEPLOY_BUCKET" \
	    --compartment-id "$TENANCY_OCID" \
	    --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
	    && log_action "$TIMESTAMP" "bucket-create" "✅ Created bucket $DEPLOY_BUCKET - DELETE_DATE: $DELETE_DATE for deployment" "success" \
	    || log_action "$TIMESTAMP" "bucket-create" "❌ Failed to create deployment bucket $DEPLOY_BUCKET" "fail"
	  sleep_random 10 20
        fi
 	# Create simulated project files
 	generate_fake_project_files
 	# Archive it
 	DEPLOY_FILE=$(generate_deploy_filename)
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
	    log_action "$TIMESTAMP" "update-volume-tag" "⚠️ No volumes found to tag" "skipped"
     	else
	    SELECTED_LINE=$((RANDOM % VOL_COUNT + 1))
	    SELECTED=$(parse_json_array "$VOLS" | sed -n "${SELECTED_LINE}p")
	    VOL_ID="${SELECTED%%|*}"
	    VOL_NAME="${SELECTED##*|}"
            sleep_random 10 20
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
	    sleep_random 10 20
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
	   log_action "$TIMESTAMP" "update-bucket-tag" "⚠️ No buckets found to tag" "skipped"
     	else
      	   ITEMS=$(echo "$BUCKETS" | grep -o '".*"' | tr -d '"')
           readarray -t BUCKET_ARRAY <<< "$ITEMS"
           RANDOM_INDEX=$(( RANDOM % ${#BUCKET_ARRAY[@]} ))
           BUCKET_NAME="${BUCKET_ARRAY[$RANDOM_INDEX]}"
	   sleep_random 10 20
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
	   sleep_random 10 20
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
	  log_action "$TIMESTAMP" "edit-volume-size" "⚠️ No volumes with auto-delete=true found to edit size" "skipped"
	else
          sleep_random 10 20
	  local AD=$(oci iam availability-domain list --query "data[0].name" --raw-output)
	  sleep_random 10 20
	  local AVAILABLE_STORAGE=$(oci limits resource-availability get \
	    --service-name block-storage \
	    --limit-name total-storage-gb \
	    --compartment-id "$TENANCY_OCID" \
	    --availability-domain "$AD" \
	    --query "data.available" \
	    --raw-output)
	
	  log_action "$TIMESTAMP" "edit-volume-size" "📦 Available Block Volume Storage: ${AVAILABLE_STORAGE} GB" "info"
	
	  if [[ "$AVAILABLE_STORAGE" -lt 1000 ]]; then
	    log_action "$TIMESTAMP" "edit-volume-size" "⚠️ Skipped: not enough storage (available: $AVAILABLE_STORAGE) - Reason: Trial Expired" "skipped"
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
	  sleep_random 10 20
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
	    "ursula" "victor" "will" "xander" "yuri" "zoe" "amy" "brian" "claire" "daniel"
	    "elena" "felix" "george" "hannah" "isaac" "julia" "kevin" "lisa" "michael"
	    "nina" "owen" "paula" "ron" "sophie" "tony" "una" "valerie" "wes" "xenia"
	    "yasmine" "zack" "team-alpha" "team-beta" "team-gamma" "team-delta"
	    "ops-core" "ml-lab" "data-science" "infra-group" "dev-squad"
	    "security-team" "networking" "frontend-team" "backend-team"
	    "cloud-admins" "sandbox-users" "qa-team" "fintech-dev" "iot-team"
	  )

	
	  local PURPOSES=(
	    "devops" "batch-jobs" "analytics" "autoscale" "monitoring" "ai-inference"
	    "image-processing" "log-ingestion" "internal-api" "customer-reporting"
	    "vpn-access" "db-backup" "event-stream" "data-export" "incident-response"
	    "terraform-ci" "cloud-health" "hpc-burst" "data-labeling" "iot-agent"
	    "threat-detection" "compliance-check" "cost-analysis" "zero-trust-policy"
	    "session-management" "email-service" "ocr-engine" "feature-flagging"
	    "rate-limiter" "api-gateway" "pubsub-handler" "kafka-stream"
	    "cdn-edge" "frontend-build" "metrics-ingestion" "timeseries-db"
	    "prometheus-exporter" "slack-integration" "alert-handler"
	    "cron-jobs" "dev-preview" "release-pipeline" "load-testing"
	    "integration-tests" "license-validator" "sftp-transfer"
	    "db-restore" "ml-training" "fin-data-pipeline" "dns-resolver"
	  )
	
	  local MATCH_RULES=(
	    "ALL {resource.type = 'instance', instance.compartment.id = '$TENANCY_OCID'}"
	    "ALL {resource.type = 'volume', volume.compartment.id = '$TENANCY_OCID'}"
	    "ANY {resource.type = 'autonomous-database'}"
	    "ALL {resource.compartment.id = '$TENANCY_OCID'}"
	    "ALL {resource.type = 'bootvolume'}"
	    "ALL {resource.type = 'bucket'}"
	    "ANY {resource.type = 'vcn', resource.compartment.id = '$TENANCY_OCID'}"
	    "ALL {resource.type = 'subnet'}"
	    "ALL {resource.type = 'security-list'}"
	    "ALL {resource.type = 'route-table'}"
	    "ANY {resource.type = 'group'}"
	    "ALL {resource.type = 'policy'}"
	    "ALL {resource.type = 'dynamic-group'}"
	    "ALL {resource.type = 'user'}"
	    "ALL {resource.type = 'tag-namespace'}"
	    "ALL {resource.type = 'instance-pool'}"
	    "ALL {resource.type = 'instance-configuration'}"
	    "ALL {resource.type = 'file-system'}"
	    "ALL {resource.type = 'mount-target'}"
	    "ANY {resource.type = 'stream'}"
	  )
	
	  local USER="${USERS[RANDOM % ${#USERS[@]}]}"
	  local PURPOSE="${PURPOSES[RANDOM % ${#PURPOSES[@]}]}"
	  local RULE="${MATCH_RULES[RANDOM % ${#MATCH_RULES[@]}]}"
	
	  local DG_NAME="dg-${USER}-${PURPOSE}-$((100 + RANDOM % 900))"
	  local DESCRIPTION="Dynamic group for ${USER}'s ${PURPOSE} tasks"
	  DELETE_DATE=$(date +%Y-%m-%d --date="+$((5 + RANDOM % 11)) days") #5 - 15d
	  sleep_random 10 20
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
        sleep_random 10 20
      	parse_json_array "$ITEMS" | while IFS='|' read -r ITEM_ID ITEM_NAME; do
        	DELETE_DATE=$(oci iam dynamic-group get --dynamic-group-id "$ITEM_ID" \
          	--query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          	--raw-output 2>/dev/null)
        	if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
          		sleep_random 10 20
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

	local PREFIXES=(
	  sales marketing support ml ai analytics prod test hr finance dev backup log data staging ops infra core research
	  it eng qa user admin security billing monitoring iot archive batch media internal external system network mobile api
	  content insight reporting global region1 region2 cloud internaltool public edge compliance
	  legal training helpdesk product risk mgmt supplychain frontend backend gateway access account customer vendor
	  sandbox beta alpha gamma delta servicecluster controlplane publicapi privateapi datalake
	  fraud billingops ci cd cicd scheduler eventbridge emailservice smsservice callcenter
	  container autoscaler deployment secretsmanager vault scanner observer telem trace alertmetrics
	  errorhandler replayer identity authorization authentication token issuer agent relay broker
	  replication syncer backupnode logcollector metricsproxy dbproxy streamingserver orchestrator
	  kafka zookeeper redis s3 gcs registry grafana prometheus tempo loki vaultbot configmgr
	)
	local FUNCTIONS=(
	  db data store system core service report etl dash pipeline api processor engine runner worker consumer sync
	  fetcher collector ingester writer generator uploader model exporter deployer sink source controller
	  frontend backend scheduler monitor validator calculator renderer translator tokenizer classifier
	  detector extractor transformer rewriter aggregator enricher filter encoder decoder trainer predictor evaluator
	  executor batcher listener watcher reader streamer broker dispatcher agent messenger handler manager
	  builder archiver logger parser chunker spawner sandboxer maintainer replayer restorer generator
	  digester postprocessor preprocessor signer analyzer normalizer hasher cacher seeder packager patcher
	  resizer scaler compressor deduplicator uploader downloader batchprocessor timeseries syncer
	  translator filterbot inferencer tagger relabeler deduplicator simulator indexer router resolver registrar
	)
	local SUFFIXES=("01" "2025" "$((RANDOM % 100))" "$(date +%y)" "$(date +%m%d)")
	local DB_NAME_PART="${PREFIXES[RANDOM % ${#PREFIXES[@]}]}-${FUNCTIONS[RANDOM % ${#FUNCTIONS[@]}]}-${SUFFIXES[RANDOM % ${#SUFFIXES[@]}]}-$(uuidgen | cut -c1-6)"
	local DB_NAME=$(echo "$DB_NAME_PART" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c1-30)
	local DISPLAY_NAME="${DB_NAME_PART^}"
	local ADMIN_PASSWORD=$(random_password)
        sleep_random 10 20
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
		  sleep_random 10 20
                  local FREE_DB_COUNT=$(oci db autonomous-database list \
		    --compartment-id "$TENANCY_OCID" \
		    --query "length(data[?\"is-free-tier\"==\`true\`])" \
		    --all --raw-output)
		
		  if [[ "$FREE_DB_COUNT" -lt 2 ]]; then
      		    log_action "$TIMESTAMP" "create-free-autonomous-db" "✅ $FREE_DB_COUNT Free ADB(s) detected → proceeding to create a new Free ADB" "info"
		    local RANDOM_HOURS=$((RANDOM % 145 + 24))  # 24 ≤ H ≤ 168
		    local DELETE_DATE=$(date -u -d "+$RANDOM_HOURS hours" '+%Y-%m-%dT%H:%M:%SZ')
		    # Create the Always Free Autonomous Database
		    sleep_random 10 20
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
		sleep_random 10 20
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
        sleep_random 10 20
      	parse_json_array "$ITEMS" | while IFS='|' read -r ITEM_ID ITEM_NAME; do
        	DELETE_DATE=$(oci db autonomous-database get --autonomous-database-id "$ITEM_ID" \
          	--query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          	--raw-output 2>/dev/null)
        	if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$NOW" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
          		sleep_random 10 20
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
		  log_action "$TIMESTAMP" "$JOB_NAME" "⚠️ No DB found to toggle" "skipped"
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
		  sleep_random 10 20
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
  CURRENT_PE_COUNT=${CURRENT_PE_COUNT:-0}
  if [[ "$CURRENT_PE_COUNT" -ge "$MAX_PE_LIMIT" ]]; then
    log_action "$TIMESTAMP" "$JOB_NAME" \
	    "⚠️ PE limit reached: $CURRENT_PE_COUNT / $MAX_PE_LIMIT" "skipped"
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
  sleep_random 10 20
  local VCN_LIST=$(oci network vcn list --compartment-id "$TENANCY_OCID" --query "data[].{id:id, name:\"display-name\"}" --raw-output)

  local VCN_COUNT=$(echo "$VCN_LIST" | grep -c '"id"')
  if [[ -z "$VCN_LIST" || "$VCN_COUNT" -eq 0 ]]; then
    log_action "$TIMESTAMP" "$JOB_NAME" " No VCNs found in compartment" "skipped"
    return;
  fi

  local VCN_SELECTED_LINE=$((RANDOM % VCN_COUNT + 1))
  local VCN_SELECTED=$(parse_json_array "$VCN_LIST" | sed -n "${VCN_SELECTED_LINE}p")
  IFS='|' read -r VCN_ID VCN_NAME <<< "$VCN_SELECTED"
  sleep_random 10 20
  local SUBNET_LIST=$(oci network subnet list --compartment-id "$TENANCY_OCID" --vcn-id "$VCN_ID" --query "data[].{id:id, name:\"display-name\"}" --raw-output)

  local SUBNET_COUNT=$(echo "$SUBNET_LIST" | grep -c '"id"')
  if [[ -z "$SUBNET_LIST" || "$SUBNET_COUNT" -eq 0 ]]; then
    log_action "$TIMESTAMP" "$JOB_NAME" "⚠️ No subnets found in VCN $VCN_NAME" "skipped"
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
  sleep_random 10 20
  local NAMESPACE=$(oci os ns get \
	  --query "data" \
	  --raw-output)
  sleep_random 10 20
  
  if ! oci os private-endpoint create \
    --compartment-id "$TENANCY_OCID" \
    --subnet-id "$SUBNET_ID" \
    --prefix "$RANDOM_PREFIX" \
    --access-targets '[{"namespace":"'${NAMESPACE}'", "compartmentId":"*", "bucket":"*"}]' \
    --name "$PE_NAME" \
    --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
    --wait-for-state COMPLETED 2>pe_error.log; then

    if grep -q "TooManyPrivateEndpoints" pe_error.log; then
      log_action "$TIMESTAMP" "$JOB_NAME" "⚠️ Skipped: Private endpoint quota exceeded" "skipped"
    else
      log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to create Private Endpoint $PE_NAME" "fail"
    fi
    return
  fi

  log_action "$TIMESTAMP" "$JOB_NAME" "✅ Created Private Endpoint $PE_NAME in subnet $SUBNET_NAME" "success"
}

job21_delete_private_endpoint() {
	log_action "$TIMESTAMP" "delete-private-endpoint" "🔍 Scanning for expired private endpoint" "start"
	local TODAY=$(date +%Y-%m-%d)
	local ITEMS=$(oci os private-endpoint list --compartment-id "$TENANCY_OCID" --query "data[].name" --raw-output)
	sleep_random 10 20
        for ITEM_NAME in $(parse_json_array_string "$ITEMS"); do
		local DELETE_DATE=$(oci os private-endpoint get --pe-name "$ITEM_NAME" \
          	--query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
          	--raw-output 2>/dev/null)
        	if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
          		sleep_random 10 20
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
	log_action "$TIMESTAMP" "$JOB_NAME" "⚠️ NoSQL table storage quota reached: $AVAILABLE_GB available" "skipped"
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
	  "user_permissions" "roles" "access_logs" "session_history" "device_metadata"
	  "campaigns" "ad_impressions" "conversion_events" "funnel_steps" "referral_links"
	  "shipping_details" "delivery_status" "returns" "warehouse_stock"
	  "financial_summary" "tax_records" "transaction_journal" "payouts"
	  "ml_predictions" "training_jobs" "model_versions" "feature_store" "inference_logs"
	  "workflow_tasks" "job_queue" "retry_attempts" "sla_breaches" "escalations"
	  "team_members" "project_assignments" "work_logs" "daily_reports" "calendar_events"
  )

  local -a DDL_LIST=(
	  "CREATE TABLE IF NOT EXISTS %s (
	     user_id STRING,
	     username STRING,
	     email STRING,
	     phone STRING,
	     address STRING,
	     city STRING,
	     country STRING,
	     zip STRING,
	     status STRING,
	     created_at LONG,
	     updated_at LONG,
	     PRIMARY KEY(user_id)
	  )"
	
	  "CREATE TABLE IF NOT EXISTS %s (
	     device_id STRING,
	     device_type STRING,
	     firmware_version STRING,
	     battery_level INTEGER,
	     location STRING,
	     last_seen_ts LONG,
	     is_active BOOLEAN,
	     tags JSON,
	     manufacturer STRING,
	     notes STRING,
	     installed_at LONG,
	     PRIMARY KEY(device_id)
	  )"
	
	  "CREATE TABLE IF NOT EXISTS %s (
	     order_id STRING,
	     user_id STRING,
	     order_status STRING,
	     payment_method STRING,
	     total_amount DOUBLE,
	     tax DOUBLE,
	     discount DOUBLE,
	     shipping_address STRING,
	     created_at LONG,
	     shipped_at LONG,
	     delivered_at LONG,
	     PRIMARY KEY(order_id)
	  )"
	
	  "CREATE TABLE IF NOT EXISTS %s (
	     event_id STRING,
	     source STRING,
	     event_type STRING,
	     metadata JSON,
	     user_agent STRING,
	     ip_address STRING,
	     region STRING,
	     latency_ms INTEGER,
	     success BOOLEAN,
	     timestamp LONG,
	     error_code STRING,
	     PRIMARY KEY(event_id)
	  )"
	
	  "CREATE TABLE IF NOT EXISTS %s (
	     model_id STRING,
	     version STRING,
	     parameters JSON,
	     accuracy FLOAT,
	     f1_score FLOAT,
	     precision FLOAT,
	     recall FLOAT,
	     dataset STRING,
	     trained_by STRING,
	     trained_at LONG,
	     notes STRING,
	     PRIMARY KEY(model_id, version)
	  )"
	
	  "CREATE TABLE IF NOT EXISTS %s (
	     invoice_id STRING,
	     customer_id STRING,
	     amount DOUBLE,
	     currency STRING,
	     issue_date LONG,
	     due_date LONG,
	     payment_status STRING,
	     items JSON,
	     tax_amount DOUBLE,
	     discount_amount DOUBLE,
	     pdf_url STRING,
	     PRIMARY KEY(invoice_id)
	  )"
	
	  "CREATE TABLE IF NOT EXISTS %s (
	     api_call_id STRING,
	     user_id STRING,
	     method STRING,
	     path STRING,
	     request_headers JSON,
	     request_body JSON,
	     response_code INTEGER,
	     response_time_ms INTEGER,
	     ts LONG,
	     geo_location STRING,
	     client_id STRING,
	     PRIMARY KEY(api_call_id)
	  )"
	
	  "CREATE TABLE IF NOT EXISTS %s (
	     session_id STRING,
	     user_id STRING,
	     start_ts LONG,
	     end_ts LONG,
	     ip_address STRING,
	     device STRING,
	     browser STRING,
	     os STRING,
	     screen_resolution STRING,
	     location STRING,
	     session_duration INTEGER,
	     PRIMARY KEY(session_id)
	  )"
	
	  "CREATE TABLE IF NOT EXISTS %s (
	     job_id STRING,
	     job_name STRING,
	     job_type STRING,
	     status STRING,
	     created_by STRING,
	     scheduled_at LONG,
	     started_at LONG,
	     finished_at LONG,
	     duration INTEGER,
	     result JSON,
	     retries INTEGER,
	     PRIMARY KEY(job_id)
	  )"
	
	  "CREATE TABLE IF NOT EXISTS %s (
	     alert_id STRING,
	     type STRING,
	     severity STRING,
	     source STRING,
	     is_acknowledged BOOLEAN,
	     acknowledged_by STRING,
	     created_at LONG,
	     resolved_at LONG,
	     resolution_notes STRING,
	     tags JSON,
	     related_tickets JSON,
	     PRIMARY KEY(alert_id)
	  )"
  )

  local TABLE_IDX=$((RANDOM % ${#TABLE_NAMES[@]}))
  local DDL_IDX=$((RANDOM % ${#DDL_LIST[@]}))

  local BASE_NAME="${TABLE_NAMES[$TABLE_IDX]}"
  local RANDOM_SUFFIX=$(tr -dc 'a-z0-9' </dev/urandom | head -c 5)
  local TABLE_NAME="${BASE_NAME}_${RANDOM_SUFFIX}"

  local DDL_TEMPLATE="${DDL_LIST[$DDL_IDX]}"
  local DDL=$(printf "$DDL_TEMPLATE" "$TABLE_NAME")
  if [[ -z "$DDL" || "$DDL" =~ ^[[:space:]]*$ ]]; then
  	log_action "$TIMESTAMP" "$JOB_NAME" "❌ Empty DDL statement for table $TABLE_NAME, skipping" "fail"
  	return
  fi
  local DELETE_DATE=$(date +%Y-%m-%d --date="+$(( RANDOM % 26 + 5 )) days") #5 - 30d
  sleep_random 10 20
  if oci nosql table create \
    --compartment-id "$TENANCY_OCID" \
    --name "$TABLE_NAME" \
    --ddl-statement "$DDL" \
    --table-limits "{\"maxReadUnits\": $READ_UNITS, \"maxWriteUnits\": $WRITE_UNITS, \"maxStorageInGBs\": $STORAGE_GB}" \
    --defined-tags '{"auto":{"auto-delete":"true","auto-delete-date":"'"$DELETE_DATE"'"}}' \
    --wait-for-state SUCCEEDED 2> db_error.log; then
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
	sleep_random 10 20
        for ITEM_NAME in $(parse_json_array_string "$ITEMS"); do
		local DELETE_DATE=$(oci nosql table get --table-name-or-id "$ITEM_NAME" \
          	--query "data.\"defined-tags\".auto.\"auto-delete-date\"" \
	   	--compartment-id "$TENANCY_OCID" \
          	--raw-output 2>/dev/null)
        	if [[ -n "$DELETE_DATE" && $(date -d "$DELETE_DATE" +%s) -lt $(date -d "$TODAY" +%s) && $((RANDOM % 2)) -eq 0 ]]; then
          		sleep_random 10 20
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
    log_action "$TIMESTAMP" "$JOB_NAME" "⚠️ No nosql table" "skipped"
    return;
  fi
  
  local ITEMS=$(echo "$TABLES" | grep -o '".*"' | tr -d '"')
  readarray -t TABLE_ARRAY <<< "$ITEMS"
  local RANDOM_INDEX=$(( RANDOM % ${#TABLE_ARRAY[@]} ))
  local TABLE_NAME="${TABLE_ARRAY[$RANDOM_INDEX]}"
  sleep_random 10 20
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
  
  local ROW_COUNT=$((RANDOM % 10 + 1))
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
	    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed insert into $TABLE_NAME: $VALUE_JSON" "fail"
    fi
    sleep_random 10 30
  done
}

job25_update_bucket_policies() {
  local JOB_NAME="create_object_storage_policies"
  local BUCKETS=$(oci os bucket list --compartment-id "$TENANCY_OCID" \
	    --query "data[].name" --raw-output)
	
  local BUCKET_COUNT=$(echo "$BUCKETS" | grep -c '"')
  if [[ -z "$BUCKETS" || "$BUCKET_COUNT" -eq 0 ]]; then
	log_action "$TIMESTAMP" "$JOB_NAME" "⚠️ No buckets found to update access policy" "skipped"
	return
  fi
  local ITEMS=$(echo "$BUCKETS" | grep -o '".*"' | tr -d '"')
  readarray -t BUCKET_ARRAY <<< "$ITEMS"
  local RANDOM_INDEX=$(( RANDOM % ${#BUCKET_ARRAY[@]} ))
  local BUCKET_NAME="${BUCKET_ARRAY[$RANDOM_INDEX]}"
  sleep_random 10 20
  log_action "$TIMESTAMP" "$JOB_NAME" "🛡️ Updating public access policy for ${BUCKET_NAME} bucket..." "start"

  local POLICIES=("NoPublicAccess" "ObjectRead" "ObjectReadWithoutList")
  local CHOSEN_POLICY=$(shuf -n 1 -e "${POLICIES[@]}")

  log_action "$TIMESTAMP" "$JOB_NAME" "🔄 Setting '$CHOSEN_POLICY' for bucket: $BUCKET_NAME" "info"
  if oci os bucket update --name "$BUCKET_NAME" --public-access-type "$CHOSEN_POLICY"; then
	log_action "$TIMESTAMP" "$JOB_NAME" "✅ Bucket $BUCKET_NAME updated with public access: $CHOSEN_POLICY" "success"
  else
	log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed update $BUCKET_NAME with public access: $CHOSEN_POLICY" "fail"
  fi
}

job26_generate_temp_presigned_url() {
  local JOB_NAME="generate_temp_presigned_url"
  log_action "$TIMESTAMP" "$JOB_NAME" "🔐 Generating Pre-Authenticated Request (PAR)..." "start"
  local BUCKETS=$(oci os bucket list --compartment-id "$TENANCY_OCID" \
	    --query "data[].name" --raw-output)
	
  local BUCKET_COUNT=$(echo "$BUCKETS" | grep -c '"')
  if [[ -z "$BUCKETS" || "$BUCKET_COUNT" -eq 0 ]]; then
	log_action "$TIMESTAMP" "$JOB_NAME" "⚠️ No buckets found to Generate Pre-Authenticated" "skipped"
	return
  fi
  local BUCKET_ITEMS=$(echo "$BUCKETS" | grep -o '".*"' | tr -d '"')
  readarray -t BUCKET_ARRAY <<< "$BUCKET_ITEMS"
  local RANDOM_INDEX=$(( RANDOM % ${#BUCKET_ARRAY[@]} ))
  local BUCKET_NAME="${BUCKET_ARRAY[$RANDOM_INDEX]}"
  sleep_random 10 20
  
  local OBJECT_LIST=$(oci os object list --bucket-name "$BUCKET_NAME" \
	    --query "data[*].name" --raw-output)
  sleep_random 10 20
  local OBJECT_LIST_COUNT=$(echo "$OBJECT_LIST" | grep -c '"')

  if [[ -z "$OBJECT_LIST" || "$OBJECT_LIST_COUNT" -eq 0 ]]; then
     local OBJECT_NAME=$(generate_file_upload)
     log_action "$TIMESTAMP" "$JOB_NAME" "⬆️ Starting to upload $OBJECT_NAME into bucket '$BUCKET_NAME'" "info"
     if oci os object put --bucket-name "$BUCKET_NAME" --file "$OBJECT_NAME" --force; then
     	   log_action "$TIMESTAMP" "$JOB_NAME" "✅ Uploaded $OBJECT_NAME to $BUCKET_NAME" "success"
	   rm -f "$OBJECT_NAME"
     else
    	   log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to upload $OBJECT_NAME to $BUCKET_NAME" "fail"
	   rm -f "$OBJECT_NAME"
           return
     fi
  else
    local ITEMS=$(echo "$OBJECT_LIST" | grep -o '".*"' | tr -d '"')
    readarray -t ITEMS_ARRAY <<< "$ITEMS"
    local RANDOM_INDEX=$(( RANDOM % ${#ITEMS_ARRAY[@]} ))
    local OBJECT_NAME="${ITEMS_ARRAY[$RANDOM_INDEX]}"
    log_action "$TIMESTAMP" "$JOB_NAME" "📂 Found existing object: $OBJECT_NAME in bucket $BUCKET_NAME" "info"
  fi

  local ACCESS_TYPES=("ObjectRead" "ObjectWrite" "ObjectReadWrite")
  local CHOSEN_ACCESS=$(shuf -n 1 -e "${ACCESS_TYPES[@]}")

  local MINUTES=$((RANDOM % 345 + 15)) # 15–360 minutes
  local EXPIRES_AT=$(date -u -d "+$MINUTES minutes" '+%Y-%m-%dT%H:%M:%SZ')

  local PAR_NAME="par-$(date +%H%M%S)-$(openssl rand -hex 1)"

  log_action "$TIMESTAMP" "$JOB_NAME" "🪪 Creating PAR $PAR_NAME for object $OBJECT_NAME in bucket $BUCKET_NAME" "info"
  log_action "$TIMESTAMP" "$JOB_NAME" "📋 Access: $CHOSEN_ACCESS | Expiry: $EXPIRES_AT" "info"

  local PAR_OUTPUT=$(oci os preauth-request create \
    --bucket-name "$BUCKET_NAME" \
    --name "$PAR_NAME" \
    --access-type "$CHOSEN_ACCESS" \
    --object-name "$OBJECT_NAME" \
    --time-expires "$EXPIRES_AT" \
    --query "data.\"access-uri\"" --raw-output)

  if [[ -n "$PAR_OUTPUT" ]]; then
    log_action "$TIMESTAMP" "$JOB_NAME" "✅ PAR created: https://objectstorage.$REGION.oraclecloud.com$PAR_OUTPUT" "success"
  else
    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to create PAR for $OBJECT_NAME" "fail"
  fi
}

job27_export_autonomous_db_wallet() {
  local JOB_NAME="export_autonomous_db_wallet"
  log_action "$TIMESTAMP" "$JOB_NAME" "📦 Export wallet from Autonomous DB..." "start"
  local DBS=$(oci db autonomous-database list \
	    --compartment-id "$TENANCY_OCID" \
	    --query "data[?\"lifecycle-state\"=='AVAILABLE'].{id:id, name:\"display-name\"}" \
	    --raw-output)
  local DB_COUNT=$(echo "$DBS" | grep -c '"id"')
  if [[ -z "$DBS" || "$DB_COUNT" -eq 0 ]]; then
	log_action "$TIMESTAMP" "$JOB_NAME" "⚠️ No Autonomous DB [AVAILABLE] found to export wallet" "skipped"
   	return
  fi
  local SELECTED_LINE=$((RANDOM % DB_COUNT + 1))
  local SELECTED=$(parse_json_array "$DBS" | sed -n "${SELECTED_LINE}p")
  IFS='|' read -r DB_OCID DB_NAME <<< "$SELECTED"

  local WALLET_NAME="wallet-$(date +%s%N | sha256sum | cut -c1-12).zip"
  local WALLET_PASSWORD=$(random_password)
  
  log_action "$TIMESTAMP" "$JOB_NAME" "🔐 Exporting wallet to $WALLET_NAME for DB: $DB_NAME ..." "info"
  sleep_random 10 20
  oci db autonomous-database generate-wallet \
    --autonomous-database-id "$DB_OCID" \
    --password "$WALLET_PASSWORD" \
    --file "$WALLET_NAME" >/dev/null

  if [[ -f "$WALLET_NAME" ]]; then
    log_action "$TIMESTAMP" "$JOB_NAME" "✅ Wallet exported to $WALLET_NAME" "success"
  else
    log_action "$TIMESTAMP" "$JOB_NAME" "❌ Failed to export wallet for DB: $DB_NAME" "fail"
  fi
  rm -f "$WALLET_NAME"
}

# === Session Check ===
#if oci iam user get --user-id "$USER_ID" &> /dev/null; then
#  log_action "$TIMESTAMP" "session" "✅ Get user info" "success"
#else
#  log_action "$TIMESTAMP" "session" "❌ Get user info" "fail"
#fi

# Choose how many jobs to run this session (1–2)
JOB_COUNT=$((RANDOM % 2 + 1))

# List of all available jobs
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
  job25_update_bucket_policies
  job26_generate_temp_presigned_url
  job27_export_autonomous_db_wallet
)

# 🧹 Remove job log entries older than 7 days
clean_old_job_logs() {
  local logfile=$OCI_BEHAVIOR_FILE
  local cutoff_date
  cutoff_date=$(date -d "-7 days" +%F)

  if [[ -f "$logfile" ]]; then
    awk -F"|" -v cutoff="$cutoff_date" '$1 >= cutoff' "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
  fi
}

# 📜 Get recently executed jobs within the last N days
get_recent_jobs() {
  local days_back="${1:-3}"
  local logfile=$OCI_BEHAVIOR_FILE

  if [[ -f "$logfile" ]]; then
    awk -v since="$(date -d "-$days_back days" +%F)" -F"|" '$1 >= since { print $2 }' "$logfile" | sort | uniq
  fi
}

# 🚀 Main logic
clean_old_job_logs

# Collect recent jobs (to avoid repeating them)
RECENT_JOBS=($(get_recent_jobs 3))
AVAILABLE_JOBS=()
LOG_JOBS=()

# Filter out recently executed jobs
for job in "${ALL_JOBS[@]}"; do
  if [[ ! " ${RECENT_JOBS[*]} " =~ " $job " ]]; then
    AVAILABLE_JOBS+=("$job")
  fi
done

# Fallback: if not enough fresh jobs, use the full list
if [[ ${#AVAILABLE_JOBS[@]} -lt $JOB_COUNT ]]; then
  SELECTED_JOBS=( $(shuf -e "${ALL_JOBS[@]}" -n "$JOB_COUNT") )
else
  SELECTED_JOBS=( $(shuf -e "${AVAILABLE_JOBS[@]}" -n "$JOB_COUNT") )
fi

# Execute selected jobs
for FUNC in "${SELECTED_JOBS[@]}"; do
  echo "▶️ Running: $FUNC"
  "$FUNC"
  echo "$(date '+%F %T')|$FUNC" >> $OCI_BEHAVIOR_FILE
  LOG_JOBS+=("$FUNC")
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
