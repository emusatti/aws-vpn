#!/bin/bash

exec > /var/log/userdata.log 2>&1

#check for internet connection
echo "Waiting for internet connection..."
$ATTEMPTS=0
$MAX_ATTEMPTS=10

while ! curl -s --max-time 5 http://connectivitycheck.gstatic.com/generate_204 > /dev/null 2>&1; do
    echo "No internet connection, retrying in 30 seconds..."
    sleep 30
done
echo "Internet connection established, proceeding..."


#setup
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

#Install OpenVPN & easyrsa
apt-get install -y openvpn easy-rsa

#check if ip_forward is enabled
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" == "0" ]; then
    echo "ip_forward is disabled, enabling..."
    sysctl -w net.ipv4.ip_forward=1
fi

#make ip_forward permanent
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
sysctl -p /etc/sysctl.d/99-openvpn.conf

#add POSTROUTING MASQUERADE to iptables
IFACE=$(ip route | grep default | awk '{print $5}')

if ! iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$IFACE" -j MASQUERADE
    echo "MASQUERADE rule added on $IFACE"
else
    echo "MASQUERADE rule already exists, skipping..."
fi

#add FORWARD rules
iptables -A FORWARD -i tun0 -o "$IFACE" -j ACCEPT
iptables -A FORWARD -i "$IFACE" -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT


#MAKE CERT PART

#easy-rsa
mkdir -p /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa
cp -Rv /usr/share/easy-rsa/* .

echo "Generating certificates..."

./easyrsa init-pki
./easyrsa --batch --req-cn="VPN-CA" build-ca nopass #default CN=VPN-CA
./easyrsa gen-dh
./easyrsa --batch gen-req server nopass #CN=server -- server.crt
./easyrsa --batch sign-req server server
./easyrsa --batch gen-req client nopass #CN=client -- client.crt
./easyrsa --batch sign-req client client
openvpn --genkey secret /etc/openvpn/pfs.key


# Create server.conf
cat > /etc/openvpn/server.conf << 'EOF'
port 1194
proto udp
dev tun
ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem
tls-cipher TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256:TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256:TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384:TLS-DHE-RSA-WITH-AES-256-CBC-SHA256
data-ciphers AES-256-GCM:AES-256-CBC
data-ciphers-fallback AES-256-CBC
auth SHA512
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
ifconfig-pool-persist ipp.txt
keepalive 10 120
persist-key
persist-tun
status openvpn-status.log
log-append openvpn.log
verb 3
tls-server
tls-auth /etc/openvpn/pfs.key 0
EOF

#save rules to survive reboot
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
apt-get install -y iptables-persistent


#Check if OpenVPN is active and enabled
if systemctl is-active --quiet openvpn@server && systemctl is-enabled --quiet openvpn@server; then
    echo "OpenVPN is active and enabled"
else
    echo "Starting and enabling OpenVPN..."
    systemctl enable openvpn@server
    systemctl start openvpn@server
fi

cat > /etc/openvpn/client.ovpn << EOF
client
dev tun
proto udp
remote $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4) 1194
tls-version-min 1.2
tls-cipher TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256:TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256:TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384:TLS-DHE-RSA-WITH-AES-256-CBC-SHA256
data-ciphers AES-256-GCM:AES-256-CBC
data-ciphers-fallback AES-256-CBC
auth SHA512
resolv-retry infinite
auth-retry none
nobind
persist-key
persist-tun
verb 3
tls-client
key-direction 1
verify-x509-name server name

<ca>
$(cat /etc/openvpn/easy-rsa/pki/ca.crt)
</ca>

<cert>
$(cat /etc/openvpn/easy-rsa/pki/issued/client.crt)
</cert>

<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client.key)
</key>

<tls-auth>
$(cat /etc/openvpn/pfs.key)
</tls-auth>
EOF

echo "client.ovpn created at /etc/openvpn/client.ovpn"
