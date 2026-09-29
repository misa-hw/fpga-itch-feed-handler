#!/usr/bin/env bash
# Download a prefix of a Nasdaq TotalView-ITCH 5.0 sample day.
#
# Nasdaq publishes full sample days at https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/
# (3.5-5.5 GB gzipped each). We stream only the first 400 MB of the gzip,
# which decompresses to ~1 GB: 32.6M messages, 04:00 -> 09:47 ET on
# 2019-07-30, including the 09:30 open. The file ends mid-message; the parser
# stops cleanly at the last complete one.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
DAY=${DAY:-07302019}
BYTES=${BYTES:-419430400}
OUT="data/$DAY.prefix.raw"
mkdir -p data
if [ -s "$OUT" ]; then echo "$OUT already present"; exit 0; fi
URL="https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/$DAY.NASDAQ_ITCH50.gz"
echo "streaming the first $BYTES bytes of $URL"
# gunzip complains about the truncated stream: expected, hence '|| true'
curl -sf -r "0-$((BYTES - 1))" "$URL" | (gunzip -c 2>/dev/null || true) > "$OUT"
ls -l "$OUT"
