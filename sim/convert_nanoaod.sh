#!/bin/bash
# Convert a DELPHI .sdst to delphi-nanoaod ROOT RNTuple.
# Usage:  convert_nanoaod <input.sdst> <output.root> [--mc|--data] [max_events]
#
# --max-events is REQUIRED: without it the PHDST T.FSEQ1 fallback rewinds
# at EOF and re-reads the file ~500x, blowing the .root up to >1 GB.
set -e
IN=${1:?usage: convert_nanoaod <input.sdst> <output.root> [--mc|--data] [max_events]}
OUT=${2:?usage: convert_nanoaod <input.sdst> <output.root> [--mc|--data] [max_events]}
MODE=${3:---mc}
MAXEV=${4:-5000}

ln -sf "$IN" /work/T.FSEQ1

/nanoaod/build/delphi-nanoaod/delphi-nanoaod \
    --pdlinput "$IN" \
    -C /nanoaod/config/delphi-nanoaod.yaml \
    --output "$OUT" \
    --max-events "$MAXEV" \
    $MODE

ls -lh "$OUT"
