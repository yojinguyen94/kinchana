#!/bin/bash
nowDate=$(date +"%d-%m-%Y %H:%M:%S" --date="7 hours")
echo $nowDate
API_URL="$1"
API_KEY="$2"
# Telegram Bot Configuration
BOT_TOKEN="$3"
CHAT_ID="$4"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Retry parameters
max_retries=30
retry_count=0

get_current_block_self() {
    local fromBlock=$(cat lastBlockStats.txt 2>/dev/null)
    if [ -z "$fromBlock" ] || [ "$fromBlock" == "null" ]; then
        fromBlock=184846
    fi
    while [ $retry_count -lt $max_retries ]; do
        local data=$(curl -s -X POST $API_URL/api/1.0 \
            -H "Content-Type: application/json" \
            -d '{
                "method": "getMiningBlocksWithTreasury",
                "params": {
                    "fromBlockId": "'"$fromBlock"'",
                    "limit": "1"
                },
                "token": "'"$API_KEY"'"
            }')
    
        if [ -n "$data" ] && [ "$data" != "null" ]; then
            lastBlockTime=$(date -d "$(echo $data | grep -oP '"dateTime":\s*"\K[^"]+') +7 hours" +"%d-%m-%Y %H:%M")
            lastBlock=$(echo $data | grep -oP '"id":\s*\K\d+')
            miningThreads=$(echo $data | grep -oP '"involvedInCount":\s*\K\d+')
            totalMiningThreads=$(echo $data | grep -oP '"numberMiners":\s*\K\d+')
            rewardPerThread=$(echo $data | grep -oP '"price":\s*\K\d+\.\d+')
            break
        else
            retry_count=$((retry_count + 1))
            echo "Attempt $retry_count/$max_retries failed to fetch current block. Retrying in 10 seconds..."
            sleep 10
        fi
    done
}
lastBlockStats=lastBlockStats_$API_KEY.txt
fromBlock=$(cat $lastBlockStats 2>/dev/null)
if [ -z "$fromBlock" ] || [ "$fromBlock" == "null" ]; then
    fromBlock=184846
fi
get_balance_self() {
    max_retries=30
    retry_count=0
    while [ $retry_count -lt $max_retries ]; do
        local data=$(curl -s -X POST $API_URL/api/1.0 \
            -H "Content-Type: application/json" \
            -d '{
                "method": "getBalance",
                "params": {
                    "currency": "CRP"
                },
                "token": "'"$API_KEY"'"
            }')
    
        if [ -n "$data" ] && [ "$data" != "null" ]; then
            balance=$(printf "%.8f" "$(echo $data | grep -oP '"result":\s*\K\d+\.\d+')")
            if [ -z "$balance" ] || [ "$balance" == "null" ]; then
                balance=0
            fi
            break
        else
            retry_count=$((retry_count + 1))
            echo "Attempt $retry_count/$max_retries failed to fetch balance. Retrying in 10 seconds..."
            sleep 10
        fi
    done
}

get_crp_price() {
    max_retries=30
    retry_count=0
    while [ $retry_count -lt $max_retries ]; do
        local data=$(curl 'https://crp.is:8182/market/pairs' \
                      -H 'Accept: application/json, text/plain, */*' \
                      -H 'Accept-Language: en-US,en;q=0.9,vi;q=0.8' \
                      -H 'Connection: keep-alive' \
                      -H 'Origin: https://crp.is' \
                      -H 'Referer: https://crp.is/' \
                      -H 'Sec-Fetch-Dest: empty' \
                      -H 'Sec-Fetch-Mode: cors' \
                      -H 'Sec-Fetch-Site: same-site' \
                      -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36' \
                      -H 'sec-ch-ua: "Chromium";v="134", "Not:A-Brand";v="24", "Google Chrome";v="134"' \
                      -H 'sec-ch-ua-mobile: ?0' \
                      -H 'sec-ch-ua-platform: "Windows"')
    
        if [ -n "$data" ] && [ "$data" != "null" ]; then
            crpPrice=$(echo $data | jq '.result.pairs[] | select(.pair.pair == "crp_usdt") | '.data_market.close'')
            break
        else
            retry_count=$((retry_count + 1))
            echo "Attempt $retry_count/$max_retries failed to fetch crp price. Retrying in 10 seconds..."
            sleep 10
        fi
    done
}

lastMiningDateStats=lastMiningDateStats_$API_KEY.txt
fromDate=$(cat $lastMiningDateStats 2>/dev/null)
get_mining_info() {
    if [ -z "$fromDate" ] || [ "$fromDate" == "null" ]; then
        fromDate=""
    fi
    local res=$(curl -s -X POST $API_URL/api/1.0 \
                    -H "Content-Type: application/json" \
                    -d '{
                        "method": "getFinanceHistory",
                        "params": {
                            "currency": "CRP",
                            "filters": "ALL_MINING",
                            "fromDate": "'"$fromDate"'"
                        },
                        "token": "'"$API_KEY"'"
                    }' | jq -c '.result[0]')
    miningReward=$(echo "$res" | jq -r '.amount_string')
    miningDetails=$(echo "$res" | jq -r '.details')
    miningCreated=$(echo "$res" | jq -r '.created')
}

get_usdt_vnd_rate() {
    local res=$(curl --compressed 'https://p2p.binance.com/bapi/c2c/v2/friendly/c2c/adv/search' \
              -H "Content-Type: application/json" \
              --data-raw '{"fiat":"VND","page":1,"rows":10,"tradeType":"SELL","asset":"USDT","countries":[],"proMerchantAds":false,"shieldMerchantAds":false,"filterType":"tradable","periods":[],"additionalKycVerifyFilter":0,"publisherType":"merchant","payTypes":[],"classifies":["mass","profession","fiat_trade"],"tradedWith":false,"followed":false}')
    sellRate=$(echo "$res" | jq -r '.data[].adv.price' | sort -nr | head -n 1)
}

get_crp_delegated() {
    local res=$(curl -s -X POST $API_URL/api/1.0 \
                    -H "Content-Type: application/json" \
                    -d '{
                        "method": "getDPoSInfo",
                        "params": {},
                        "token": "'"$API_KEY"'"
                    }')
    totalCRPDelegated=$(echo "$res" | jq '[.result.investors[].amount | tonumber] | add')
}

get_list_total_mining_threads() {
    max_retries=30
    retry_count=0
    while [ $retry_count -lt $max_retries ]; do
        local data=$(curl -s -X POST $API_URL/api/1.0 \
            -H "Content-Type: application/json" \
            -d '{
                "method": "getMiningBlocksWithTreasury",
                "params": {
                    "fromBlockId": "",
                    "limit": "96"
                },
                "token": "'"$API_KEY"'"
            }')
    
        if [ -n "$data" ] && [ "$data" != "null" ]; then
            local data_file="list_total_mining_threads_$API_KEY.dat"
            rm -f $data_file
            echo "$data" | jq -c '.result[]' | while read -r entry; do
                dateTime=$(echo "$entry" | grep -oP '"dateTime":\s*"\K[^"]+')
                numberMiners=$(echo "$entry" | grep -oP '"numberMiners":\s*\K[0-9]+')
                involvedInCount=$(echo "$entry" | grep -oP '"involvedInCount":\s*\K\d+')
                pricePerThread=$(echo "$entry" | grep -oP '"price":\s*\K\d+\.\d+')
                miningRewardValue=$(echo "$involvedInCount * $pricePerThread" | bc -l)
                formattedMiningRewardValue=$(printf "%.6f" "$miningRewardValue")
                formatted_time=$(date -d "$dateTime +7 hours" +"%d-%m-%Y %H:%M")
                
                echo "\"$formatted_time\" $numberMiners $formattedMiningRewardValue" >> "$data_file"
            done
            echo "✅ Generated $data_file"
            break
        else
            retry_count=$((retry_count + 1))
            echo "Attempt $retry_count/$max_retries failed to fetch list total mining threads. Retrying in 10 seconds..."
            sleep 10
        fi
    done
}

generate_chart() {
    local data_file="list_total_mining_threads_$API_KEY.dat"
    #rm -f mining_chart_final_$API_KEY.png
    # Create gnuplot script
    gnuplot_script="plot_chart_$(date +%s%N).gnuplot"
    printf '%s\n' \
    "set terminal png size 800,600" \
    "set output 'mining_chart_final_$API_KEY.png'" \
     "" \
    "set xdata time" \
    "set timefmt '\"%d-%m-%Y %H:%M\"'" \
    "set format x '%d-%m-%Y %H:%M'" \
    "set xtics rotate by -45 font ',8'" \
    "set grid" \
    "" \
    "# Background color #3b3e4a and white text" \
    "set object 1 rectangle from screen 0,0 to screen 1,1 fillcolor rgb\"#3b3e4a\" behind" \
    "set border lc rgb \"white\"" \
    "set tics textcolor rgb \"white\"" \
    "set title \"Total mining threads and Reward\" textcolor rgb \"white\"" \
    "set xlabel \"Time\" textcolor rgb \"white\"" \
    "set ylabel \"Threads\" textcolor rgb \"white\"" \
    "set y2label \"Reward (CRP)\" textcolor rgb \"white\"" \
    "set y2tics textcolor rgb \"white\"" \
    "set y2range [0:*]" \
    "" \
    "set key at screen 0.98,0.98 textcolor rgb \"white\" font ',8'" \
    "" \
    "plot \"$data_file\" using 1:2 axes x1y1 with lines lt rgb \"#6c98fd\" lw 2 title 'Threads', \\" \
    "     \"$data_file\" using 1:3 axes x1y2 with lines lt rgb \"#ff4d4d\" lw 2 title 'Reward (CRP)'" \
    > "$gnuplot_script"
        
    # Run gnuplot to generate chart
    gnuplot "$gnuplot_script"
    
    echo "✅ Chart generated: mining_chart_final_$API_KEY.png"
    rm -f $gnuplot_script
}

# Function to send a Telegram notification
send_telegram_notification() {
    local message="$1"
    #curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    #    -d chat_id="$CHAT_ID" \
    #    -d text="$message" > /dev/null
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" \
     -F chat_id="$CHAT_ID" \
     -F photo=@"./mining_chart_final_$API_KEY.png" \
     -F caption="$(echo -e "$message")" > /dev/null
}

get_current_block_self

if [ "$lastBlock" -le "$fromBlock" ]; then
    echo "✅ Block $lastBlock has been processed. Status: informed."
    exit 0
fi

echo $lastBlock > $lastBlockStats

get_balance_self
get_crp_price
get_mining_info
get_usdt_vnd_rate
get_crp_delegated
get_list_total_mining_threads
generate_chart

maximumThreads=$(echo "$totalCRPDelegated $balance" | awk '{print int(($1 + $2) / 64)}')
totalCRPDelegatedValue=$(echo "$crpPrice * $totalCRPDelegated" | bc -l)
formattedTotalCRPDelegatedValue=$(printf "%.4f" "$totalCRPDelegatedValue")
totalCRPDelegatedVndValue=$(echo "$sellRate * $formattedTotalCRPDelegatedValue" | bc -l)
totalCRPDelegatedVndFormattedValue=$(LC_NUMERIC=en_US.UTF-8 printf "%'.0f\n" "$totalCRPDelegatedVndValue")

value=$(echo "$crpPrice * $balance" | bc -l)
formattedValue=$(printf "%.4f" "$value")
vndValue=$(echo "$sellRate * $formattedValue" | bc -l)
vndFormattedValue=$(LC_NUMERIC=en_US.UTF-8 printf "%'.0f\n" "$vndValue")
messageBot="🚀 Mining Stats\n"

textStats="$nowDate\n$messageBot\n🍀 CRP/USDT (based crp.is): $crpPrice\$\n🍀 USDT/VND Binance P2P: $(LC_NUMERIC=en_US.UTF-8 printf "%'.0f\n" "$sellRate")đ\n🍀 CRP Balance: $balance CRP ≈ $formattedValue\$ ≈ $vndFormattedValueđ\n🍀 CRP Invested: $totalCRPDelegated CRP ≈ $formattedTotalCRPDelegatedValue\$ ≈ $totalCRPDelegatedVndFormattedValueđ\n🍀 Mining Threads: $miningThreads\n🍀 Maximum Threads: $maximumThreads\n🍀 Last Block: $lastBlock\n🍀 Last Block Time: $lastBlockTime\n🍀 Reward Per Thread: $rewardPerThread CRP\n🍀 Total Mining Threads: $totalMiningThreads\n"
if [ -n "$miningReward" ] && [ "$miningReward" != "null" ] && [ "$miningThreads" -ne 0 ]; then
   echo $miningCreated > $lastMiningDateStats
   formattedTime=$(date -d "$miningCreated UTC +7 hours" +"%d-%m-%Y %H:%M")
   miningRewardValue=$(echo "$crpPrice * $miningReward" | bc -l)
   formattedMiningRewardValue=$(printf "%.4f" "$miningRewardValue")
   miningRewardVndValue=$(echo "$sellRate * $formattedMiningRewardValue" | bc -l)
   formattedMiningRewardVndValue=$(LC_NUMERIC=en_US.UTF-8 printf "%'.0f\n" "$miningRewardVndValue")
   textStats+="🍀 $miningDetails [$formattedTime]: $miningReward CRP ≈ $formattedMiningRewardValue$ ≈ $formattedMiningRewardVndValueđ"

   textStats+="\n\n🏦 Estimated Earnings\n\n"
   dailyReward=$(echo "$miningReward * 96" | bc -l)
   dailyRewardValue=$(echo "$crpPrice * $dailyReward" | bc -l)
   formattedDailyRewardValue=$(printf "%.4f" "$dailyRewardValue")
   dailyMiningRewardVndValue=$(echo "$sellRate * $formattedDailyRewardValue" | bc -l)
   formattedDailyMiningRewardVndValue=$(LC_NUMERIC=en_US.UTF-8 printf "%'.0f\n" "$dailyMiningRewardVndValue")
   textStats+="🍀 Daily: $dailyReward CRP ≈ $formattedDailyRewardValue$ ≈ $formattedDailyMiningRewardVndValueđ\n"
   
   weeklyReward=$(echo "$dailyReward * 7" | bc -l)
   weeklyRewardValue=$(echo "$crpPrice * $weeklyReward" | bc -l)
   formattedWeeklyRewardValue=$(printf "%.4f" "$weeklyRewardValue")
   weeklyMiningRewardVndValue=$(echo "$sellRate * $formattedWeeklyRewardValue" | bc -l)
   formattedWeeklyMiningRewardVndValue=$(LC_NUMERIC=en_US.UTF-8 printf "%'.0f\n" "$weeklyMiningRewardVndValue")
   textStats+="🍀 Weekly: $weeklyReward CRP ≈ $formattedWeeklyRewardValue$ ≈ $formattedWeeklyMiningRewardVndValueđ\n"
   
   monthlyReward=$(echo "$dailyReward * 30" | bc -l)
   monthlyRewardValue=$(echo "$crpPrice * $monthlyReward" | bc -l)
   formattedMonthlyRewardValue=$(printf "%.4f" "$monthlyRewardValue")
   monthlyMiningRewardVndValue=$(echo "$sellRate * $formattedMonthlyRewardValue" | bc -l)
   formattedMonthlyMiningRewardVndValue=$(LC_NUMERIC=en_US.UTF-8 printf "%'.0f\n" "$monthlyMiningRewardVndValue")
   textStats+="🍀 Monthly: $monthlyReward CRP ≈ $formattedMonthlyRewardValue$ ≈ $formattedMonthlyMiningRewardVndValueđ"
   
fi

if [ -f stats_$API_KEY.txt ]; then
    cp stats_$API_KEY.txt pre_stats_$API_KEY.txt
fi

echo -e $textStats > stats_$API_KEY.txt

if [ ! -f pre_stats_$API_KEY.txt ]; then
    cp stats_$API_KEY.txt pre_stats_$API_KEY.txt
fi

extract_value() {
    echo "$1" | grep -oE '[0-9]+(,[0-9]{3})*(\.[0-9]+)?' | tr -d ',' | tail -1
}

compare_values() {
    local field="$1"
    local before_line="$2"
    local after_line="$3"

    if [[ -z "$after_line" ]]; then return; fi

    if [[ "$field" == "Last Block" || "$field" == "Last Block Time" ]]; then
        messageBot+="\n$after_line"
        return
    fi

    if [[ "$field" == "Daily" ]]; then
        messageBot+="\n\n🏦 Estimated Earnings\n"
    fi

    local before_val=$(extract_value "$before_line")
    local after_val=$(extract_value "$after_line")

    if [[ -z "$before_val" || -z "$after_val" ]]; then
        messageBot+="\n$after_line"
        return
    fi

    before_val="${before_val/,/.}"
    after_val="${after_val/,/.}"

    local unit=""
    local fo="%.4f"
    case "$field" in
        "CRP/USDT")
            unit="$"
            ;;
        "Reward Per Thread")
            unit=" CRP"
            fo="%.8f"
            ;;
        "Total Mining Threads" | "Mining Threads" | "Maximum Threads")
            fo="%.0f"
            ;;
        "USDT/VND Binance P2P" | "CRP Balance" | "CRP Invested" | "Mining reward for block" | "Daily" | "Weekly" | "Monthly")
            unit="đ"
            fo="%.0f"
            ;;
    esac
    delta=$(awk "BEGIN { printf \"$fo\", $after_val - $before_val }")
    if (( $(awk "BEGIN { print ($delta > 0) }") )); then
        emoji="🟢"
    elif (( $(awk "BEGIN { print ($delta < 0) }") )); then
        emoji="🔴"
    fi

    if (( $(awk "BEGIN {print ($delta == 0)}") )); then
        messageBot+="\n$after_line"
    else
        if [[ "$unit" == "đ" ]]; then
            delta_formated=$(LC_NUMERIC=en_US.UTF-8 printf "%'.0f\n" "$delta")
        else
            delta_formated=$delta
        fi
        if (( $(awk "BEGIN { print ($delta > 0) }") )); then
            messageBot+="\n$after_line $emoji (+$delta_formated$unit)"
        else
            messageBot+="\n$after_line $emoji ($delta_formated$unit)"
        fi
    fi
}



FIELDS=(
    "CRP/USDT"
    "USDT/VND Binance P2P"
    "CRP Balance"
    "CRP Invested"
    "Mining Threads"
    "Maximum Threads"
    "Last Block"
    "Last Block Time"
    "Reward Per Thread"
    "Total Mining Threads"
    "Mining reward for block"
    "Daily"
    "Weekly"
    "Monthly"
)

for field in "${FIELDS[@]}"; do
    before_line=$(grep -i "$field" pre_stats_$API_KEY.txt | head -1)
    after_line=$(grep -i "$field" stats_$API_KEY.txt | head -1)
    compare_values "$field" "$before_line" "$after_line"
done

cat stats_$API_KEY.txt

send_telegram_notification "$messageBot"
