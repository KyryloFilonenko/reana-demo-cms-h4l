# Running the Level 4 analysis on REANA

Level 3 processes a single AOD file and draws the one Higgs candidate it finds
as a single marker on top of pre-made Monte Carlo histograms. Level 4 processes
**every file of all six CMS collision datasets** — 12 306 AOD files, roughly 43
TB read over XRootD — so the observed data becomes a full histogram and the
result reproduces the published CMS reference plot.

| Dataset                                     | recid | Files | Validation JSON |
| ------------------------------------------- | ----- | ----- | --------------- |
| `/DoubleMu/Run2011A-12Oct2013-v1/AOD`       | 17    | 1378  | 2011 (7 TeV)    |
| `/DoubleElectron/Run2011A-12Oct2013-v1/AOD` | 16    | 1697  | 2011 (7 TeV)    |
| `/DoubleMuParked/Run2012B-22Jan2013-v1/AOD` | 6004  | 2279  | 2012 (8 TeV)    |
| `/DoubleMuParked/Run2012C-22Jan2013-v1/AOD` | 6030  | 2920  | 2012 (8 TeV)    |
| `/DoubleElectron/Run2012B-22Jan2013-v1/AOD` | 6003  | 1643  | 2012 (8 TeV)    |
| `/DoubleElectron/Run2012C-22Jan2013-v1/AOD` | 6029  | 2389  | 2012 (8 TeV)    |

The files of each dataset are split into chunks of at most 320 files (43 chunks
in total), and each chunk is processed by one job. The chunk size comes from a
measured 45 s per file, which puts a chunk at about 4 hours. The full workflow
is 53 steps: 43 `analyze_chunk` jobs, 6 per-dataset merges, 2 era combinations
(2012 B+C), one CMSSW build and the final plot.

The 43 `analyze_chunk` jobs run on **CERN HTCondor**, which offers far more
parallel slots than the Kubernetes quota. The short steps stay on Kubernetes.

## 1. Prerequisites

- A REANA account at <https://reana.cern.ch> and its access token
- A CERN computing account (needed for the HTCondor backend)

```bash
git clone https://github.com/KyryloFilonenko/reana-demo-cms-h4l.git
cd reana-demo-cms-h4l

python3 -m venv ~/.virtualenvs/myreana
source ~/.virtualenvs/myreana/bin/activate
pip install reana-client

export REANA_SERVER_URL=https://reana.cern.ch/
export REANA_ACCESS_TOKEN=<your-token>

reana-client ping   # verify the connection and token
```

## 2. Kerberos credentials for HTCondor

CERN HTCondor authenticates with a Kerberos keytab. This is a one-time setup;
without it no HTCondor job will start. On `lxplus.cern.ch`:

```bash
cern-get-keytab --keytab ~/.keytab --user --login <your-cern-login>
kdestroy; kinit -kt ~/.keytab <your-cern-login>; klist   # verify
```

Copy `~/.keytab` to the machine running `reana-client`, then upload it:

```bash
reana-client secrets-add --env CERN_USER=<your-cern-login> \
                         --env CERN_KEYTAB=.keytab \
                         --file ~/.keytab
reana-client secrets-list
```

`CERN_KEYTAB` is the **file name** (`.keytab`), not a path. The HTCondor backend
injects the Kerberos token into each job on its own, so the workflow
specification does not need a `kerberos: true` flag.

## 3. Probe HTCondor with a single file

HTCondor adds three unknowns that the Kubernetes runs never exercised: Kerberos
authentication, running the container image on a condor node, and XRootD reach
to EOS from outside the Kubernetes cluster. This pilot runs the same CMSSW steps
as a real chunk job but over one AOD file, so any of those problems surface in
about a minute instead of after four hours.

```bash
reana-client create -n htcondor-pilot --file reana_htcondor_pilot.yaml
export REANA_WORKON=htcondor-pilot
reana-client upload
reana-client start

reana-client status
reana-client download results/htcondor_pilot_timing.txt
cat results/htcondor_pilot_timing.txt      # DURATION_SECONDS=<N>
```

If `DURATION_SECONDS` is far above the 45 s measured on Kubernetes, condor nodes
are slower than assumed and the chunk size in `workflow/chunk_lists/` should be
regenerated smaller (see [make_chunks.py](make_chunks.py)) before the full run.
`htcondor_max_runtime` is set to `tomorrow` (24 h) against an expected 4 h, so
there is a sixfold margin.

## 4. Run the full analysis

```bash
reana-client create -n level4-htcondor
export REANA_WORKON=level4-htcondor
reana-client upload
reana-client start
```

Everything runs server-side, so the local machine can be shut down once the
workflow is `running`. Expect roughly 5 hours of wall time plus HTCondor queue
time. Progress can be checked later from any machine with the same
`REANA_SERVER_URL`, `REANA_ACCESS_TOKEN` and `REANA_WORKON`.

```bash
reana-client status
reana-client download results/mass4l_combine_user.pdf
```

The result should match `5500/mass4l_combine.png`, the reference plot shipped
with [CERN Open Data record 5500](https://opendata.cern.ch/record/5500).

## Notes from earlier runs

**`reana-client status` can fail with `IncompleteRead`.** The status response
carries the accumulated logs of every job, and CMSSW is very verbose
(`MessageLogger` runs at `INFO` with no limit), so the payload grows to roughly
160 MB and the transfer breaks on a slow link. The workflow itself is unaffected
— polling only reads. `reana-client ls -w <workflow> 'results/*'` returns the
same progress information in a few kilobytes and is the reliable way to monitor
a long run.

**Recovering from failed chunks.** Individual chunks can fail — preemption is a
real risk at four hours per job. `reana-client restart -f` was observed _not_ to
apply an updated specification, so recover by seeding a fresh workflow with the
results that already exist:

```bash
reana-client download -w <old-workflow> results/chunks
unzip -o download_*_chunks_*.zip -d .
rm download_*_chunks_*.zip

reana-client create -n level4-recovery
export REANA_WORKON=level4-recovery
reana-client upload                  # inputs first
reana-client upload results/chunks   # then the finished chunks, so they look newer
reana-client start
```

Snakemake treats the uploaded chunks as up to date and recomputes only what is
missing.

**Rebuilding the file lists.** [fetch_file_index.py](fetch_file_index.py) reads
the file index of an Open Data record straight from the public
`opendata.cern.ch` API, as a stand-in for `cernopendata-client` where that is
not installable. [make_chunks.py](make_chunks.py) turns such a list into chunk
files:

```bash
python3 fetch_file_index.py 6030 files_6030.txt
python3 make_chunks.py files_6030.txt workflow/chunks_DoubleMuParked_Run2012C.json \
        --chunk-size 320 --lists-dir workflow/chunk_lists/DoubleMuParked_Run2012C
```

**Monte Carlo is not yet part of the workflow.** The plot still takes its
simulated backgrounds from the pre-made ROOT files in `data/`. Processing the 14
MC datasets of `5500/List_indexfile.txt` through Level 4 the same way as the
collision data is the remaining piece of work.
