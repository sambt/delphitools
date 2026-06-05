#!/bin/bash
# Convert ONE DELPHI SDST file (.al / .sdst) to a delphi-nanoaod ROOT file,
# using the hepbench/delphi-nanoaod:dev container.
#
# Usage:
#   ./convert.sh <input.al|.sdst> --data|--mc [--out PATH.root] [options]
#
# Options:
#   --out PATH.root  where to write the ROOT file (parent dirs are created).
#                    Default: ./out/<input-basename>.root
#   --max-events N   cap processing at N events (default: process ALL = stop
#                    at end of file). See "How event counting works" below.
#   --legacy [N]     use the T.FSEQ1 fallback instead of a PDLINPUT control
#                    file. That mode REWINDS at EOF, so --max-events is
#                    mandatory (N defaults to 5000). Only for reproducing the
#                    parent repo's behaviour; the default mode is preferred.
#
# Scratch files (PDLINPUT, fort.*, T.FSEQ*) stay inside the container and are
# discarded on exit -- ONLY the .root is written to --out. (Earlier versions
# wrote scratch alongside the output; that is fixed.)
#
# ---------------------------------------------------------------------------
# How event counting works (why this matters)
# ---------------------------------------------------------------------------
# The DELPHI framework is told which files to read via a PDLINPUT control file
# containing a `FILE = <path>` line (per the CERN Open Data DELPHI analysis
# guide). Fed this way, PHDST reads the file ONCE and stops cleanly at EOF --
# so the DEFAULT mode here processes exactly every event, no more, no fewer,
# and you do NOT need --max-events. (Verified: PHEND reports "Processed 1
# Files" and the run ends; "Reached maximum number of events" does NOT appear.)
#
# The parent repo instead symlinks the raw data file onto T.FSEQ1 with no PDL
# config; in that fallback PHDST REWINDS at EOF and re-reads from the top, so
# max-events too LOW truncates and too HIGH duplicates. Use --legacy only to
# reproduce that.
#
# Real data (--data) needs the DDB conditions database (recid 80509),
# bind-mounted at /eos/opendata/delphi/condition-data. Located at $DDB_DIR,
# else by finding DBcalb.dat under ./ddb (see download.sh ddb).
#
# Examples:
#   ./convert.sh samples/mc/Y10638.1.al --mc
#   ./convert.sh samples/data/Y13709.170.al --data --out /data/root/foo.root
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

IN="${1:?usage: convert.sh <input.al|.sdst> --data|--mc [--out PATH.root] [--max-events N] [--legacy [N]]}"
shift

MODE=""; MAXEV=""; LEGACY=0; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --data) MODE="--data"; shift ;;
        --mc)   MODE="--mc";   shift ;;
        --out)  OUT="${2:?--out needs a path}"; shift 2 ;;
        --max-events) MAXEV="${2:?--max-events needs a number}"; shift 2 ;;
        --legacy)
            LEGACY=1; shift
            case "${1:-}" in ''|--*) : ;; *[!0-9]*) : ;; *) MAXEV="$1"; shift ;; esac ;;
        *) echo "[convert] unexpected arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "$MODE" ] || { echo "[convert] must pass --data or --mc" >&2; exit 2; }
[ -f "$IN" ]   || { echo "[convert] input not found: $IN" >&2; exit 1; }
if [ "$LEGACY" -eq 1 ] && [ -z "$MAXEV" ]; then MAXEV=5000; fi

IN="$(realpath "$IN")"
IN_DIR="$(dirname "$IN")"
IN_BASE="$(basename "$IN")"

[ -n "$OUT" ] || OUT="$HERE/out/${IN_BASE%.*}.root"
OUT_DIR="$(dirname "$OUT")"
OUT_BASE="$(basename "$OUT")"
mkdir -p "$OUT_DIR"

# Mounts as "host:container[:ro]" strings (run_in_image prefixes -v). Scratch
# (PDLINPUT/fort.*/T.FSEQ*) lives in a container-internal /scratch, discarded on
# --rm, so it never touches $OUT_DIR.
MOUNTS=("$(to_mount_path "$IN_DIR"):/input:ro" "$(to_mount_path "$OUT_DIR"):/out")

DDB_NOTE=""
if [ "$MODE" = "--data" ]; then
    DDB="${DDB_DIR:-}"
    if [ -z "$DDB" ]; then
        hit="$(find "$HERE/ddb" -name DBcalb.dat 2>/dev/null | head -1)"
        [ -n "$hit" ] && DDB="$(dirname "$hit")"
    fi
    if [ -z "$DDB" ] || [ ! -d "$DDB" ]; then
        echo "[convert] --data needs the DDB conditions (recid 80509)." >&2
        echo "[convert] get it with:  ./download.sh ddb     (lands in ./ddb/80509)" >&2
        echo "[convert] or point at a copy:  DDB_DIR=/path/to/condition-data ./convert.sh ..." >&2
        exit 1
    fi
    MOUNTS+=("$(to_mount_path "$DDB"):${DELPHI_DDB_MOUNT}:ro")
    DDB_NOTE="  DDB=$DDB"
fi

MAXFLAG=""
[ -n "$MAXEV" ] && MAXFLAG="--max-events $MAXEV"

echo "[convert] engine: $CONTAINER  image=$IMAGE"
echo "[convert] input:  $IN"
echo "[convert] output: $OUT"

# Build the in-container command. CWD is /scratch so PDLINPUT/fort.*/T.FSEQ*
# never touch /out; only /out/<base>.root persists to the host.
CFG="/nanoaod/config/delphi-nanoaod.yaml"
if [ "$LEGACY" -eq 1 ]; then
    echo "[convert] mode:   $MODE  method=legacy(T.FSEQ1 rewind)  max-events=$MAXEV$DDB_NOTE"
    PREP="ln -sf /input/${IN_BASE} /scratch/T.FSEQ1; PDLARG='--pdlinput /input/${IN_BASE}'"
else
    echo "[convert] mode:   $MODE  method=PDLINPUT(stop at EOF)  max-events=${MAXEV:-<all>}$DDB_NOTE"
    PREP="printf 'FILE = /input/%s\n' '${IN_BASE}' > /scratch/PDLINPUT.ctl; PDLARG='--pdlinput /scratch/PDLINPUT.ctl'"
fi

INNER="set -e; mkdir -p /scratch; cd /scratch; ${PREP}; \
    /nanoaod/build/delphi-nanoaod/delphi-nanoaod \
        \$PDLARG -C ${CFG} \
        --output /out/${OUT_BASE} ${MAXFLAG} ${MODE}; \
    ls -lh /out/${OUT_BASE}"

run_in_image || { rc=$?; echo "[convert] FAILED (rc=$rc)" >&2; exit "$rc"; }

echo "[convert] wrote $OUT"
