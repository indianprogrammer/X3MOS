#!/bin/bash
# ==============================================================================
# LINUX CGNAT INSTALLATION & CONFIGURATION SCRIPT (JOOL)
# Private IP Range: 100.64.0.0/10 | Public IP Range: 103.69.44.0/27
# ==============================================================================

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

echo "Step 1: Installing Jool Kernel Modules and Tools..."
apt update
apt install -y jool-dkms jool-tools

echo "Step 2: Enabling Linux IPv4 Forwarding..."
sysctl -w net.ipv4.ip_forward=1
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

echo "Step 3: Creating Jool Configuration File..."
mkdir -p /etc/jool
cat << 'EOF' > /etc/jool/jool.conf
{
    "comment": "CGNAT Deployment",
    "instance": "cgnat1",
    "framework": "netfilter",
    "global": {
        "pool6": "100.64.0.0/10"
    }
}
EOF

echo "Step 4: Creating Initialization Script..."
cat << 'EOF' > /usr/local/bin/init-cgnat.sh
#!/bin/bash
# Clear any existing instances to avoid conflicts
jool instance remove cgnat1 2>/dev/null

# Add the NAT44 stateful instance using Netfilter
jool instance add cgnat1 --type NAT44 --framework netfilter

# Add your public IP pool (Usable range from your /27 block)
jool pool4 add cgnat1 103.69.44.1-103.69.44.30 --port 1024-65535
EOF

chmod +x /usr/local/bin/init-cgnat.sh

echo "Step 5: Creating and Enabling Systemd Service..."
cat << 'EOF' > /etc/systemd/system/cgnat.service
[Unit]
Description=Carrier-Grade NAT via Jool
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/init-cgnat.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cgnat.service
systemctl start cgnat.service

echo "=============================================================================="
echo "CGNAT Setup Complete!"
echo "Verify status using: sudo systemctl status cgnat.service"
echo "View active sessions using: sudo jool session display"
echo "=============================================================================="
