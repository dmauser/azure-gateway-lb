#!/bin/sh

# Script Params
# $1 = OPNScriptURI
# $2 = Primary/Secondary/SingNic/TwoNics
# $3 = Trusted Nic subnet prefix - used to get the gw
# $4 = Private IP Secondary Server

# Check if Primary or Secondary Server to setup Firewal Sync
# Note: Firewall Sync should only be setup in the Primary Server
if [ "$2" = "Primary" ]; then
    fetch $1config-active-active-primary.xml
    fetch $1get_nic_gw.py
    gwip=$(python get_nic_gw.py $3)
    sed -i "" "s/yyy.yyy.yyy.yyy/$gwip/" config-active-active-primary.xml
    sed -i "" "s/xxx.xxx.xxx.xxx/$4/" config-active-active-primary.xml
    sed -i "" "s/lll.lll.lll.lll/$5/" config-active-active-primary.xml
    sed -i "" "s/rrr.rrr.rrr.rrr/$6/" config-active-active-primary.xml
    sed -i "" "s/<hostname>OPNsense<\/hostname>/<hostname>OPNsense-Primary<\/hostname>/" config-active-active-primary.xml
    cp config-active-active-primary.xml /usr/local/etc/config.xml
    cat > /usr/local/etc/rc.syshook.d/start/25-azure <<EOL
    ifconfig hn0 mtu 4000
    ifconfig hn1 mtu 4000
    ifconfig vxlan0 down
    ifconfig vxlan0 vxlanlocal $5 vxlanremote $6 vxlanlocalport 10800 vxlanremoteport 10800
    ifconfig vxlan0 up
    ifconfig vxlan1 down
    ifconfig vxlan1 vxlanlocal $5 vxlanremote $6 vxlanlocalport 10801 vxlanremoteport 10801
    ifconfig vxlan1 up
    ifconfig bridge0 addm vxlan0
    ifconfig bridge0 addm vxlan1
    EOL
    chmod +x /usr/local/etc/rc.syshook.d/start/25-azure
elif [ "$2" = "Secondary" ]; then
    fetch $1config.xml
    fetch $1get_nic_gw.py
    gwip=$(python get_nic_gw.py $3)
    sed -i "" "s/yyy.yyy.yyy.yyy/$gwip/" config.xml
    sed -i "" "s/lll.lll.lll.lll/$4/" config.xml
    sed -i "" "s/rrr.rrr.rrr.rrr/$5/" config.xml
    sed -i "" "s/<hostname>OPNsense<\/hostname>/<hostname>OPNsense-Secondary<\/hostname>/" config.xml
    cp config.xml /usr/local/etc/config.xml
    cat > /usr/local/etc/rc.syshook.d/start/25-azure <<EOL
    ifconfig hn0 mtu 4000
    ifconfig hn1 mtu 4000
    ifconfig vxlan0 down
    ifconfig vxlan0 vxlanlocal $4 vxlanremote $5 vxlanlocalport 10800 vxlanremoteport 10800
    ifconfig vxlan0 up
    ifconfig vxlan1 down
    ifconfig vxlan1 vxlanlocal $4 vxlanremote $5 vxlanlocalport 10801 vxlanremoteport 10801
    ifconfig vxlan1 up
    ifconfig bridge0 addm vxlan0
    ifconfig bridge0 addm vxlan1
    EOL
    chmod +x /usr/local/etc/rc.syshook.d/start/25-azure
elif [ "$2" = "SingNic" ]; then
    fetch $1config-snic.xml
    cp config-snic.xml /usr/local/etc/config.xml
elif [ "$2" = "TwoNics" ]; then
    fetch $1config.xml
    fetch $1get_nic_gw.py
    gwip=$(python get_nic_gw.py $3)
    sed -i "" "s/yyy.yyy.yyy.yyy/$gwip/" config.xml
    sed -i "" "s/lll.lll.lll.lll/$4/" config.xml
    sed -i "" "s/rrr.rrr.rrr.rrr/$5/" config.xml
    cp config.xml /usr/local/etc/config.xml
fi

#OPNSense default configuration template
#fetch https://raw.githubusercontent.com/dmauser/opnazure/master/scripts/$1
#cp $1 /usr/local/etc/config.xml

# 1. Package to get root certificate bundle from the Mozilla Project (FreeBSD)
# 2. Install bash to support Azure Backup integration
env IGNORE_OSVERSION=yes
pkg bootstrap -f; pkg update -f
env ASSUME_ALWAYS_YES=YES pkg install ca_root_nss && pkg install -y bash

#Download OPNSense Bootstrap and Permit Root Remote Login
fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in
#fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in
sed -i "" 's/#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config

#OPNSense
sed -i "" "s/reboot/shutdown -r +1/g" opnsense-bootstrap.sh.in
sh ./opnsense-bootstrap.sh.in -y -r "21.7"

# Add Azure waagent
fetch https://github.com/Azure/WALinuxAgent/archive/refs/tags/v2.4.0.2.tar.gz
tar -xvzf v2.4.0.2.tar.gz
cd WALinuxAgent-2.4.0.2/
python3 setup.py install --register-service --lnx-distro=freebsd --force
cd ..

# Fix waagent by replacing configuration settings
ln -s /usr/local/bin/python3.8 /usr/local/bin/python
#sed -i "" 's/command_interpreter="python"/command_interpreter="python3"/' /etc/rc.d/waagent
#sed -i "" 's/#!\/usr\/bin\/env python/#!\/usr\/bin\/env python3/' /usr/local/sbin/waagent
sed -i "" 's/ResourceDisk.EnableSwap=y/ResourceDisk.EnableSwap=n/' /etc/waagent.conf
fetch $1actions_waagent.conf
cp actions_waagent.conf /usr/local/opnsense/service/conf/actions.d

# Remove wrong route at initialization
cat > /usr/local/etc/rc.syshook.d/start/22-remoteroute <<EOL
#!/bin/sh
route delete 168.63.129.16
EOL
chmod +x /usr/local/etc/rc.syshook.d/start/22-remoteroute

#Adds support to LB probe from IP 168.63.129.16
# Add Azure VIP on Arp table
echo # Add Azure Internal VIP >> /etc/rc.conf
echo static_arp_pairs=\"azvip\" >>  /etc/rc.conf
echo static_arp_azvip=\"168.63.129.16 12:34:56:78:9a:bc\" >> /etc/rc.conf
# Makes arp effective
service static_arp start
# To survive boots adding to OPNsense Autorun/Bootup:
echo service static_arp start >> /usr/local/etc/rc.syshook.d/start/20-freebsd