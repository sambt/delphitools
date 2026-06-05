#!/bin/bash
# Submit a DELPHI record conversion as a SLURM array job, one slice per task.
#
# Usage:
#   slurm/submit.sh <dataset|nickname|recid> --dest DIR [options] [-- <sbatch args>]
#
#   <dataset>     a preset (data|mc|mc-apacic), a DELPHI nickname (e.g.
#                 short94_c2, sh_qqps_b94_2l_c2), or a raw recid.
#
# Options (before the optional `--`):
#   --dest DIR        REQUIRED. Output root; EOS layout mirrored under it.
#   --data | --mc     force the mode (needed only for a raw recid).
#   --per-task N      files converted per array task (default 4).
#   --max-concurrent M   cap simultaneously-running tasks (default 20 -> %M).
#   --filter RE | --range I-J   convert only a subset of the record.
#   --max-events N    cap events per file (default: all / stop at EOF).
#   --keep-inputs     keep staged .al/.sdst (default: delete after convert).
#   --logdir DIR      where SLURM .out/.err go (default <dest>/_logs).
#   --dry-run         print the sbatch command + array sizing, don't submit.
#
# Anything after `--` is passed straight to sbatch (e.g. --partition=shared
# --account=foo --time=24:00:00 --mem=8G).
#
# Before submitting it ensures the image and, for data, the DDB are in
# place on the submit node so array tasks don't each rebuild/redownload them.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
PIPE_DIR="$(cd "$HERE/.." && pwd)"
. "$PIPE_DIR/lib.sh"

DATASET="${1:?usage: submit.sh <dataset|nickname|recid> --dest DIR [opts] [-- <sbatch args>]}"
shift || true

DEST=""; MODE=""; PER_TASK=4; MAXC=20; FILTER=""; RANGE=""
MAXEV=""; KEEP=0; LOGDIR=""; DRY=0; SB_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST="${2:?}"; shift 2 ;;
        --data) MODE="--data"; shift ;;
        --mc)   MODE="--mc";   shift ;;
        --per-task) PER_TASK="${2:?}"; shift 2 ;;
        --max-concurrent) MAXC="${2:?}"; shift 2 ;;
        --filter) FILTER="${2:?}"; shift 2 ;;
        --range)  RANGE="${2:?}"; shift 2 ;;
        --max-events) MAXEV="${2:?}"; shift 2 ;;
        --keep-inputs) KEEP=1; shift ;;
        --logdir) LOGDIR="${2:?}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --) shift; while [ $# -gt 0 ]; do SB_ARGS+=("$1"); shift; done ;;
        *) echo "[submit] unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -n "$DEST" ] || { echo "[submit] --dest DIR is required" >&2; exit 2; }
need sbatch
need cernopendata-client "pip install --user cernopendata-client"

# How many files are selected? (batch.sh --count resolves nickname + applies
# the same --filter/--range selection, then prints just the number.)
SELARGS=()
[ -n "$MODE" ]   && SELARGS+=("$MODE")
[ -n "$FILTER" ] && SELARGS+=(--filter "$FILTER")
[ -n "$RANGE" ]  && SELARGS+=(--range "$RANGE")
TOTAL="$("$PIPE_DIR/batch.sh" "$DATASET" --count ${SELARGS[@]+"${SELARGS[@]}"} | tail -n1)"
case "$TOTAL" in ''|*[!0-9]*) echo "[submit] could not determine file count (got '$TOTAL')" >&2; exit 1;; esac
[ "$TOTAL" -gt 0 ] || { echo "[submit] 0 files selected" >&2; exit 1; }

NCHUNKS=$(( (TOTAL + PER_TASK - 1) / PER_TASK ))
LAST=$(( NCHUNKS - 1 ))
[ -n "$LOGDIR" ] || LOGDIR="$DEST/_logs"
mkdir -p "$LOGDIR" "$DEST"

echo "[submit] dataset=$DATASET  dest=$DEST"
echo "[submit] $TOTAL files / $PER_TASK per task -> array 0-$LAST (%$MAXC concurrent)"

# Ensure image + (for data) DDB on the submit node so tasks don't race on them.
# (Skipped on --dry-run: a preview must not build images or download 3 GB.)
if [ "$DRY" -eq 0 ]; then
    echo "[submit] ensuring converter image..."
    "$PIPE_DIR/get_image.sh" auto
    EFFMODE="$MODE"
    case "$DATASET" in data) EFFMODE="${EFFMODE:---data}";; mc|mc-apacic) EFFMODE="${EFFMODE:---mc}";; esac
    if [ "$EFFMODE" = "--data" ] && [ -z "${DDB_DIR:-}" ]; then
        if [ "$(find "$PIPE_DIR/ddb" -name 'DB*.dat' 2>/dev/null | wc -l | tr -d ' ')" -lt 7 ]; then
            echo "[submit] fetching DDB conditions (recid $DDB_RECID, ~3 GB) once..."
            "$PIPE_DIR/download.sh" ddb
        fi
    fi
fi

# Export everything the task needs.
EXPORTS="ALL,PIPE_DIR=$PIPE_DIR,DATASET=$DATASET,DEST=$DEST,PER_TASK=$PER_TASK"
[ -n "$MODE" ]  && EXPORTS="$EXPORTS,MODE=$MODE"
[ -n "$MAXEV" ] && EXPORTS="$EXPORTS,MAXEV=$MAXEV"
[ "$KEEP" -eq 1 ] && EXPORTS="$EXPORTS,KEEP=1"
[ -n "${DDB_DIR:-}" ] && EXPORTS="$EXPORTS,DDB_DIR=$DDB_DIR"
[ -n "${CONTAINER:-}" ] && EXPORTS="$EXPORTS,CONTAINER=$CONTAINER"

SB=(sbatch --array="0-${LAST}%${MAXC}"
    --chdir="$LOGDIR"
    --export="$EXPORTS"
    ${SB_ARGS[@]+"${SB_ARGS[@]}"}
    "$HERE/convert.sbatch")

if [ "$DRY" -eq 1 ]; then
    echo "[submit] DRY RUN, would run:"; printf '   %q' "${SB[@]}"; echo
    exit 0
fi
echo "[submit] submitting..."
"${SB[@]}"
