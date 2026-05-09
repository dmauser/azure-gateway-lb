ssh dmauser@104.43.226.104

# To be run inside Linux VM

#Create a service file
sudo vim /etc/systemd/system/nvanetwork.service

[Unit]
Description=vni service

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/bin/nvavnisetup.sh

[Install]
WantedBy=multi-user.target
:wq

#Create the file that actually sets up the VNIs
sudo vim /usr/local/bin/nvavnisetup.sh
#These should match those configure on the GW LB Backend pool
client_internal_vni=900
client_internal_port=10800
client_external_vni=901
client_external_port=10801
nva_lb_ip=10.0.0.36

#MTU of 4000
sudo ifconfig eth0 mtu 4000

# Internal tunnel
sudo ip link add vxlan${client_internal_vni} type vxlan id ${client_internal_vni} remote ${nva_lb_ip} dstport ${client_internal_port} nolearning
sudo ip link set vxlan${client_internal_vni} up
# External tunnel
sudo ip link add vxlan${client_external_vni} type vxlan id ${client_external_vni} remote ${nva_lb_ip} dstport ${client_external_port} nolearning
sudo ip link set vxlan${client_external_vni} up
# Optional: bridge both VXLAN interfaces together (works around routing between them)
sudo ip link add br-client type bridge
sudo ip link set vxlan${client_internal_vni} master br-client
sudo ip link set vxlan${client_external_vni} master br-client
sudo ip link set br-client up
:wq

#Make usable as a service
sudo chmod 744 /usr/local/bin/nvavnisetup.sh

sudo chmod 664 /etc/systemd/system/nvanetwork.service
sudo systemctl daemon-reload
sudo systemctl enable nvanetwork.service
