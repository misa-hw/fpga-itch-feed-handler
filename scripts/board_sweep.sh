#!/usr/bin/env bash
# The 1 Gb/s board test (scripts/board_linerate.sh) on the first LIMIT
# packets at several rates (RATES, packets/s, "top" = as fast as tcpreplay
# goes), each on a freshly programmed board; results in
# results/board_sweep_RATE.*. Run with the Wukong cabled to eno1; undo with
# scripts/fpga_disconnect.sh.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
iface="${IFACE:-eno1}"
limit="${LIMIT:-100000}"
rates="${RATES:-20000 60000 top}"
sudo -v || exit 1
sudo nmcli device set "$iface" managed no
sudo ip link set "$iface" up
sudo tc qdisc replace dev "$iface" root pfifo limit 1000000
for r in $rates; do
  echo "=================== $r packets/s, first $limit packets"
  if [[ $r == top ]]; then
    LIMIT="$limit" OUT="results/board_sweep_$r" ./scripts/board_linerate.sh
  else
    LIMIT="$limit" PPS="$r" OUT="results/board_sweep_$r" ./scripts/board_linerate.sh
  fi
done
