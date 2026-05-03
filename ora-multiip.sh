#!/bin/bash

# ====== INPUT PARAM ======
net=$(ip link show | awk -F: '/^[0-9]+:/ {print $2}' | tr -d ' ' | grep -v '^lo$' | head -n1)
INPUT_FILE="$1"          # ví dụ: ips.txt
NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"

echo "[+] Parse IPs từ file..."

# Lấy IP từ JS array → chuyển thành list
IPS=$(grep -oP '\d+\.\d+\.\d+\.\d+' $INPUT_FILE)

# Convert thành bash array
readarray -t IP_ARRAY <<< "$IPS"

echo "[+] Danh sách IP:"
printf '%s\n' "${IP_ARRAY[@]}"

echo "[+] Add IP vào interface..."

for ip in "${IP_ARRAY[@]}"; do
    echo "-> $ip"
    sudo ip addr add $ip/24 dev $net 2>/dev/null
done

echo "[+] Backup netplan..."
sudo cp $NETPLAN_FILE ${NETPLAN_FILE}.bak

echo "[+] Generate netplan config..."

ADDRS=""
for ip in "${IP_ARRAY[@]}"; do
    ADDRS+="        - $ip/24"$'\n'
done

FIRST_IP=${IP_ARRAY[0]}
GATEWAY=$(echo $FIRST_IP | awk -F. '{print $1"."$2"."$3".1"}')

sudo bash -c "cat > $NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    $net:
      dhcp4: no
      addresses:
$ADDRS
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF

echo "[+] Fix permission..."
sudo chmod 600 $NETPLAN_FILE

echo "[+] Apply netplan..."
sudo netplan apply

echo "[✓] Done!"
