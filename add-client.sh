#!/bin/sh
set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <client-name>"
    exit 1
fi

CLIENT_NAME="$1"
TINC_NAME="${TINC_NAME:-gnet}"

echo "Adding client: $CLIENT_NAME to VPN network: $TINC_NAME"

docker exec tinc-master-node tinc -n "$TINC_NAME" invite "$CLIENT_NAME"