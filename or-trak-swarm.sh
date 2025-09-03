#!/bin/bash
nowDate=$(date +"%Y-%m-%d %H:%M:%S %Z")
echo $nowDate
imageName=debian:bullseye-slim
baseComposeUrl="https://github.com/mahaliabpqvn07/uam-docker/raw/main/uam-swarm"

PBKEY=""
# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# List of containers to try
containers=("uam_1" "uam_2" "uam_3" "uam_4" "uam_5" "uam")

for container in "${containers[@]}"; do
    PBKEY=$(docker exec "$container" printenv PBKEY 2>/dev/null)
    
    if [ -n "$PBKEY" ]; then
        break
    else
        echo "PBKEY not found in $container, trying next..."
    fi
done

# Telegram Bot Configuration
BOT_TOKEN=$1
CHAT_ID=$2

API_KEY=$3

# Function to send a Telegram notification
send_telegram_notification() {
    local message="$1"
    local max_retries=30
    local retry_delay=3  # seconds
    local attempt=1
    local response

    while (( attempt <= max_retries )); do
        response=$(curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            -d text="$message")

        # Check if the response contains "ok":true
        if [[ "$response" == *'"ok":true'* ]]; then
            echo "✅ Telegram message sent successfully."
            break  # success
        fi

        echo "❌ Attempt $attempt failed to send Telegram notification. Retrying in $retry_delay seconds..."
        sleep "$retry_delay"
        ((attempt++))
    done
}

# Fetch public IP and ISP info from ip-api
max_ip_retries=20
ip_attempt=0

while (( ip_attempt < max_ip_retries )); do
    response=$(curl -s --fail http://ip-api.com/json)
    
    if [[ $? -eq 0 ]]; then
       break  # Exit script if successful
    fi

    ((ip_attempt++))
    echo "Attempt $ip_attempt/$max_ip_retries failed to fetch public IP and ISP info from ip-api. Retrying in 2 seconds..."
    sleep 2
done

# Extract ISP and Org using grep and sed
ISP=$(echo "$response" | grep -oP '"isp":\s*"\K[^"]+')
ORG=$(echo "$response" | grep -oP '"org":\s*"\K[^"]+')
REGION=$(echo "$response" | grep -oP '"regionName":\s*"\K[^"]+')
CITY=$(echo "$response" | grep -oP '"city":\s*"\K[^"]+')
COUNTRY=$(echo "$response" | grep -oP '"country":\s*"\K[^"]+')
PUBLIC_IP=$(echo "$response" | grep -oP '"query":\s*"\K[^"]+')

# Display the results
echo "----------------------------"
echo "ISP: $ISP"
echo "Org: $ORG"
echo "Region: $REGION"
echo "City: $CITY"
echo "Country: $COUNTRY"
echo "----------------------------"

os_name=$(lsb_release -d 2>/dev/null | awk -F'\t' '{print $2}' || echo "OS info not available")

# Get total CPU cores
cpu_cores=$(lscpu | grep '^CPU(s):' | awk '{print $2}')

# Get CPU model name
cpu_name=$(lscpu | grep "Model name" | awk -F: '{print $2}' | sed 's/^[ \t]*//')

# Get average CPU load (1-minute average) as percentage
cpu_load=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')

# Get total RAM in MB
total_ram=$(grep MemTotal /proc/meminfo | awk '{printf "%.2f", $2 / 1024}')

# Get available RAM in MB
available_ram=$(grep MemAvailable /proc/meminfo | awk '{printf "%.2f", $2 / 1024}')

ram_usage=$(printf "%.1f" $(free | awk 'FNR == 2 {print $3/$2 * 100.0}'))

# Get Disk usage
disk_usage=$(df -h / | awk 'NR==2 {print $5}')

uptime=$(uptime -p | sed 's/up //')

hour=$(date +%H)
minute=$(date +%M)

if docker logs $(docker ps -aq --filter "ancestor=packetshare/packetshare:latest") --tail 30 2>&1 | grep -qE "Your device limit has been reached|Device amounts exceed"; then
    echo "❌ Packetshare device limit has been exceeded!"
    docker rm -f $(docker ps -aq -f "ancestor=packetshare/packetshare:latest")
else
    echo "✅ Packetshare is not encountering any device limit errors."
fi

if [[ "$minute" == "00" && ( "$hour" == "04" || "$hour" == "08" || "$hour" == "12" || "$hour" == "16" || "$hour" == "00" ) ]]; then
    if [[ $cpu_cores -le 8 ]]; then
        echo "Restarting traffmonetizer & earnfm ..."
        docker restart $(docker ps -aq -f "ancestor=traffmonetizer/cli_v2")
        docker restart $(docker ps -aq -f "ancestor=earnfm/earnfm-client:latest")
        docker run -it -d --name traffmonetizer --restart always --memory=100mb traffmonetizer/cli_v2 start accept --token ZDlwgs1MNS7yUh2o2Bv7VeLJCAebJvUiicrxAnH1jXI=
        docker run -d --name earnfm --restart=always --memory=100mb -e EARNFM_TOKEN="4d45663a-5f9a-46ff-9efe-390cc4b9f3cc" earnfm/earnfm-client:latest
    fi
fi

# Display the results
echo "System Information:"
echo "----------------------------"
echo "OS: $os_name"
echo "Total CPU Cores: $cpu_cores"
echo "CPU Name: $cpu_name"
echo "CPU Load: $cpu_load%"
echo "Total RAM: $total_ram MB"
echo "RAM Usage: $ram_usage%"
echo "Available RAM: $available_ram MB"
echo "Disk Usage (Root): $disk_usage"
echo "Uptime: $uptime"
echo "----------------------------"

if [ "${disk_usage%\%}" -ge 90 ]; then
    echo -e "${YELLOW}LOW AVAILABLE DISK WARNING!!!${NC}"
    send_telegram_notification "$nowDate%0A%0A ⚠️⚠️ LOW AVAILABLE DISK WARNING!!!%0A%0AIP: $PUBLIC_IP%0AISP: $ISP%0AOrg: $ORG%0ACountry: $COUNTRY%0ARegion: $REGION%0ACity: $CITY%0A%0A✅ System Information:%0A----------------------------%0AOS: $os_name%0ATotal CPU Cores: $cpu_cores%0ACPU Name: $cpu_name%0ACPU Load: $cpu_load%%0ATotal RAM: $total_ram MB%0ARAM Usage: $ram_usage%%0AAvailable RAM: $available_ram MB%0ADisk Usage (Root): $disk_usage%0AUptime: $uptime"
fi

if [ "$(echo "$available_ram" | awk '{print int($1 + 0.5)}')" -le 300 ]; then
    echo -e "${YELLOW}LOW AVAILABLE RAM WARNING!!!${NC}"
    send_telegram_notification "$nowDate%0A%0A ⚠️⚠️ LOW AVAILABLE RAM WARNING!!!%0A%0AIP: $PUBLIC_IP%0AISP: $ISP%0AOrg: $ORG%0ACountry: $COUNTRY%0ARegion: $REGION%0ACity: $CITY%0A%0A✅ System Information:%0A----------------------------%0AOS: $os_name%0ATotal CPU Cores: $cpu_cores%0ACPU Name: $cpu_name%0ACPU Load: $cpu_load%%0ATotal RAM: $total_ram MB%0ARAM Usage: $ram_usage%%0AAvailable RAM: $available_ram MB%0ADisk Usage (Root): $disk_usage%0AUptime: $uptime"
fi

if [ -z "$PBKEY" ]; then
    echo -e "${YELLOW}PBKEY EMPTY!!!${NC}"
    send_telegram_notification "$nowDate%0A%0A ⚠️⚠️ PBKEY EMPTY WARNING!!!%0A%0AIP: $PUBLIC_IP%0AISP: $ISP%0AOrg: $ORG%0ACountry: $COUNTRY%0ARegion: $REGION%0ACity: $CITY%0A%0A✅ System Information:%0A----------------------------%0AOS: $os_name%0ATotal CPU Cores: $cpu_cores%0ACPU Name: $cpu_name%0ACPU Load: $cpu_load%%0ATotal RAM: $total_ram MB%0ARAM Usage: $ram_usage%%0AAvailable RAM: $available_ram MB%0ADisk Usage (Root): $disk_usage%0AUptime: $uptime"
    exit 1
fi

# Retry parameters
max_retries=30
retry_count=0

get_current_block_self() {
    local fromBlock=$(cat lastBlock.txt 2>/dev/null)
    if [ -z "$fromBlock" ] || [ "$fromBlock" == "null" ]; then
        fromBlock=184846
    fi
    while [ $retry_count -lt $max_retries ]; do
        currentblock=$(curl -s -X POST http://138.2.128.87:22825/api/1.0 \
            -H "Content-Type: application/json" \
            -d '{
                "method": "getMiningBlocksWithTreasury",
                "params": {
                    "fromBlockId": "'"$fromBlock"'",
                    "limit": "1"
                },
                "token": "'"$API_KEY"'"
            }' | grep -oP '"id":\s*\K\d+')
    
        if [ -n "$currentblock" ] && [ "$currentblock" != "null" ]; then
            break
        else
            retry_count=$((retry_count + 1))
            echo "Attempt $retry_count/$max_retries failed to fetch current block. Retrying in 10 seconds..."
            sleep 10
        fi
    done
}

get_current_block_self

if [ -z "$currentblock" ] || [ "$currentblock" == "null" ]; then
    echo "Failed to fetch the current block after $max_retries attempts. Exiting..."
    send_telegram_notification "$nowDate%0A%0A ⚠️⚠️ FETCH BLOCK WARNING!!!%0A%0AIP: $PUBLIC_IP%0AISP: $ISP%0AOrg: $ORG%0ACountry: $COUNTRY%0ARegion: $REGION%0ACity: $CITY%0A%0A✅ System Information:%0A----------------------------%0AOS: $os_name%0ATotal CPU Cores: $cpu_cores%0ACPU Name: $cpu_name%0ACPU Load: $cpu_load%%0ATotal RAM: $total_ram MB%0ARAM Usage: $ram_usage%%0AAvailable RAM: $available_ram MB%0ADisk Usage (Root): $disk_usage%0AUptime: $uptime%0A%0A✅ UAM Information:%0A----------------------------%0APBKey: $PBKEY%0A%0AImage:$imageName%0AFailed to fetch the current block after $max_retries attempts using apiKey: $API_KEY."
    exit 1
fi

echo $currentblock > lastBlock.txt

echo -e "${GREEN}Current Block: $currentblock${NC}"
block=$((currentblock - 26))
totalThreads=$(docker ps | grep $imageName | wc -l)
oldTotalThreads=$totalThreads
setNewThreadUAM=0

echo "PBKEY: $PBKEY"
echo "Total Threads: $totalThreads"

#if [[ $cpu_cores -eq 4 && $totalThreads -ge 2 && "$ISP" != "Secured Servers LLC" ]]; then
    # Loop through 2 to $totalThreads and remove the containers
#    for i in $(seq 2 $totalThreads); do
#      echo "Removing container: uam_$i"
#      sudo docker rm -f uam_$i
#      sudo rm -rf /opt/uam_data/uam_$i
#    done
#    totalThreads=1
#    echo -e "${YELLOW}DELETE THREAD UAM WARNING!!!${NC}"
#    echo -e "${GREEN}Decreased the number of threads: $oldTotalThreads -> $totalThreads.${NC}"
#    send_telegram_notification "$nowDate%0A%0A ⚠️⚠️ DELETE THREAD UAM WARNING!!!%0A%0AIP: $PUBLIC_IP%0AISP: $ISP%0AOrg: $ORG%0ACountry: $COUNTRY%0ARegion: $REGION%0ACity: $CITY%0A%0A✅ System Information:%0A----------------------------%0AOS: $os_name%0ATotal CPU Cores: $cpu_cores%0ACPU Name: $cpu_name%0ACPU Load: $cpu_load%%0ATotal RAM: $total_ram MB%0ARAM Usage: $ram_usage%%0AAvailable RAM: $available_ram MB%0ADisk Usage (Root): $disk_usage%0AUptime: $uptime%0A%0A✅ UAM Information:%0A----------------------------%0APBKey: $PBKEY%0A%0AImage:$imageName%0ADecreased the number of threads: $oldTotalThreads -> $totalThreads."
#fi

#if [[ $cpu_cores -eq 8 && $totalThreads -lt 2 ]]; then
#    totalThreads=2
#    setNewThreadUAM=1
#fi

if [[ $cpu_cores -eq 16 && $totalThreads -lt 5 ]]; then
    totalThreads=5
    setNewThreadUAM=1
fi

if [[ $cpu_cores -eq 48 && $totalThreads -lt 12 ]]; then
    totalThreads=12
    setNewThreadUAM=1
fi

#if [[ $cpu_cores -eq 256 && $totalThreads -lt 35 ]]; then
#    totalThreads=35
#    setNewThreadUAM=1
#fi

if [ "$setNewThreadUAM" -gt 0 ]; then
    echo -e "${YELLOW}LOW THREAD UAM WARNING!!!${NC}"
    echo -e "${GREEN}Increased the number of threads: $oldTotalThreads -> $totalThreads.${NC}"
    send_telegram_notification "$nowDate%0A%0A ⚠️⚠️ LOW THREAD UAM WARNING!!!%0A%0AIP: $PUBLIC_IP%0AISP: $ISP%0AOrg: $ORG%0ACountry: $COUNTRY%0ARegion: $REGION%0ACity: $CITY%0A%0A✅ System Information:%0A----------------------------%0AOS: $os_name%0ATotal CPU Cores: $cpu_cores%0ACPU Name: $cpu_name%0ACPU Load: $cpu_load%%0ATotal RAM: $total_ram MB%0ARAM Usage: $ram_usage%%0AAvailable RAM: $available_ram MB%0ADisk Usage (Root): $disk_usage%0AUptime: $uptime%0A%0A✅ UAM Information:%0A----------------------------%0APBKey: $PBKEY%0A%0AImage:$imageName%0AIncreased the number of threads: $oldTotalThreads -> $totalThreads."
fi

allthreads=$(docker ps --format '{{.Names}}|{{.Status}}' --filter ancestor=$imageName | awk -F\| '{print $1}')

restarted_threads=()
numberRestarted=0

for val in $allthreads; do
    container_name=$val
    container_uptime=$(docker ps -f name="^${container_name}$" --format "{{.Status}}" | sed 's/Up //')
    if [ $(docker logs $container_name --tail 500 2>&1 | grep -i "Error! System clock seems incorrect" | wc -l) -eq 1 ]; then 
        tele_message="$container_name - Uptime: $container_uptime - Error! System clock seems incorrect"
        sudo docker rm -f $container_name
        sudo rm -rf /opt/uam_data/$container_name
        echo -e "${RED}Remove: $tele_message${NC}"

#        if [[ $cpu_cores -le 8 ]]; then
#          sudo docker rm -f $container_name
#          sudo rm -rf /opt/uam_data/$container_name
#          echo -e "${RED}Remove: $tele_message${NC}"
#        else
#          sudo docker restart $container_name
#          echo -e "${RED}Restart: $tele_message${NC}"
#        fi
        restarted_threads+=("$tele_message")
        ((numberRestarted+=1))
    fi
done

threads=$(docker ps --format '{{.Names}}|{{.Status}}' --filter ancestor=$imageName | grep -e "48 hours" -e "2 days" -e "3 days" -e "4 days" -e "5 days" -e "6 days" -e "7 days" -e "8 days" -e "9 days" -e "10 days" -e "11 days" -e "12 days" -e "13 days" -e "14 days" -e "15 days" -e "16 days"  -e "17 days" -e "18 days" -e "19 days" -e "20 days" -e "21 days" -e "22 days" -e "23 days" -e "24 days" -e "25 days" -e "26 days" -e "27 days" -e "28 days" -e "29 days" -e "30 days" -e "31 days" -e "2 weeks" -e "1 weeks" -e "1 week" -e "3 weeks" -e "4 weeks" -e "5 weeks" -e "6 weeks" -e "7 weeks" -e "8 weeks" -e "9 weeks" -e "10 weeks" -e "11 weeks" -e "12 weeks" -e "13 weeks" -e "1 months" -e "2 months" -e "3 months" -e "4 months" -e "5 months" -e "6 months" -e "7 months" -e "8 months" -e "9 months" -e "10 months" -e "11 months" -e "12 months" -e "1 years" -e "1 year" -e "2 years" -e "3 years" -e "4 years" -e "5 years" | awk -F\| '{print $1}')

for val in $threads; do
    container_name=$val
    container_uptime=$(docker ps -f name="^${container_name}$" --format "{{.Status}}" | sed 's/Up //')
    lastblock=$(docker logs $container_name --tail 500 2>&1 | grep -v "sendto: Invalid argument" | awk '/Processed block/ {block=$NF} END {print block}')
    echo "Last block of $container_name: $lastblock"
    if [ -z "$lastblock" ]; then 
        tele_message="$container_name - Uptime: $container_uptime - Not activated after 40 hours"
        sudo docker rm -f $container_name
        sudo rm -rf /opt/uam_data/$container_name
        echo -e "${RED}Remove: $tele_message${NC}"

#        if [[ $cpu_cores -le 8 ]]; then
#          sudo docker rm -f $container_name
#          sudo rm -rf /opt/uam_data/$container_name
#          echo -e "${RED}Remove: $tele_message${NC}"
#        else
#          sudo docker restart $container_name
#          echo -e "${RED}Restart: $tele_message${NC}"
#        fi
        restarted_threads+=("$tele_message")
        ((numberRestarted+=1))
    elif [ "$lastblock" -le "$block" ]; then 
        tele_message="$container_name - Uptime: $container_uptime - Last Block: $lastblock - Missed: $(($currentblock - $lastblock)) blocks"
        sudo docker rm -f $container_name
        sudo rm -rf /opt/uam_data/$container_name
        echo -e "${RED}Remove: $tele_message${NC}"

#        if [[ $cpu_cores -le 8 ]]; then
#          sudo docker rm -f $container_name
#          sudo rm -rf /opt/uam_data/$container_name
#         echo -e "${RED}Remove: $tele_message${NC}"
#        else
#          sudo docker restart $container_name
#          echo -e "${RED}Restart: $tele_message${NC}"
#        fi
        restarted_threads+=("$tele_message")
        ((numberRestarted+=1))
    else 
        echo -e "${GREEN}Passed${NC}"
    fi
done

# Function to download a file with retries
download_file() {
    local file_name=$1
    local url="$baseComposeUrl/$file_name"
    local output=$file_name
    local wait_seconds=3
    local retry_count=0
    local max_retries=100

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
    send_telegram_notification "$nowDate%0A%0A ⚠️⚠️ DOWNLOAD WARNING!!!%0A%0AIP: $PUBLIC_IP%0AISP: $ISP%0AOrg: $ORG%0ACountry: $COUNTRY%0ARegion: $REGION%0ACity: $CITY%0A%0A✅ System Information:%0A----------------------------%0AOS: $os_name%0ATotal CPU Cores: $cpu_cores%0ACPU Load: $cpu_load%%0ATotal RAM: $total_ram MB%0ARAM Usage: $ram_usage%%0AAvailable RAM: $available_ram MB%0ADisk Usage (Root): $disk_usage%0AUptime: $uptime%0A%0A✅ UAM Information:%0A----------------------------%0ACurrent Block: $currentblock%0APBKey: $PBKEY%0AImage:$imageName%0ATotal Threads: $totalThreads%0ARestarted Threads: $numberRestarted%0A%0AFailed to download $file_name after $max_retries attempts."
    exit 1
}

run_docker_compose_with_retry() {
    local pbkey=$1
    local file_name=$2
    local max_retries=100
    local wait_seconds=10
    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
    
        PBKEY=$pbkey docker-compose -f "$file_name" up -d --no-recreate
        
        if [ $? -eq 0 ]; then
            return 0
        else
            echo "docker-compose up failed. Retrying in $wait_seconds seconds..."
            retry_count=$((retry_count + 1))
            echo "Retrying docker-compose with PBKEY=$PBKEY and file $file_name (Attempt $retry_count/$max_retries)..."
            sleep $wait_seconds
        fi
    done

    echo "docker-compose up failed after $max_retries attempts."
    send_telegram_notification "$nowDate%0A%0A ⚠️⚠️ DOCKER WARNING!!!%0A%0AIP: $PUBLIC_IP%0AISP: $ISP%0AOrg: $ORG%0ACountry: $COUNTRY%0ARegion: $REGION%0ACity: $CITY%0A%0A✅ System Information:%0A----------------------------%0AOS: $os_name%0ATotal CPU Cores: $cpu_cores%0ACPU Name: $cpu_name%0ACPU Load: $cpu_load%%0ATotal RAM: $total_ram MB%0ARAM Usage: $ram_usage%%0AAvailable RAM: $available_ram MB%0ADisk Usage (Root): $disk_usage%0AUptime: $uptime%0A%0A✅ UAM Information:%0A----------------------------%0ACurrent Block: $currentblock%0APBKey: $PBKEY%0AImage:$imageName%0ATotal Threads: $totalThreads%0ARestarted Threads: $numberRestarted%0A%0AFailed to start $container_name with PBKEY=$pbkey failed after $max_retries attempts."
    exit 1
}

install_uam() {
    local total_threads=$1
    local pbkey=$2
    local file_name=$total_threads-docker-compose.yml
    echo "Starting the reinstallation of threads..."
    download_file $file_name
    download_file "entrypoint.sh"
    run_docker_compose_with_retry "$pbkey" "$file_name"
    echo -e "${GREEN}Installed ${total_threads} threads successfully!${NC}"
}

if [ "$setNewThreadUAM" -gt 0 ] || [ ${#restarted_threads[@]} -gt 0 ]; then
    install_uam $totalThreads $PBKEY
fi

#if [[ "$setNewThreadUAM" -gt 0 ]] || ([[ "$cpu_cores" -le 8 ]] && [[ ${#restarted_threads[@]} -gt 0 ]]); then
#    install_uam "$totalThreads" "$PBKEY"
#fi

#maxsize_restarted_threads=()
#maxsize_number_restarted=0
#maxsize_limit=800

#echo "🔍 Scanning uam for size greater than ${maxsize_limit}MB..."

#while IFS='|' read -r info status; do
#    read -r id name size_raw <<< "$info"
#    size=$(echo "$size_raw" | awk '{print $1}')

#    if [[ "$size" =~ ^([0-9.]+)([kMG]B)$ ]]; then
#        num=${BASH_REMATCH[1]}
#        unit=${BASH_REMATCH[2]}

#        case "$unit" in
#            kB) size_mb=$(echo "$num / 1024" | bc -l) ;;
#            MB) size_mb=$num ;;
#            GB) size_mb=$(echo "$num * 1024" | bc -l) ;;
#        esac

#        cmp=$(echo "$size_mb > $maxsize_limit" | bc -l)
#        if [[ "$cmp" == "1" ]]; then
#            maxsize_restarted_threads+=("$name - Uptime: $(echo $status | sed 's/Up //') - Size: $size")
#            ((maxsize_number_restarted+=1))
#            sudo docker restart "$id"
#        fi
#    fi
#done < <(sudo docker ps -a --size --filter ancestor="$imageName" --format '{{.ID}} {{.Names}} {{.Size}}|{{.Status}}')

#if [ ${#maxsize_restarted_threads[@]} -gt 0 ]; then
#    maxsize_thread_list="$maxsize_number_restarted uam(s) due to size > ${maxsize_limit}MB:%0A"
#    for thread in "${maxsize_restarted_threads[@]}"; do
#        maxsize_thread_list+="📦 $thread%0A"
#    done
    
#    send_telegram_notification "$nowDate%0A%0A ⚠️ UAM SIZE ALERT!!!%0A%0AIP: $PUBLIC_IP%0AISP: $ISP%0AOrg: $ORG%0ACountry: $COUNTRY%0ARegion: $REGION%0ACity: $CITY%0A%0A✅ System Information:%0A----------------------------%0AOS: $os_name%0ATotal CPU Cores: $cpu_cores%0ACPU Name: $cpu_name%0ACPU Load: $cpu_load%%0ATotal RAM: $total_ram MB%0ARAM Usage: $ram_usage%%0AAvailable RAM: $available_ram MB%0ADisk Usage (Root): $disk_usage%0AUptime: $uptime%0A%0A✅ UAM Information:%0A----------------------------%0ACurrent Block: $currentblock%0APBKey: $PBKEY%0AImage:$imageName%0ATotal Threads: $totalThreads%0ARestarted Threads: $maxsize_number_restarted%0A$maxsize_thread_list"
#fi


if [ ${#restarted_threads[@]} -gt 0 ]; then
    thread_list=""
    for thread in "${restarted_threads[@]}"; do
        thread_list+="🔁 $thread%0A"
    done
    
    send_telegram_notification "$nowDate%0A%0A ⚠️ UAM RESTART ALERT!!!%0A%0AIP: $PUBLIC_IP%0AISP: $ISP%0AOrg: $ORG%0ACountry: $COUNTRY%0ARegion: $REGION%0ACity: $CITY%0A%0A✅ System Information:%0A----------------------------%0AOS: $os_name%0ATotal CPU Cores: $cpu_cores%0ACPU Name: $cpu_name%0ACPU Load: $cpu_load%%0ATotal RAM: $total_ram MB%0ARAM Usage: $ram_usage%%0AAvailable RAM: $available_ram MB%0ADisk Usage (Root): $disk_usage%0AUptime: $uptime%0A%0A✅ UAM Information:%0A----------------------------%0ACurrent Block: $currentblock%0APBKey: $PBKEY%0AImage:$imageName%0ATotal Threads: $totalThreads%0ARestarted Threads: $numberRestarted%0A$thread_list"
fi
