#!/bin/sh
set -e

usage="# $0 <add|del> namespace_name"

printerr() {
	>&2 echo "$@"
}

# 1 - name of network namespace
create_netns() {
	printerr "# Create network namespace"
	ip netns add "$1"
	ip netns exec "$1" ip addr add 127.0.0.1/8 dev lo
	ip netns exec "$1" ip link set lo up
	# add dns routing inside the nameserver
	mkdir -p /etc/netns/"$1"
	echo 'nameserver 1.1.1.1' > /etc/netns/"$1"/resolv.conf
	printerr "$1 created with config in /etc/netns/$1"
}

get_free_subnet() {
	printerr "# Get free /24 subnet ip for routing"
	subrange="10.200"
	existing_highest=$(ip addr | grep -Po "$subrange.\\d+" | awk 'BEGIN{FS=OFS="."}{print $NF}'| sort -r | head -n 1)
	if [ -z $existing_highest ]; then existing_highest=1; fi
	free_new=$(echo "$existing_highest + 1" | bc)
	if [ $free_new -lt 256 ]; then
		printerr "Found $subrange.$free_new"
		echo "$subrange.$free_new"
		return 0
	fi
	printerr "Found nothing"
	return 1
}

# 1 - name of network namespace
# 2 - subnet
create_interfaces() {
	printerr "# Create veth interfaces"
	vpn0="${1}veth0"
	vpn1="${1}veth1"
	subnet="$2"
	printerr "Outer interface $vpn0 and inner $vpn1 associated with $subnet."
	ip link add "$vpn0" type veth peer name "$vpn1"
	ip link set "$vpn0" up
	ip link set "$vpn1" netns "$1" up
	ip addr add "$subnet.1/24" dev "$vpn0"
	ip netns exec "$1" ip addr add "$subnet.2/24" dev "$vpn1"
	ip netns exec "$1" ip route add default via "$subnet.1" dev "$vpn1"
	# return name of vpn0
	echo "$vpn0"
}


# 1 - name of entrypoint to veth
# 2 - subnet of veth
enable_routing() {
	printerr "# Create iptables rules."
	if ! iptables -C INPUT \! -i "$1" -s "${2}.0/24" -j DROP 2> /dev/null; then
		printerr "INPUT rule created for ${2}.0/24"
		iptables -A INPUT \! -i "$1" -s "${2}.0/24" -j DROP
	else
		printerr "INPUT rule already exists for ${2}.0/24"
	fi
	if ! iptables -t nat -C POSTROUTING -s "${2}.0/24" -o wl+ -j MASQUERADE 2> /dev/null; then
		printerr "POSTROUTING rule created for ${2}.0/24 wl+"
		iptables -t nat -A POSTROUTING -s "${2}.0/24" -o wl+ -j MASQUERADE
	else
		printerr "POSTROUTING rule already exists for ${2}.0/24 wl+"
	fi
	if ! iptables -t nat -C POSTROUTING -s "${2}.0/24" -o en+ -j MASQUERADE 2> /dev/null; then
		printerr "POSTROUTING rule created for ${2}.0/24 en+"
		iptables -t nat -A POSTROUTING -s "${2}.0/24" -o en+ -j MASQUERADE
	else
		printerr "POSTROUTING rule already exists for ${2}.0/24 en+"
	fi
	sysctl -q net.ipv4.ip_forward=1
}

if [ $(id -u) -ne 0 ]; then
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
		if ! ip netns | grep "$2" > /dev/null; then
			echo "Cannot find given netns."
			exit
		fi
		printerr "Delete netns for $2"
		sudo ip netns del "$2"
		printerr "Delete ${2}veth0 link"
		sudo ip link del "${2}veth0"
		printerr "iptables not cleaned. Check manually."
		;;
	"")
		echo $usage
esac
