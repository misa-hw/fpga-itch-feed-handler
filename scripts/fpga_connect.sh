#!/usr/bin/env bash
# Run after plugging the Ethernet cable from eno1 into the Wukong: takes eno1
# away from NetworkManager, brings it up with a FIFO qdisc, and runs a 1 Gb/s
# board test: scripts/board_recovery.sh (A/B lines with losses and a
# retransmission server, for the image with gap recovery), or with
# TEST=linerate scripts/board_linerate.sh (images without it). Their
# variables, e.g. PROGRAM=0 or BITSTREAM=..., pass through.
# Undo with scripts/fpga_disconnect.sh after unplugging.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
iface="${IFACE:-eno1}"
sudo -v
sudo nmcli device set "$iface" managed no
sudo ip link set "$iface" up
# the default fq_codel qdisc reorders and drops a fast single-flow burst
# (measured: frames ~1,900 apart interleaved, the tail dropped); use a FIFO
sudo tc qdisc replace dev "$iface" root pfifo limit 1000000
exec "./scripts/board_${TEST:-recovery}.sh" "$@"
