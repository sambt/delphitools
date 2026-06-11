#!/bin/bash
# Shared config + runtime helpers for the standalone DELPHI pipeline.
# Source from each script:  . "$(dirname "$0")/lib.sh"
#
# Everything here is self-contained: this directory does not depend on
# the rest of the repo. The only external tools needed are a container
# runtime (docker/podman) and `cernopendata-client` (for downloads).

# ---------------------------------------------------------------------------
# Container image
# ---------------------------------------------------------------------------
# The converter image. Built from sim/Dockerfile.nanoaod in the parent repo,
# or loaded from a tarball cache. See get_image.sh.
: "${IMAGE:=hepbench/delphi-nanoaod:dev}"

# Path the image expects the DDB conditions data to be mounted at (real data
# conversion only). Baked into the SKELANA/PHDST setup inside the image.
DELPHI_DDB_MOUNT=/eos/opendata/delphi/condition-data

# ---------------------------------------------------------------------------
# CERN Open Data record IDs (https://opendata.cern.ch)
# ---------------------------------------------------------------------------
# Looked up by the `data`/`mc`/`mc-apacic` dataset presets in download.sh.
RECID_DATA=81431        # Real 1994 hadronic short DST, .al   (Y13709.* / Y13710.*)
RECID_MC=81197          # MC Z->qqbar BAST, b-life 1.6 tune, .al   (primary reference)
RECID_MC_APACIC=81418   # MC Z->hadrons APACIC 1.0.5, .sdst        (alt generator)
# DDB conditions database = recid 80509 ("DELPHI conditions databases",
# DOI 10.7483/OPENDATA.DELPHI.18JY.GL8K): 7 DB*.dat files, ~3.0 GiB, served
# at root://eospublic.cern.ch//eos/opendata/delphi/condition-data/ . The
# repo's ddb/80509/ dir is named after this recid (NOT a run period).
: "${DDB_RECID:=80509}"

# ---------------------------------------------------------------------------
# Container runtime detection (ported from sim/_runtime.sh)
# ---------------------------------------------------------------------------
# Engine is docker or podman (on most clusters `docker` is an alias/shim for
# rootless podman -- the args we use are common to both). Force a choice with
# CONTAINER=...; otherwise auto-detect.
if [ -z "${CONTAINER:-}" ]; then
    if command -v wslpath >/dev/null 2>&1 \
       && [ -x '/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe' ]; then
        # WSL2: Docker Desktop needs the Windows-side exe for bind mounts.
        CONTAINER='/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe'
    elif command -v docker >/dev/null 2>&1; then
        CONTAINER=docker
    elif command -v podman >/dev/null 2>&1; then
        CONTAINER=podman
    else
        echo "[lib] no container runtime found (need docker or podman)" >&2
        return 1 2>/dev/null || exit 1
    fi
fi
export CONTAINER

# Echo a path in the form the runtime needs for a -v bind mount: a Windows UNC
# path under WSL-docker, identity everywhere else.
to_mount_path() {
    if command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

# ---------------------------------------------------------------------------
# Podman storage relocation (HPC disk-space fix)
# ---------------------------------------------------------------------------
# By default rootless podman stores images (and stages image-load temp blobs)
# under /tmp or /run/user/$UID, which on many compute nodes is small/tmpfs and
# cannot hold the ~17 GB image -> load fails with:
#   docker-archive: writing blob ... /tmp/...: no space left on device
# Point $HEPBENCH_PODMAN_DIR at a ROOMY node-local scratch and every podman call
# (load/run/build/save) will keep its store + temp there. Defaults to
# $SLURM_TMPDIR inside a job if that is set. Use a node-local disk (overlay
# driver); for a networked FS (Lustre/NFS) also set HEPBENCH_PODMAN_DRIVER=vfs.
: "${HEPBENCH_PODMAN_DIR:=${SLURM_TMPDIR:-}}"
if [ -n "${HEPBENCH_PODMAN_DIR:-}" ]; then
    if mkdir -p "$HEPBENCH_PODMAN_DIR/storage" "$HEPBENCH_PODMAN_DIR/run" \
                "$HEPBENCH_PODMAN_DIR/tmp" 2>/dev/null; then
        _hb_scfg="$HEPBENCH_PODMAN_DIR/storage.conf"
        if [ ! -f "$_hb_scfg" ]; then
            cat > "$_hb_scfg" <<EOF
[storage]
driver = "${HEPBENCH_PODMAN_DRIVER:-overlay}"
graphroot = "$HEPBENCH_PODMAN_DIR/storage"
runroot = "$HEPBENCH_PODMAN_DIR/run"
EOF
        fi
        export CONTAINERS_STORAGE_CONF="$_hb_scfg"   # podman (incl. docker->podman shim) honors this
        export TMPDIR="$HEPBENCH_PODMAN_DIR/tmp"      # where image-load stages temp blobs
    else
        echo "[lib] WARNING: HEPBENCH_PODMAN_DIR not writable ($HEPBENCH_PODMAN_DIR);" >&2
        echo "[lib]          podman will use its default store -- image load may run out of space." >&2
    fi
fi

# Run a bash snippet inside the image. Caller sets two globals:
#   MOUNTS=( "host:container[:ro]" ... )   bind mounts
#   INNER="...bash..."                      command to run as: bash -c "$INNER"
run_in_image() {
    local m args=(run --rm --entrypoint /bin/bash)
    for m in "${MOUNTS[@]}"; do args+=(-v "$m"); done
    args+=("$IMAGE" -c "$INNER")
    "$CONTAINER" "${args[@]}"
}

# Require a command on PATH or die with a helpful message.
need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[lib] required tool not found: $1${2:+  ($2)}" >&2
        exit 1
    }
}
