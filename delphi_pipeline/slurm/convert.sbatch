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
# Leave HEPBENCH_PODMAN_DIR unset to auto-pick a location (and auto-clean it):
#   - $SLURM_TMPDIR if SLURM provides one (SLURM cleans it up for us), else
#   - a per-job dir on node-local /scratch, which WE delete at the end.
# >>> EDIT HERE if your node-local scratch isn't /scratch, or export it before
#     submit.sh. Set HEPBENCH_PODMAN_DRIVER=vfs if it lives on Lustre/NFS. <<<
NODE_SCRATCH_DEFAULT="/scratch/$USER/hepbench_podman_${SLURM_JOB_ID:-$$}"

_OWN_PODMAN_DIR=0   # 1 => this script created the dir and is responsible for deleting it
if [ -z "${HEPBENCH_PODMAN_DIR:-}" ]; then
    if [ -n "${SLURM_TMPDIR:-}" ]; then
        HEPBENCH_PODMAN_DIR="$SLURM_TMPDIR"          # SLURM auto-cleans -> we don't
    else
        HEPBENCH_PODMAN_DIR="$NODE_SCRATCH_DEFAULT"  # our per-job dir -> we clean it
        _OWN_PODMAN_DIR=1
    fi
fi
export HEPBENCH_PODMAN_DIR

# Clean up our per-job podman store on exit (success, failure, or SLURM timeout),
# so scratch doesn't fill with leftover 17 GB image stores.
cleanup() {
    rc=$?
    if [ "${_OWN_PODMAN_DIR:-0}" = "1" ] && [ -n "${HEPBENCH_PODMAN_DIR:-}" ]; then
        echo "[task $k] cleaning up podman store $HEPBENCH_PODMAN_DIR"
        # containers ran with --rm, so nothing is mounted by the time we get here;
        # plain rm frees the unpacked ~17 GB image. (|| true: don't fail the task
        # on a stray busy mount -- node-local scratch is purged after the job too.)
        rm -rf "$HEPBENCH_PODMAN_DIR" 2>/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT

echo "[task $k] $DATASET  files ${i_start}-${i_end}  mode=${MODE:-auto}  engine=$CONTAINER"
echo "[task $k] dest=$DEST"
echo "[task $k] podman store: $HEPBENCH_PODMAN_DIR (auto-clean=$_OWN_PODMAN_DIR)"

# NOTE: run (don't exec) batch.sh so the EXIT trap fires for cleanup. set -e
# makes a batch.sh failure propagate as the task's exit code.
"$PIPE_DIR/batch.sh" "$DATASET" --dest "$DEST" $MODE \
    --range "${i_start}-${i_end}" \
    ${MAXEV:+--max-events "$MAXEV"} \
    ${KEEP:+--keep-inputs} \
    ${BYTYPE:+--by-type}
