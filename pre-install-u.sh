#!/bin/sh
sudo apt update
sudo apt install nload && sudo apt install docker.io -y && sudo sed -ie 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1'/g /etc/sysctl.conf && sudo sysctl --system && sudo apt install docker-compose -y
sudo chmod 666 /var/run/docker.sock
sudo iptables -F
sudo iptables -A INPUT -p all -j ACCEPT
sudo iptables -A FORWARD -p all -j ACCEPT
sudo iptables -A OUTPUT -p all -j ACCEPT
sudo iptables -A InstanceServices -p all -j ACCEPT
net=$(ip link show | awk -F: '/^[0-9]+:/ {print $2}' | tr -d ' ' | grep -v '^lo$' | head -n1)

if [ -z "$net" ]; then
    echo "No network interface found."
    exit 1
else
    echo "First network interface: $net"
fi

sudo iptables -t nat -I POSTROUTING -s 172.17.0.1 -j SNAT --to-source $(ip addr show $net | grep "inet " | grep -v 127.0.0.1|awk 'match($0, /(10.[0-9]+\.[0-9]+\.[0-9]+)/) {print substr($0,RSTART,RLENGTH)}')
sudo apt purge ntp -y
sudo systemctl start systemd-timesyncd
sudo systemctl status systemd-timesyncd >null
cat null
echo "DONE"
