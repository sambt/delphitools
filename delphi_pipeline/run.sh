#!/bin/bash
# End-to-end: ensure image -> download N files -> convert each to .root.
#
# Usage:
#   ./run.sh <data|mc|mc-apacic> [--files N] [--filter NAME] [--max-events M]
#
# By default every event in each file is converted (the converter stops at
# end of file). Pass --max-events M only if you want to cap it.
#
# Examples:
#   ./run.sh mc   --files 2
#   ./run.sh data --filter 'Y13709.170.al'     # downloads DDB automatically
#   ./run.sh mc   --files 1 --max-events 625
#
# data       -> converts with --data (DDB recid 80509 fetched automatically)
# mc/mc-*    -> converts with --mc
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

DATASET="${1:?usage: run.sh <data|mc|mc-apacic> [--files N] [--filter NAME] [--max-events M]}"
shift || true

DL_ARGS=(); CONV_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --files)      DL_ARGS+=(--files "$2"); shift 2 ;;
        --filter)     DL_ARGS+=(--filter "$2"); shift 2 ;;
        --max-events) CONV_ARGS+=(--max-events "$2"); shift 2 ;;
        *) echo "[run] unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$DATASET" in
    data)              MODE="--data"; PATTERN='*.al' ;;
    mc)                MODE="--mc";   PATTERN='*.al' ;;
    mc-apacic)         MODE="--mc";   PATTERN='*.sdst' ;;
    *) echo "[run] dataset must be data|mc|mc-apacic" >&2; exit 2 ;;
esac

echo "=== [run] 1/4  ensure converter image ==="
"$HERE/get_image.sh" auto

if [ "$DATASET" = "data" ]; then
    echo "=== [run] 2/4  ensure DDB conditions (recid 80509) ==="
    if ! find "$HERE/ddb" -name DBcalb.dat >/dev/null 2>&1; then
        "$HERE/download.sh" ddb
    else
        echo "[run] DDB already present under ./ddb"
    fi
else
    echo "=== [run] 2/4  (no DDB needed for MC) ==="
fi

echo "=== [run] 3/4  download $DATASET ==="
"$HERE/download.sh" "$DATASET" ${DL_ARGS[@]+"${DL_ARGS[@]}"}

echo "=== [run] 4/4  convert ==="
DEST="$HERE/samples/$DATASET"
# find (not globstar) so this works on bash 3.2 (macOS) and whatever nesting
# cernopendata-client produces under $DEST.
FOUND=0
while IFS= read -r f; do
    FOUND=1
    echo "--- converting $(basename "$f") ---"
    "$HERE/convert.sh" "$f" "$MODE" ${CONV_ARGS[@]+"${CONV_ARGS[@]}"}
done < <(find "$DEST" -type f -name "$PATTERN" 2>/dev/null | sort)
if [ "$FOUND" -eq 0 ]; then
    echo "[run] no $PATTERN files found under $DEST" >&2
    exit 1
fi

echo "=== [run] done. outputs: ==="
ls -lh "$HERE"/out/*.root 2>/dev/null || echo "  (no .root produced)"
