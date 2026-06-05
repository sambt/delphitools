#!/bin/bash
# Download DELPHI inputs from CERN Open Data (https://opendata.cern.ch)
# via cernopendata-client.
#
# Usage:
#   ./download.sh <dataset> [options]
#
# Datasets (presets resolve to a recid in lib.sh):
#   data        real 1994 hadronic short DST (.al),  recid 81431
#   mc          MC Z->qqbar BAST b-life 1.6 (.al),   recid 81197   (primary)
#   mc-apacic   MC Z->hadrons APACIC (.sdst),        recid 81418   (alt gen)
#   ddb         DDB conditions data (needed for real-data conversion)
#   <number>    any raw CERN Open Data recid
#
# Options:
#   --files N         download the first N files of the record (default 1)
#   --filter NAME     download only files matching NAME (e.g. 'Y13709.170.al');
#                     overrides --files
#   --dest DIR        output directory (default ./samples/<dataset>)
#   --list            just list the files in the record and exit
#
# Examples:
#   ./download.sh data --filter 'Y13709.170.al'
#   ./download.sh mc   --files 4
#   ./download.sh 81431 --list
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
need cernopendata-client "pip install --user cernopendata-client"

DATASET="${1:?usage: download.sh <data|mc|mc-apacic|ddb|RECID> [--files N|--filter NAME] [--dest DIR] [--list]}"
shift || true

N=""; FILTER=""; DEST=""; LIST=0
while [ $# -gt 0 ]; do
    case "$1" in
        --files)  N="$2"; shift 2 ;;
        --filter) FILTER="$2"; shift 2 ;;
        --all)    N="all"; shift ;;
        --dest)   DEST="$2"; shift 2 ;;
        --list)   LIST=1; shift ;;
        *) echo "[download] unknown option: $1" >&2; exit 2 ;;
    esac
done

# Resolve preset -> recid.
case "$DATASET" in
    data)       RECID=$RECID_DATA ;;
    mc)         RECID=$RECID_MC ;;
    mc-apacic)  RECID=$RECID_MC_APACIC ;;
    ddb)
        RECID=$DDB_RECID
        # The DDB needs ALL 7 DB*.dat files, not just the first. Land them
        # under ./ddb/<recid>/ so convert.sh --data finds them automatically.
        [ -n "$DEST" ] || DEST="$HERE/ddb/$RECID"
        [ -n "$N" ] || N="all" ;;
    ''|*[!0-9]*) echo "[download] unknown dataset '$DATASET' (use data|mc|mc-apacic|ddb|<recid>)" >&2; exit 2 ;;
    *) RECID=$DATASET ;;
esac

[ -n "$DEST" ] || DEST="$HERE/samples/$DATASET"

if [ "$LIST" -eq 1 ]; then
    echo "[download] files in recid $RECID:"
    cernopendata-client get-file-locations --recid "$RECID"
    exit 0
fi

mkdir -p "$DEST"
echo "[download] recid=$RECID  dest=$DEST"

# cernopendata-client (1.0.2) downloads into the CWD, creating a <recid>/...
# subtree; there is no --download-dir. So run it from inside $DEST. The
# tr|grep filter drops the per-KiB "Progress:" spam but keeps the summary.
[ -n "$N" ] || N=1                  # default for data/mc presets: first file
if [ -n "$FILTER" ]; then
    echo "[download] filter-name: $FILTER"
    SEL=(--filter-name "$FILTER")
elif [ "$N" = "all" ]; then
    echo "[download] all files in record"
    SEL=()                          # no filter = whole record
else
    echo "[download] first $N file(s) (range 1-$N)"
    SEL=(--filter-range "1-$N")
fi

( cd "$DEST" && cernopendata-client download-files --recid "$RECID" \
    ${SEL[@]+"${SEL[@]}"} 2>&1 | tr '\r' '\n' | grep -vi 'Progress:' ) || true

echo "[download] done. files under $DEST:"
find "$DEST" -type f ! -name '*.filtered' | sort
