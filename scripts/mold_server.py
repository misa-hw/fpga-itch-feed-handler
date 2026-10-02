#!/usr/bin/env python3
"""MoldUDP64 retransmission server for the board's gap recovery (needs root:
raw sockets).

  mold_server.py serve IFACE PCAP
      Answer the board's re-requests with the messages of PCAP (the full
      session as the exchange sent it). A request is a MoldUDP64 header
      (session, first sequence number, count) from the board
      (02:00:00:00:00:10, 192.168.10.2:26401) to 192.168.10.1:26402; the
      answer is MoldUDP64 packets back to the board's address.

  mold_server.py heartbeat IFACE PCAP [N]
      Send N (default 3) heartbeats on line A announcing the sequence number
      after the session's last message, as an exchange does when the feed is
      idle, so the board sees losses at the very end of the feed. Only once
      the replay has finished: an earlier heartbeat would make every message
      still to come look missing.

Addresses are those of src/net/packet.ml (order_endpoints, request_endpoints,
retransmission_endpoints, default_endpoints).
"""
import socket
import struct
import sys
import time

BOARD_MAC = bytes.fromhex("020000000010")
HOST_MAC = bytes.fromhex("020000000002")
HOST_IP = bytes([192, 168, 10, 1])
BOARD_IP = bytes([192, 168, 10, 2])
REQUEST_PORT = 26402  # the server's
BOARD_PORT = 26401  # where answers go
FEED_SRC_MAC = bytes.fromhex("020000000001")
FEED_IP = bytes([233, 54, 12, 111])
FEED_MAC = bytes.fromhex("01005e360c6f")
FEED_PORT = 26477
MAX_PAYLOAD = 1400


def read_pcap(path):
    """The session name and {sequence number: message} of a pcap of
    MoldUDP64 frames."""
    session = None
    messages = {}
    with open(path, "rb") as f:
        header = f.read(24)
        endian = "<" if header[:4] in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
        while len(rec := f.read(16)) == 16:
            caplen = struct.unpack_from(endian + "I", rec, 8)[0]
            frame = f.read(caplen)
            if len(frame) < 42 + 20 or frame[12:14] != b"\x08\x00" or frame[23] != 17:
                continue
            ihl = (frame[14] & 0x0F) * 4
            payload = frame[14 + ihl + 8 :]
            session = payload[:10]
            seq, count = struct.unpack_from(">QH", payload, 10)
            if count in (0, 0xFFFF):
                continue
            pos = 20
            for k in range(count):
                (n,) = struct.unpack_from(">H", payload, pos)
                messages.setdefault(seq + k, payload[pos + 2 : pos + 2 + n])
                pos += 2 + n
    return session, messages


def ip_checksum(header):
    total = sum(struct.unpack(">10H", header))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def udp_frame(dst_mac, src_mac, src_ip, dst_ip, src_port, dst_port, payload):
    udp = struct.pack(">HHHH", src_port, dst_port, 8 + len(payload), 0) + payload
    ip = bytearray(struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0x4000, 64, 17, 0, src_ip, dst_ip))
    struct.pack_into(">H", ip, 10, ip_checksum(bytes(ip)))
    frame = dst_mac + src_mac + b"\x08\x00" + bytes(ip) + udp
    return frame + bytes(max(0, 60 - len(frame)))


def mold_packet(session, seq, messages):
    return session + struct.pack(">QH", seq, len(messages)) + b"".join(
        struct.pack(">H", len(m)) + m for m in messages
    )


def raw_socket(iface):
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800))
    s.bind((iface, 0))
    return s


def serve(iface, pcap):
    session, messages = read_pcap(pcap)
    print(f"serving {len(messages)} messages of session {session!r} on {iface}", flush=True)
    s = raw_socket(iface)
    # promiscuous: requests go to 02:00:00:00:00:02, not this NIC's address
    ifindex = socket.if_nametoindex(iface)
    s.setsockopt(263, 1, struct.pack("IHH8s", ifindex, 1, 0, b""))  # SOL_PACKET, PACKET_ADD_MEMBERSHIP, PROMISC
    requests = served = unknown = 0
    while True:
        frame = s.recv(2048)
        if frame[6:12] != BOARD_MAC or frame[23] != 17:
            continue
        ihl = (frame[14] & 0x0F) * 4
        (dst_port,) = struct.unpack_from(">H", frame, 14 + ihl + 2)
        if dst_port != REQUEST_PORT:
            continue
        payload = frame[14 + ihl + 8 :]
        seq, count = struct.unpack_from(">QH", payload, 10)
        requests += 1
        batch, first, size = [], seq, 20
        for k in range(seq, seq + count):
            m = messages.get(k)
            if m is None:
                unknown += 1
                break
            if batch and size + 2 + len(m) > MAX_PAYLOAD:
                s.send(udp_frame(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, REQUEST_PORT, BOARD_PORT,
                                 mold_packet(session, first, batch)))
                batch, first, size = [], k, 20
            batch.append(m)
            size += 2 + len(m)
            served += 1
        if batch:
            s.send(udp_frame(BOARD_MAC, HOST_MAC, HOST_IP, BOARD_IP, REQUEST_PORT, BOARD_PORT,
                             mold_packet(session, first, batch)))
        print(f"request {requests}: {count} from {seq}; served {served} messages so far"
              + (f", {unknown} past the end" if unknown else ""), flush=True)


def heartbeat(iface, pcap, n):
    session, messages = read_pcap(pcap)
    following = max(messages) + 1
    s = raw_socket(iface)
    for _ in range(n):
        s.send(udp_frame(FEED_MAC, FEED_SRC_MAC, HOST_IP, FEED_IP, FEED_PORT, FEED_PORT,
                         mold_packet(session, following, [])))
        time.sleep(0.2)
    print(f"sent {n} heartbeats: next sequence number {following}")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "serve":
        serve(sys.argv[2], sys.argv[3])
    elif len(sys.argv) >= 4 and sys.argv[1] == "heartbeat":
        heartbeat(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 3)
    else:
        sys.exit(__doc__)
