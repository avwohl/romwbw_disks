#!/bin/sh
#
# common.sh - shared settings for the romwbw_disks build scripts.
# Sourced, never run.  POSIX sh: these run on macOS's /bin/sh and on CI.

# The interface version this tree publishes.  It names the contract between
# this repo and the emulator clients (catalog shape, asset naming, and the
# HBIOS host-extension ABI that the w8/r8 on the disks call).  See
# docs/INTERFACE_V0.md.  Bump it only for a BREAKING change to that contract.
IFACE="v0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"

# Where unpacked upstream RomWBW releases live.  Big (a 199MB zip unpacks to
# ~1GB), so it is deliberately outside the repo and shared between versions.
ROMWBW_CACHE="${ROMWBW_CACHE:-$HOME/esrc}"
DLDIR="$ROMWBW_CACHE/.romwbw-dl"

UM80="${UM80:-um80}"
UL80="${UL80:-ul80}"

die() { echo "FATAL: $*" >&2; exit 1; }
note() { echo "  $*"; }

filesize() { wc -c < "$1" | tr -d ' '; }

sha256of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Read one dotted key out of a version manifest without needing jq.
# vjson 3.5.1 hbios.ver_byte -> 0x35
vjson() {
    python3 - "$ROOT/versions/$1/version.json" "$2" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    d=d[k]
print(d)
PY
}

need_tools() {
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || die "$t is not on PATH
       um80/ul80: pip install um80
       cpmcp/cpmrm/cpmls: cpmtools (brew install cpmtools / apt install cpmtools)"
    done
}

# Every published asset carries the interface version and the RomWBW version.
# One function, so the catalog generator and the builders cannot disagree.
# asset_name hd1k_combo .img 3.5.1 -> hd1k_combo-v0-3.5.1.img
asset_name() { printf '%s-%s-%s%s\n' "$1" "$IFACE" "$3" "$2"; }

# The immutable per-version release tag.  Assets never move between tags.
release_tag() { printf '%s-romwbw-%s\n' "$IFACE" "$1"; }
