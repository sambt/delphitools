#!/bin/bash
# Submit the conversion of the core 1992-1995 LEP1 Z->qqbar (hadronic) MC to
# ROOT, spread across SLURM array jobs -- the simulation counterpart to
# submit_lep1_core.sh. Output mirrors the EOS layout under <DEST>.
#
# Usage (identical to submit_lep1_core.sh):
#   ./submit_lep1_mc.sh <DEST> [--per-task N] [--max-concurrent M]
#                              [--dry-run] [-- <sbatch args>]
#
# Example:
#   ./submit_lep1_mc.sh $SCRATCH/delphi_root --per-task 4 \
#       -- --partition=shared --account=myacct --time=08:00:00 --mem=4G
#
# ---------------------------------------------------------------------------
# Which MC? The Z->qqbar parton-shower sample (`sh_qqps_*`) for each year,
# picked to MATCH that year's data processing letter (so it pairs with the
# datasets in submit_lep1_core.sh). DELPHI's tune letter is NOT uniform across
# years -- it's `k` for 92/93 and `b` for 94/95 in the processing we want, and
# 1995 uses `1l` not `2l` -- so these are pinned by recid-verified nickname:
#   sh_qqps_k92_2l_e2  81053   71 files  (pairs with short92_e2)
#   sh_qqps_k93_2l_d2  81177   17 files  (pairs with short93_d2)
#   sh_qqps_b94_2l_c2  81197  212 files  (pairs with short94_c2)  [validated]
#   sh_qqps_b95_1l_d2  81512  100 files  (pairs with short95_d2)
# Browse alternatives (other tunes b/k/r/s/sa, generators) with:  ./catalog.sh qqps --sim
#
# NOTE on leptonic MC: the data short DST is the "OR of the physics teams"
# (inclusive: hadronic AND leptonic), so Z->mu mu / ee / tau tau events are in
# the converted data. The matching *signal* MC for those is SEPARATE channels,
# e.g.  lo_dymu_* (di-muon),  sh_kk2f* (mu mu / tau tau, higher precision),
# lo_baba_* (Bhabha ee),  koz4/koralz (tau tau).  Add their nicknames to
# DATASETS below if your analysis needs leptonic signal/background MC.
# ---------------------------------------------------------------------------
DATASETS=(
    sh_qqps_k92_2l_e2     # 1992 Z->qqbar
    sh_qqps_k93_2l_d2     # 1993
    sh_qqps_b94_2l_c2     # 1994
    sh_qqps_b95_1l_d2     # 1995
)

set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

DEST="${1:?usage: submit_lep1_mc.sh <DEST> [--per-task N] [--max-concurrent M] [--dry-run] [-- <sbatch args>]}"
shift

PER_TASK=4; MAXC=20; DRY=""; SB=()
while [ $# -gt 0 ]; do
    case "$1" in
        --per-task) PER_TASK="${2:?}"; shift 2 ;;
        --max-concurrent) MAXC="${2:?}"; shift 2 ;;
        --dry-run) DRY="--dry-run"; shift ;;
        --) shift; while [ $# -gt 0 ]; do SB+=("$1"); shift; done ;;
        *) echo "[lep1-mc] unknown option: $1" >&2; exit 2 ;;
    esac
done

echo "[lep1-mc] submitting ${#DATASETS[@]} MC datasets -> $DEST"
echo "[lep1-mc] datasets: ${DATASETS[*]}"
echo "[lep1-mc] per-task=$PER_TASK  max-concurrent=$MAXC  ${DRY:+(dry-run)}"
[ ${#SB[@]} -gt 0 ] && echo "[lep1-mc] sbatch args: ${SB[*]}"
echo

for d in "${DATASETS[@]}"; do
    echo "=== [lep1-mc] $d ==="
    if [ ${#SB[@]} -gt 0 ]; then
        "$HERE/slurm/submit.sh" "$d" --dest "$DEST" \
            --per-task "$PER_TASK" --max-concurrent "$MAXC" $DRY -- "${SB[@]}"
    else
        "$HERE/slurm/submit.sh" "$d" --dest "$DEST" \
            --per-task "$PER_TASK" --max-concurrent "$MAXC" $DRY
    fi
    echo
done

echo "[lep1-mc] all submitted. Watch with:  squeue --me"
echo "[lep1-mc] outputs accumulate under $DEST (EOS layout mirrored); logs in $DEST/_logs."
echo "[lep1-mc] re-run this exact command later to fill in any files that failed"
echo "          (resumable: existing .root files are skipped)."
