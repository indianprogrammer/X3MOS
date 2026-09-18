#!/bin/bash
# ==============================================================================
# DEBIAN 13 SYSTEMD-NETWORKD VLAN CONFIGURATION SCRIPT
# Physical Interface: eth0 | VLAN ID: 100 | IP: 192.168.100.10/24
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

echo "Step 1: Enabling systemd-networkd..."
systemctl enable systemd-networkd
systemctl start systemd-networkd

echo "Step 2: Creating the Virtual VLAN Device (.netdev)..."
cat << 'EOF' > /etc/systemd/network/20-vlan100.netdev
[NetDev]
Name=eth0.100
Kind=vlan

[VLAN]
Id=100
EOF

echo "Step 3: Binding the VLAN to the Physical Interface..."
cat << 'EOF' > /etc/systemd/network/10-eth0.network
[Match]
Name=eth0

[Network]
VLAN=eth0.100
DHCP=yes
EOF

echo "Step 4: Configuring the Layer 3 IP Profile for the VLAN..."
cat << 'EOF' > /etc/systemd/network/30-eth0.100.network
[Match]
Name=eth0.100

[Network]
Address=192.168.100.10/24
Gateway=192.168.100.1
DNS=1.1.1.1 8.8.8.8
EOF

echo "Step 5: Applying Changes..."
systemctl restart systemd-networkd

echo "=============================================================================="
echo "VLAN 100 Setup Complete!"
echo "Verify configuration using: ip link show dev eth0.100"
echo "Check IP state using: networkctl status eth0.100"
echo "=============================================================================="
