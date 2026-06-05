#!/bin/bash
# Submit the conversion of the core 1992-1995 LEP1 short-DST (Z-peak) DATA to
# ROOT, spread across SLURM array jobs -- one array job per dataset, each split
# into many file-slice tasks. Output mirrors the EOS layout under <DEST>.
#
# These short DSTs are the "OR of the physics teams" -- the INCLUSIVE stream,
# i.e. hadronic AND leptonic events (Z->qqbar, mu mu, ee, tau tau all present).
# There is no separate "hadronic" short DST at LEP1; the leptonic events are
# already here. (A dedicated, more detailed leptonic set exists as the Long-DST
# `lolept9X` stream -- add those nicknames if you want it.)
#
# Usage:
#   ./submit_lep1_core.sh <DEST> [--per-task N] [--max-concurrent M]
#                                [--dry-run] [-- <sbatch args>]
#
#   <DEST>             output root on your storage (e.g. $SCRATCH/delphi_root)
#   --per-task N       files converted per array task (default 4)
#   --max-concurrent M cap running tasks per job (default 20)
#   --dry-run          show what would be submitted, submit nothing
#   -- <sbatch args>   forwarded to sbatch for every job (partition, account,
#                      time, mem, qos, ...). REQUIRED in practice on most clusters.
#
# Example:
#   ./submit_lep1_core.sh $SCRATCH/delphi_root --per-task 4 \
#       -- --partition=shared --account=myacct --time=08:00:00 --mem=4G
#
# ---------------------------------------------------------------------------
# Which datasets? Each year's (inclusive) short DST, latest available processing.
# Open Data offers more than one reprocessing for some years; the LATEST letter
# is generally the recommended one. Edit DATASETS to taste -- e.g. add the
# earlier processings (short92_d2, short93_c1) if you want them, or add the
# Long-DST leptonic (lolept9X) stream for richer leptonic-event content.
#   recid / files (from catalog.sh):
#     short92_e2  81098  172 files   (also: short92_d2 81090, 97)
#     short93_d2  81166  181 files   (also: short93_c1 81172, 151)
#     short94_c2  81431  429 files
#     short95_d2  81502  246 files
# Note: 1990 is RAW-only and 1991 is lower-stats -> not in the core set.
# (Matched MC is separate -- the sh_qqps_*9X records; convert those with
#  ./submit_lep1_core.sh-style loops over their nicknames, or batch.sh directly.)
# ---------------------------------------------------------------------------
DATASETS=(short92_e2 short93_d2 short94_c2 short95_d2)

set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

DEST="${1:?usage: submit_lep1_core.sh <DEST> [--per-task N] [--max-concurrent M] [--dry-run] [-- <sbatch args>]}"
shift

PER_TASK=4; MAXC=20; DRY=""; SB=()
while [ $# -gt 0 ]; do
    case "$1" in
        --per-task) PER_TASK="${2:?}"; shift 2 ;;
        --max-concurrent) MAXC="${2:?}"; shift 2 ;;
        --dry-run) DRY="--dry-run"; shift ;;
        --) shift; while [ $# -gt 0 ]; do SB+=("$1"); shift; done ;;
        *) echo "[lep1] unknown option: $1" >&2; exit 2 ;;
    esac
done

echo "[lep1] submitting ${#DATASETS[@]} datasets -> $DEST"
echo "[lep1] datasets: ${DATASETS[*]}"
echo "[lep1] per-task=$PER_TASK  max-concurrent=$MAXC  ${DRY:+(dry-run)}"
[ ${#SB[@]} -gt 0 ] && echo "[lep1] sbatch args: ${SB[*]}"
echo

for d in "${DATASETS[@]}"; do
    echo "=== [lep1] $d ==="
    if [ ${#SB[@]} -gt 0 ]; then
        "$HERE/slurm/submit.sh" "$d" --dest "$DEST" \
            --per-task "$PER_TASK" --max-concurrent "$MAXC" $DRY -- "${SB[@]}"
    else
        "$HERE/slurm/submit.sh" "$d" --dest "$DEST" \
            --per-task "$PER_TASK" --max-concurrent "$MAXC" $DRY
    fi
    echo
done

echo "[lep1] all submitted. Watch with:  squeue --me"
echo "[lep1] outputs accumulate under $DEST (EOS layout mirrored); logs in $DEST/_logs."
echo "[lep1] re-run this exact command later to fill in any files that failed"
echo "       (resumable: existing .root files are skipped)."
