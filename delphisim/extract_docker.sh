#!/bin/bash
set -euo pipefail

# Arguments
NUM_EVENTS=$1
CONFIG_FILE_HOST=$2  # The local config file path

# Hardcoded Internal Settings
IMAGE="alqanb/pythia_delphi_pipeline"
CONFIG_INTERNAL="/work/config_pushed.txt"

if [ "$#" -ne 3 ]; then
    echo "Usage: ./extract_docker.sh [num_events] [config_file] [output_directory]"
    exit 1
fi

if [ ! -f "$CONFIG_FILE_HOST" ]; then
    echo "Error: Config file $CONFIG_FILE_HOST not found."
    exit 1
fi

mkdir -p "$3"
# Portable absolute path (macOS lacks GNU `readlink -f`)
OUTPUT_DIR_HOST=$(cd "$3" && pwd)

# Name the output as <config-name-without-extension>_<num-events>.root
CONFIG_NAME=$(basename "$CONFIG_FILE_HOST")
CONFIG_NAME="${CONFIG_NAME%.*}"
OUT_NAME="${CONFIG_NAME}_${NUM_EVENTS}.root"

echo "--- Starting Container ---"
CONTAINER_ID=$(docker run -d --entrypoint /bin/bash "$IMAGE" -c "tail -f /dev/null")

# Always clean up the container, even on error
cleanup() {
    echo "--- Cleaning Up ---"
    docker stop -t 1 "$CONTAINER_ID" > /dev/null 2>&1 || true
    docker rm "$CONTAINER_ID" > /dev/null 2>&1 || true
}
trap cleanup EXIT

echo "--- Transferring Config File ---"
# Manually push the host file into the container instead of mounting
docker cp "$CONFIG_FILE_HOST" "$CONTAINER_ID:$CONFIG_INTERNAL"

echo "--- Running Physics Pipeline ---"
docker exec -w /work "$CONTAINER_ID" /bin/bash -c "
    # --- 1. SATISFY THE PDL2PDL TRAP ---
    export DELPHI_INSTALL_DIR=/delphi
    export GROUP_DIR=/delphi

    # --- 2. ENVIRONMENT SETUP ---
    export DELPHI_DAT=/delphi/releases/almalinux-9-x86_64/latest/dstana/161018/dat
    export PERL5LIB=/delphi/perl:\$PERL5LIB

    # ROOT and FastJet setup
    source /opt/root/bin/thisroot.sh
    export LD_LIBRARY_PATH=/opt/fastjet/dist/lib:/opt/root/lib:\$LD_LIBRARY_PATH

    # --- 3. RUN THE PIPELINE ---
    echo 'Executing run_pipeline.sh...'
    ./run_pipeline.sh $NUM_EVENTS data /work/ $CONFIG_INTERNAL && \
    echo 'Executing delphi-nanoaod...'
    ./delphi-nanoaod/build/delphi-nanoaod/delphi-nanoaod \
      -C ./delphi-nanoaod/config/delphi-nanoaod.yaml \
      -P my_pdl.pdl -O data.root --mc
"

echo "--- Exporting Files ---"
if docker exec "$CONTAINER_ID" /bin/bash -c "[[ -f /work/data.root ]]"; then
    docker cp "$CONTAINER_ID:/work/simana_data.sdst" "$OUTPUT_DIR_HOST/"
    docker cp "$CONTAINER_ID:/work/data.root" "$OUTPUT_DIR_HOST/$OUT_NAME"
    echo "Success: Files exported to $OUTPUT_DIR_HOST (root file: $OUT_NAME)"
else
    echo "Error: data.root was not found. Check logs for pipeline crashes."
    exit 1
fi
