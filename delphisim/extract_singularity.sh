#!/bin/bash
set -euo pipefail

# Arguments
NUM_EVENTS=$1
CONFIG_FILE_HOST=$2   # The local config file path
OUTPUT_DIR_ARG=$3     # Where to drop the results on the host

# Path to the Singularity image (.sif). Override with: SIF=/path/to.sif ./extract_singularity.sh ...
SIF="${SIF:-./pythia_delphi_pipeline.sif}"

if [ "$#" -ne 3 ]; then
    echo "Usage: SIF=/path/to/image.sif ./extract_singularity.sh [num_events] [config_file] [output_directory]"
    exit 1
fi

if [ ! -f "$CONFIG_FILE_HOST" ]; then
    echo "Error: Config file $CONFIG_FILE_HOST not found."
    exit 1
fi

if [ ! -f "$SIF" ]; then
    echo "Error: Singularity image $SIF not found. Set SIF=/path/to/image.sif"
    exit 1
fi

# Pick singularity or apptainer, whichever exists
if command -v singularity >/dev/null 2>&1; then
    SING=singularity
elif command -v apptainer >/dev/null 2>&1; then
    SING=apptainer
else
    echo "Error: neither 'singularity' nor 'apptainer' found on PATH."
    exit 1
fi

mkdir -p "$OUTPUT_DIR_ARG"
OUTPUT_DIR_HOST=$(cd "$OUTPUT_DIR_ARG" && pwd)

# Name the output as <config-name-without-extension>_<num-events>.root
CONFIG_NAME=$(basename "$CONFIG_FILE_HOST")
CONFIG_NAME="${CONFIG_NAME%.*}"
OUT_NAME="${CONFIG_NAME}_${NUM_EVENTS}.root"

# Stage the config into the (writable) bound output dir so the container can read it.
cp "$CONFIG_FILE_HOST" "$OUTPUT_DIR_HOST/config_pushed.txt"
CONFIG_INTERNAL="/output/config_pushed.txt"

# The .sif is read-only and the pipeline writes into /work. Back that with a DISK overlay
# image (NOT --writable-tmpfs, which lives in RAM and OOMs on real event counts).
# Created on the same filesystem as the output dir so it has real disk to grow into.
OVERLAY_SIZE_MB="${OVERLAY_SIZE_MB:-8192}"
OVERLAY_IMG="${OVERLAY_IMG:-$OUTPUT_DIR_HOST/.delphi_overlay_$$.img}"

cleanup() {
    rm -f "$OVERLAY_IMG"
}
trap cleanup EXIT

echo "--- Creating ${OVERLAY_SIZE_MB} MB disk overlay ($OVERLAY_IMG) ---"
$SING overlay create --size "$OVERLAY_SIZE_MB" "$OVERLAY_IMG"

echo "--- Running Physics Pipeline ($SING) ---"
# Notes on the flags:
#   --cleanenv        : start from the image's environment, not the host's (matches `docker run`)
#   --overlay <img>   : the .sif is read-only; this disk-backed overlay makes /work writable.
#                       It lives on disk (not RAM), and is discarded on exit, so we copy the
#                       results to the bound /output dir before the shell ends.
#   -B ...:/output    : bind the host output directory in, writable, as /output
$SING exec --cleanenv --overlay "$OVERLAY_IMG" \
    -B "$OUTPUT_DIR_HOST":/output \
    "$SIF" /bin/bash -c "
    cd /work

    # --- 1. SATISFY THE PDL2PDL TRAP ---
    export DELPHI_INSTALL_DIR=/delphi
    export GROUP_DIR=/delphi

    # --- 2. ENVIRONMENT SETUP ---
    export DELPHI_DAT=/delphi/releases/almalinux-9-x86_64/latest/dstana/161018/dat
    export PERL5LIB=/delphi/perl:\${PERL5LIB:-}

    # ROOT and FastJet setup
    source /opt/root/bin/thisroot.sh
    export LD_LIBRARY_PATH=/opt/fastjet/dist/lib:/opt/root/lib:\${LD_LIBRARY_PATH:-}

    # --- 3. RUN THE PIPELINE ---
    echo 'Executing run_pipeline.sh...'
    ./run_pipeline.sh $NUM_EVENTS data /work/ $CONFIG_INTERNAL && \
    echo 'Executing delphi-nanoaod...'
    ./delphi-nanoaod/build/delphi-nanoaod/delphi-nanoaod \
      -C ./delphi-nanoaod/config/delphi-nanoaod.yaml \
      -P my_pdl.pdl -O data.root --mc && \

    # --- 4. EXPORT (overlay is ephemeral, so copy out before we exit) ---
    echo 'Exporting results to /output...' && \
    cp /work/simana_data.sdst /output/ && \
    cp /work/data.root        /output/$OUT_NAME
"

echo "--- Exporting Files ---"
if [ -f "$OUTPUT_DIR_HOST/$OUT_NAME" ]; then
    echo "Success: Files exported to $OUTPUT_DIR_HOST (root file: $OUT_NAME)"
else
    echo "Error: data.root was not found. Check logs for pipeline crashes."
    exit 1
fi
