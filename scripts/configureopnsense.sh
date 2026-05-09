#!/bin/sh

# Configure OPNsense for Azure Gateway Load Balancer (active-active NVA pair).
#
# Usage:
#   configureopnsense.sh <uri_prefix> <role> <local_ip_cidr> <peer_ip>
#
# Parameters:
#   $1  URI prefix    Type: URL string (trailing slash required)
#                     Example: https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/
#                     Used: base URL for fetch of XML templates (glb-config-active-active-primary.xml /
#                           glb-config.xml), get_nic_gw.py helper, and actions_waagent.conf
#
#   $2  Role          Type: string — "Primary" or "Secondary"
#                     Example: Primary
#                     Used: selects which XML template to apply; sets OPNsense hostname suffix
#                           (OPNsense-Primary / OPNsense-Secondary); controls HA-sync substitution
#                           (xxx.xxx.xxx.xxx replaced only for Primary)
#
#   $3  Local CIDR    Type: IPv4/prefix (CIDR notation, no spaces)
#                     Example: 10.0.1.5/24
#                     Used: passed to get_nic_gw.py to derive LAN gateway → yyy.yyy.yyy.yyy in XML;
#                           IP portion (CIDR stripped) → lll.lll.lll.lll in XML and VXLAN local addr
#
#   $4  Peer IP       Type: IPv4 address (no prefix)
#                     Example: 10.0.1.6
#                     Used: rrr.rrr.rrr.rrr in XML (VXLAN remote addr, both roles);
#                           xxx.xxx.xxx.xxx in XML (HA-sync synchronizetoip, Primary only)
#
# XML placeholder mapping:
#   yyy.yyy.yyy.yyy  -> LAN gateway (derived from $3 via get_nic_gw.py)
#   xxx.xxx.xxx.xxx  -> peer NVA IP / HA-sync target ($4, Primary only)
#   lll.lll.lll.lll  -> local NVA IP (IP portion of $3, CIDR stripped)
#   rrr.rrr.rrr.rrr  -> peer NVA IP ($4)
#
# Example invocations:
#   Primary NVA:
#     sh configureopnsense.sh \
#       https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/ \
#       Primary 10.0.1.5/24 10.0.1.6
#
#   Secondary NVA:
#     sh configureopnsense.sh \
#       https://raw.githubusercontent.com/dmauser/azure-gateway-lb/main/scripts/ \
#       Secondary 10.0.1.6/24 10.0.1.5
#
# Invocation context:
#   This script is executed via Azure Custom Script Extension, configured in
#   bicep/modules/VM/vmext.bicep. The module parameters map as follows:
#     OPNScriptURI          -> $1 (URI prefix; also used as fileUris base)
#     ShellScriptParameters -> "$2 $3 $4" (Role, LocalCIDR, PeerIP assembled in Bicep)
#   The extension runs: sh configureopnsense.sh <OPNScriptURI> <ShellScriptParameters>
#
# VXLAN port persistence (Phase 2):
#   VXLAN interfaces use non-standard ports: 10800 (vxlan0 / ID 800, internal)
#   and 10801 (vxlan1 / ID 801, external). As of Phase 2, these ports are declared
#   directly in the XML templates via <vxlanlocalport>/<vxlanremoteport> tags, ensuring
#   the correct ports survive OPNsense config reloads. The rc.syshook startup hook
#   (25-azure) also enforces them at boot as a secondary safeguard.

set -euo pipefail
trap 'echo "Error on line $LINENO (exit $?)" >&2' ERR

# Derive bare local IP (strip CIDR prefix) for XML and VXLAN substitutions
localip=$(echo $3 | cut -d'/' -f1)

if [ "$2" = "Primary" ]; then
    fetch $1glb-config-active-active-primary.xml
    fetch $1get_nic_gw.py
    gwip=$(python3 get_nic_gw.py $3)
    sed -i "" "s/yyy.yyy.yyy.yyy/$gwip/" glb-config-active-active-primary.xml
    sed -i "" "s/xxx.xxx.xxx.xxx/$4/" glb-config-active-active-primary.xml
    sed -i "" "s/lll.lll.lll.lll/$localip/" glb-config-active-active-primary.xml
    sed -i "" "s/rrr.rrr.rrr.rrr/$4/" glb-config-active-active-primary.xml
    sed -i "" "s/<hostname>OPNsense<\/hostname>/<hostname>OPNsense-Primary<\/hostname>/" glb-config-active-active-primary.xml
    cp glb-config-active-active-primary.xml /usr/local/etc/config.xml
elif [ "$2" = "Secondary" ]; then
    fetch $1glb-config.xml
    fetch $1get_nic_gw.py
    gwip=$(python3 get_nic_gw.py $3)
    sed -i "" "s/yyy.yyy.yyy.yyy/$gwip/" glb-config.xml
    sed -i "" "s/lll.lll.lll.lll/$localip/" glb-config.xml
    sed -i "" "s/rrr.rrr.rrr.rrr/$4/" glb-config.xml
    sed -i "" "s/<hostname>OPNsense<\/hostname>/<hostname>OPNsense-Secondary<\/hostname>/" glb-config.xml
    cp glb-config.xml /usr/local/etc/config.xml
fi

#OPNSense default configuration template
#fetch https://raw.githubusercontent.com/dmauser/opnazure/master/scripts/$1
#cp $1 /usr/local/etc/config.xml

# 1. Package to get root certificate bundle from the Mozilla Project (FreeBSD)
# 2. Install bash to support Azure Backup integration
#env IGNORE_OSVERSION=yes
#pkg bootstrap -f; pkg update -f
#env ASSUME_ALWAYS_YES=YES pkg install ca_root_nss && pkg install -y bash

#Download OPNSense Bootstrap and Permit Root Remote Login
# fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in
#fetch https://raw.githubusercontent.com/opnsense/update/7ba940e0d57ece480540c4fd79e9d99a87f222c8/src/bootstrap/opnsense-bootstrap.sh.in
fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in
sed -i "" 's/#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config

#OPNSense
# Due to a recent change in pkg the following commands no longer finish with status code 0
#		pkg unlock -a
#		pkg delete -fa
# This resplace of set -e which force the script to finish in case of non status code 0 has to be inplace
sed -i "" "s/set -e/#set -e/g" opnsense-bootstrap.sh.in
sed -i "" "s/reboot/shutdown -r +1/g" opnsense-bootstrap.sh.in
sh ./opnsense-bootstrap.sh.in -y -r 25.1

# Add Azure waagent
fetch https://github.com/Azure/WALinuxAgent/archive/refs/tags/v2.12.0.4.tar.gz
tar -xvzf v2.12.0.4.tar.gz
cd WALinuxAgent-2.12.0.4/
python3 setup.py install --register-service --lnx-distro=freebsd --force
cd ..

# Fix waagent by replacing configuration settings
##sed -i "" 's/command_interpreter="python"/command_interpreter="python3"/' /etc/rc.d/waagent
##sed -i "" 's/#!\/usr\/bin\/env python/#!\/usr\/bin\/env python3/' /usr/local/sbin/waagent
sed -i "" 's/ResourceDisk.EnableSwap=y/ResourceDisk.EnableSwap=n/' /etc/waagent.conf
fetch $1actions_waagent.conf
cp actions_waagent.conf /usr/local/opnsense/service/conf/actions.d

# Installing bash - This is a requirement for Azure custom Script extension to run
pkg install -y bash
pkg install -y os-frr

# Remove wrong route at initialization
cat > /usr/local/etc/rc.syshook.d/start/22-remoteroute <<EOL
#!/bin/sh
route delete 168.63.129.16
EOL
chmod +x /usr/local/etc/rc.syshook.d/start/22-remoteroute

#VXLAN config — identical for Primary and Secondary; IPs derived from $3/$4
echo ifconfig hn0 mtu 4000 >> /usr/local/etc/rc.syshook.d/start/25-azure
echo ifconfig hn1 mtu 4000 >> /usr/local/etc/rc.syshook.d/start/25-azure
echo ifconfig vxlan0 down >> /usr/local/etc/rc.syshook.d/start/25-azure
echo ifconfig vxlan0 vxlanlocal $localip vxlanremote $4 vxlanlocalport 10800 vxlanremoteport 10800 >> /usr/local/etc/rc.syshook.d/start/25-azure
echo ifconfig vxlan0 up >> /usr/local/etc/rc.syshook.d/start/25-azure
echo ifconfig vxlan1 down >> /usr/local/etc/rc.syshook.d/start/25-azure
echo ifconfig vxlan1 vxlanlocal $localip vxlanremote $4 vxlanlocalport 10801 vxlanremoteport 10801 >> /usr/local/etc/rc.syshook.d/start/25-azure
echo ifconfig vxlan1 up >> /usr/local/etc/rc.syshook.d/start/25-azure
echo ifconfig bridge0 addm vxlan0 >> /usr/local/etc/rc.syshook.d/start/25-azure
echo ifconfig bridge0 addm vxlan1 >> /usr/local/etc/rc.syshook.d/start/25-azure
chmod +x /usr/local/etc/rc.syshook.d/start/25-azure

#Adds support to LB probe from IP 168.63.129.16
# Add Azure VIP on Arp table
echo # Add Azure Internal VIP >> /etc/rc.conf
echo static_arp_pairs=\"azvip\" >>  /etc/rc.conf
echo static_arp_azvip=\"168.63.129.16 12:34:56:78:9a:bc\" >> /etc/rc.conf
# Makes arp effective
service static_arp start
# To survive boots adding to OPNsense Autorun/Bootup:
echo service static_arp start >> /usr/local/etc/rc.syshook.d/start/20-freebsd

# Reset WebGUI certificate
echo #\!/bin/sh >> /usr/local/etc/rc.syshook.d/start/94-restartwebgui
echo configctl webgui restart renew >> /usr/local/etc/rc.syshook.d/start/94-restartwebgui
echo rm /usr/local/etc/rc.syshook.d/start/94-restartwebgui >> /usr/local/etc/rc.syshook.d/start/94-restartwebgui
chmod +x /usr/local/etc/rc.syshook.d/start/94-restartwebgui