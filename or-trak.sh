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

botToken=$(cat bot_token_track_uam.txt 2>/dev/null)
chatId=$(cat bot_chat_id_track_uam.txt 2>/dev/null)
apiKey=$(cat api_key_track_uam.txt 2>/dev/null)
nameFile=or-trak-hu.sh
#sudo rm -f $nameFile
download_file $nameFile "https://github.com/yojinguyen94/kinchana/raw/main/$nameFile"
sudo chmod +x $nameFile
./$nameFile "$botToken" "$chatId" "$apiKey"
