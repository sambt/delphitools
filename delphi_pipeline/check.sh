#!/bin/bash
# Check completeness of a conversion campaign: for each dataset, report which
# expected .root files are present under <DEST> and list any that are missing
# (or, with --check-events, present but empty/unreadable).
#
# It wraps `batch.sh --check`, so it uses the SAME nickname/recid resolution,
# file selection, and --by-type path logic as the conversion itself -- it just
# checks for outputs instead of producing them. Nothing is downloaded or built
# (unless you pass --check-events, which needs the image to open the files).
#
# Usage:
#   ./check.sh --dest DIR [--no-by-type] [--check-events] [--range I-J|--filter RE] \
#              <dataset|nickname|recid> [<dataset2> ...]
#
# The submit_lep1_*.sh scripts write with --by-type (data/ vs mc/ prefixes), so
# --by-type is ON here by default; pass --no-by-type if you converted with pure
# EOS mirroring.
#
# Examples:
#   # did all four LEP1 data years finish?
#   ./check.sh --dest $SCRATCH/delphi_root short92_e2 short93_d2 short94_c2 short95_d2
#
#   # check the Z->qqbar MC, and actually open each file to confirm it has events
#   ./check.sh --dest $SCRATCH/delphi_root --check-events \
#       sh_qqps_k92_2l_e2 sh_qqps_k93_2l_d2 sh_qqps_b94_2l_c2 sh_qqps_b95_1l_d2
#
# Exit status: 0 only if every selected file is present (and valid, with
# --check-events) for ALL datasets; 1 otherwise -- so it is usable in scripts.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

DEST=""; BYTYPE=1; CHECKEV=0; PASS=(); DATASETS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST="${2:?--dest needs a dir}"; shift 2 ;;
        --no-by-type) BYTYPE=0; shift ;;
        --check-events) CHECKEV=1; shift ;;
        --range)  PASS+=(--range "${2:?}"); shift 2 ;;
        --filter) PASS+=(--filter "${2:?}"); shift 2 ;;
        --*) echo "[check] unknown option: $1" >&2; exit 2 ;;
        *) DATASETS+=("$1"); shift ;;
    esac
done
[ -n "$DEST" ] || { echo "[check] --dest DIR is required" >&2; exit 2; }
[ ${#DATASETS[@]} -gt 0 ] || { echo "[check] give at least one dataset/nickname/recid" >&2; exit 2; }

echo "[check] dest=$DEST  datasets=${#DATASETS[@]}  by-type=$BYTYPE  check-events=$CHECKEV"
echo
rc=0
for d in "${DATASETS[@]}"; do
    args=("$d" --dest "$DEST" --check)
    [ "$BYTYPE" -eq 1 ] && args+=(--by-type)
    [ "$CHECKEV" -eq 1 ] && args+=(--check-events)
    [ ${#PASS[@]} -gt 0 ] && args+=("${PASS[@]}")
    "$HERE/batch.sh" "${args[@]}" || rc=1
done

echo
if [ "$rc" -eq 0 ]; then
    echo "[check] ALL COMPLETE."
else
    echo "[check] INCOMPLETE -- re-run the matching submit script(s) to fill the gaps" >&2
    echo "[check] (conversion is resumable: present files are skipped)." >&2
fi
exit "$rc"
