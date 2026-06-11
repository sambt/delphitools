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
#   --all             submit the FULL array. Default is to submit ONLY the tasks
#                     whose chunk still has a missing .root (cheap gap-filling on
#                     re-run); --all forces every task regardless.
#   --logdir DIR      where SLURM .out/.err go (default <dest>/_logs).
#   --dry-run         print the sbatch command + array sizing, don't submit.
#
# By default this checks what's already converted under --dest and submits only
# the array tasks needed to fill the gaps. So just re-run the same command to
# retry stragglers -- it won't re-submit files you already have.
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

# Compress a newline-separated, sorted-unique int list into a SLURM array spec,
# e.g.  0 1 2 5 7 8  ->  "0-2,5,7-8".
compress_ranges() {
    local nums=() n s p out="" i
    while IFS= read -r n; do [ -n "$n" ] && nums+=("$n"); done <<< "$1"
    [ ${#nums[@]} -eq 0 ] && return 0
    s="${nums[0]}"; p="${nums[0]}"
    for ((i = 1; i < ${#nums[@]}; i++)); do
        n="${nums[i]}"
        if [ "$n" -eq $((p + 1)) ]; then p="$n"
        else
            if [ "$s" -eq "$p" ]; then out+="${out:+,}$s"; else out+="${out:+,}$s-$p"; fi
            s="$n"; p="$n"
        fi
    done
    if [ "$s" -eq "$p" ]; then out+="${out:+,}$s"; else out+="${out:+,}$s-$p"; fi
    printf '%s' "$out"
}

DATASET="${1:?usage: submit.sh <dataset|nickname|recid> --dest DIR [opts] [-- <sbatch args>]}"
shift || true

DEST=""; MODE=""; PER_TASK=4; MAXC=20; FILTER=""; RANGE=""
MAXEV=""; KEEP=0; BYTYPE=0; LOGDIR=""; DRY=0; ONLY_MISSING=1; SB_ARGS=()
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
        --by-type) BYTYPE=1; shift ;;
        --all) ONLY_MISSING=0; shift ;;   # submit the full array even if some files already exist
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

# Default: submit only the array tasks whose chunk holds a not-yet-converted file,
# so re-running cheaply fills gaps instead of re-submitting everything. --all
# forces the full array. The pruning relies on the same file ordering the tasks
# use, so it is skipped when a --filter/--range subset is active.
ARRAY="0-${LAST}"
if [ "$ONLY_MISSING" -eq 1 ] && [ -z "$FILTER" ] && [ -z "$RANGE" ]; then
    MISSARGS=(--missing)
    [ -n "$MODE" ]      && MISSARGS+=("$MODE")
    [ "$BYTYPE" -eq 1 ] && MISSARGS+=(--by-type)
    missidx="$("$PIPE_DIR/batch.sh" "$DATASET" --dest "$DEST" "${MISSARGS[@]}" | grep -E '^[0-9]+$' || true)"
    if [ -z "$missidx" ]; then
        echo "[submit] all $TOTAL files already present under $DEST -- nothing to submit."
        exit 0
    fi
    # missing file indices (1-based) -> chunk ids (0-based) -> compressed array spec
    chunks="$(printf '%s\n' "$missidx" | awk -v p="$PER_TASK" '{print int(($1-1)/p)}' | sort -n -u)"
    ARRAY="$(compress_ranges "$chunks")"
    nmiss="$(printf '%s\n' "$missidx" | grep -c .)"
    ntask="$(printf '%s\n' "$chunks" | grep -c .)"
    echo "[submit] $TOTAL files, $nmiss missing -> $ntask task(s): array $ARRAY (%$MAXC concurrent)"
    echo "[submit] (re-run fills only gaps; pass --all to force the full 0-$LAST array)"
else
    echo "[submit] $TOTAL files / $PER_TASK per task -> array 0-$LAST (%$MAXC concurrent)"
fi

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
[ "$BYTYPE" -eq 1 ] && EXPORTS="$EXPORTS,BYTYPE=1"
[ -n "${DDB_DIR:-}" ] && EXPORTS="$EXPORTS,DDB_DIR=$DDB_DIR"
[ -n "${CONTAINER:-}" ] && EXPORTS="$EXPORTS,CONTAINER=$CONTAINER"
[ -n "${HEPBENCH_PODMAN_DIR:-}" ] && EXPORTS="$EXPORTS,HEPBENCH_PODMAN_DIR=$HEPBENCH_PODMAN_DIR"
[ -n "${HEPBENCH_PODMAN_DRIVER:-}" ] && EXPORTS="$EXPORTS,HEPBENCH_PODMAN_DRIVER=$HEPBENCH_PODMAN_DRIVER"

SB=(sbatch --array="${ARRAY}%${MAXC}"
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
