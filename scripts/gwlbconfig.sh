#!/bin/sh

# Install opnsense
fetch https://raw.githubusercontent.com/huangyingting/glb-demo/master/opnsense/config.xml
sed -i "" "s/yyy.yyy.yyy.yyy/$1/" config.xml
sed -i "" "s/lll.lll.lll.lll/$2/" config.xml
sed -i "" "s/rrr.rrr.rrr.rrr/$3/" config.xml

cp config.xml /usr/local/etc/config.xml
env IGNORE_OSVERSION=yes
env ASSUME_ALWAYS_YES=YES pkg bootstrap -f
env ASSUME_ALWAYS_YES=YES pkg update -f
env ASSUME_ALWAYS_YES=YES pkg install ca_root_nss && pkg install -y bash
fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in
sed -i "" 's/#PermitRootLogin no/PermitRootLogin yes/' /etc/ssh/sshd_config
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
sed -i "" 's/ResourceDisk.EnableSwap=y/ResourceDisk.EnableSwap=n/' /etc/waagent.conf
fetch https://raw.githubusercontent.com/huangyingting/glb-demo/master/opnsense/actions_waagent.conf
cp actions_waagent.conf /usr/local/opnsense/service/conf/actions.d

# Remove wrong route at initialization
cat > /usr/local/etc/rc.syshook.d/start/22-remoteroute <<EOL
#!/bin/sh
route delete 168.63.129.16
EOL
chmod +x /usr/local/etc/rc.syshook.d/start/22-remoteroute

# Tweak opnsense as we need to support non-standard vxlan port
cat > /usr/local/etc/rc.syshook.d/start/25-azure <<EOL
#!/bin/sh
route delete 168.63.129.16
ifconfig vxlan0 down
ifconfig vxlan0 vxlanlocal $2 vxlanremote $3 vxlanlocalport 10800 vxlanremoteport 10800
ifconfig vxlan0 up
ifconfig vxlan1 down
ifconfig vxlan1 vxlanlocal $2 vxlanremote $3 vxlanlocalport 10801 vxlanremoteport 10801
ifconfig vxlan1 up
ifconfig bridge0 addm vxlan0
ifconfig bridge0 addm vxlan1
EOL
chmod +x /usr/local/etc/rc.syshook.d/start/25-azure

# Add support to LB probe from IP 168.63.129.16
echo # Add Azure internal vip >> /etc/rc.conf
echo static_arp_pairs=\"azvip\" >>  /etc/rc.conf
echo static_arp_azvip=\"168.63.129.16 12:34:56:78:9a:bc\" >> /etc/rc.conf
# Makes arp effective
service static_arp start
# To survive boots adding to OPNsense autorun/bootup:
echo service static_arp start >> /usr/local/etc/rc.syshook.d/start/20-freebsd