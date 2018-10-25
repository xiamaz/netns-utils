#!/bin/sh

# 1 - name of network namespace
create_netns() {
	ip netns add "$1"
	ip netns exec "$1" ip addr add 127.0.0.1/8 dev lo
	ip netns exec "$1" ip link set lo up
	# add dns routing inside the nameserver
	mkdir -p /etc/netns/"$1"
	echo 'nameserver 8.8.8.8' > /etc/netns/"$1"/resolv.conf
}

# 1 - name of network namespace
create_interfaces() {
	ip link add nsvpn0 type veth peer name nsvpn1
	ip link set nsvpn0 up
	ip link set nsvpn1 netns "$1" up
	ip addr add 10.200.200.1/24 dev nsvpn0
	ip netns exec "$1" ip addr add 10.200.200.2/24 dev nsvpn1
	ip netns exec "$1" ip route add default via 10.200.200.1 dev nsvpn1
}


enable_routing() {
	iptables -A INPUT \! -i nsvpn0 -s 10.200.200.0/24 -j DROP
	iptables -t nat -A POSTROUTING -s 10.200.200.0/24 -o wl+ -j MASQUERADE
	sysctl -q net.ipv4.ip_forward=1
}

case $1 in
"")
	echo "# <cmd> namespace_name"
	;;
*)
	create_netns $1
	create_interfaces $1
	enable_routing
	;;
esac
