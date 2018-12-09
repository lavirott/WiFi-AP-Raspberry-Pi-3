#!/bin/bash

SSID="${1:-RaspberryPi}"
PASSPHRASE="${2:-raspberry}"
IP_RANGE="${3:-192.168.222}"
INC="${4:-eth0}"
WIFI="${5:-wlan0}"

pause() {
#	read -p "Appuyer sur une touche pour continuer ..." var
	echo -n
}

begin() {
	echo -n $1
}

end() {
	echo " done."
	pause
}

if [ "`whoami`" != "root" ]
then
	echo "This script must be run as root."
	echo "  sudo ./install.sh"
	exit -1
fi

echo "Setting up your WiFi-Accesspoint on your pi with:"
echo " SSID: $SSID"
echo " PASSPHRASE: $PASSPHRASE"
echo " IP-Address: $IP_RANGE.1"
echo " IP-Range: $IP_RANGE.0"
echo " Incomming device: $INC"
echo " WiFi device: $WIFI"
echo

# Check if INC (eth0) and WIFI (wlan0) are available
begin "Test if interfaces exist..."
ifconfig -a | grep "$WIFI" > /dev/null
if [ "$?" != "0" ]
then
  echo
  echo "$WIFI not found, exiting";
  exit -1
fi
ifconfig -a | grep "$INC" > /dev/null
if [ "$?" != "0" ]
then
  echo
  echo "$INC not found, exiting";
  exit -1
fi
end

# Update os
begin "Update OS..."
apt-get update > /dev/null
apt-get -y upgrade > /dev/null
end

# Install new packages for Access Point management
begin "Install necessary packages..."
apt-get -y install hostapd dnsmasq iptables bridge-utils > /dev/null
end

# Modify dhcpcd.conf
DHCPCD_CONF="# Modified for WiFi AP
interface $WIFI
  static ip_address=$IP_RANGE.1/24
  nohook wpa_supplicant
denyinterfaces $INC
denyinterfaces $WIFI
"

if [ -f /etc/dhcpcd.conf ]
then
	grep "# Modified for WiFi AP" /etc/dhcpcd.conf > /dev/null
	if [ "$?" == "1" ]
	then
	  begin "Updating DHCP configuration file..."
		echo "$DHCPCD_CONF" >> /etc/dhcpcd.conf
		end
	else
		grep "  static ip_address=$IP_RANGE.1/24" /etc/dhcpcd.conf > /dev/null
		if [ "$?" == "1" ]
		then
			sed -i.bak "s/  static ip_address=.*.1\/24/  static ip_address=$IP_RANGE.1\/24/g" /etc/dhcpcd.conf
		else
			echo "DHCP service already modified."
		fi
	fi
fi

# Create bridge interface file
INTERF_CONF="# Bridge setup
auto br0
iface br0 inet manual
bridge_ports $INC $WIFI
"

begin "Update interface for new bridge..."
echo "$INTERF_CONF" > /etc/network/interfaces.d/bridge
end

# Create dnsmasq.conf file
CONF_DNSMASQ="expand-hosts
domain-needed               # Don't forward short names
bogus-priv                  # Drop the non-routed address spaces.
bind-interfaces             # Bind to the interface
server=8.8.8.8              # Use Google DNS
listen-address=$IP_RANGE.1  # Address to listen on
interface=$WIFI             # Use the require wireless interface - usually wlan0
dhcp-range=$IP_RANGE.2,$IP_RANGE.250,255.255.255.0,12h
"

if [ ! -f "/etc/dnsmasq.conf.orig" ]
then
	begin "Backup dnsmasq.conf file..."
  mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
	end
fi
begin "Create dnsmasq.conf file..."
echo "$CONF_DNSMASQ" > /etc/dnsmasq.conf
end

# Create hostapd.conf
CONF_HOSTAP="ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
# Interface setting
interface=$WIFI
bridge=br0
hw_mode=g
channel=6
wmm_enabled=0
macaddr_acl=0
ignore_broadcast_ssid=0
# WPA2 Setting
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
# SSID and password settings
ssid=$SSID
wpa_passphrase=$PASSPHRASE
"

begin "Creating hostapd.conf..."
echo "$CONF_HOSTAP" > /etc/hostapd/hostapd.conf
end

# Setup hostap deamon config
begin "Update hostapd to reference configuration file..."
sed -i.bak 's/#DAEMON_CONF=""/DAEMON_CONF="\/etc\/hostapd\/hostapd.conf"/g' /etc/default/hostapd
end

# Add ip-forward=1
begin "Activate IPv4 forward and save it..."
sed -i.bak 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
echo 1 > /proc/sys/net/ipv4/ip_forward
end

# Add iptables rues
begin "Reinitialize iptables for routing and masquerade..."
iptables -t nat -F
iptables -F
iptables -t nat -A POSTROUTING -o $INC -j MASQUERADE
iptables -A FORWARD -i $INC -o $WIFI -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i $WIFI -o $INC -j ACCEPT
# Save iptables rules
iptables-save > /etc/iptables.ipv4.nat
end

# Create script to relead iptables on boot
begin "Restore iptables on boot..."
echo '#!/bin/sh' > /etc/network/if-up.d/iptables
echo "echo 'RUNNING iptables restore now'" >> /etc/network/if-up.d/iptables
echo "iptables-restore < /etc/iptables.ipv4.nat" >> /etc/network/if-up.d/iptables
echo "exit 0;" >> /etc/network/if-up.d/iptables

chmod +x /etc/network/if-up.d/iptables
end

# Create bridge
ifconfig -a | grep br0 > /dev/null
if [ "$?" != "0" ]
then
  begin "Creating bridge..."
	brctl addbr br0
	brctl addif br0 $INC
  end
else
	echo "Bridge br0 already exists."
fi

# test access point
echo "Installation done!"
echo
echo "You must reboot your device for this new config to take effect."
read -p "Do you want to reboot now ? [y/n] " response
if [ "$response" == "y" -o "$response" == "Y" ]
then
  echo "Rebooting..."
fi
