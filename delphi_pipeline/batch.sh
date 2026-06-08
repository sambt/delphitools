#!/bin/bash
# Bulk download + convert a whole DELPHI record to ROOT, mirroring the CERN
# Open Data EOS path structure under a destination directory.
#
#   /eos/opendata/delphi/<path>/file.al   ->   <DEST>/<path>/file.root
#
# e.g.  .../delphi/collision-data/Y10638/Y10638.1.al
#         ->  <DEST>/collision-data/Y10638/Y10638.1.root
#
# Per file it: downloads the .al/.sdst to a staging area, converts it (default
# stop-at-EOF = every event), writes the .root to its mirrored path, then
# deletes the staged input (unless --keep-inputs). It is RESUMABLE: a file
# whose .root already exists (non-empty) is skipped, so re-running continues
# where it left off.
#
# Usage:
#   ./batch.sh <dataset|recid> --dest DIR [--data|--mc] [selection] [options]
#
# dataset presets (imply the mode): data | mc | mc-apacic   (see lib.sh)
# raw recid: also pass --data or --mc explicitly.
#
# Selection (default: ALL files in the record):
#   --range I-J       files I..J in the record's file list (1-based)
#   --files N         the first N files
#   --filter REGEXP   only files whose name matches the egrep pattern
#
# Options:
#   --dest DIR        REQUIRED. Top-level output dir; EOS structure mirrored under it.
#   --by-type         prefix the mirrored path with data/ or mc/ -- DELPHI stores
#                     its official sim under collision-data/ alongside real data,
#                     so without this the qqps MC and data are indistinguishable
#                     by path. (APACIC sim is already under simulated-data/.)
#   --keep-inputs     keep the staged .al/.sdst after conversion (default: delete)
#   --max-events N    cap events per file (default: all / stop at EOF)
#   --stage DIR       staging dir for downloads (default: <DEST>/.staging)
#   --dry-run         print the planned <input> -> <output.root> mapping, do nothing
#
# Parallelism: run independent shards as separate processes, e.g.
#   ./batch.sh data --dest /d --range 1-100  &
#   ./batch.sh data --dest /d --range 101-200 &
# (each file uses its own container scratch + distinct output, so shards are
# safe to run concurrently; on a cluster, map --range onto array tasks.)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

DATASET="${1:?usage: batch.sh <dataset|recid> --dest DIR [--data|--mc] [--by-type] [--range I-J|--files N|--filter RE] [--keep-inputs] [--max-events N] [--check[-events]] [--dry-run]}"
shift || true

MODE=""; DEST=""; STAGE=""; RANGE=""; NFILES=""; FILTER=""
KEEP=0; DRY=0; COUNT=0; MAXEV=""; BYTYPE=0; CHECK=0; CHECKEV=0
while [ $# -gt 0 ]; do
    case "$1" in
        --data) MODE="--data"; shift ;;
        --mc)   MODE="--mc";   shift ;;
        --dest) DEST="${2:?--dest needs a dir}"; shift 2 ;;
        --stage) STAGE="${2:?--stage needs a dir}"; shift 2 ;;
        --range) RANGE="${2:?--range needs I-J}"; shift 2 ;;
        --files) NFILES="${2:?--files needs N}"; shift 2 ;;
        --filter) FILTER="${2:?--filter needs a regexp}"; shift 2 ;;
        --max-events) MAXEV="${2:?--max-events needs a number}"; shift 2 ;;
        --keep-inputs) KEEP=1; shift ;;
        --by-type) BYTYPE=1; shift ;;  # prefix outputs with data/ or mc/ (the EOS
                                       # layout doesn't separate official sim from data)
        --check) CHECK=1; shift ;;       # report which expected .root exist; convert nothing
        --check-events) CHECK=1; CHECKEV=1; shift ;;  # ...and open each to verify >0 events
        --dry-run) DRY=1; shift ;;
        --count) COUNT=1; shift ;;   # print N selected files and exit (for slurm/submit.sh)
        *) echo "[batch] unknown option: $1" >&2; exit 2 ;;
    esac
done
[ "$COUNT" -eq 1 ] || [ -n "$DEST" ] || { echo "[batch] --dest DIR is required" >&2; exit 2; }
[ -n "$DEST" ] || DEST="/tmp/_batch_count"   # placeholder; --count never writes

# Resolve a DELPHI nickname (e.g. short94_c2, sh_qqps_b94_2l_c2) -> recid + mode
# via the Open Data API. Echoes "<recid> <--data|--mc>".
resolve_nick() {
    need curl
    python3 - "$1" <<'PY'
import json,sys,urllib.request,urllib.parse
nick=sys.argv[1]
u="https://opendata.cern.ch/api/records/?q="+urllib.parse.quote(nick)+"&experiment=DELPHI&size=50&type=Dataset"
try:
    hits=json.load(urllib.request.urlopen(u,timeout=40)).get('hits',{}).get('hits',[])
except Exception as e:
    sys.exit(f"resolve error: {e}")
want=[("DELPHI collision data "+nick,"--data"),("DELPHI simulation data "+nick,"--mc")]
for h in hits:
    t=h.get('metadata',{}).get('title','')
    for title,mode in want:
        if t==title:
            print(h['metadata']['recid'],mode); sys.exit(0)
sys.exit(f"no exact DELPHI record for nickname '{nick}' (try ./catalog.sh '{nick}')")
PY
}

# Resolve dataset preset / nickname / recid -> recid + implied mode.
case "$DATASET" in
    data)       RECID=$RECID_DATA;      MODE="${MODE:---data}" ;;
    mc)         RECID=$RECID_MC;        MODE="${MODE:---mc}" ;;
    mc-apacic)  RECID=$RECID_MC_APACIC; MODE="${MODE:---mc}" ;;
    '') echo "[batch] missing dataset" >&2; exit 2 ;;
    *[!0-9]*)   # non-numeric, non-preset -> treat as a nickname, resolve via API
        r="$(resolve_nick "$DATASET")" || { echo "[batch] $r" >&2; exit 2; }
        RECID="${r% *}"; MODE="${MODE:-${r#* }}"
        echo "[batch] nickname '$DATASET' -> recid $RECID ($MODE)" ;;
    *) RECID=$DATASET ;;
esac
[ -n "$MODE" ] || { echo "[batch] raw recid needs --data or --mc" >&2; exit 2; }
[ -n "$STAGE" ] || STAGE="$DEST/.staging"

# --by-type: prefix outputs with data/ or mc/ so the (official) simulation that
# EOS stores under collision-data/ alongside real data is still distinguishable.
TYPEPFX=""
if [ "$BYTYPE" -eq 1 ]; then
    case "$MODE" in --data) TYPEPFX="data/";; --mc) TYPEPFX="mc/";; esac
fi

need cernopendata-client "pip install --user cernopendata-client"

# ---- gather + select the file list (EOS-relative paths) --------------------
# get-file-locations prints URLs like
#   http://opendata.cern.ch/eos/opendata/delphi/collision-data/Y10638/Y10638.1.al
# strip through /eos/opendata/delphi/ to get the mirror-relative path.
echo "[batch] recid=$RECID  mode=$MODE  dest=$DEST"
ALL="$(cernopendata-client get-file-locations --recid "$RECID" \
        | sed -E 's#^.*/eos/opendata/delphi/##' )"

# apply selection
SEL="$ALL"
[ -n "$FILTER" ] && SEL="$(printf '%s\n' "$SEL" | grep -E "$FILTER" || true)"
if [ -n "$RANGE" ]; then
    I="${RANGE%-*}"; J="${RANGE#*-}"
    SEL="$(printf '%s\n' "$SEL" | sed -n "${I},${J}p")"
elif [ -n "$NFILES" ]; then
    SEL="$(printf '%s\n' "$SEL" | head -n "$NFILES")"
fi
SEL="$(printf '%s\n' "$SEL" | sed '/^$/d')"
TOTAL="$(printf '%s\n' "$SEL" | grep -c . || true)"
if [ "$COUNT" -eq 1 ]; then echo "$TOTAL"; exit 0; fi
[ "$TOTAL" -gt 0 ] || { echo "[batch] no files selected" >&2; exit 1; }
echo "[batch] selected $TOTAL / $(printf '%s\n' "$ALL" | grep -c .) file(s)"

# ---- dry run: just show the mapping ----------------------------------------
if [ "$DRY" -eq 1 ]; then
    echo "[batch] dry-run mapping (input EOS path -> output .root):"
    printf '%s\n' "$SEL" | while IFS= read -r rel; do
        case "$rel" in *.al) o="${rel%.al}.root";; *.sdst) o="${rel%.sdst}.root";; *) o="$rel.root";; esac
        printf '   /eos/opendata/delphi/%s\n      -> %s/%s%s\n' "$rel" "$DEST" "$TYPEPFX" "$o"
    done
    exit 0
fi

# ---- check mode: report which expected .root exist; convert nothing ---------
if [ "$CHECK" -eq 1 ]; then
    [ "$CHECKEV" -eq 1 ] && "$HERE/get_image.sh" auto >/dev/null   # needed to open files
    present=0; MISS=()
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in *.al) outrel="${rel%.al}.root";; *.sdst) outrel="${rel%.sdst}.root";; *) outrel="$rel.root";; esac
        out="$DEST/$TYPEPFX$outrel"
        if [ ! -s "$out" ]; then MISS+=("$TYPEPFX$outrel  (missing)"); continue; fi
        if [ "$CHECKEV" -eq 1 ]; then
            d="$(cd "$(dirname "$out")" && pwd)"; b="$(basename "$out")"
            MOUNTS=("$(to_mount_path "$d"):/w:ro")
            INNER="cd /w && python3 -c \"import ROOT;print(ROOT.RNTupleReader.Open('Events','$b').GetNEntries())\""
            ne="$(run_in_image 2>/dev/null | tr -dc '0-9\n' | grep -E '^[0-9]+$' | tail -1 || true)"
            if [ -z "$ne" ] || [ "$ne" -eq 0 ]; then MISS+=("$TYPEPFX$outrel  (0 events / unreadable)"); continue; fi
        fi
        present=$((present+1))
    done < <(printf '%s\n' "$SEL")
    echo "[batch] check ($DATASET): $present/$TOTAL present, ${#MISS[@]} missing/bad -> $DEST/$TYPEPFX"
    if [ ${#MISS[@]} -gt 0 ]; then
        printf '   %s\n' "${MISS[@]}"
        exit 1
    fi
    echo "[batch] all $TOTAL files present."
    exit 0
fi

# ---- ensure image (+ DDB for data) -----------------------------------------
"$HERE/get_image.sh" auto
if [ "$MODE" = "--data" ] && [ -z "${DDB_DIR:-}" ]; then
    # The DDB needs all 7 DB*.dat files; a partial download must not pass.
    ndb="$(find "$HERE/ddb" -name 'DB*.dat' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$ndb" -lt 7 ]; then
        echo "[batch] DDB incomplete ($ndb/7 files); downloading (recid $DDB_RECID, ~3 GB)..."
        "$HERE/download.sh" ddb
    fi
fi

# ---- the loop --------------------------------------------------------------
mkdir -p "$DEST"
n=0; ok=0; skip=0; fail=0
printf '%s\n' "$SEL" | { while IFS= read -r rel; do
    n=$((n+1))
    base="$(basename "$rel")"
    reldir="$(dirname "$rel")"
    case "$rel" in *.al) outrel="${rel%.al}.root";; *.sdst) outrel="${rel%.sdst}.root";; *) outrel="$rel.root";; esac
    out="$DEST/$TYPEPFX$outrel"

    if [ -s "$out" ]; then
        echo "[batch] ($n/$TOTAL) skip (exists): $outrel"; skip=$((skip+1)); continue
    fi
    echo "[batch] ($n/$TOTAL) $rel"

    # download into staging (cernopendata-client writes <cwd>/<recid>/<base>)
    sdir="$STAGE/$reldir"; mkdir -p "$sdir"
    if [ ! -s "$sdir/$base" ]; then
        ( cd "$sdir" && cernopendata-client download-files --recid "$RECID" --filter-name "$base" 2>&1 \
            | tr '\r' '\n' | grep -vi 'Progress:' ) || true
        # client nests under ./<recid>/ -- flatten to $sdir/$base
        if [ ! -s "$sdir/$base" ]; then
            found="$(find "$sdir" -name "$base" -type f 2>/dev/null | head -1)"
            [ -n "$found" ] && mv "$found" "$sdir/$base"
        fi
    fi
    if [ ! -s "$sdir/$base" ]; then
        echo "[batch]   ! download failed: $base" >&2; fail=$((fail+1)); continue
    fi

    # convert -> mirrored .root
    if "$HERE/convert.sh" "$sdir/$base" "$MODE" --out "$out" ${MAXEV:+--max-events "$MAXEV"}; then
        ok=$((ok+1))
        [ "$KEEP" -eq 1 ] || rm -f "$sdir/$base"
    else
        echo "[batch]   ! convert failed: $base" >&2; fail=$((fail+1))
    fi
done
echo "[batch] done. ok=$ok skip=$skip fail=$fail total=$TOTAL"
# tidy empty staging dirs
find "$STAGE" -type d -empty -delete 2>/dev/null || true
}
