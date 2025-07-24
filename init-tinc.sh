#!/bin/sh
set -e

TINC_NAME="${TINC_NAME:-gnet}"
MASTER_NAME="${MASTER_NAME:-master}"
MASTER_IP="${MASTER_IP:-10.200.210.1}"
NETWORK="${NETWORK:-10.200.210.0/24}"
PORT="${PORT:-655}"
CONFIG_DIR="/usr/local/etc/tinc/$TINC_NAME"

echo "Initializing tinc VPN master node..."

if [ ! -d "$CONFIG_DIR" ]; then
    echo "Creating configuration directory..."
    mkdir -p "$CONFIG_DIR/hosts"
    
    echo "Initializing tinc with name: $MASTER_NAME"
    tinc -n "$TINC_NAME" init "$MASTER_NAME"
    
    echo "Configuring master node subnet..."
    tinc -n "$TINC_NAME" add subnet "$MASTER_IP/32"
    
    echo "Creating tinc.conf..."
    cat > "$CONFIG_DIR/tinc.conf" << EOF
Name = $MASTER_NAME
Interface = tun0
Mode = router
Port = $PORT
AddressFamily = ipv4
EOF

    echo "Creating tinc-up script..."
    cat > "$CONFIG_DIR/tinc-up" << 'EOF'
#!/bin/sh
ip link set $INTERFACE up
ip addr add 10.200.210.1/24 dev $INTERFACE
ip route add 10.200.210.0/24 dev $INTERFACE
EOF
    chmod +x "$CONFIG_DIR/tinc-up"

    echo "Creating tinc-down script..."
    cat > "$CONFIG_DIR/tinc-down" << 'EOF'
#!/bin/sh
ip route del 10.200.210.0/24 dev $INTERFACE
ip addr del 10.200.210.1/24 dev $INTERFACE
ip link set $INTERFACE down
EOF
    chmod +x "$CONFIG_DIR/tinc-down"

    echo "Adding Address to host file..."
    PUBLIC_IP=$(wget -qO- http://ipinfo.io/ip 2>/dev/null || echo "0.0.0.0")
    if [ "$PUBLIC_IP" != "0.0.0.0" ]; then
        echo "Address = $PUBLIC_IP" >> "$CONFIG_DIR/hosts/$MASTER_NAME"
    fi
    echo "Port = $PORT" >> "$CONFIG_DIR/hosts/$MASTER_NAME"

    echo "tinc configuration completed!"
else
    echo "Configuration already exists, skipping initialization..."
fi

echo "Starting tinc daemon..."
exec tincd -n "$TINC_NAME" -D -d2