#!/bin/bash
# Submit the conversion of the LEP1 APACIC Z->hadrons MC to ROOT, spread across
# SLURM array jobs. Companion to submit_lep1_mc.sh: APACIC++ 1.0.5 is an
# ALTERNATIVE parton-shower / hadronisation model for Z->qqbar, used as the
# fragmentation systematic against the default PYTHIA `sh_qqps_*` sample. Output
# mirrors the EOS layout under <DEST>.
#
# Usage (identical to the other submitters):
#   ./submit_lep1_mc_apacic.sh <DEST> [--per-task N] [--max-concurrent M]
#                                     [--dry-run] [-- <sbatch args>]
#
# ---------------------------------------------------------------------------
# Datasets. Open Data has exactly three APACIC records (short-DST, .sdst),
# one each for 1993/94/95, matching those years' data processing. There is NO
# 1992 APACIC sample.  (Browse:  ./catalog.sh apacic --sim)
#   sh_apacic105_e91.25_wp93_2l_d2  81130  300 files  20.9 GB  (pairs with short93_d2)
#   sh_apacic105_e91.25_w94_2l_c2   81418  943 files  71.6 GB  (pairs with short94_c2)
#   sh_apacic105_e91.25_wp95_1l_d2  81515  448 files  33.3 GB  (pairs with short95_d2)
# These are Z-peak (e91.25). Pair with the matching PYTHIA qqps year from
# submit_lep1_mc.sh to estimate the hadronisation-model uncertainty.
# ---------------------------------------------------------------------------
DATASETS=(
    sh_apacic105_e91.25_wp93_2l_d2    # 1993
    sh_apacic105_e91.25_w94_2l_c2     # 1994
    sh_apacic105_e91.25_wp95_1l_d2    # 1995
)

set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

DEST="${1:?usage: submit_lep1_mc_apacic.sh <DEST> [--per-task N] [--max-concurrent M] [--dry-run] [-- <sbatch args>]}"
shift

PER_TASK=4; MAXC=20; DRY=""; SB=()
while [ $# -gt 0 ]; do
    case "$1" in
        --per-task) PER_TASK="${2:?}"; shift 2 ;;
        --max-concurrent) MAXC="${2:?}"; shift 2 ;;
        --dry-run) DRY="--dry-run"; shift ;;
        --) shift; while [ $# -gt 0 ]; do SB+=("$1"); shift; done ;;
        *) echo "[lep1-apacic] unknown option: $1" >&2; exit 2 ;;
    esac
done

echo "[lep1-apacic] submitting ${#DATASETS[@]} APACIC MC datasets -> $DEST"
echo "[lep1-apacic] datasets: ${DATASETS[*]}"
echo "[lep1-apacic] per-task=$PER_TASK  max-concurrent=$MAXC  ${DRY:+(dry-run)}"
[ ${#SB[@]} -gt 0 ] && echo "[lep1-apacic] sbatch args: ${SB[*]}"
echo

for d in "${DATASETS[@]}"; do
    echo "=== [lep1-apacic] $d ==="
    if [ ${#SB[@]} -gt 0 ]; then
        "$HERE/slurm/submit.sh" "$d" --dest "$DEST" \
            --per-task "$PER_TASK" --max-concurrent "$MAXC" --by-type $DRY -- "${SB[@]}"
    else
        "$HERE/slurm/submit.sh" "$d" --dest "$DEST" \
            --per-task "$PER_TASK" --max-concurrent "$MAXC" --by-type $DRY
    fi
    echo
done

echo "[lep1-apacic] all submitted. Watch with:  squeue --me"
echo "[lep1-apacic] outputs accumulate under $DEST (EOS layout mirrored); logs in $DEST/_logs."
echo "[lep1-apacic] re-run this exact command later to fill in any files that failed"
echo "              (resumable: existing .root files are skipped)."
