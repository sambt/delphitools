#!/bin/bash
# Make the converter image (hepbench/delphi-nanoaod:dev) available locally.
#
# Usage:
#   ./get_image.sh                 # auto: present? use it. else tarball? load it. else build (+seed tarball)
#   ./get_image.sh build           # build from ../sim/Dockerfile.nanoaod (no save)
#   ./get_image.sh save [TARBALL]  # docker/podman save the image -> tarball
#   ./get_image.sh load [TARBALL]  # docker/podman load image <- tarball
#   ./get_image.sh check           # report image + tarball status
#
# WHY a tarball: on HPC, rootless podman's image store (graphroot) is usually
# NODE-LOCAL and ephemeral (/tmp, /run/user/$UID, local scratch), so a new job
# starts with an empty store and would otherwise rebuild from scratch every
# time. Keep ONE tarball on shared/persistent storage and each job loads it
# (seconds-minutes) instead of rebuilding (~20 min). See HEPBENCH_IMAGE_TARBALL.
#
#   $ podman info --format '{{.Store.GraphRoot}}'   # where YOUR images live
#
# The tarball path defaults to <pipeline>/delphi-nanoaod-dev.tar (your repo
# checkout = shared storage). Point it at project/scratch space with:
#   export HEPBENCH_IMAGE_TARBALL=/n/project/me/delphi-nanoaod-dev.tar
#
# The image is built FROM jingyucms/delphi-pythia8:latest (public docker.io
# pull) + ROOT 6.38, FastJet 3.4.3, and the compiled delphi-nanoaod converter.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

SIM_DIR="${SIM_DIR:-$(cd "$HERE/.." && pwd)/sim}"
TARBALL="${HEPBENCH_IMAGE_TARBALL:-$HERE/delphi-nanoaod-dev.tar}"

have_image() { "$CONTAINER" image inspect "$IMAGE" >/dev/null 2>&1; }

do_build() {
    [ -f "$SIM_DIR/Dockerfile.nanoaod" ] || {
        echo "[get_image] Dockerfile not found at $SIM_DIR/Dockerfile.nanoaod" >&2
        echo "[get_image] set SIM_DIR=/path/to/repo/sim and retry" >&2
        exit 1
    }
    echo "[get_image] building $IMAGE from $SIM_DIR/Dockerfile.nanoaod (~17-20 min)"
    "$CONTAINER" build -f "$SIM_DIR/Dockerfile.nanoaod" -t "$IMAGE" "$SIM_DIR"
}

do_save() {
    tar="${1:-$TARBALL}"
    mkdir -p "$(dirname "$tar")"
    echo "[get_image] saving $IMAGE -> $tar (this is large, ~minutes)"
    "$CONTAINER" save -o "$tar" "$IMAGE"
    echo "[get_image] saved: $(du -h "$tar" | cut -f1)  $tar"
}

# Resolve the tarball path, tolerating a compressed variant of the default name
# (podman `load` reads gzip transparently). Echoes the first that exists, else
# the plain default.
resolve_tarball() {
    local t
    for t in "$TARBALL" "$TARBALL.gz" "${TARBALL%.tar}.tar.gz" "${TARBALL%.tar}.tgz"; do
        [ -f "$t" ] && { printf '%s' "$t"; return 0; }
    done
    printf '%s' "$TARBALL"
}

do_load() {
    tar="${1:-$(resolve_tarball)}"
    [ -f "$tar" ] || { echo "[get_image] tarball not found: $tar" >&2; exit 1; }
    echo "[get_image] loading $IMAGE <- $tar"
    "$CONTAINER" load -i "$tar"
}

case "${1:-auto}" in
    check)
        have_image && echo "[get_image] image present in store: $IMAGE" \
                   || echo "[get_image] image NOT in local store: $IMAGE"
        _tar="$(resolve_tarball)"
        [ -f "$_tar" ] && echo "[get_image] tarball present: $_tar ($(du -h "$_tar" | cut -f1))" \
                       || echo "[get_image] tarball MISSING: $TARBALL"
        echo "[get_image] store graphroot: $("$CONTAINER" info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo '?')"
        have_image || [ -f "$_tar" ] || exit 1 ;;
    build) do_build ;;
    save)  shift; do_save "${1:-}" ;;
    load)  shift; do_load "${1:-}" ;;
    auto)
        _tar="$(resolve_tarball)"
        if have_image; then
            echo "[get_image] already in local store: $IMAGE"
        elif [ -f "$_tar" ]; then
            do_load "$_tar"
        else
            echo "[get_image] not in store and no tarball ($TARBALL); building once..."
            do_build
            # Seed the tarball so future jobs LOAD instead of rebuilding.
            if do_save "$TARBALL"; then :; else
                echo "[get_image] WARNING: could not write tarball $TARBALL (build kept; set HEPBENCH_IMAGE_TARBALL to writable shared storage)" >&2
            fi
        fi ;;
    ensure-tarball)
        # Submit-node use: jobs each LOAD the tarball into their own store, so the
        # submit node only needs the tarball FILE to exist -- it must NOT touch
        # podman (its default store is often Lustre $HOME, where the overlay
        # driver fails: "a network file system with user namespaces is not
        # supported"). So check the file first, with no container call.
        _tar="$(resolve_tarball)"
        if [ -f "$_tar" ]; then
            echo "[get_image] tarball present: $_tar ($(du -h "$_tar" 2>/dev/null | cut -f1)) -- jobs will load it"
        elif have_image; then
            echo "[get_image] no tarball; saving one from the local store..."
            do_save "$TARBALL"
        else
            echo "[get_image] no tarball ($TARBALL) and no image in store; building once..."
            echo "[get_image] (if this is a login node on a networked FS, build on a"
            echo "[get_image]  node with local-disk podman storage, or set HEPBENCH_PODMAN_DIR"
            echo "[get_image]  to local disk / HEPBENCH_PODMAN_DRIVER=vfs, then ./get_image.sh save)"
            do_build
            do_save "$TARBALL" || echo "[get_image] WARNING: could not write tarball $TARBALL" >&2
        fi ;;
    *) echo "usage: $0 {auto|ensure-tarball|build|save [tar]|load [tar]|check}" >&2; exit 2 ;;
esac
