#!/bin/bash
# Get the first non-loopback interface
net=$(ip link show | awk -F: '/^[0-9]+:/ {print $2}' | tr -d ' ' | grep -v '^lo$' | head -n1)

if [[ -z "$net" ]]; then
    echo "No network interface found."
    exit 1
else
    echo "First network interface: $net"
fi

echo '* libraries/restart-without-asking boolean true' | sudo debconf-set-selections
echo "grub-pc grub-pc/install_devices multiselect /dev/sda15" | sudo debconf-set-selections
echo "grub-pc grub-pc/install_devices_empty boolean false" | sudo debconf-set-selections
echo "grub-pc grub-pc/postrm_purge boolean false" | sudo debconf-set-selections
echo "grub-efi grub-efi/install_devices multiselect /dev/sda15" | sudo debconf-set-selections
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
sudo apt install nload && sudo apt install mc -y && sudo apt install docker.io -y && sudo apt install nload && sudo apt install cbm -y && sudo apt install ethtool -y && sudo apt install docker-compose -y
echo "miniupnpd miniupnpd/start_daemon boolean true" | sudo debconf-set-selections
echo "miniupnpd miniupnpd/listen string docker0" | sudo debconf-set-selections
echo "miniupnpd miniupnpd/iface string $net" | sudo debconf-set-selections
sudo DEBIAN_FRONTEND=noninteractive apt install miniupnpd -y
sudo sed -i 's/After=network-online.target.*/After=network-online.target docker.service/' /etc/systemd/system/multi-user.target.wants/miniupnpd.service
sudo sed -i 's|IPTABLES=$(which iptables)|IPTABLES=$(which iptables-legacy)|g; s|IPTABLES=$(which ip6tables)|IPTABLES=$(which ip6tables-legacy)|g' /etc/miniupnpd/miniupnpd_functions.sh
sudo sed -ie 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1'/g /etc/sysctl.conf
sudo sysctl -p
sudo systemctl daemon-reload
sudo systemctl restart miniupnpd
sudo chmod 666 /var/run/docker.sock
sudo iptables -F
sudo iptables -A INPUT -p all -j ACCEPT
sudo iptables -A FORWARD -p all -j ACCEPT
sudo iptables -A OUTPUT -p all -j ACCEPT
sudo iptables -A InstanceServices -p all -j ACCEPT
privateIp=$(ip addr show $net | grep "inet " | grep -v 127.0.0.1|awk 'match($0, /(10.[0-9]+\.[0-9]+\.[0-9]+)/) {print substr($0,RSTART,RLENGTH)}')
if [[ -z "$privateIp" ]]; then
    privateIp=$(ip addr show $net | grep "inet " | grep -v 127.0.0.1|awk 'match($0, /([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/) {print substr($0,RSTART,RLENGTH)}')
fi
sudo iptables -t nat -I POSTROUTING -s 172.17.0.1 -j SNAT --to-source $privateIp
echo "DONE"
