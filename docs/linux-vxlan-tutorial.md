# Linux VXLAN — Manual Tutorial (NOT a runnable script)

> **Status:** Reference only. This is a step-by-step walkthrough for setting up a Linux client to receive VXLAN-encapsulated traffic. It contains interactive vim editor commands (`:wq`) and is meant to be followed by hand, not executed.

> **Note:** The VNI values used here (900/901) are intentionally different from the lab's primary VXLAN tunnel IDs (800/801) and ports (10800/10801) used by OPNsense. This tutorial is independent of the main GLB lab deployment.

## Tutorial

SSH into your Linux VM:

```bash
ssh dmauser@104.43.226.104
```

The steps below should be run inside the Linux VM:

### 1. Create a systemd service file

Open vim to create the systemd service file:

```bash
sudo vim /etc/systemd/system/nvanetwork.service
```

Add the following content (type `:wq` when done to save and exit):

```ini
[Unit]
Description=vni service

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/bin/nvavnisetup.sh

[Install]
WantedBy=multi-user.target
```

### 2. Create the VXLAN setup script

Open vim to create the VXLAN setup script (type `:wq` when done to save and exit):

```bash
sudo vim /usr/local/bin/nvavnisetup.sh
```

Add the following content. **Note:** These VNI values (900/901) should match those configured on the GLB Backend pool:

```bash
client_internal_vni=900
client_internal_port=10800
client_external_vni=901
client_external_port=10801
nva_lb_ip=10.0.0.36

# Set MTU of 4000
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
```

### 3. Enable and start the service

Make the script executable and enable the systemd service:

```bash
sudo chmod 744 /usr/local/bin/nvavnisetup.sh
sudo chmod 664 /etc/systemd/system/nvanetwork.service
sudo systemctl daemon-reload
sudo systemctl enable nvanetwork.service
```

Your VXLAN tunnels are now configured and will start automatically on VM reboot.
