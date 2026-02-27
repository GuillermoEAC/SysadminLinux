#!/bin/bash

INTERFACE="enp0s8"
CONFIG_FILE="/etc/dhcp/dhcpd.conf"
LEASE_FILE="/var/lib/dhcp/dhcpd.leases"
SUBNET="192.168.100.0"
NETMASK="255.255.255.0"

if ! dpkg -l | grep -q isc-dhcp-server; then
    apt update -y
    apt install isc-dhcp-server -y
fi

ip addr show $INTERFACE | grep -q "192.168.100.1"
if [ $? -ne 0 ]; then
    ip addr flush dev $INTERFACE
    ip addr add 192.168.100.1/24 dev $INTERFACE
    ip link set $INTERFACE up
fi

valid_ip() {
    [[ $1 =~ ^192\.168\.100\.([0-9]{1,3})$ ]] && [ ${BASH_REMATCH[1]} -ge 1 ] && [ ${BASH_REMATCH[1]} -le 254 ]
}

read -p "Nombre del Ambito: " SCOPENAME

until valid_ip "$START"; do
    read -p "IP Inicial: " START
done

until valid_ip "$END"; do
    read -p "IP Final: " END
done

read -p "Duracion del Lease en horas: " LEASEHOURS
LEASESECONDS=$((LEASEHOURS*3600))

GATEWAY="192.168.100.1"

cat > $CONFIG_FILE <<EOF
default-lease-time $LEASESECONDS;
max-lease-time $LEASESECONDS;

subnet $SUBNET netmask $NETMASK {
    range $START $END;
    option routers $GATEWAY;
    option subnet-mask $NETMASK;
    option broadcast-address 192.168.100.255;
}
EOF

sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$INTERFACE\"/" /etc/default/isc-dhcp-server

dhcpd -t -cf $CONFIG_FILE

systemctl restart isc-dhcp-server
systemctl enable isc-dhcp-server

echo "Estado del servicio:"
systemctl status isc-dhcp-server --no-pager

echo "Concesiones activas:"
cat $LEASE_FILE