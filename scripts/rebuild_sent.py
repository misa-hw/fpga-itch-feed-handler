#!/usr/bin/env python3
"""Rebuild the frames the host really sent, in the order it sent them.

tcpdump on the sending interface keeps only the first 64 bytes of each
frame. MoldUDP64 sequence numbers identify frames uniquely, so the full
frames are taken from the original pcap:

    rebuild_sent.py ORIGINAL.pcap HOST_CAPTURE.pcap OUT.pcap [LIMIT]

It prints what the sender did to the first LIMIT (default all) packets of
ORIGINAL, and the counters the board's MoldUDP64 receiver must show for
the sent stream (a message whose sequence number is below the next
expected one is dropped as a duplicate; one above it counts a gap).
`pcapgen expect -mold-receiver OUT.pcap` gives the matching book output.
"""
import struct
import sys


def records(path):
    with open(path, "rb") as f:
        header = f.read(24)
        endian = "<" if header[:4] in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
        while len(rec := f.read(16)) == 16:
            caplen = struct.unpack_from(endian + "I", rec, 8)[0]
            frame = f.read(caplen)
            if len(frame) < caplen:
                return
            yield header, rec, frame


def seq(frame):
    return struct.unpack_from("!Q", frame, 42 + 10)[0]


def count(frame):
    return struct.unpack_from("!H", frame, 42 + 18)[0]


def main():
    original, capture, out = sys.argv[1:4]
    limit = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else None
    sent = [seq(frame) for _, _, frame in records(capture)]
    full = {}
    header = None
    for k, (header, rec, frame) in enumerate(records(original)):
        if limit is not None and k >= limit:
            break
        full[seq(frame)] = (rec, frame)
    unknown = [s for s in sent if s not in full]
    if unknown:
        sys.exit(f"{len(unknown)} captured frames are not in the original pcap")
    with open(out, "wb") as f:
        f.write(header)
        for s in sent:
            rec, frame = full[s]
            f.write(rec + frame)
    backward = sum(1 for a, b in zip(sent, sent[1:]) if b < a)
    repeated = len(sent) - len(set(sent))
    synced, expected, msgs, dups, gaps = False, 0, 0, 0, 0
    for s in sent:
        for k in range(count(full[s][1])):
            q = s + k
            if not synced or q >= expected:
                gaps += synced and q > expected
                synced, expected = True, q + 1
                msgs += 1
            else:
                dups += 1
    print(f"original={len(full)} sent={len(sent)} missing={len(set(full) - set(sent))} "
          f"reordered={backward} repeated={repeated} msg={msgs} dup={dups} gap={gaps}")


main()
