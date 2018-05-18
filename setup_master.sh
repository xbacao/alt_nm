#!/bin/sh
DIR="$(dirname "$(readlink -f "$0")")"

##TODO MUDAR O FLUSH SO PARA ESTAS INTERFACES

NAMESPACE=wifijail
NS_PREFIX=ip\ netns\ exec\ ${NAMESPACE}
ETH_INTERFACE=enp0s31f6
ETH_METRIC=100
WLAN_INTERFACE=wlp2s0
WLAN_METRIC=200
GW=192.168.1.254
WPA_CONFIG=/opt/m1l10n/netq5g_wpa.conf 		#CHANGE_IF_NEEDED

GREEN='\e[0;32m'
RED='\033[0;31m'	
NC='\033[0m' 				

usage(){
	echo "Usage: $0 [option]"
	echo "options:"
	echo "-i install"
	echo "-r run"
	echo "-s stop"
}

#$1 = msg
print_info(){
	echo -e "${GREEN}$1${NC}"
}

print_warning(){
	echo -e "${RED}$1${NC}"
}

#$1 = msg
exit_error(){
	print_warning "ERROR: $1"
	exit -1
}

install(){
	mkdir -p /etc/${NAMESPACE}/wifijail/ || exit_error "creating config dns dir"
	echo "nameserver 8.8.8.8" >> /etc/${NAMESPACE}/wifijail/resolv.conf || exit_error "configuring namespace dns"
	ln -s ${DIR}/$0 /usr/bin/setnet
	ln -s ${DIR}/execw.sh /usr/bin/execw
}

clean_config(){
	iptables -F
	iptables -X
	iptables -t nat -F
	iptables -t mangle -F
	ip link set dev ${ETH_INTERFACE} down
	ip link set dev ${WLAN_INTERFACE} down
	ip route flush dev ${WLAN_INTERFACE}
	ip route flush dev ${ETH_INTERFACE}
	ip addr flush dev ${WLAN_INTERFACE}
	ip addr flush dev ${ETH_INTERFACE}
	killall wpa_supplicant dhcpcd
	ip netns del ${NAMESPACE}
	ip link delete veth0
	ip rule del from all fwmark 0x2 lookup rtable_wifi_only
}

setup_eth_interface(){
	print_info "Setting up ${ETH_INTERFACE} ..."

	ip link set dev ${ETH_INTERFACE} up || exit_error "Failed to setup ${ETH_INTERFACE} (up) :("

	dhcpcd -m ${ETH_METRIC} ${ETH_INTERFACE} && print_info "${ETH_INTERFACE} interface ready!" || exit_error "Failed to setup ${ETH_INTERFACE} (dhcp) :("
}

setup_wlan_interface(){
	print_info "Setting up ${WLAN_INTERFACE} ..."

	ip link set dev ${WLAN_INTERFACE} up || exit_error "Failed to setup ${WLAN_INTERFACE} (up) :("

	wpa_supplicant -B -Dnl80211 -i${WLAN_INTERFACE} -c${WPA_CONFIG} || exit_error "Failed to setup WLAN interface (wpa_supplicant) :("

	dhcpcd -S domain_name_servers=8.8.8.8 -m ${WLAN_METRIC} ${WLAN_INTERFACE} && print_info "${WLAN_INTERFACE} interface ready!" || exit_error "Failed to setup ${WLAN_INTERFACE} interface (dhcp) :("
}

setup_netns(){
	ip netns add ${NAMESPACE} || exit_error "create network namespace"
	ip link add veth0 type veth peer name veth1 || exit_error "create virtual ethernet link"
	ip link set veth1 netns ${NAMESPACE} || exit_error "assign virtual ethernet endpoint to namespace"
	${NS_PREFIX} ip addr add 10.1.1.2/24 dev veth1 || exit_error "set address to namespace interface"
	${NS_PREFIX} ip link set dev veth1 up || exit_error "set namespace interface up"
	ip addr add 10.1.1.1/24 dev veth0 || exit_error "set host interface address"
	ip link set dev veth0 up || exit_error "set host interface up"

	sysctl -w net.ipv4.ip_forward=1 || exit_error "enable packet forwarding"
	sysctl -w net.ipv4.conf.${WLAN_INTERFACE}.rp_filter=2 || exit_error "enable packet address switching"
	iptables -A INPUT -i veth0 -j ACCEPT || exit_error "create forwarding packet rule 1"
	iptables -A PREROUTING -i veth0 -t mangle -j MARK --set-mark 2  || exit_error "create forwarding packet rule 2"
	ip rule add fwmark 2 table rtable_wifi_only  || exit_error "ip rule"
	iptables -A FORWARD -i veth0 -o ${WLAN_INTERFACE} -j ACCEPT || exit_error "create forwarding packet rule 3"
	iptables -A FORWARD -i ${WLAN_INTERFACE} -o veth0 -m state --state ESTABLISHED,RELATED -j ACCEPT || exit_error "create forwarding packet rule 4"
	iptables -t nat -A POSTROUTING -o ${WLAN_INTERFACE} -j MASQUERADE || exit_error "create forwarding packet rule 5"

	ip route add 10.1.1.0/24 dev veth0 proto kernel scope link src 10.1.1.1 table rtable_wifi_only || exit_error "create rtable_wifi_only static route 1"
	ip route add default via 192.168.1.254 dev ${WLAN_INTERFACE} metric 1 table rtable_wifi_only || exit_error "create rtable_wifi_only static route 2"

	${NS_PREFIX} ip route add default via 10.1.1.1 dev veth1 metric 1 || exit_error "create static default route in namespace"

	iptables -A INPUT -i docker0 -j ACCEPT || exit_error "docker iptables 1"
	iptables -A PREROUTING -i docker0 -t mangle -j MARK --set-mark 3  || exit_error "docker iptables 2"
	ip rule add fwmark 3 table rtable_wifi_only || exit_error "docker iptables 3"
	iptables -A FORWARD -i docker0 -o ${WLAN_INTERFACE} -j ACCEPT || exit_error "docker iptables 4"
	iptables -A FORWARD -i ${WLAN_INTERFACE} -o docker0 -m state --state ESTABLISHED,RELATED -j ACCEPT || exit_error "docker iptables 5"
}

stop(){
	killall dhcpcd wpa_supplicant
}

if [ "$#" -ne 1 ] ; then
	echo "Bad arguments!"
	usage $0
	exit 1
fi

while getopts irs o
do 
	case "$o" in
		i)
		install
		;;
		r)
		clean_config
		setup_wlan_interface
		setup_eth_interface					#IF SOMETHING IS BLOCKED (LIKE DEBIAN/UBUNTU REPOS' DOMAINS) JUST COMMENT THIS LINE TO DISABLE THE CABLED NETWORK
		setup_netns
		;;
		s)
		clean_config
		stop
		;;
		[?])  
		usage $0
		exit 2
		;;
	esac
done
