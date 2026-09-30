#!/usr/bin/env bash
# Program the already built bitstream, replay a paced pcap over a direct
# Ethernet cable, and compare the board's UART change count/hash with OCaml.
# The NIC must first be given a static IPv4 address by the user (README).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
pcap="${PCAP:-build/board_slow.pcap}"
source_ip="${SOURCE_IP:-192.168.10.1}"
iface="${IFACE:-eno1}"
max_packets="${MAX_PACKETS:-400}"
interval_ms="${INTERVAL_MS:-10}"
uart="${UART:-/dev/ttyUSB0}"
bit="${BITSTREAM:-fpga/build/board_top_50.bit}"
capture="${CAPTURE:-results/board_uart.txt}"
expected="${EXPECTED:-results/board_expected.txt}"
mkdir -p "$(dirname "$capture")"
mkdir -p "$(dirname "$expected")"
test -s "$bit"
check_address() {
  ip -4 -o address show dev "$iface" |
    awk -v target="$source_ip" '$3 == "inet" { split($4, part, "/"); if (part[1] == target) found = 1 } END { exit !found }'
}
if ! check_address; then
  echo "$source_ip is absent from $iface; assign it after taking $iface out of NetworkManager management" >&2
  exit 1
fi
wait_100_link() {
  local speed=''
  for _ in $(seq 1 30); do
    speed="$(cat "/sys/class/net/$iface/speed" 2>/dev/null || true)"
    [[ $speed == 100 ]] && return 0
    sleep 1
  done
  echo "$iface negotiated ${speed:-no} Mb/s; this bitstream requires a 100 Mb/s link" >&2
  return 1
}
# Program first: the PHY only brings the link up once a board image drives
# its reset pin high (another bitstream, e.g. a probe, can hold it in reset).
openFPGALoader-xpcu -c xilinxPlatformCableUsb "$bit"
sleep 2
if ! check_address; then
  echo "$source_ip disappeared from $iface during board programming" >&2
  exit 1
fi
wait_100_link
stty -F "$uart" 115200 raw -echo cs8 -cstopb -parenb
# Drain data queued before programming (including lines from a previous run).
timeout 1 cat "$uart" > /dev/null || test "$?" -eq 124
duration=$(python3 -c 'import sys; print(int(float(sys.argv[1])*int(sys.argv[2])/1000)+8)' "$interval_ms" "$max_packets")
timeout "$duration" cat "$uart" > "$capture" &
reader=$!
sleep 1
python3 scripts/replay_udp.py "$pcap" --source-ip "$source_ip" \
  --max-packets "$max_packets" --interval-ms "$interval_ms"
wait "$reader" || test "$?" -eq 124
./_build/default/bin/pcapgen.exe expect "$pcap" -max-packets "$max_packets" > "$expected"
python3 - "$capture" "$expected" "$max_packets" <<'PY'
import re
import sys
board = open(sys.argv[1], encoding="ascii", errors="replace").read().splitlines()
model = open(sys.argv[2], encoding="ascii").read().splitlines()
status = [line for line in board if line.startswith("S") and " hash=" in line]
if not status:
    sys.exit("no board status line captured")
line = status[-1]
fields = dict(re.findall(r"\b([a-z][a-z0-9]*)=([0-9a-fA-F]+)", line))
actual = {key: fields[key] for key in ("chg", "hash") if key in fields}
want = dict(re.findall(r"\b(chg|hash)=([0-9a-fA-F]+)", model[-1]))
board_events = [entry for entry in board if entry.startswith("E ")]
model_events = [entry for entry in model if entry.startswith("E ")]
print("last board status:", line)
print("model:", model[-1])
if set(actual) != {"chg", "hash"} or actual != want:
    sys.exit("board/model change count or hash differs")
if not line.startswith("S1"):
    sys.exit("board receive clock was not running at the final status")
if int(fields.get("acc", "-1"), 16) != int(sys.argv[3]):
    sys.exit("board accepted frame count differs from the packet count")
for key in ("fcs", "gap", "ovf", "lost"):
    if int(fields.get(key, "-1"), 16):
        sys.exit(f"board {key} counter is nonzero or absent")
if board_events != model_events:
    for index, (a, b) in enumerate(zip(board_events, model_events)):
        if a != b:
            sys.exit(f"UART event {index} differs: board {a!r}, model {b!r}")
    sys.exit(f"UART event count differs: board {len(board_events)}, model {len(model_events)}")
print(f"{len(board_events)} UART events, count and hash match the OCaml model")
PY
