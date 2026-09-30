#!/usr/bin/env python3
"""MII receive stimulus for the gate-level board test bench.

One hex line per 25 MHz RX_CLK cycle: bit 4 = RX_DV, bits 3:0 = RXD[3:0].
Each pcap frame is sent as it would come from the PHY at 100 Mb/s:
preamble, SFD, frame, FCS, low nibble of each byte first, then idle cycles.
"""
import sys
import zlib


def main():
    pcap, n, gap, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    lines = ["00"] * 2000  # PHY idle while the order book clears its tables
    count = 0
    with open(pcap, "rb") as f:
        f.read(24)
        while count < n:
            rec = f.read(16)
            if len(rec) < 16:
                break
            caplen = int.from_bytes(rec[8:12], "little")
            frame = f.read(caplen)
            fcs = zlib.crc32(frame).to_bytes(4, "little")
            wire = b"\x55" * 7 + b"\xd5" + frame + fcs
            for b in wire:
                lines.append("%02x" % (0x10 | (b & 0xF)))
                lines.append("%02x" % (0x10 | (b >> 4)))
            lines.extend(["00"] * gap)
            count += 1
    with open(out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{count} frames, {len(lines)} RX_CLK cycles -> {out}")


if __name__ == "__main__":
    main()
