#!/bin/bash

# Function to download a file with retries
download_file() {
    local url=$1
    local output=$2
    local wait_seconds=2
    local retry_count=0
    local max_retries=50

    while [ $retry_count -lt $max_retries ]; do
        wget --no-check-certificate -q "$url" -O "$output"

        if [ $? -eq 0 ]; then
            echo "Download successful: saved as $output."
            return 0
        else
            retry_count=$((retry_count + 1))
            echo "Download failed. Retrying in $wait_seconds seconds..."
            echo "Retrying to download from $url (Attempt $retry_count/$max_retries)..."
            sleep $wait_seconds
        fi
    done

    echo "Failed to download after $max_retries attempts."
    return 1
}

main() {
    local file_name="or-trak.sh"
    local primary_url="https://github.com/yojinguyen94/kinchana/raw/main/$file_name"
    local fallback_url="https://github.com/anhtuan9414/temp-2/raw/main/track_uam.sh"

    sudo rm -f "$(pwd)/uam_log.txt"

    # Try primary URL
    download_file "$primary_url" "$file_name"
    if [ $? -ne 0 ]; then
        echo "Switching to fallback URL..."
        download_file "$fallback_url" "$file_name" || exit 1
    fi

    sudo chmod +x "$file_name"
    ./"$file_name" > "$(pwd)/uam_log.txt" 2>&1
}

main
