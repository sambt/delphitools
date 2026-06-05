# delphi_pipeline — standalone DELPHI download + ROOT conversion

A self-contained pipeline that pulls DELPHI SDST files from **CERN Open Data**
and converts them to **ROOT** (delphi-nanoaod RNTuples), for both **real data**
and **MC (sim)**. It reuses the converter image built in the parent repo's
`sim/` but otherwise has no dependency on the rest of hepbench.

> This is the **DELPHI** experiment (LEP) on <https://opendata.cern.ch> — not CMS.

## TL;DR

```bash
# 0. one-time: install the CERN Open Data client
pip install --user cernopendata-client          # see "Install" below

# find what's available (recids, sizes)
./catalog.sh short9 --data

# MC (sim): image + download 2 files + convert every event in each
./run.sh mc --files 2

# Real data: fetch DDB (recid 80509) + one named shard + convert every event
./run.sh data --filter 'Y13709.170.al'

# Bulk, mirroring the EOS layout (local), by nickname:
./batch.sh short94_c2 --dest /data/delphi_root

# Bulk on a SLURM cluster (one slice of files per array task):
slurm/submit.sh short94_c2 --dest $SCRATCH/delphi_root --per-task 4 \
  -- --partition=shared --time=08:00:00
```

Local outputs land in `./out/*.root` (single-file) or under `--dest` mirroring
the EOS path (bulk); downloads in `./samples/<dataset>/`; the conditions
database in `./ddb/80509/`. **For bulk/cluster use, jump to
[Running on a SLURM cluster](#running-on-a-slurm-cluster) and the
[DELPHI data map](#delphi-data-map-what-the-recordsnicknames-mean).**

---

## What converts to ROOT, and where the image comes from

- **Converter:** the `delphi-nanoaod` binary
  ([github.com/jingyucms/delphi-nanoaod](https://github.com/jingyucms/delphi-nanoaod)).
  It reads `.al`/`.sdst` SDSTs through the **SKELANA** Fortran framework
  (common blocks gated by `IFL*` flags in a YAML) and a C++ `NanoAODWriter`
  emits a ROOT **RNTuple** (`Events`) using **ROOT 6.38** + **FastJet 3.4.3**.
- **Image:** `hepbench/delphi-nanoaod:dev`, built `FROM jingyucms/delphi-pythia8`
  (a public docker.io pull) by `../sim/Dockerfile.nanoaod` — which adds ROOT,
  FastJet, and the compiled converter. Get it via `./get_image.sh` (build) or
  `./get_image.sh load <tarball>` (from a cached `docker save` tarball).

---

## Install prerequisites

**1. A container runtime** — `docker` or `podman` (auto-detected; override with
`CONTAINER=…`). On many HPC clusters `docker` is an alias/shim for rootless
`podman` and everything just works; the args used here are common to both.

**2. `cernopendata-client`** (for downloads). It is a standalone CLI, so a
user-level pip install is fine:

```bash
pip install --user cernopendata-client
```

> 📌 **On the cluster, also install the xrootd extra** — plain-HTTP downloads
> from Open Data are slow (~70 MB/min observed). xrootd is much faster for bulk
> pulls, and `batch.sh` will use it automatically when available:
> ```bash
> pip install --user 'cernopendata-client[xrootd]'   # or: pip install --user fsspec-xrootd
> ```

Verify: `cernopendata-client version`.

**3. The converter image:**

```bash
./get_image.sh auto          # build if missing (~17-20 min the first time)
# or, if you have a saved tarball:
./get_image.sh load /path/to/hepbench-delphi-nanoaod-dev.tar
./get_image.sh check         # report whether the image is present
```

On a cluster where building is slow or disallowed, build the image once on a
machine with a daemon, `../sim/image_sync.sh save` a tarball, copy it over, and
`./get_image.sh load <tarball>` there (rootless `podman load` works the same).

---

## Running the conversion pipeline

### Option A — one command, end to end

```bash
./run.sh mc   --files 2                      # 2 MC files, every event each
./run.sh data --filter 'Y13709.170.al'       # 1 data shard; DDB auto-fetched
./run.sh mc   --files 1 --max-events 625     # cap at 625 events
```

`run.sh` does: ensure image → (for data) ensure DDB → download → convert each
downloaded file. By default it converts **every event** in each file.

### Option B — step by step

```bash
# 1. download (-> ./samples/<dataset>/)
./download.sh mc --files 2
./download.sh data --filter 'Y13709.170.al'

# 2. (data only) download the conditions database (-> ./ddb/80509/)
./download.sh ddb

# 3. convert one file (-> ./out/<name>.root, or pass --out PATH.root)
./convert.sh samples/mc/<file>.sdst   --mc                 # -> ./out/<name>.root
./convert.sh samples/data/<file>.al   --data --out /d/x.root
```

Scratch files (`PDLINPUT`, `fort.*`, `T.FSEQ*`) stay inside the container and
are discarded — only the `.root` is written to the output location.

### Option C — bulk conversion, mirroring the EOS layout (recommended for many files)

`batch.sh` downloads + converts a whole record (or a slice of it) into a
destination tree that **mirrors the CERN Open Data EOS path**:

```
/eos/opendata/delphi/<path>/file.al   ->   <DEST>/<path>/file.root
```

```bash
# preview the input -> output mapping without downloading anything
./batch.sh data --dest /data/delphi_root --range 1-5 --dry-run

# convert the first 5 data shards (DDB auto-fetched), every event each
./batch.sh data --dest /data/delphi_root --range 1-5

# convert an entire MC record
./batch.sh mc --dest /data/delphi_root

# a raw recid (mode must be given explicitly)
./batch.sh 81418 --dest /data/delphi_root --mc --filter 'Y.*\.1\.sdst'
```

Per file it stages the input, converts it, writes the mirrored `.root`, then
**deletes the staged input** (pass `--keep-inputs` to keep it). It is
**resumable**: any file whose `.root` already exists is skipped, so a
re-run continues where an interrupted run stopped.

`batch.sh` accepts a **preset** (`data`/`mc`/`mc-apacic`), a raw **recid**, or a
DELPHI **nickname** (e.g. `short94_c2`, `sh_qqps_b94_2l_c2`) which it resolves to
a recid via the Open Data API:

```bash
./batch.sh short94_c2          --dest /data/delphi_root      # real 1994 Z data
./batch.sh sh_qqps_b94_2l_c2   --dest /data/delphi_root      # matched Z->qqbar MC
```

Selection: `--range I-J` (1-based), `--files N`, or `--filter REGEXP`
(default: all files in the record). Run several `--range` shards as separate
processes — or array tasks on a cluster — to parallelize; each file uses its
own container scratch and a distinct output, so shards don't collide.

### Finding what to convert — `catalog.sh`

Discover recids/nicknames and their sizes before committing disk:

```bash
./catalog.sh short9 --data        # LEP1 short-DST data, all years (recids + sizes)
./catalog.sh qqps_b94 --sim       # the 1994 Z->qqbar MC family
./catalog.sh xsdst98 --data       # 1998 extended-short-DST data streams
./catalog.sh short94_c2           # exact dataset -> its recid
```

Columns: `recid | nickname | data/sim | EOS container | files | size`. See the
**DELPHI data map** below for what the nicknames mean and what a mainstream
LEP1 analysis actually needs.

---

## Running on a SLURM cluster

`slurm/submit.sh` converts a whole record (or nickname/recid) as an **array
job** — one slice of files per task — writing the same EOS-mirrored `.root`
tree to your storage area. Because `batch.sh` is resumable, failed/requeued
tasks just pick up where they left off.

```bash
# 1994 Z data: 429 files, 4 per task -> 108 array tasks, <=20 at once
slurm/submit.sh short94_c2 --dest $SCRATCH/delphi_root --per-task 4 \
    -- --partition=shared --account=myacct --time=08:00:00 --mem=4G
```

Tasks use docker/podman (auto-detected; `docker` is usually a podman shim on the
cluster). What `submit.sh` does:
1. resolves the dataset → recid, counts the selected files, and computes the
   array size (`ceil(N / --per-task)`),
2. ensures the image (and, for data, the **DDB**) are present **on the submit
   node once**, so tasks don't each rebuild/redownload,
3. submits `sbatch --array=0-(K-1)%<max-concurrent>` with everything exported.

Key options: `--per-task N` (files/task, default 4), `--max-concurrent M`
(default 20), `--range`/`--filter` to do a subset, `--keep-inputs`,
`--max-events`, `--logdir`. **Anything after `--` is passed straight to
`sbatch`** (partition, account, time, memory, QOS, …) — the `#SBATCH` lines in
`slurm/convert.sbatch` are only conservative defaults. Add `--dry-run` to print
the array sizing and exact `sbatch` command without submitting.

Tips for large campaigns:
- Tune `--per-task` so each task runs a sensible wall-time (conversion is a few
  minutes/file natively, more under emulation). 1 file/task = maximal
  parallelism but more scheduling overhead.
- Re-submitting the same command after a partial run only fills in missing
  `.root` files (resumability), so it doubles as a "retry failures" pass.
- Staging (`<dest>/.staging`) and inputs are deleted as files convert; only the
  `.root` tree and `<dest>/_logs` remain.

---

## DELPHI data map (what the records/nicknames mean)

A practical guide to navigating the ~12,700 DELPHI Open Data records.

**recID / nickname.** Each Open Data **record** (recid) is one DELPHI dataset,
identified by a **nickname** in its title (`DELPHI collision data <nick>` or
`DELPHI simulation data <nick>`). Both data and MC have recids. Select by
nickname/recid — `catalog.sh` finds them.

**Real-data streams** (nickname prefix), per year `YY`. A nickname encodes the
DST **format** and the event **stream**; the record's own description spells it
out (`catalog.sh` shows the nickname, and the Open Data record page the prose,
e.g. *"Short DSTs, 'OR' of the physics teams"*).

| Prefix | Meaning |
|---|---|
| `rawd<YY>` | RAW data — huge (28–390 GB/yr), under `raw-data/`. You almost never want this. |
| `short<YY>` / `xshort<YY>` | **short DST, "OR" of the physics teams** — the INCLUSIVE LEP1 stream (hadronic **and** leptonic). The main analysis dataset (`x` = extended). |
| `xsdst<YY>` | **extended short DST** — the main LEP2 analysis format (inclusive). |
| `long<YY>` | full **long DST**, "OR" of teams (more per-event detail; inclusive). |
| `lolept<YY>` | **Long-DST of the LEPTONIC events** — dedicated, more-detailed leptonic stream (the leptonic events are *also* in `short<YY>`). |
| `hadr<YY>` / `lept<YY>` | LEP2 explicit **hadronic** / **leptonic** streams. `dsto<YY>` = DST output. |
| `scan`, `stic`, `alld` | energy-scan runs, STIC luminosity stream, "all data". |

> **There is no "hadronic-only" short DST at LEP1.** `short<YY>` is the union of
> all physics teams' selections, so Z→μμ/ee/ττ are already in it. Use `short<YY>`
> for inclusive analyses; reach for `lolept<YY>` only if you want the richer
> Long-DST reconstruction of the leptonic subset.

Trailing tags: `_c1/_c2/_d2/_e1/_e2` = processing/reprocessing version; `z` =
data at the Z peak (e.g. `dsto00z`); `e183/e192/e196/e200/e202` = √s in GeV
(LEP2). Year → energy: **'91–'95 ≈ 91.2 GeV (Z peak)**; **'96 = 161/172**,
**'97 = 183**, **'98 = 189**, **'99 = 192–202**, **'00 = ~204–209 GeV**.

**EOS containers (`Y#####` / `R#####`).** Opaque storage-bucket IDs — **no
physics meaning**. The year/energy is in the nickname, not the container; the
same year can span several containers by processing (`short92_d2`→`Y10055`,
`short92_e2`→`Y13723`). `Y` vs `R` only tracks the production generation (all
LEP1 is `Y…`; later LEP2 reprocessings are `R…`). `batch.sh` resolves the
container for you — never navigate by it.

**Simulation (MC).** Nickname encodes generator + channel + conditions, e.g.
`sh_qqps_b94_2l_c2` = PYTHIA parton-shower **Z→qq̄**, 1994 conditions, matching
data's `short94_c2`. Others: `sh_kk2f…` (KK2f), `sh_apacic…` (APACIC shower),
`sh_wphact…` (4-fermion), `sh_hzha…`/`pythia…yuk…` (Higgs searches),
`eeqq/eemm/lvqq/llll/…` (4-fermion & 2-photon). `lo_*` = long-DST sim.
The `simulated-data/{cern,karlsruhe,wupp,…}` subfolders are just the **production
site** (storage origin), not a physics difference. DELPHI produced MC matched to
each year's conditions, so for a measurement you pair the MC processing tag with
the data processing tag.

**What a mainstream LEP1 analysis needs.** The flagship DELPHI results (Z
lineshape, R_b/R_c, α_s, event shapes, fragmentation) use **LEP1, Z-peak data,
1992–1995** (1990 is RAW-only, 1991 lower stats):

- **Real data:** `short92`–`short95` (inclusive short DST — hadronic **and**
  leptonic) — order ~100 GB total. Ready-made: `./submit_lep1_core.sh`.
- **Hadronic MC:** matched `sh_qqps_*9X` (Z→qq̄) — `./submit_lep1_mc.sh`.
- **Leptonic MC** (Z→μμ `lo_dymu_*`, Z→ττ KORALZ `lo_kora_*`/`lo_koz4_*`,
  Z→ee Bhabha `lo_baba_*`) — `./submit_lep1_mc_leptonic.sh`. Optional, for
  di-lepton analyses; not all year/channel combos exist on Open Data (see the
  script header for the gaps, e.g. 1992 has only Z→μμ).
- **Skip:** `rawd*`, all of LEP2 (`96`–`00`) unless doing W/Higgs/high-energy,
  and the thousands of Higgs/SUSY-scan MC records.

So you do **not** need the full catalog — a handful of records (tens to a few
hundred GB of `.al`, less as `.root`) covers core 90s physics. The matched
**Z→qq̄ MC tune letter varies by year** (`k` for '92/'93, `b` for '94/'95) —
`submit_lep1_mc.sh` pins the verified per-year recids; `catalog.sh qqps --sim`
shows alternatives.

---

## Event counting: "exactly every event", and the `--max-events` story

**Short answer: the default mode already gives you exactly every event in the
file — no more, no fewer — and you do not need `--max-events`.**

Why `--max-events` exists at all, and why the parent repo treats it as
mandatory, comes down to *how the input file is handed to the framework:

- **The DELPHI way (what this pipeline does by default).** The framework is
  told which files to read via a **`PDLINPUT` control file** containing a
  `FILE = <path>` line (per the
  [CERN Open Data DELPHI analysis guide](https://opendata.cern.ch/docs/delphi-guide-analysis)).
  Fed this way, PHDST opens the file, reads it **once**, and **stops cleanly at
  end of file**. `convert.sh` writes that control file for you, so the output
  contains precisely the events in the input.

- **The parent-repo way (`--legacy` here).** The repo wrappers instead symlink
  the raw data file straight onto `T.FSEQ1` (PHDST's Fortran sequential unit 1)
  with no PDL config. In that fallback PHDST **rewinds at EOF and re-reads the
  file from the top, indefinitely**. The only thing that stops it is the
  converter's own per-event check — in
  [`phdst_analysis.cpp`](https://github.com/jingyucms/delphi-nanoaod/blob/main/delphi-analysis/src/phdst_analysis.cpp):

  ```cpp
  if (maxEventsToProcess_ > 0 && NEVENT > maxEventsToProcess_) {
      std::cout << "...Reached maximum number of events" << std::endl;
      return -3;            // -3 tells PHDST to stop
  }
  ```

  So in `--legacy` mode `--max-events` is the *only* brake, and it is sharp on
  both sides:
  - too **low**  → output is truncated (fewer events than the file holds);
  - too **high** → output has **duplicate** events (it re-read from event 1);
  - exactly the file's event count → every event, once.

  Because CERN Open Data does **not** publish per-file event counts (the record
  page gives only a dataset-wide total), you can't pick that exact number ahead
  of time. That is exactly why "stop at EOF" (the default mode) is the right
  way to get every event, and why the repo had to cap with `--max-events`.

**Practical guidance**

| You want | Do this |
|---|---|
| Every event in the file | default — just omit `--max-events` |
| A quick sample of N events | `--max-events N` |
| Reproduce the repo's behaviour | `--legacy [N]` (N defaults to 5000) |

After a default-mode run, the converter log should **not** print
"Reached maximum number of events" — if it doesn't, the job stopped at EOF and
you have the full file.

> ⚠️ If your image's PHDST does not honour the `FILE =` control file (older
> builds may not), fall back to `--legacy` and set `--max-events` to a value at
> or below the true event count to avoid duplicates.

---

## The DDB conditions database (real data only)

Real-data conversion (`--data`) needs DELPHI's **conditions database (DDB)**,
bind-mounted into the container at `/eos/opendata/delphi/condition-data`.

It **is** a CERN Open Data record and is pullable with the same client:

- **recid `80509`** — *"DELPHI conditions databases"*
  (DOI `10.7483/OPENDATA.DELPHI.18JY.GL8K`)
- 7 files, ~3.0 GiB: `DBcalb.dat`, `DBgeom.dat`, `DBlepm.dat`, `DBmisc.dat`,
  `DBrunt.dat`, `DBscon.dat`, `DBsysf.dat`
- served at `root://eospublic.cern.ch//eos/opendata/delphi/condition-data/`

```bash
./download.sh ddb                  # -> ./ddb/80509/   (where convert.sh looks)
# equivalently, by hand:
cernopendata-client download-files --recid 80509 --download-dir ./ddb/80509
# or list it first:
cernopendata-client list-directory /eos/opendata/delphi/condition-data
```

`convert.sh --data` finds the DDB automatically by locating `DBcalb.dat` under
`./ddb`; override with `DDB_DIR=/path/to/condition-data`. (The directory name
`80509` is the **recid**, not a run period — the upstream `docs/SETUP.md`
labelling is misleading on this point.) MC conversion needs no DDB.

---

## Datasets (presets in `lib.sh`)

| Preset | recid | Format | What |
|---|---|---|---|
| `data` | 81431 | `.al` | Real 1994 hadronic short DST (`Y13709.*`/`Y13710.*`) |
| `mc` | 81197 | `.al` | MC Z→qq̄ BAST, b-life 1.6 tune (primary reference) |
| `mc-apacic` | 81418 | `.sdst` | MC Z→hadrons APACIC (alternative generator) |
| `ddb` | 80509 | `.dat` | DELPHI conditions database (needed for real data) |

`./download.sh <recid> --list` lists the files in any record.

---

## The scripts

| Script | Does |
|---|---|
| `catalog.sh`   | Browse the DELPHI Open Data catalog → find recids/nicknames + sizes. |
| `get_image.sh` | Build / load / check the `hepbench/delphi-nanoaod:dev` image. |
| `download.sh`  | Pull files from CERN Open Data by dataset preset or raw recid. |
| `convert.sh`   | Convert one `.al`/`.sdst` → `.root` (`--data`/`--mc`; stops at EOF; `--out PATH`). |
| `batch.sh`     | Bulk download+convert a record/nickname, mirroring EOS layout; resumable. |
| `slurm/submit.sh` | Submit a record as a SLURM array job (one slice of files per task). |
| `slurm/convert.sbatch` | The array-task body (calls `batch.sh --range`). |
| `run.sh`       | Simple one-dataset orchestrate: image → DDB → download → convert to `./out`. |
| `cluster_smoketest.sh` | One-shot sanity check on a new machine: convert 1 data + 1 MC file. |
| `submit_lep1_core.sh` | Submit the full 1992–1995 LEP1 short-DST **data** conversion as SLURM jobs. |
| `submit_lep1_mc.sh` | Submit the matched 1992–1995 Z→qq̄ (hadronic) **MC** as SLURM jobs. |
| `submit_lep1_mc_leptonic.sh` | Submit the 1992–1995 leptonic **MC** (Z→μμ/ττ/ee) as SLURM jobs. |
| `lib.sh`       | Shared config (recids), docker/podman detection, `run_in_image`. |

## Notes / gotchas

- **Anything below the SDST layer is gone** (raw hits, per-cell calo, per-photon
  RICH). The `.root` is reconstructed-level. See `../docs/SCHEMA.md`.
- **Calibrated variant:** to enable `IFLENR`/`IFLRNQ`, mount a custom YAML and
  pass `-C` to it — see `../sim/nanoaod_calib/` for that pattern.
- **Overrides:** image name `IMAGE=...`; runtime `CONTAINER=podman`; DDB
  location `DDB_DIR=...`; DDB recid `DDB_RECID=...`.

## Sources

- [CERN Open Data — DELPHI analysis guide (PDLINPUT / `FILE =`)](https://opendata.cern.ch/docs/delphi-guide-analysis)
- [delphi-nanoaod `phdst_analysis.cpp` (max-events / `-3` stop)](https://github.com/jingyucms/delphi-nanoaod/blob/main/delphi-analysis/src/phdst_analysis.cpp)
- [CERN Open Data record 80509 — DELPHI conditions databases](https://opendata.cern.ch/record/80509)
- [cernopendata-client CLI (`download-files`, `list-directory`, `--protocol xrootd`)](https://cernopendata-client.readthedocs.io/en/latest/cliapi.html)
