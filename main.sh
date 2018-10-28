#!/bin/sh
set -e

usage="# $0 <add|del> namespace_name"

# 1 - name of network namespace
create_netns() {
	ip netns add "$1"
	ip netns exec "$1" ip addr add 127.0.0.1/8 dev lo
	ip netns exec "$1" ip link set lo up
	# add dns routing inside the nameserver
	mkdir -p /etc/netns/"$1"
	echo 'nameserver 1.1.1.1' > /etc/netns/"$1"/resolv.conf
}

get_free_subnet() {
	subrange="10.200"
	existing_highest=$(ip addr | grep -Po "$subrange.\\d+" | awk 'BEGIN{FS=OFS="."}{print $NF}'| sort -r | head -n 1)
	if [ -z $existing_highest ]; then existing_highest=1; fi
	free_new=$(echo "$existing_highest + 1" | bc)
	if [ $free_new -lt 256 ]; then
		echo "$subrange.$free_new"
		return 0
	fi
	return 1
}

# 1 - name of network namespace
# 2 - subnet
create_interfaces() {
	vpn0="${1}veth0"
	vpn1="${1}veth1"
	subnet="$2"
	ip link add "$vpn0" type veth peer name "$vpn1"
	ip link set "$vpn0" up
	ip link set "$vpn1" netns "$1" up
	ip addr add "$subnet.1/24" dev "$vpn0"
	ip netns exec "$1" ip addr add "$subnet.2/24" dev "$vpn1"
	ip netns exec "$1" ip route add default via "$subnet.1" dev "$vpn1"
	echo "$vpn0"
}


# 1 - name of entrypoint to veth
# 2 - subnet of veth
enable_routing() {
	iptables -A INPUT \! -i "$1" -s "${2}.0/24" -j DROP
	iptables -t nat -A POSTROUTING -s "${2}.0/24" -o wl+ -j MASQUERADE
	sysctl -q net.ipv4.ip_forward=1
}

if [ "$EUID" -ne 0 ]; then
	echo "Please run as root."
	echo $usage
	exit
fi

case "$1" in
	add)
		if [ -z "$2" ]; then
			echo "Enter netns name."
			exit
		fi
		create_netns "$2"
		subnet=$(get_free_subnet)
		vethext=$(create_interfaces "$2" "$subnet")
		enable_routing "$vethext" "$subnet"
		;;
	del)
		if ip netns | grep "$2" > /dev/null; then
			echo "Cannot find given netns."
			exit
		fi
		sudo ip netns del "$2"
		sudo ip link del "${2}veth0"
		;;
	"")
		echo $usage
esac
