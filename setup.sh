#!/bin/bash -e

# Copyright (c) 2015 – 2020 Ali Fakih
# Released under the MIT licence: http://opensource.org/licenses/mit-license

echo 
echo " SETUP IKEV2 EAP Radius With Let's Encrypty"
echo 

function exit_badly {
	echo "$1"
	exit 1
}

[[ $(lsb_release-rs) =="18.04"]] || [[ $(lsb_release-rs) == "20.04" ]] || exit_badly "This script is for Ubuntu 20.04 or 18.04 only: aborting"
[[ $(id -u) -eq 0 ]] || exit_badly "Please re-run as root (e.g. ./path/to/this/script)"


echo "****** Updating Repositories ******"
echo

export DEBIAN_FRONTEND-noninteractive

apt-get update

echo "installing StrongSwan"
apt-get install -y language-pack-en strongswan libstrongswan-standard-plugins strongswan-libcharon libcharon-standard-plugins libcharon-extra-plugins moreutils iptables-persistent

echo "installing Certbot"
apt-get install certbot

echo 
echo "Generating Certificate"
echo
mkdir -p /etc/ letsencrypt
echo 'rsa-key-size = 4096 pre-hook = /sbin/iptables -I INPUT -p tcp --dport 80 -j ACCEPT post-hook = /sbin/iptables -D INPUT -p tcp --dport 80 -j ACCEPT renew-hook = /usr/sbin/ipsec reload && /usr/sbin/ipsec secrets' > /etc/letsencrypt/cli.ini
echo 
echo "Generate the certificate and get it ready for strongswan. Note: hostname must resolve to this machine already, to enable Let’s Encrypt certificate setup."
echo 

read -r -p "email: " EMAIL
echo 
read -r -p "domain: " DOMAIN
echo 
certbot certonly --non-interactive --agree-tos --standalone --preferred-challenges http --email ${EMAIL} -d ${DOMAIN}
ln -f -s /etc/letsencrypt/live/${DOMAIN}/cert.pem    /etc/ipsec.d/certs/cert.pem
ln -f -s /etc/letsencrypt/live/${DOMAIN}/privkey.pem /etc/ipsec.d/private/privkey.pem
ln -f -s /etc/letsencrypt/live/${DOMAIN}/chain.pem   /etc/ipsec.d/cacerts/chain.pem

ehco 
echo "/etc/letsencrypt/archive/${DOMAIN}* r," >> /etc/apparmor.d/local/usr.lib.ipsec.charon
echo

aa-status --enabled invoke-rc.d apparmor reload

echo "Setup Iptables"
echo 

apt-get install iptables-persistent -y
iptables -P INPUT   ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT  ACCEPT
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -A INPUT -p udp --dport  500 -j ACCEPT
iptables -A INPUT -p udp --dport 4500 -j ACCEPT

# forward VPN traffic anywhere
echo "forward VPN traffic"
echo 
read -r -p "IP FORWARD: 10.10.10.10/24" IPFORWARD
iptables -A FORWARD --match policy --pol ipsec --dir in  --proto esp -s ${IPFORWARD} -j ACCEPT
iptables -A FORWARD --match policy --pol ipsec --dir out --proto esp -d ${IPFORWARD} -j ACCEPT
iptables -P FORWARD ACCEPT

# reduce MTU/MSS values for dumb VPN clients
echo
echo "Reduce MTU/MSS"
echo
iptables -t mangle -A FORWARD --match policy --pol ipsec --dir in -s ${IPFORWARD} -o eth0 -p tcp -m tcp --tcp-flags SYN,RST SYN -m tcpmss --mss 1361:1536 -j TCPMSS --set-mss 1360

# masquerade VPN traffic over eth0 etc.
echo 
read -r -p "Enter your interface: exp: eth0 / ens3" INTERFACE
echo "masquerade VPN traffic over eth0 etc."
iptables -t nat -A POSTROUTING -s ${IPFORWARD} -o ${INTERFACE} -m policy --pol ipsec --dir out -j ACCEPT  # exempt IPsec traffic from masquerading
iptables -t nat -A POSTROUTING -s ${IPFORWARD} -o ${INTERFACE} -j MASQUERADE

echo
echo "SAVING RULES"
echo
iptables-save > /etc/iptables/rules.v4

echo "IKEV2 with Radius Auth"
echo '
# vpnforward
net.ipv4.ip_forward = 1
net.ipv4.ip_no_pmtu_disc = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.disable_ipv6 = 1
' >> /etc/sysctl.conf

sysctl -p
echo "${DOMAIN} : RSA \"privkey.pem\"" > /etc/ipsec.secrets


echo "config setup
  strictcrlpolicy=yes
  uniqueids=never
conn roadwarrior
  auto=add
  compress=no
  type=tunnel
  keyexchange=ikev2
  fragmentation=yes
  forceencaps=yes
 
  ike=aes256-sha1-modp1024,aes256gcm16-sha256-ecp521,aes256-sha256-ecp384
  esp=aes256-sha1,aes128-sha256-modp3072,aes256gcm16-sha256,aes256gcm16-ecp384
 
  dpdaction=clear
  dpddelay=180s
  rekey=no
  left=%any
  leftid=@YOUR.DOMAIN.COM
  leftcert=cert.pem
  leftsendcert=always
  leftsubnet=0.0.0.0/0
  right=%any
  rightid=%any
  rightauth=eap-radius # this uses radius authentication 
  eap_identity=%any
  rightdns=8.8.8.8,8.8.4.4
  rightsourceip=10.10.10.0/24
  rightsendcert=never
 
" > /etc/ipsec.conf

echo '
# vpnforward
net.ipv4.ip_forward = 1
net.ipv4.ip_no_pmtu_disc = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.disable_ipv6 = 1
' >> /etc/sysctl.conf

sysctl -p

read -r -p "Username: " USERNAME
read -r -s -p "PASSWORD: " VPNPASSWORD
echo "${DOMAIN} : RSA \"privkey.pem\"
${USERNAME} : EAP \""${VPNPASSWORD}"\"
" > /etc/ipsec.secrets


echo "config setup
  strictcrlpolicy=yes
  uniqueids=never
conn roadwarrior
  auto=add
  compress=no
  type=tunnel
  keyexchange=ikev2
  fragmentation=yes
  forceencaps=yes
 
  ike=aes256-sha1-modp1024,aes256gcm16-sha256-ecp521,aes256-sha256-ecp384
  esp=aes256-sha1,aes128-sha256-modp3072,aes256gcm16-sha256,aes256gcm16-ecp384
 
  dpdaction=clear
  dpddelay=180s
  rekey=no
  left=%any
  leftid=@${DOMAIN}
  leftcert=cert.pem
  leftsendcert=always
  leftsubnet=0.0.0.0/0
  right=%any
  rightid=%any
  rightauth=eap-mschapv2 # users are stored in /etc/ipsec.secrets
  eap_identity=%any
  rightdns=8.8.8.8,8.8.4.4
  rightsourceip=${IPFORWARD}
  rightsendcert=never
 
" > /etc/ipsec.conf

ipsec restart


