#!/bin/bash
# SLURM array task: convert one slice of a DELPHI record to ROOT.
# Submitted by slurm/submit.sh -- don't sbatch this directly unless you set the
# PIPE_DIR / DATASET / DEST / PER_TASK env vars yourself.
#
# Each array task handles files [k*PER_TASK+1 .. (k+1)*PER_TASK] of the record
# (k = SLURM_ARRAY_TASK_ID) by calling batch.sh --range. batch.sh is resumable
# (skips files whose .root already exists), so requeued/rerun tasks are safe.
#
# Resource directives are conservative defaults; override at submit time via
# slurm/submit.sh passthrough (e.g. --partition=..., --time=..., --account=...).
#SBATCH --job-name=delphi-conv
#SBATCH --output=%x_%A_%a.out
#SBATCH --error=%x_%A_%a.err
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
set -eu

: "${PIPE_DIR:?set by submit.sh}"
: "${DATASET:?}" ; : "${DEST:?}" ; : "${PER_TASK:?}"
MODE="${MODE:-}"               # --data | --mc | empty (preset/nick implies it)
k="${SLURM_ARRAY_TASK_ID:?run via sbatch --array}"

i_start=$(( k * PER_TASK + 1 ))
i_end=$(( i_start + PER_TASK - 1 ))

# Engine: docker/podman, auto-detected by lib.sh unless the submitter pinned
# CONTAINER. On clusters with rootless podman, `docker` is usually a podman shim.
export CONTAINER="${CONTAINER:-docker}"

echo "[task $k] $DATASET  files ${i_start}-${i_end}  mode=${MODE:-auto}  engine=$CONTAINER"
echo "[task $k] dest=$DEST"

exec "$PIPE_DIR/batch.sh" "$DATASET" --dest "$DEST" $MODE \
    --range "${i_start}-${i_end}" \
    ${MAXEV:+--max-events "$MAXEV"} \
    ${KEEP:+--keep-inputs}
