#!/bin/bash
# Browse the DELPHI Open Data catalog: find recids/nicknames to feed to batch.sh
# or slurm/submit.sh. Queries the opendata.cern.ch records API.
#
# Usage:
#   ./catalog.sh [PATTERN] [--data|--sim] [--limit N]
#
#   PATTERN   substring matched against the nickname/title (e.g. short94, qqps,
#             short9, xsdst98). Omit to list everything matching the type.
#   --data    only real collision data records
#   --sim     only simulation (MC) records
#   --limit N cap rows shown (default 60)
#
# Columns:  recid | nickname | data/sim | EOS area/container | files | size
#
# Examples:
#   ./catalog.sh short9 --data         # LEP1 short-DST data, all years
#   ./catalog.sh qqps_b94 --sim        # the 1994 Z->qqbar MC family
#   ./catalog.sh short94_c2            # exact dataset -> recid for batch.sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
need curl
need python3

PATTERN=""; TYPE=""; LIMIT=60
while [ $# -gt 0 ]; do
    case "$1" in
        --data) TYPE="collision"; shift ;;
        --sim)  TYPE="simulation"; shift ;;
        --limit) LIMIT="${2:?}"; shift 2 ;;
        --*) echo "[catalog] unknown option: $1" >&2; exit 2 ;;
        *) PATTERN="$1"; shift ;;
    esac
done

python3 - "$PATTERN" "$TYPE" "$LIMIT" <<'PY'
import json,sys,urllib.request,urllib.parse
pattern,typ,limit=sys.argv[1],sys.argv[2],int(sys.argv[3])

def fetch(q, maxpages):
    rows=[]; seen=set()
    for page in range(1,maxpages+1):
        u=("https://opendata.cern.ch/api/records/?q="+urllib.parse.quote(q)
           +"&experiment=DELPHI&type=Dataset&size=200&page=%d"%page)
        try:
            hits=json.load(urllib.request.urlopen(u,timeout=50)).get('hits',{}).get('hits',[])
        except Exception as e:
            sys.exit(f"[catalog] API error: {e}")
        if not hits: break
        for h in hits:
            md=h.get('metadata',{}); t=md.get('title','')
            kind = 'data' if 'collision data' in t else ('sim' if 'simulation data' in t else '')
            if not kind: continue
            if typ and typ not in t: continue
            nick = t.split(' data ',1)[-1]
            if pattern and pattern.lower() not in nick.lower(): continue
            rid = md.get('recid')
            if rid in seen: continue
            seen.add(rid)
            uri=next((f.get('uri','') for f in md.get('files',[]) if f.get('uri')),"")
            rel=uri.split('/eos/opendata/delphi/',1)[-1] if uri else ""
            cont="/".join(rel.split('/')[:2])
            nf=len(md.get('files',[])); sz=md.get('distribution',{}).get('size',0)
            rows.append((nick,rid,kind,cont,nf,sz))
    return rows

# 1st try: let the API narrow by the pattern token (fast for full tokens like
# short94, qqps). Fall back to a broad type-scoped fetch + local substring
# filter, which catches partial tokens (e.g. "short9") the search won't tokenize.
rows=[]
if pattern:
    rows=fetch(pattern, 12)
if not rows:
    broad = "collision data" if typ=="collision" else ("simulation data" if typ=="simulation" else (pattern or "data"))
    rows=fetch(broad, 60)
rows.sort(key=lambda r:r[0])
print(f"{'nickname':22s} {'recid':>6s}  {'type':4s} {'eos container':26s} {'files':>5s}  size")
tot_files=tot_sz=0
for nick,rid,kind,cont,nf,sz in rows[:limit]:
    print(f"{nick:22s} {rid:>6}  {kind:4s} {cont:26s} {nf:>5}  {sz/1e9:6.2f} GB")
    tot_files+=nf; tot_sz+=sz
shown=min(len(rows),limit)
print(f"\n{shown} record(s) shown" + (f" (of {len(rows)} matched; raise --limit)" if len(rows)>limit else "")
      + f"  |  {tot_files} files, {tot_sz/1e9:.1f} GB total")
PY
