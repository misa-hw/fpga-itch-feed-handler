#!/usr/bin/env python3
"""Send MoldUDP64 payloads from a pcap through the host UDP stack.

The FPGA filters the multicast destination MAC/IP/port, so a direct link
does not need a static ARP entry or raw-socket privilege. The host interface
must already have an IPv4 address (see README). Original source addresses
and timestamps are deliberately replaced; sequence numbers and ITCH bytes
are unchanged. Pace packets so the board's 115200-baud UART can print them.
"""

import argparse
import ipaddress
import socket
import struct
import time


def packets(path, limit):
    with open(path, "rb") as stream:
        header = stream.read(24)
        if len(header) != 24:
            raise ValueError("short pcap header")
        magic = header[:4]
        if magic in (b"\x4d\x3c\xb2\xa1", b"\xd4\xc3\xb2\xa1"):
            endian = "<"
        elif magic in (b"\xa1\xb2\x3c\x4d", b"\xa1\xb2\xc3\xd4"):
            endian = ">"
        else:
            raise ValueError("unsupported pcap magic")
        if struct.unpack_from(endian + "I", header, 20)[0] != 1:
            raise ValueError("pcap link type is not Ethernet")
        count = 0
        while count < limit:
            record = stream.read(16)
            if not record:
                return
            if len(record) != 16:
                raise ValueError("short pcap record header")
            caplen = struct.unpack_from(endian + "I", record, 8)[0]
            frame = stream.read(caplen)
            if len(frame) != caplen:
                raise ValueError("short pcap frame")
            count += 1
            if len(frame) < 42 or frame[12:14] != b"\x08\x00":
                raise ValueError(f"frame {count} is not IPv4 Ethernet")
            ihl = (frame[14] & 0x0F) * 4
            if ihl < 20 or len(frame) < 14 + ihl + 8 or frame[23] != 17:
                raise ValueError(f"frame {count} is not IPv4 UDP")
            udp = 14 + ihl
            length = struct.unpack_from("!H", frame, udp + 4)[0]
            if length < 8 or udp + length > len(frame):
                raise ValueError(f"frame {count} has an invalid UDP length")
            dst = str(ipaddress.IPv4Address(frame[30:34]))
            port = struct.unpack_from("!H", frame, udp + 2)[0]
            yield dst, port, frame[udp + 8 : udp + length]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pcap")
    parser.add_argument("--source-ip", required=True, help="IPv4 address assigned to the direct-cable NIC")
    parser.add_argument("--max-packets", type=int, default=400)
    parser.add_argument("--interval-ms", type=float, default=10.0)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.max_packets < 1 or args.interval_ms < 0:
        parser.error("packet count must be positive and interval nonnegative")
    source = socket.inet_aton(args.source_ip)
    sock = None
    if not args.dry_run:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, source)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    sent = 0
    try:
        for dst, port, payload in packets(args.pcap, args.max_packets):
            if (dst, port) != ("233.54.12.111", 26477):
                raise ValueError(f"unexpected feed destination {dst}:{port}")
            if sock is not None:
                sock.sendto(payload, (dst, port))
                time.sleep(args.interval_ms / 1000.0)
            sent += 1
    finally:
        if sock is not None:
            sock.close()
    print(f"{'checked' if args.dry_run else 'sent'} {sent} MoldUDP64 packets")


if __name__ == "__main__":
    main()
