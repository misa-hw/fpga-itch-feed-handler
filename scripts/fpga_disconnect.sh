#!/usr/bin/env bash
# Run after unplugging the Wukong: gives eno1 back to NetworkManager with
# every link speed advertised and the default qdisc.
set -euo pipefail
iface="${IFACE:-eno1}"
sudo ethtool -s "$iface" advertise 0x02f autoneg on || true
sudo tc qdisc del dev "$iface" root 2>/dev/null || true  # back to the default qdisc
sudo nmcli device set "$iface" managed yes
echo "$iface is managed by NetworkManager again"
