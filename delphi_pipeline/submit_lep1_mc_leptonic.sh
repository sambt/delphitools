#!/bin/bash
# Submit the conversion of the 1992-1995 LEP1 LEPTONIC signal MC (Z->mu mu,
# Z->tau tau, Z->e e) to ROOT, spread across SLURM array jobs. Companion to
# submit_lep1_mc.sh (which does the Z->qqbar hadronic MC). Output mirrors the
# EOS layout under <DEST>.
#
# Usage (identical to the other submitters):
#   ./submit_lep1_mc_leptonic.sh <DEST> [--per-task N] [--max-concurrent M]
#                                       [--dry-run] [-- <sbatch args>]
#
# ---------------------------------------------------------------------------
# Channels & pinning. The leptonic signal lives in separate MC families, one
# per final state. These recid-verified nicknames are picked to MATCH each
# year's data processing letter (short92_e2 / short93_d2 / short94_c2 /
# short95_d2) where Open Data has one; gaps are noted.
#
#   Z->mu mu  (DYMU):
#     lo_dymu_r92_2l_e2  81060    lo_dymu_r93_1g_d2  81118
#     lo_dymu_r94_2l_c2  81309    lo_dymu_r95_1l_d2  81495
#   Z->tau tau  (KORALZ; koz4 = KORALZ v4):
#     lo_kora_b93_1g_d2  81156    lo_koz4_b94_2l_c2  81398
#     lo_kora_b95_1l_d2  81490                       (no matched 1992 tau-tau MC)
#   Z->e e  (Bhabha, BABAMC):
#     lo_baba_m94_2l_c2  81279    lo_baba_r95_1l_d2  81552
#                                 (1992: none; 1993 Bhabha only at c1: lo_baba_m93_1g_c1 81162)
#
# GAPS (DELPHI didn't ship a matched-processing sample for every year/channel):
#   - 1992: only Z->mu mu is available at the e2 processing.
#   - 1993 Z->e e: only the c1 processing exists (add lo_baba_m93_1g_c1 if needed).
# Browse all options:  ./catalog.sh dymu --sim   /   kora   /   baba   /   koz4
# Two-photon background (gamma gamma -> mu mu) is `lo_ggmu_*` -- add if needed.
# ---------------------------------------------------------------------------
DATASETS=(
    # --- Z -> mu mu (DYMU) ---
    lo_dymu_r92_2l_e2     # 1992
    lo_dymu_r93_1g_d2     # 1993
    lo_dymu_r94_2l_c2     # 1994
    lo_dymu_r95_1l_d2     # 1995
    # --- Z -> tau tau (KORALZ) ---
    lo_kora_b93_1g_d2     # 1993
    lo_koz4_b94_2l_c2     # 1994
    lo_kora_b95_1l_d2     # 1995
    # --- Z -> e e (Bhabha) ---
    lo_baba_m94_2l_c2     # 1994
    lo_baba_r95_1l_d2     # 1995
)

set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

DEST="${1:?usage: submit_lep1_mc_leptonic.sh <DEST> [--per-task N] [--max-concurrent M] [--dry-run] [-- <sbatch args>]}"
shift

PER_TASK=4; MAXC=20; DRY=""; SB=()
while [ $# -gt 0 ]; do
    case "$1" in
        --per-task) PER_TASK="${2:?}"; shift 2 ;;
        --max-concurrent) MAXC="${2:?}"; shift 2 ;;
        --dry-run) DRY="--dry-run"; shift ;;
        --) shift; while [ $# -gt 0 ]; do SB+=("$1"); shift; done ;;
        *) echo "[lep1-lept] unknown option: $1" >&2; exit 2 ;;
    esac
done

echo "[lep1-lept] submitting ${#DATASETS[@]} leptonic MC datasets -> $DEST"
echo "[lep1-lept] datasets: ${DATASETS[*]}"
echo "[lep1-lept] per-task=$PER_TASK  max-concurrent=$MAXC  ${DRY:+(dry-run)}"
[ ${#SB[@]} -gt 0 ] && echo "[lep1-lept] sbatch args: ${SB[*]}"
echo

for d in "${DATASETS[@]}"; do
    echo "=== [lep1-lept] $d ==="
    if [ ${#SB[@]} -gt 0 ]; then
        "$HERE/slurm/submit.sh" "$d" --dest "$DEST" \
            --per-task "$PER_TASK" --max-concurrent "$MAXC" $DRY -- "${SB[@]}"
    else
        "$HERE/slurm/submit.sh" "$d" --dest "$DEST" \
            --per-task "$PER_TASK" --max-concurrent "$MAXC" $DRY
    fi
    echo
done

echo "[lep1-lept] all submitted. Watch with:  squeue --me"
echo "[lep1-lept] outputs accumulate under $DEST (EOS layout mirrored); logs in $DEST/_logs."
echo "[lep1-lept] re-run this exact command later to fill in any files that failed"
echo "            (resumable: existing .root files are skipped)."
