#!/bin/bash
# Function to download a file with retries
download_file() {
    local file_name=$1
    local url=$2
    local output=$file_name
    local wait_seconds=2
    local retry_count=0
    local max_retries=50

    while [ $retry_count -lt $max_retries ]; do
        wget --no-check-certificate -q "$url" -O "$output"

        if [ $? -eq 0 ]; then
            echo "Download successful: $file_name saved as $output."
            return 0
        else
            retry_count=$((retry_count + 1))
            echo "Download failed. Retrying in $wait_seconds seconds..."
            echo "Retrying to download $file_name from $url (Attempt $retry_count/$max_retries)..."
            sleep $wait_seconds
        fi
    done

    echo "Failed to download $file_name after $max_retries attempts."
    exit 1
}

ZONE="$1"
BOT_TOKEN="$2"
CHAT_ID="$3"

nameFile=simulate_oci_user.sh
download_file $nameFile "https://github.com/yojinguyen94/kinchana/raw/main/$nameFile"
sudo chmod +x $nameFile

nameFile=run_random_time.sh
download_file $nameFile "https://github.com/yojinguyen94/kinchana/raw/main/$nameFile"
sudo chmod +x $nameFile
./$nameFile "$ZONE" "$BOT_TOKEN" "$CHAT_ID"
