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

# /etc/bashrc, ~/.bash_profile and conda/mamba activation are NOT written to be
# "set -u" / "set -e" safe (e.g. /etc/bashrc references BASHRCSOURCED before it
# is set), so relax both just around them, then restore for the rest of the job.
set +eu
source ~/.bash_profile  # for CONTAINER, IMAGE, and PATH updates from get_image.sh
mamba activate cms
set -eu
# ------------------------------------------------------------------------------

: "${PIPE_DIR:?set by submit.sh}"
: "${DATASET:?}" ; : "${DEST:?}" ; : "${PER_TASK:?}"
MODE="${MODE:-}"               # --data | --mc | empty (preset/nick implies it)
k="${SLURM_ARRAY_TASK_ID:?run via sbatch --array}"

i_start=$(( k * PER_TASK + 1 ))
i_end=$(( i_start + PER_TASK - 1 ))

# Engine: docker/podman, auto-detected by lib.sh unless the submitter pinned
# CONTAINER. On clusters with rootless podman, `docker` is usually a podman shim.
export CONTAINER="${CONTAINER:-docker}"

# Podman's image store + temp MUST sit on roomy node-local scratch, or the ~17 GB
# image load fails with "no space left on device" (the default /tmp is tiny).
# Prefer $SLURM_TMPDIR; otherwise a per-job dir on node-local /scratch. Override
# HEPBENCH_PODMAN_DIR for your site (and set HEPBENCH_PODMAN_DRIVER=vfs if it must
# live on a networked FS like Lustre). lib.sh consumes it.
export HEPBENCH_PODMAN_DIR="${HEPBENCH_PODMAN_DIR:-${SLURM_TMPDIR:-/scratch/$USER/hepbench_podman_${SLURM_JOB_ID:-$$}}}"

echo "[task $k] $DATASET  files ${i_start}-${i_end}  mode=${MODE:-auto}  engine=$CONTAINER"
echo "[task $k] dest=$DEST"
echo "[task $k] podman store: $HEPBENCH_PODMAN_DIR"

exec "$PIPE_DIR/batch.sh" "$DATASET" --dest "$DEST" $MODE \
    --range "${i_start}-${i_end}" \
    ${MAXEV:+--max-events "$MAXEV"} \
    ${KEEP:+--keep-inputs} \
    ${BYTYPE:+--by-type}
