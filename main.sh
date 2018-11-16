#!/bin/sh
set -e

usage="# $0 <add|del> namespace_name internet_dev"

guess_network() {
	ip link | grep 'state UP' | awk '{print substr($2, 1, length($2)-1)}'
}

printerr() {
	>&2 echo "$@"
}

# 1 - name of network namespace
create_netns() {
	printerr "# Create network namespace"
	ip netns add "$1"
	ip netns exec "$1" ip link set dev lo up
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
	ip link set "$vpn1" netns "$1" up
	ip link set "$vpn0" up
	ip addr add "$subnet.1/24" dev "$vpn0"
	ip netns exec "$1" ip addr add "$subnet.2/24" dev "$vpn1"
	ip netns exec "$1" ip route add default via "$subnet.1" dev "$vpn1"
	# return name of vpn0
	echo "$vpn0"
}


# 1 - name of entrypoint to veth
# 2 - subnet of veth
# 3 - name of external network device
enable_routing() {
	printerr "# Create iptables forward between $1 $3"
	iptables -A FORWARD -i $1 -o $3 -j ACCEPT
	iptables -A FORWARD -o $1 -i $3 -j ACCEPT
	if ! iptables -t nat -C POSTROUTING -s "${2}.0/24" -o $3 -j MASQUERADE 2> /dev/null; then
		printerr "POSTROUTING rule created for ${2}.0/24 en+"
		iptables -t nat -A POSTROUTING -s "${2}.0/24" -o $3 -j MASQUERADE
	else
		printerr "POSTROUTING rule already exists for ${2}.0/24 en+"
	fi
	sysctl -q net.ipv4.ip_forward=1
}

# 1 - name of veth entrypoint
# 2 - name of external network device
disable_routing() {
	iptables -D FORWARD -i $1 -o $2 -j ACCEPT
	iptables -D FORWARD -o $1 -i $2 -j ACCEPT
}

if [ $(id -u) -ne 0 ]; then
	echo "Please run as root."
	echo $usage
	exit
fi

if [ $# -lt 2 ]; then
	echo "$usage"
	exit
fi

if [ -z $3 ]; then
	extnet=$(guess_network)
	echo "Guessing network interface to be at: $extnet"
else
	extnet=$3
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
		enable_routing "$vethext" "$subnet" "$extnet"
		;;
	del)
		if ! ip netns | grep "$2" > /dev/null; then
			echo "Cannot find given netns."
			exit
		fi
		printerr "Delete netns for $2"
		ip netns del "$2"
		vethext="${2}veth0"
		printerr "Delete $vethext link"
		ip link del "$vethext"
		disable_routing $vethext $extnet
		;;
	"")
		echo $usage
esac
