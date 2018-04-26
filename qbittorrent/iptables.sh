#!/bin/bash
# Forked from binhex's OpenVPN dockers

# Wait until tunnel is up
while : ; do
	tunnelstat=$(netstat -ie | grep -E "tun|tap")
	if [[ ! -z "${tunnelstat}" ]]; then
		break
	else
		sleep 1
	fi
done

echo "[info] WebUI port defined as ${WEBUI_PORT}" | ts '%Y-%m-%d %H:%M:%.S'

# ip route
###

DEBUG=false

# get default gateway of interfaces as looping through them
DEFAULT_GATEWAY=$(ip -4 route list 0/0 | cut -d ' ' -f 3)

# strip whitespace from start and end of lan_network_item
export LAN_NETWORK=$(echo "${LAN_NETWORK}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')

echo "[info] Adding ${LAN_NETWORK} as route via docker eth0" | ts '%Y-%m-%d %H:%M:%.S'
ip route add "${LAN_NETWORK}" via "${DEFAULT_GATEWAY}" dev eth0

# split comma seperated string into list from LAN_NETWORKS env variable
IFS=',' read -ra lan_network_list <<< "${LAN_NETWORKS}"

lancount=0
lan_network_devices=()
# process lan networks in the list
for lan_network_item in "${lan_network_list[@]}"; do
	lan_network_item=$(echo "${lan_network_item}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
	# Get network interface name for corresponding networks
	for interface in $(ifconfig | cut -d ' ' -f1| tr ':' '\n' | awk NF)
	do
		int_ip=$(ifconfig "${interface}" | grep -o "inet [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*" | grep -o "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*")
		int_mask=$(ifconfig "${interface}" | grep -o "netmask [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*" | grep -o "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*")
		int_cidr=$(ipcalc "${int_ip}" "${int_mask}" | grep -P -o -m 1 "(?<=Network:)\s+[^\s]+" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
		if [[ $int_cidr == $lan_network_item ]]; then
			lan_network_devices+=(${interface})
			echo "$int_cidr detected on $interface interface"
			
			# get default gateway of interfaces as looping through them
			DEFAULT_GATEWAY2=$(/sbin/ip route |grep '^default' | awk "/${interface}/ {print $3}")

			# strip whitespace from start and end of lan_network_item
			lan_network_item=$(echo "${lan_network_item}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
			
			ip route add "${lan_network_item}" via "${DEFAULT_GATEWAY2}" dev ${interface}
		fi
	done

	lancount=$((lancount+1))
done

echo "[info] ip route defined as follows..." | ts '%Y-%m-%d %H:%M:%.S'
echo "--------------------"
ip route
echo "--------------------"

# setup iptables marks to allow routing of defined ports via eth0
###

if [[ "${DEBUG}" == "true" ]]; then
	echo "[debug] Modules currently loaded for kernel" ; lsmod
fi

# check we have iptable_mangle, if so setup fwmark
lsmod | grep iptable_mangle
iptable_mangle_exit_code=$?

if [[ $iptable_mangle_exit_code == 0 ]]; then

	echo "[info] iptable_mangle support detected, adding fwmark for tables" | ts '%Y-%m-%d %H:%M:%.S'

	# setup route for qbittorrent webui using set-mark to route traffic for port 8080 to eth0
	echo "8080    webui" >> /etc/iproute2/rt_tables
	ip rule add fwmark 1 table webui
	ip route add default via ${DEFAULT_GATEWAY} table webui

fi

# identify docker bridge interface name (probably eth0)
 docker_interface=$(netstat -ie | grep -vE "lo|tun|tap" | sed -n '1!p' | grep -P -o -m 1 '^[\w]+')
if [[ "${DEBUG}" == "true" ]]; then
	echo "[debug] Docker interface defined as ${docker_interface}"
fi

# identify ip for docker bridge interface
docker_ip=$(ifconfig "${docker_interface}" | grep -o "inet [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*" | grep -o "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*")
if [[ "${DEBUG}" == "true" ]]; then
 	echo "[debug] Docker IP defined as ${docker_ip}"
fi

# identify netmask for docker bridge interface
docker_mask=$(ifconfig "${docker_interface}" | grep -o "netmask [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*" | grep -o "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*")
if [[ "${DEBUG}" == "true" ]]; then
	echo "[debug] Docker netmask defined as ${docker_mask}"
fi

# convert netmask into cidr format
docker_network_cidr=$(ipcalc "${docker_ip}" "${docker_mask}" | grep -P -o -m 1 "(?<=Network:)\s+[^\s]+" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
echo "[info] Docker network defined as ${docker_network_cidr}" | ts '%Y-%m-%d %H:%M:%.S'

# input iptable rules
###

# set policy to drop ipv4 for input
iptables -P INPUT DROP

# set policy to drop ipv6 for input
ip6tables -P INPUT DROP 1>&- 2>&-

# accept input to tunnel adapter
iptables -A INPUT -i "${VPN_DEVICE_TYPE}" -j ACCEPT

# accept input to/from LANs (172.x range is internal dhcp)
for lan_network_item in "${lan_network_list[@]}"; do
	iptables -A INPUT -s "${lan_network_item}" -d "${lan_network_item}" -j ACCEPT
done
iptables -A INPUT -s "${docker_network_cidr}" -d "${docker_network_cidr}" -j ACCEPT

# accept input to vpn gateway
iptables -A INPUT -i eth0 -p $VPN_PROTOCOL --sport $VPN_PORT -j ACCEPT

# accept input to qbittorrent webui port
for lan_network_device in "${lan_network_devices[@]}"; do
	if [ -z "${WEBUI_PORT}" ]; then
		iptables -A INPUT -i ${lan_network_device} -p tcp --dport 8080 -j ACCEPT
		iptables -A INPUT -i ${lan_network_device} -p tcp --sport 8080 -j ACCEPT
	else
		iptables -A INPUT -i ${lan_network_device} -p tcp --dport ${WEBUI_PORT} -j ACCEPT
		iptables -A INPUT -i ${lan_network_device} -p tcp --sport ${WEBUI_PORT} -j ACCEPT
	fi
done

# accept input to qbittorrent daemon port - used for lan access
lancount=0
for lan_network_device in "${lan_network_devices[@]}"; do
	if [ -z "${INCOMING_PORT}" ]; then
		iptables -A INPUT -i ${lan_network_device} -s "${lan_network_list[$lancount]}" -p tcp --dport 8999 -j ACCEPT
	else
		iptables -A INPUT -i ${lan_network_device} -s "${lan_network_list[$lancount]}" -p tcp --dport ${INCOMING_PORT} -j ACCEPT
	fi
	lancount=$((lancount+1))
done
if [ -z "${INCOMING_PORT}" ]; then
	iptables -A INPUT -i eth0 -s "${LAN_NETWORK}" -p tcp --dport 8999 -j ACCEPT
else
	iptables -A INPUT -i eth0 -s "${LAN_NETWORK}" -p tcp --dport ${INCOMING_PORT} -j ACCEPT
fi
	


# accept input icmp (ping)
iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT

# accept input to local loopback
iptables -A INPUT -i lo -j ACCEPT

# output iptable rules
###

# set policy to drop ipv4 for output
iptables -P OUTPUT DROP

# set policy to drop ipv6 for output
ip6tables -P OUTPUT DROP 1>&- 2>&-

# accept output from tunnel adapter
iptables -A OUTPUT -o "${VPN_DEVICE_TYPE}" -j ACCEPT

# accept output to/from LANs
for lan_network_item in "${lan_network_list[@]}"; do
	iptables -A OUTPUT -s "${lan_network_item}" -d "${lan_network_item}" -j ACCEPT
done
iptables -A OUTPUT -s "${docker_network_cidr}" -d "${docker_network_cidr}" -j ACCEPT
	
# accept output from vpn gateway
iptables -A OUTPUT -o eth0 -p $VPN_PROTOCOL --dport $VPN_PORT -j ACCEPT

# if iptable mangle is available (kernel module) then use mark
if [[ $iptable_mangle_exit_code == 0 ]]; then

	# accept output from qBittorrent webui port - used for external access
	if [ -z "${WEBUI_PORT}" ]; then
		iptables -t mangle -A OUTPUT -p tcp --dport 8080 -j MARK --set-mark 1
		iptables -t mangle -A OUTPUT -p tcp --sport 8080 -j MARK --set-mark 1
	else
		iptables -t mangle -A OUTPUT -p tcp --dport ${WEBUI_PORT} -j MARK --set-mark 1
		iptables -t mangle -A OUTPUT -p tcp --sport ${WEBUI_PORT} -j MARK --set-mark 1
	fi
	
fi

# accept output from qBittorrent webui port - used for lan access
for lan_network_device in "${lan_network_devices[@]}"; do
	if [ -z "${WEBUI_PORT}" ]; then
		iptables -A OUTPUT -o ${lan_network_device} -p tcp --dport 8080 -j ACCEPT
		iptables -A OUTPUT -o ${lan_network_device} -p tcp --sport 8080 -j ACCEPT
	else
		iptables -A OUTPUT -o ${lan_network_device} -p tcp --dport ${WEBUI_PORT} -j ACCEPT
		iptables -A OUTPUT -o ${lan_network_device} -p tcp --sport ${WEBUI_PORT} -j ACCEPT
	fi
done

if [ -z "${WEBUI_PORT}" ]; then
	iptables -A OUTPUT -o eth0 -p tcp --dport 8080 -j ACCEPT
	iptables -A OUTPUT -o eth0 -p tcp --sport 8080 -j ACCEPT
else
	iptables -A OUTPUT -o eth0 -p tcp --dport ${WEBUI_PORT} -j ACCEPT
	iptables -A OUTPUT -o eth0 -p tcp --sport ${WEBUI_PORT} -j ACCEPT
fi

# accept output to qBittorrent daemon port - used for lan access
lancount=0
for lan_network_device in "${lan_network_devices[@]}"; do
	if [ -z "${INCOMING_PORT}" ]; then
		iptables -A OUTPUT -o ${lan_network_device} -d "${lan_network_list[$lancount]}" -p tcp --sport 8999 -j ACCEPT
	else
		iptables -A OUTPUT -o ${lan_network_device} -d "${lan_network_list[$lancount]}" -p tcp --sport ${INCOMING_PORT} -j ACCEPT
	fi
	lancount=$((lancount+1))
done

if [ -z "${INCOMING_PORT}" ]; then
	iptables -A OUTPUT -o eth0 -d "${LAN_NETWORK}" -p tcp --sport 8999 -j ACCEPT
else
	echo "[info] Incoming connections port defined as ${INCOMING_PORT}" | ts '%Y-%m-%d %H:%M:%.S'
	iptables -A OUTPUT -o eth0 -d "${LAN_NETWORK}" -p tcp --sport ${INCOMING_PORT} -j ACCEPT
fi

# accept output for icmp (ping)
iptables -A OUTPUT -p icmp --icmp-type echo-request -j ACCEPT

# accept output from local loopback adapter
iptables -A OUTPUT -o lo -j ACCEPT

echo "[info] iptables defined as follows..." | ts '%Y-%m-%d %H:%M:%.S'
echo "--------------------"
iptables -S
echo "--------------------"

exec /bin/bash /etc/qbittorrent/start.sh
