# Top-level entry points. Every target works from a fresh clone
# (after `make data`, which downloads the ITCH sample).
SHELL := /bin/bash
DUNE := eval "$$(opam env --switch=oxcaml 2>/dev/null)"; dune
TEST_SUITES := tests/model tests/net

.PHONY: all build test promote data pcaps clean

all: build

build:
	$(DUNE) build

data:
	./scripts/fetch_itch.sh

# ppx_expect in this Hardcaml preview crashes when promoting output for tests
# nested in a bigger dune project, so each suite is its own dune project
# (with a symlink to ../../src) and is run with --root.
test: build
	@set -e; for t in $(TEST_SUITES); do echo "== $$t"; $(DUNE) test --root $$t; done; echo "all tests passed"

promote:
	@for t in $(TEST_SUITES); do $(DUNE) test --root $$t --auto-promote || true; done

clean:
	$(DUNE) clean
	@for t in $(TEST_SUITES); do rm -rf $$t/_build; done

# Stage 2: pcaps from the ITCH sample (build/, not committed)
SYMBOLS ?= QQQ,SPY,IWM,DIA,TQQQ,SQQQ,AMD,UVXY
ITCH ?= data/07302019.prefix.raw
PCAPGEN := ./_build/default/bin/pcapgen.exe

pcaps: build
	mkdir -p build
	$(PCAPGEN) gen $(ITCH) -o build/tracked.pcap -only $(SYMBOLS)
	$(PCAPGEN) check build/tracked.pcap -itch $(ITCH) -only $(SYMBOLS)
	$(PCAPGEN) gen $(ITCH) -o build/full.pcap
	$(PCAPGEN) check build/full.pcap -itch $(ITCH)
