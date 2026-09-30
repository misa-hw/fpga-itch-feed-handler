#!/usr/bin/env bash
# 1 Gb/s board test: program the gigabit image, replay a pcap's raw frames
# as fast as the host sends them (tcpreplay, needs sudo), and compare the
# board's top-of-book change count and CRC-32 hash with the OCaml reference
# book. The hash covers every change, so it decides the test even though
# the UART drops most event lines at speed (counted as "lost").
#
# The host does not always send what tcpreplay is given: at top speed it
# drops and reorders frames before they reach the NIC (seen at the kernel's
# transmit tap, also with a FIFO qdisc). So tcpdump records what really
# left the host, the full frames are rebuilt in that order
# (scripts/rebuild_sent.py), and the board must match the model run on that
# stream with the hardware's MoldUDP64 rule (late messages are duplicates).
# Sender drops and reorders are reported separately.
#
# LIMIT=N sends only the first N packets; PPS=R paces them at R packets/s
# (at ~200/s the UART prints every event, which are then compared line by
# line too). PROGRAM=0 uses the board as it is (already programmed and
# nothing received since).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
pcap="${PCAP:-build/tracked.pcap}"
iface="${IFACE:-eno1}"
uart="${UART:-/dev/ttyUSB0}"
bit="${BITSTREAM:-fpga/build/board_top_gmii.bit}"
out="${OUT:-results/board_linerate}"
limit="${LIMIT:-}"
mkdir -p "$(dirname "$out")" build
test -s "$bit"
command -v tcpreplay > /dev/null || { echo "tcpreplay is not installed" >&2; exit 1; }
dune build ./bin/pcapgen.exe
sudo -v
sudo systemctl stop itch-capture 2> /dev/null || true
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
trap 'kill $reader 2> /dev/null || true; sudo systemctl stop itch-capture 2> /dev/null || true' EXIT
# wait for a status line proving the board's receive clock runs
for _ in $(seq 1 20); do
  grep -q '^S1 ' "$out.uart.txt" && break
  sleep 0.5
done
grep -q '^S1 ' "$out.uart.txt" || { echo "no S1 status line: the board's receive clock is not running" >&2; exit 1; }
# record what leaves the host. tcpdump runs as a transient systemd unit:
# AppArmor blocks signals to it from some terminals (e.g. VS Code's).
rm -f "$out.host.pcap"
since=$(date '+%Y-%m-%d %H:%M:%S')
sudo systemd-run --quiet --collect --unit=itch-capture \
  tcpdump -i "$iface" -B 524288 -s 64 -Z "$USER" -w "$PWD/$out.host.pcap" 'ether dst 01:00:5e:36:0c:6f'
sleep 2
rate=(--topspeed)
[[ -n ${PPS:-} ]] && rate=(--pps="$PPS")
sudo tcpreplay --intf1="$iface" "${rate[@]}" ${limit:+--limit="$limit"} --preload-pcap "$pcap" 2>&1 | tee "$out.tcpreplay.txt"
# two more status lines after the last frame
sleep 3
kill $reader
sudo systemctl stop itch-capture
sleep 1
sudo journalctl --since "$since" -u itch-capture -o cat 2> /dev/null | grep -E 'captured|dropped' | tee "$out.capture.txt" || true
python3 scripts/rebuild_sent.py "$pcap" "$out.host.pcap" build/sent.pcap "$limit" | tee "$out.sent.txt"
./_build/default/bin/pcapgen.exe expect build/sent.pcap -mold-receiver > "$out.expected.txt"
python3 - "$out.uart.txt" "$out.expected.txt" "$out.sent.txt" "$out.capture.txt" <<'PY'
import re
import sys
board = open(sys.argv[1], encoding="ascii", errors="replace").read().splitlines()
model = open(sys.argv[2]).read().splitlines()
sent = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", open(sys.argv[3]).read())}
capture = open(sys.argv[4]).read()
want = {k: int(v, 16) for k, v in re.findall(r"\b(chg|hash)=([0-9a-fA-F]+)", model[-1])}
status = [line for line in board if line.startswith("S") and " hash=" in line]
if not status:
    sys.exit("no board status line captured")
line = status[-1]
b = {k: int(v, 16) for k, v in re.findall(r"\b([a-z]+)=([0-9a-fA-F]+)", line)}
print("last board status:", line)
print(f"sender: {sent['sent']} of {sent['original']} frames left the host, "
      f"{sent['missing']} dropped, {sent['reordered']} out of order")
print(f"board:  {b.get('acc')} frames accepted, {b.get('msg')} messages, {b.get('dup')} duplicates, "
      f"{b.get('gap')} gaps, {b.get('chg')} changes (hash {b.get('hash', 0):08x}), "
      f"{b.get('lost')} UART lines dropped, book FIFO peak {b.get('fmax')}")
print(f"model on the sent stream: {sent['msg']} messages, {sent['dup']} duplicates, {sent['gap']} gaps, "
      f"{want['chg']} changes (hash {want['hash']:08x})")
bad = []
m = re.search(r"(\d+) packets? dropped by kernel", capture)
if m is None or int(m.group(1)):
    bad.append("the host capture is incomplete (tcpdump drops), so the sent stream is unknown")
if (b.get("chg"), b.get("hash")) != (want["chg"], want["hash"]):
    bad.append("change count or hash differs from the model")
if not line.startswith("S1"):
    bad.append("receive clock not running at the final status")
if b.get("acc") != sent["sent"]:
    bad.append(f"accepted {b.get('acc')} frames, the host sent {sent['sent']}")
if (b.get("msg"), b.get("dup"), b.get("gap")) != (sent["msg"], sent["dup"], sent["gap"]):
    bad.append("MoldUDP64 counters differ from the sent stream's")
for key in ("fcs", "err", "ovf"):
    if b.get(key, -1):
        bad.append(f"{key}={b.get(key)}")
if b.get("lost") == 0:
    # every event was printed: compare them one by one
    board_events = [l.strip() for l in board if l.startswith("E ")]
    model_events = [l for l in model if l.startswith("E ")]
    for k, (x, y) in enumerate(zip(board_events, model_events)):
        if x != y:
            bad.append(f"event {k} differs: board {x!r}, model {y!r}")
            break
    else:
        if len(board_events) != len(model_events):
            bad.append(f"{len(board_events)} board events, {len(model_events)} in the model")
if bad:
    sys.exit("FAIL: " + "; ".join(bad))
clean = sent["missing"] == 0 and sent["reordered"] == 0
print("PASS: every top-of-book change matches the reference book on the stream that was sent"
      + ("" if clean else " (the sender dropped or reordered frames; see above)"))
PY
