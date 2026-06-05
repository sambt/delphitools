#!/bin/bash
# One-shot sanity check for a fresh machine/cluster: download + convert one MC
# file and one real-data file, then confirm each .root has events. Run this
# once after setting up the image + cernopendata-client, before launching big
# SLURM campaigns.
#
# Usage:
#   ./cluster_smoketest.sh [--dest DIR] [--keep]
#
#   --dest DIR   where outputs go (default ./smoketest_out, EOS layout mirrored)
#   --keep       keep the downloaded inputs + .root (default: delete at the end)
#
# Exits 0 only if BOTH conversions produced a .root with >0 events.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

DEST="$HERE/smoketest_out"; KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST="${2:?}"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        *) echo "[smoketest] unknown option: $1" >&2; exit 2 ;;
    esac
done

need cernopendata-client "pip install --user cernopendata-client"
echo "[smoketest] engine=$CONTAINER  image=$IMAGE  dest=$DEST"
echo "[smoketest] ensuring converter image..."
"$HERE/get_image.sh" auto

# Count entries in the Events RNTuple of a .root, via the container.
count_events() {
    local root="$1" dir base out
    dir="$(cd "$(dirname "$root")" && pwd)"; base="$(basename "$root")"
    MOUNTS=("$(to_mount_path "$dir"):/w:ro")
    INNER="cd /w && python3 -c \"import ROOT; print(ROOT.RNTupleReader.Open('Events','$base').GetNEntries())\""
    out="$(run_in_image 2>/dev/null | tr -dc '0-9\n' | grep -E '^[0-9]+$' | tail -1 || true)"
    printf '%s' "${out:-0}"
}

run_one() {
    local label="$1" dataset="$2"   # e.g. "MC" mc   /   "DATA" data
    echo
    echo "=== [smoketest] $label: download + convert 1 file ($dataset) ==="
    # batch.sh handles image+DDB ensure, EOS-mirrored output, and resumability.
    "$HERE/batch.sh" "$dataset" --dest "$DEST" --range 1-1 ${KEEP:+--keep-inputs} \
        2>&1 | grep -viE 'VDMCBS|GETTPARA|CART_P|RESCALE|CONFPV|suppressed|MAKEMOD|Schurr|NEUTRAL|Progress:' || true
}

run_one "MC"   mc
run_one "DATA" data

echo
echo "=== [smoketest] verifying outputs ==="
PASS=1
for f in $(find "$DEST" -name '*.root' -type f | sort); do
    n="$(count_events "$f")"
    rel="${f#$DEST/}"
    if [ "${n:-0}" -gt 0 ]; then
        echo "  OK   $rel  ($n events)"
    else
        echo "  FAIL $rel  (0 events / unreadable)"; PASS=0
    fi
done
# need at least two .root (one MC, one data)
NROOT="$(find "$DEST" -name '*.root' -type f | wc -l | tr -d ' ')"
[ "$NROOT" -ge 2 ] || { echo "  FAIL only $NROOT .root produced (expected 2)"; PASS=0; }

if [ "$KEEP" -eq 0 ]; then
    echo "[smoketest] cleaning up $DEST (pass --keep to retain)"
    rm -rf "$DEST"
fi

echo
if [ "$PASS" -eq 1 ]; then
    echo "[smoketest] PASS — data + MC both convert and contain events."
    exit 0
else
    echo "[smoketest] FAIL — see messages above." >&2
    exit 1
fi
