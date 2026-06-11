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

# HEPBENCH_PODMAN_DIR is a BASE directory. Each array task gets its OWN per-job
# subdir  <base>/hepbench_podman_<jobid>  as the podman image store, and removes
# it on exit. So concurrent tasks NEVER share a store (no races on `podman load`)
# and scratch doesn't fill with leftover ~17 GB image stores. The base must be
# roomy node-local scratch, or the image load fails with "no space left on
# device" (the default /tmp is tiny). Base preference:
#   your $HEPBENCH_PODMAN_DIR, else $SLURM_TMPDIR, else /scratch/$USER.
# >>> EDIT the base if your node-local scratch isn't /scratch. Keep it on LOCAL
#     disk so the overlay driver works; only a network base needs
#     HEPBENCH_PODMAN_DRIVER=vfs (slower). <<<
# Node-local /scratch on FASRC Cannon: per-node, fast, overlay works, purged
# after the job. Override by exporting HEPBENCH_PODMAN_DIR before submitting.
PODMAN_BASE="${HEPBENCH_PODMAN_DIR:-/scratch/$USER}"
HEPBENCH_PODMAN_DIR="$PODMAN_BASE/hepbench_podman_${SLURM_JOB_ID:-$$}"
export HEPBENCH_PODMAN_DIR
unset HEPBENCH_PODMAN_DRIVER   # local disk -> overlay (default); ensure no stray vfs

# Remove THIS task's store on exit (success, failure, or SLURM timeout) so it
# never accumulates. (--rm containers leave nothing mounted by the time we get
# here; || true avoids failing the task on a stray busy mount.)
cleanup() {
    rc=$?
    if [ -n "${HEPBENCH_PODMAN_DIR:-}" ]; then
        echo "[task $k] removing podman store $HEPBENCH_PODMAN_DIR"
        rm -rf "$HEPBENCH_PODMAN_DIR" 2>/dev/null || true
    fi
    # also remove the small local runroot lib.sh put on /tmp (default name)
    rm -rf "/tmp/hepbench_podman_run_${USER:-u}_${SLURM_JOB_ID:-$$}" 2>/dev/null || true
    exit "$rc"
}
trap cleanup EXIT

echo "[task $k] $DATASET  files ${i_start}-${i_end}  mode=${MODE:-auto}  engine=$CONTAINER"
echo "[task $k] dest=$DEST"
echo "[task $k] podman store: $HEPBENCH_PODMAN_DIR (removed on exit)"

# NOTE: run (don't exec) batch.sh so the EXIT trap fires for cleanup. set -e
# makes a batch.sh failure propagate as the task's exit code.
"$PIPE_DIR/batch.sh" "$DATASET" --dest "$DEST" $MODE \
    --range "${i_start}-${i_end}" \
    ${MAXEV:+--max-events "$MAXEV"} \
    ${KEEP:+--keep-inputs} \
    ${BYTYPE:+--by-type}
