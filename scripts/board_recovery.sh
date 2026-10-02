#!/usr/bin/env bash
# Gap recovery on the board (1 Gb/s image with recovery): send the feed on
# two lines, A and B (B a few packets behind), each losing packets at random
# and a few lost on both (bin/pcapgen.exe ab), with the host running a
# MoldUDP64 retransmission server (scripts/mold_server.py) that answers the
# board's re-requests. Whatever the lines, the host's sender (which drops
# and reorders at top speed) and the retransmissions do, the board must end
# with exactly the reference book's top-of-book changes over the whole
# session, and send exactly the model's orders: nothing lost, nothing stale.
#
# DROP_A, DROP_B: loss on each line (default 0.02); AB=0 sends the recorded
# feed as it is (one line, only the host's own losses); LIMIT=N uses the
# first N packets; PPS=R paces the replay (default 60000; PPS=top for top
# speed, where the host's own drops and reorders add to the losses); PROGRAM=0
# uses the board as it is (it must not have received anything since it was
# programmed: a session starts at message 1).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
reference="${PCAP:-build/tracked.pcap}"
iface="${IFACE:-eno1}"
uart="${UART:-/dev/ttyUSB0}"
bit="${BITSTREAM:-fpga/build/board_top_gmii.bit}"
out="${OUT:-results/board_recovery}"
limit="${LIMIT:-}"
mkdir -p "$(dirname "$out")" build
test -s "$bit"
command -v tcpreplay > /dev/null || { echo "tcpreplay is not installed" >&2; exit 1; }
dune build ./bin/pcapgen.exe
pcapgen=./_build/default/bin/pcapgen.exe
max=(${limit:+-max-packets "$limit"})
if [[ ${AB:-1} != 0 ]]; then
  feed=build/recovery_ab.pcap
  "$pcapgen" ab "$reference" "$feed" -drop-a "${DROP_A:-0.02}" -drop-b "${DROP_B:-0.02}" "${max[@]}" | tee "$out.ab.txt"
else
  feed=$reference
  echo "packets=${limit:-all} (one line, as recorded)" | tee "$out.ab.txt"
fi
sudo -v
sudo systemctl stop itch-orders itch-mold 2> /dev/null || true
if [[ ${PROGRAM:-1} != 0 ]]; then
  openFPGALoader-xpcu -c xilinxPlatformCableUsb "$bit"
  # programming resets the board's PHY; renegotiate once it is out of reset
  sleep 2
  sudo ethtool -r "$iface" || true
fi
# a gigabit link can take a while, and bounce, after a PHY reset
speed='' last=''
for _ in $(seq 1 120); do
  speed="$(cat "/sys/class/net/$iface/speed" 2> /dev/null || true)"
  [[ $speed != "$last" ]] && echo "$iface link: ${speed} Mb/s"
  last=$speed
  [[ $speed == 1000 ]] && break
  sleep 1
done
if [[ $speed != 1000 ]]; then
  echo "$iface negotiated ${speed:-no} Mb/s; this test needs a 1000 Mb/s link" >&2
  exit 1
fi
stty -F "$uart" 115200 raw -echo cs8 -cstopb -parenb
timeout 1 cat "$uart" > /dev/null || test "$?" -eq 124
cat "$uart" > "$out.uart.txt" &
reader=$!
trap 'kill $reader 2> /dev/null || true; sudo systemctl stop itch-orders itch-mold 2> /dev/null || true' EXIT
for _ in $(seq 1 20); do
  grep -q '^S1 ' "$out.uart.txt" && break
  sleep 0.5
done
grep -q '^S1 ' "$out.uart.txt" || { echo "no S1 status line: the board's receive clock is not running" >&2; exit 1; }
grep '^S1 ' "$out.uart.txt" | tail -1 | grep -q ' rqs=' \
  || { echo "this bitstream has no gap recovery (no rqs= field); use scripts/board_linerate.sh" >&2; exit 1; }
since=$(date '+%Y-%m-%d %H:%M:%S')
# the retransmission server, and a capture of the board's frames (orders and
# re-requests), as transient units: AppArmor blocks signals to them from
# some terminals (e.g. VS Code's)
sudo systemd-run --quiet --collect --unit=itch-mold \
  python3 "$PWD/scripts/mold_server.py" serve "$iface" "$PWD/$reference"
rm -f "$out.orders.pcap"
sudo systemd-run --quiet --collect --unit=itch-orders \
  tcpdump -i "$iface" -B 65536 -Z "$USER" -w "$PWD/$out.orders.pcap" 'ether src 02:00:00:00:00:10 and udp dst port 26400'
# the server reads the whole session first
for _ in $(seq 1 120); do
  sudo journalctl --since "$since" -u itch-mold -o cat 2> /dev/null | grep -q '^serving' && break
  sleep 1
done
sudo journalctl --since "$since" -u itch-mold -o cat | grep '^serving' || { echo "the retransmission server did not start" >&2; exit 1; }
# 60,000 frames/s by default (both lines: about 2 minutes for the whole
# session); PPS=top for as fast as the host sends
pps="${PPS:-60000}"
rate=(--pps="$pps")
[[ $pps == top ]] && rate=(--topspeed)
sudo tcpreplay --intf1="$iface" "${rate[@]}" --preload-pcap "$feed" 2>&1 | tee "$out.tcpreplay.txt"
# an exchange's heartbeats: losses at the very end show up too
sleep 0.5
sudo python3 scripts/mold_server.py heartbeat "$iface" "$reference" 3
# time for the last requests, and two more status lines
sleep 3
kill $reader
sudo systemctl stop itch-orders itch-mold
sleep 1
sudo journalctl --since "$since" -u itch-mold -o cat > "$out.server.txt" 2> /dev/null || true
tail -1 "$out.server.txt"
"$pcapgen" expect "$reference" -summary "${max[@]}" > "$out.expected.txt"
"$pcapgen" orders "$reference" "${max[@]}" > "$out.orders_expected.txt"
python3 - "$out.uart.txt" "$out.expected.txt" "$out.orders.pcap" "$out.orders_expected.txt" "$reference" "$limit" "$out.ab.txt" <<'PY'
import os
import re
import struct
import sys
sys.path.insert(0, "scripts")
from mold_server import read_pcap

board = open(sys.argv[1], encoding="ascii", errors="replace").read().splitlines()
want = {k: int(v, 16) for k, v in re.findall(r"\b(chg|hash)=([0-9a-fA-F]+)", open(sys.argv[2]).read())}
limit = int(sys.argv[6]) if sys.argv[6] else None
if limit is None:
    _, messages = read_pcap(sys.argv[5])
    n_messages = len(messages)
else:
    # the first LIMIT packets' messages
    n_messages = 0
    with open(sys.argv[5], "rb") as f:
        f.read(24)
        for _ in range(limit):
            rec = f.read(16)
            if len(rec) < 16:
                break
            frame = f.read(struct.unpack_from("<I", rec, 8)[0])
            count = struct.unpack_from(">H", frame, 42 + 18)[0]
            n_messages += 0 if count == 0xFFFF else count
status = [line for line in board if line.startswith("S") and " hash=" in line and " tmax=" in line]
if not status:
    sys.exit("no board status line captured")
line = status[-1]
b = {k: int(v, 16) for k, v in re.findall(r"\b([a-z][a-z0-9]*)=([0-9a-fA-F]+)", line)}
print("last board status:", line)
print("feed:", open(sys.argv[7]).read().strip())
print(f"board: {b['acc']} frames accepted, {b['msg']} messages passed on of {n_messages}; "
      f"{b['dup']} duplicates dropped, {b['gap']} gaps seen, {b['rqs']} re-requests, {b['rpl']} messages "
      f"replayed from the buffer (peak {b['bpk']} parked), {b['bovf']} dropped by a full buffer, "
      f"{b['mlost']} given up, stale {b['stl']}")
print(f"board: {b['chg']} changes (hash {b['hash']:08x}); model over the whole session: "
      f"{want['chg']} changes (hash {want['hash']:08x})")
bad = []
if (b["chg"], b["hash"]) != (want["chg"], want["hash"]):
    bad.append("change count or hash differs from the model over the whole session")
if b["msg"] != n_messages:
    bad.append(f"{b['msg']} messages passed on, the session has {n_messages}")
if b["mlost"] or b["stl"]:
    bad.append(f"messages given up: {b['mlost']}")
if not line.startswith("S1"):
    bad.append("receive clock not running at the final status")
for key in ("fcs", "err", "ovf"):
    if b.get(key, -1):
        bad.append(f"{key}={b.get(key)}")
got = []
if os.path.exists(sys.argv[3]):
    with open(sys.argv[3], "rb") as f:
        f.read(24)
        while len(rec := f.read(16)) == 16:
            got.append(f.read(struct.unpack_from("<I", rec, 8)[0]).hex())
want_orders = [l for l in open(sys.argv[4]).read().split() if not l.startswith("orders=")]
print(f"orders: board sent {b['osent']} (dropped {b['odrop']}), host captured {len(got)}, model {len(want_orders)}; "
      f"tick-to-trade p50 {b['t50']}, max {b['tmax']} cycles")
if got != want_orders:
    bad.append(f"orders differ from the model's ({len(got)} captured, {len(want_orders)} expected)")
if bad:
    sys.exit("FAIL: " + "; ".join(bad))
print("PASS: every message of the session reached the book, in order, and every top-of-book change "
      "and every order matches the reference model")
PY
