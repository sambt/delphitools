#!/bin/bash
# Make the converter image (hepbench/delphi-nanoaod:dev) available locally.
#
# Usage:
#   ./get_image.sh                 # auto: use if present, else build
#   ./get_image.sh build           # build from ../sim/Dockerfile.nanoaod
#   ./get_image.sh load <TARBALL>  # docker/podman load from a docker-archive tarball
#   ./get_image.sh check           # just report whether the image is present
#
# The image is built FROM jingyucms/delphi-pythia8:latest (a public docker.io
# pull) and adds ROOT 6.38, FastJet 3.4.3, and the compiled delphi-nanoaod
# converter from github.com/jingyucms/delphi-nanoaod. On a cluster with rootless
# podman, `docker` is usually a podman shim and `build`/`load` work the same; if
# building is slow/disallowed there, build once elsewhere and `load` a tarball
# (see ../sim/image_sync.sh save/load).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

# The Dockerfile + build context live in the parent repo's sim/ dir.
SIM_DIR="${SIM_DIR:-$(cd "$HERE/.." && pwd)/sim}"

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

do_load() {
    tar="${1:?usage: get_image.sh load <tarball.tar>}"
    [ -f "$tar" ] || { echo "[get_image] tarball not found: $tar" >&2; exit 1; }
    echo "[get_image] loading $IMAGE from $tar"
    "$CONTAINER" load -i "$tar"
}

case "${1:-auto}" in
    check)
        if have_image; then echo "[get_image] present: $IMAGE"; else
            echo "[get_image] MISSING: $IMAGE (run ./get_image.sh build|load)"; exit 1; fi ;;
    build) do_build ;;
    load)  shift; do_load "$@" ;;
    auto)
        if have_image; then
            echo "[get_image] already present: $IMAGE"
        else
            echo "[get_image] not present; building..."
            do_build
        fi ;;
    *) echo "usage: $0 {auto|build|load <tar>|check}" >&2; exit 2 ;;
esac
