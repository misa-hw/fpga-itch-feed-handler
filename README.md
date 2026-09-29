# fpga-itch-feed-handler

A hardware market-data feed handler in Hardcaml: Nasdaq TotalView-ITCH 5.0
over MoldUDP64/UDP/IPv4/Ethernet, parsed at one byte per clock, feeding an
order book in FPGA block RAM that reports top-of-book changes.

Work in progress, built in stages:

1. [x] OCaml reference model: ITCH 5.0 codec and reference order book (`src/model`)
2. [ ] Packet generator (MoldUDP64 → pcap)
3. [ ] Hardcaml Ethernet/IPv4/UDP/MoldUDP64 parser
4. [ ] Hardcaml ITCH decoder
5. [ ] Hardware order book
6. [ ] Full-pipeline verification against the model
7. [ ] Board bring-up (QMTech Wukong, XC7A100T)

```
make data   # download a 1 GB prefix of a Nasdaq sample day
make test
```
