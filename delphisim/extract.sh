#!/bin/bash

# Arguments
NUM_EVENTS=$1
CONFIG_FILE_HOST=$2  # The local config file path
OUTPUT_DIR_HOST=$(readlink -f "$3")

# Hardcoded Internal Settings
PREFIX="data"
CONFIG_INTERNAL="/work/config_pushed.txt"

if [ "$#" -ne 3 ]; then
    echo "Usage: ./myscript.sh [num_events] [config_file] [output_directory]"
    exit 1
fi

if [ ! -f "$CONFIG_FILE_HOST" ]; then
    echo "Error: Config file $CONFIG_FILE_HOST not found."
    exit 1
fi

mkdir -p "$OUTPUT_DIR_HOST"

echo "--- Starting Container (Rootless) ---"
CONTAINER_ID=$(podman run -d --entrypoint /bin/bash delphi-complete:v2 -c "tail -f /dev/null")

echo "--- Transferring Config File ---"
# Manually push the host file into the container instead of mounting
podman cp "$CONFIG_FILE_HOST" "$CONTAINER_ID:$CONFIG_INTERNAL"

echo "--- Running Physics Pipeline ---"
podman exec -w /work "$CONTAINER_ID" /bin/bash -c "
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
if podman exec "$CONTAINER_ID" /bin/bash -c "[[ -f /work/data.root ]]"; then
    podman cp "$CONTAINER_ID:/work/simana_data.sdst" "$OUTPUT_DIR_HOST/"
    podman cp "$CONTAINER_ID:/work/data.root" "$OUTPUT_DIR_HOST/"
    echo "Success: Files exported to $OUTPUT_DIR_HOST"
else
    echo "Error: data.root was not found. Check logs for pipeline crashes."
fi

echo "--- Cleaning Up ---"
podman stop -t 1 "$CONTAINER_ID" > /dev/null
podman rm "$CONTAINER_ID" > /dev/null
