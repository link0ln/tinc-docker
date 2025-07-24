#!/bin/sh
# firewall-simple-v2.sh - Simplified version without ME

# Configuration
SUBNET="192.168.31.64/26"
VPN_GATEWAY="10.200.210.1"
VPN_INTERFACE="tap5"
DEFAULT_GATEWAY="10.178.4.1"
WAN_IP="10.178.5.63"
IPSET_NAME_RU="RU"

# Interface names
LAN_INTERFACE="br-lan"
WAN_INTERFACE="eth0"

# Routing tables
TABLE_RU=100
TABLE_VPN=200

# Routing marks
MARK_RU=1
MARK_VPN=2

# Routing priorities
PRIORITY_RU=32765
PRIORITY_VPN=32764

ACTION="${1:-check}"

rule_exists() {
    ip rule list | grep -q "fwmark $1 lookup $2"
}

route_exists() {
    ip route show table "$1" 2>/dev/null | grep -q "default"
}

route_local_exists() {
    ip route show table "$1" 2>/dev/null | grep -q "$SUBNET"
}

check_rules() {
    echo "=== Checking firewall rules ==="

    echo -n "FORWARD rule for $SUBNET: "
    if iptables -C FORWARD -s "$SUBNET" -j ACCEPT 2>/dev/null; then
        echo "EXISTS"
    else
        echo "MISSING"
    fi

    echo -n "FORWARD rule $LAN_INTERFACE->$WAN_INTERFACE: "
    if iptables -C FORWARD -i "$LAN_INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT 2>/dev/null; then
        echo "EXISTS"
    else
        echo "MISSING"
    fi

    echo -n "FORWARD rule $VPN_INTERFACE->$LAN_INTERFACE: "
    if iptables -C FORWARD -i "$VPN_INTERFACE" -o "$LAN_INTERFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        echo "EXISTS"
    else
        echo "MISSING"
    fi

    echo -n "FORWARD rule $LAN_INTERFACE->$VPN_INTERFACE: "
    if iptables -C FORWARD -i "$LAN_INTERFACE" -o "$VPN_INTERFACE" -j ACCEPT 2>/dev/null; then
        echo "EXISTS"
    else
        echo "MISSING"
    fi

    echo -n "MANGLE rule for RU (mark $MARK_RU): "
    if iptables -t mangle -C PREROUTING -s "$SUBNET" -m mark --mark 0x0 -m set --match-set "$IPSET_NAME_RU" dst -j MARK --set-xmark "0x$MARK_RU/0xffffffff" 2>/dev/null; then
        echo "EXISTS"
    else
        echo "MISSING"
    fi

    echo -n "MANGLE rule for others (mark $MARK_VPN): "
    if iptables -t mangle -C PREROUTING -s "$SUBNET" -m mark --mark 0x0 -j MARK --set-xmark "0x$MARK_VPN/0xffffffff" 2>/dev/null; then
        echo "EXISTS"
    else
        echo "MISSING"
    fi

    echo "Routing rules:"
    ip rule show

    echo "Routes in tables:"
    echo "Table $TABLE_RU (RU direct):"
    ip route show table $TABLE_RU 2>/dev/null || echo "  Empty"
    echo "Table $TABLE_VPN (VPN):"
    ip route show table $TABLE_VPN 2>/dev/null || echo "  Empty"
}

clean_rules() {
    echo "=== Cleaning firewall rules ==="

    # Remove filter rules
    iptables -D FORWARD -i "$LAN_INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$VPN_INTERFACE" -o "$LAN_INTERFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$LAN_INTERFACE" -o "$VPN_INTERFACE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -s "$SUBNET" -j ACCEPT 2>/dev/null || true

    # Remove mangle rules
    iptables -t mangle -D PREROUTING -j CONNMARK --restore-mark --nfmask 0xffffffff --ctmask 0xffffffff 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "$SUBNET" -m mark --mark 0x0 -m set --match-set "$IPSET_NAME_RU" dst -j MARK --set-xmark "0x$MARK_RU/0xffffffff" 2>/dev/null || true
    iptables -t mangle -D PREROUTING -s "$SUBNET" -m mark --mark 0x0 -j MARK --set-xmark "0x$MARK_VPN/0xffffffff" 2>/dev/null || true
    iptables -t mangle -D PREROUTING -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff 2>/dev/null || true

    # Remove NAT rules
    iptables -t nat -D POSTROUTING -s "$SUBNET" -o "$WAN_INTERFACE" -m set --match-set "$IPSET_NAME_RU" dst -j SNAT --to-source "$WAN_IP" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$SUBNET" -o "$WAN_INTERFACE" -m set --match-set "$IPSET_NAME_RU" dst -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$SUBNET" -o "$VPN_INTERFACE" -j MASQUERADE 2>/dev/null || true

    # Remove postrouting_wan_rule entries
    iptables -t nat -D postrouting_wan_rule -s "$SUBNET" -m mark --mark "0x$MARK_RU" -j RETURN 2>/dev/null || true
    iptables -t nat -D postrouting_wan_rule -s "$SUBNET" -m mark --mark "0x$MARK_VPN" -j RETURN 2>/dev/null || true
    iptables -t nat -D postrouting_wan_rule -s "$SUBNET" -m set --match-set "$IPSET_NAME_RU" dst -j RETURN 2>/dev/null || true

    # Remove routing rules
    ip rule del fwmark $MARK_RU table $TABLE_RU 2>/dev/null || true
    ip rule del fwmark $MARK_VPN table $TABLE_VPN 2>/dev/null || true

    # Remove routes
    ip route flush table $TABLE_RU 2>/dev/null || true
    ip route flush table $TABLE_VPN 2>/dev/null || true

    echo "Cleanup complete"
}

setup_rules() {
    echo "=== Setting up firewall rules ==="

    # Check ipsets
    if ! ipset list "$IPSET_NAME_RU" >/dev/null 2>&1; then
        echo "ERROR: ipset $IPSET_NAME_RU does not exist!"
        return 1
    fi

    # Add CONNMARK rules first if missing
    if ! iptables -t mangle -C PREROUTING -j CONNMARK --restore-mark --nfmask 0xffffffff --ctmask 0xffffffff 2>/dev/null; then
        iptables -t mangle -I PREROUTING 1 -j CONNMARK --restore-mark --nfmask 0xffffffff --ctmask 0xffffffff
        echo "Added CONNMARK restore"
    fi

    # Add mangle rules
    if ! iptables -t mangle -C PREROUTING -s "$SUBNET" -m mark --mark 0x0 -m set --match-set "$IPSET_NAME_RU" dst -j MARK --set-xmark "0x$MARK_RU/0xffffffff" 2>/dev/null; then
        iptables -t mangle -A PREROUTING -s "$SUBNET" -m mark --mark 0x0 -m set --match-set "$IPSET_NAME_RU" dst -j MARK --set-xmark "0x$MARK_RU/0xffffffff"
        echo "Added MANGLE rule for RU"
    fi

    if ! iptables -t mangle -C PREROUTING -s "$SUBNET" -m mark --mark 0x0 -j MARK --set-xmark "0x$MARK_VPN/0xffffffff" 2>/dev/null; then
        iptables -t mangle -A PREROUTING -s "$SUBNET" -m mark --mark 0x0 -j MARK --set-xmark "0x$MARK_VPN/0xffffffff"
        echo "Added MANGLE rule for others (VPN)"
    fi

    if ! iptables -t mangle -C PREROUTING -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff 2>/dev/null; then
        iptables -t mangle -A PREROUTING -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff
        echo "Added CONNMARK save"
    fi

    # Add filter rules
    if ! iptables -C FORWARD -i "$LAN_INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT 2>/dev/null; then
        # Find position after "br-miot DROP" rule
        local pos=$(iptables -L FORWARD --line-numbers -n | grep "br-miot.*DROP" | awk '{print $1}')
        if [ -n "$pos" ]; then
            iptables -I FORWARD $((pos + 1)) -i "$LAN_INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT
        else
            iptables -I FORWARD 2 -i "$LAN_INTERFACE" -o "$WAN_INTERFACE" -j ACCEPT
        fi
        echo "Added FORWARD $LAN_INTERFACE->$WAN_INTERFACE"
    fi

    # Always add VPN_INTERFACE rules (they will be used when VPN_INTERFACE comes up)
    if ! iptables -C FORWARD -i "$VPN_INTERFACE" -o "$LAN_INTERFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        iptables -I FORWARD 3 -i "$VPN_INTERFACE" -o "$LAN_INTERFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        echo "Added FORWARD $VPN_INTERFACE->$LAN_INTERFACE"
    fi

    if ! iptables -C FORWARD -i "$LAN_INTERFACE" -o "$VPN_INTERFACE" -j ACCEPT 2>/dev/null; then
        iptables -I FORWARD 4 -i "$LAN_INTERFACE" -o "$VPN_INTERFACE" -j ACCEPT
        echo "Added FORWARD $LAN_INTERFACE->$VPN_INTERFACE"
    fi

    if ! iptables -C FORWARD -s "$SUBNET" -j ACCEPT 2>/dev/null; then
        iptables -I FORWARD 5 -s "$SUBNET" -j ACCEPT
        echo "Added FORWARD rule for subnet"
    fi

    # Add NAT rules
    local nat_pos=$(iptables -t nat -L POSTROUTING --line-numbers | grep -n "zone_wan_postrouting" | head -1 | awk -F: '{print $1}')
    if [ -z "$nat_pos" ] || [ "$nat_pos" -lt 5 ]; then
        nat_pos=5
    fi

    if ! iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$WAN_INTERFACE" -m set --match-set "$IPSET_NAME_RU" dst -j SNAT --to-source "$WAN_IP" 2>/dev/null; then
        iptables -t nat -I POSTROUTING $nat_pos -s "$SUBNET" -o "$WAN_INTERFACE" -m set --match-set "$IPSET_NAME_RU" dst -j SNAT --to-source "$WAN_IP"
        echo "Added SNAT for RU at position $nat_pos"
        nat_pos=$((nat_pos + 1))
    fi

    if ! iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$WAN_INTERFACE" -m set --match-set "$IPSET_NAME_RU" dst -j MASQUERADE 2>/dev/null; then
        iptables -t nat -I POSTROUTING $nat_pos -s "$SUBNET" -o "$WAN_INTERFACE" -m set --match-set "$IPSET_NAME_RU" dst -j MASQUERADE
        echo "Added MASQUERADE for RU at position $nat_pos"
        nat_pos=$((nat_pos + 1))
    fi

    # Always add VPN_INTERFACE NAT rule (will be used when VPN_INTERFACE comes up)
    if ! iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$VPN_INTERFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -I POSTROUTING $nat_pos -s "$SUBNET" -o "$VPN_INTERFACE" -j MASQUERADE
        echo "Added MASQUERADE for VPN at position $nat_pos"
    fi

    # Add postrouting_wan_rule entries
    if ! iptables -t nat -C postrouting_wan_rule -s "$SUBNET" -m set --match-set "$IPSET_NAME_RU" dst -j RETURN 2>/dev/null; then
        iptables -t nat -A postrouting_wan_rule -s "$SUBNET" -m set --match-set "$IPSET_NAME_RU" dst -j RETURN
    fi
    if ! iptables -t nat -C postrouting_wan_rule -s "$SUBNET" -m mark --mark "0x$MARK_VPN" -j RETURN 2>/dev/null; then
        iptables -t nat -A postrouting_wan_rule -s "$SUBNET" -m mark --mark "0x$MARK_VPN" -j RETURN
    fi
    if ! iptables -t nat -C postrouting_wan_rule -s "$SUBNET" -m mark --mark "0x$MARK_RU" -j RETURN 2>/dev/null; then
        iptables -t nat -A postrouting_wan_rule -s "$SUBNET" -m mark --mark "0x$MARK_RU" -j RETURN
    fi

    # Add routing rules
    if ! rule_exists "0x$MARK_RU" "$TABLE_RU"; then
        ip rule add fwmark $MARK_RU table $TABLE_RU priority $PRIORITY_RU
        echo "Added routing rule for fwmark $MARK_RU"
    fi

    if ! rule_exists "0x$MARK_VPN" "$TABLE_VPN"; then
        ip rule add fwmark $MARK_VPN table $TABLE_VPN priority $PRIORITY_VPN
        echo "Added routing rule for fwmark $MARK_VPN"
    fi

    # Add routes to table RU (direct) with local route
    if ! route_exists "$TABLE_RU"; then
        ip route add default via "$DEFAULT_GATEWAY" dev "$WAN_INTERFACE" table $TABLE_RU
        echo "Added default route for table $TABLE_RU"
    fi

    if ! route_local_exists "$TABLE_RU"; then
        ip route add "$SUBNET" dev "$LAN_INTERFACE" table $TABLE_RU
        echo "Added local route for table $TABLE_RU"
    fi

    # Setup VPN routes - always add them, they will be used when VPN_INTERFACE comes up
    if ip link show "$VPN_INTERFACE" >/dev/null 2>&1; then
        if ! ip link show "$VPN_INTERFACE" | grep -q "UP"; then
            echo "Bringing up $VPN_INTERFACE..."
            ip link set "$VPN_INTERFACE" up
            sleep 1
        fi
    fi

    # Always add routes for table VPN (they will work when VPN_INTERFACE is up)
    if ! route_exists "$TABLE_VPN"; then
        if ip link show "$VPN_INTERFACE" >/dev/null 2>&1; then
            ip route add default via "$VPN_GATEWAY" dev "$VPN_INTERFACE" table $TABLE_VPN
            echo "Added default route for table $TABLE_VPN"
        else
            # Add route without specifying device - kernel will figure it out when VPN_INTERFACE comes up
            ip route add default via "$VPN_GATEWAY" table $TABLE_VPN 2>/dev/null || echo "Will add route to table $TABLE_VPN when VPN is up"
        fi
    fi

    if ! route_local_exists "$TABLE_VPN"; then
        ip route add "$SUBNET" dev "$LAN_INTERFACE" scope link table $TABLE_VPN
        echo "Added local route for table $TABLE_VPN"
    fi

    # IMPORTANT: We do NOT delete default route from main table!
    # Router needs it to connect to VPN server
    echo "Note: Main routing table keeps default route for router connectivity"
}

# Special function to setup VPN routes after VPN_INTERFACE is up
setup_vpn_routes() {
    echo "=== Setting up VPN routes ==="

    if ! ip link show "$VPN_INTERFACE" >/dev/null 2>&1; then
        echo "ERROR: $VPN_INTERFACE not found!"
        return 1
    fi

    # Make sure VPN_INTERFACE is up
    if ! ip link show "$VPN_INTERFACE" | grep -q "UP"; then
        echo "Bringing up $VPN_INTERFACE..."
        ip link set "$VPN_INTERFACE" up
        sleep 1
    fi

    # Add/update routes for table VPN
    ip route del default table $TABLE_VPN 2>/dev/null || true
    ip route add default via "$VPN_GATEWAY" dev "$VPN_INTERFACE" table $TABLE_VPN
    echo "Updated default route for table $TABLE_VPN"
}

# Function to add client subnet rule
add_client_rule() {
    echo "=== Adding client subnet rule ==="
    
    # Remove old rule if exists
    ip rule del from "$SUBNET" iif "$LAN_INTERFACE" lookup 250 2>/dev/null || true
    
    # Add new rule with high priority
    ip rule add from "$SUBNET" iif "$LAN_INTERFACE" lookup 250 priority 50
    
    # Make sure table 250 is empty
    ip route flush table 250
    
    echo "Added rule: from $SUBNET iif $LAN_INTERFACE lookup 250 priority 50"
}

case "$ACTION" in
    check)
        check_rules
        ;;
    clean)
        clean_rules
        ;;
    setup)
        setup_rules
        ;;
    setup-vpn)
        setup_vpn_routes
        ;;
    add-client-rule)
        add_client_rule
        ;;
    reset)
        clean_rules
        setup_rules
        add_client_rule
        ;;
    *)
        echo "Usage: $0 {check|clean|setup|setup-vpn|add-client-rule|reset}"
        exit 1
        ;;
esac