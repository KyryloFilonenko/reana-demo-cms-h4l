# Variant B: HTCondor without REANA

Two ways to get `analyze_chunk` onto CERN HTCondor:

- **Variant A (REANA, working today):** `reana.yaml` / `workflow/Snakefile`,
  run via `reana-client` on Kubernetes -- see [LEVEL4.md](LEVEL4.md). This is
  the validated path; use it unless you're specifically trying variant B.
- **Variant B (this file):** drive HTCondor directly with
  [`snakemake-executor-plugin-htcondor`](https://snakemake.github.io/snakemake-plugin-catalog/plugins/executor/htcondor.html),
  no REANA server involved. Worth trying because REANA's two `htcondorcern`
  bugs (entrypoint/job_wrapper.sh, `unpacked_img` hang -- see LEVEL4.md
  "Later: analyze_chunk on HTCondor") live in `reana-job-controller`'s own job
  submission code; this plugin submits jobs its own way, so it may not hit
  them at all.

**Status: `smoke` passes, `pilot` not yet run.** Job submission, execution and
output retrieval all work against CERN's HTCondor pool (see "What it answered"
below). Whether a real CMSSW job runs there is what `pilot` tests, and that is
still open.

## What's different from the REANA path

- **The `snakemake` process itself must stay running for the whole workflow.**
  Unlike `reana-client start`, which hands the run off to the server, this
  `snakemake` invocation is the thing polling HTCondor and driving the DAG. If
  it dies (closed terminal, lxplus session drop), the jobs are affected --
  the plugin's own docs warn that exiting the terminal aborts jobs in
  non-shared-filesystem mode, and even in shared mode there is no supervisor
  left running to notice a job finished. **Always run it inside `tmux` /
  `screen`, or under `nohup ... &`.**
- **You get real per-job HTCondor logs**, not REANA's "emitted no logs":
  every job gets its own submit/log/out/err files under `.snakemake/htcondor/`
  (see `htcondor-jobdir` in the profile). This is the main diagnostic upgrade
  over the REANA path, where a hung `/cvmfs/` job gave no way to see what
  HTCondor itself thought was happening.
- **The job runs in a scratch directory, not in your working directory.** The
  plugin submits with an absolute `Cmd` and `Iwd` and adds no transfer
  directives, i.e. it assumes a shared filesystem. HTCondor disagrees:
  `should_transfer_files` defaults to `IF_NEEDED` and the access and execution
  points on this pool don't share a `FILESYSTEM_DOMAIN`, so the job gets
  `/pool/condor/dir_NNN` and only new files at the **top level** of it are
  transferred back. Hence the two rules here read inputs through absolute
  `/afs` paths and write their outputs at the top level. An output under
  `results/` is silently lost -- the run reports success and then
  "missing locally".

## Files

- [`htcondor_direct.smk`](htcondor_direct.smk) -- `smoke` (no container, no
  CMSSW: proves `condor_submit` reaches a worker at all, and that the worker
  has CVMFS and `apptainer`/`singularity`) and `pilot` (the same CMSSW steps
  as a real `analyze_chunk` job, over the one AOD file in
  `workflow/calibration_file.txt` -- mirrors `reana_htcondor_pilot.yaml`).
- [`workflow/profiles/htcondor-direct/config.yaml`](workflow/profiles/htcondor-direct/config.yaml)
  -- the Snakemake profile: `executor: htcondor`, apptainer as the container
  backend, default memory/disk.

## 1. Set up on lxplus

`snakemake>=8.6` needs Python >=3.11, and lxplus's plain `python3` is 3.9.
Two candidates exist, and only one of them works here:

- **`/usr/bin/python3.12` (system): no.** It runs on lxplus, but the batch
  execution nodes don't have `libpython3.12.so.1.0` installed, so the
  interpreter cannot start there at all.
- **LCG on CVMFS: yes.** CVMFS is mounted identically on lxplus and on the
  execution nodes, so the same interpreter and the same libraries are visible
  from both.

```bash
LCG=/cvmfs/sft.cern.ch/lcg/views/LCG_110/x86_64-el9-gcc15-opt
$LCG/bin/python3 --version          # 3.13.11
$LCG/bin/python3 -m venv ~/.virtualenvs/htcondor-direct
source ~/.virtualenvs/htcondor-direct/bin/activate
pip install --upgrade pip
pip install "snakemake>=8.6" snakemake-executor-plugin-htcondor
```

**Do not pass `--copies`.** The venv default (symlinks) is what you want, and
`--copies` actively breaks this setup: the LCG interpreter finds its own
`libpython` through a *relative* RPATH (`$ORIGIN/../lib`), so a copy placed in
`~/.virtualenvs/.../bin/` looks for the library in
`~/.virtualenvs/.../lib/`, finds nothing, and dies -- `venv --copies` itself
fails at the `ensurepip` step with exit 127 for exactly this reason. Left as a
symlink, `$ORIGIN` resolves through to the CVMFS `bin/` directory and the
library is found.

The matching half of this is `htcondor_submit_transfer_executable: "False"` in
[the profile](workflow/profiles/htcondor-direct/config.yaml): the plugin never
sets `transfer_executable`, so HTCondor's default (`True`) would copy the
interpreter into the execution point's scratch directory and break `$ORIGIN`
all over again. See the comment there.

Confirm lxplus can talk to the pool at all, independently of REANA:

```bash
klist                    # valid Kerberos ticket (kinit if not)
condor_q                 # should return, even if empty, not error out
condor_status -avail | head
```

## 2. Smoke test

```bash
cd ~/reana-demo-cms-h4l   # your clone
tmux new -s htcondor-direct   # or: screen -S htcondor-direct
source ~/.virtualenvs/htcondor-direct/bin/activate

snakemake -s htcondor_direct.smk \
  --workflow-profile workflow/profiles/htcondor-direct \
  --jobs 1 -p smoke
```

**While it runs**, in another lxplus session (or another `tmux` pane):

```bash
condor_q                         # job should appear: Idle -> Running -> gone
ls .snakemake/htcondor/          # one directory per submitted job
cat .snakemake/htcondor/*/*.log  # HTCondor's own event log for the job
cat .snakemake/htcondor/*/*.out .snakemake/htcondor/*/*.err
```

**After it finishes:**

```bash
condor_history -limit 5          # confirm it shows Completed, not Removed/Held
cat htcondor_direct_smoke.txt
```

If `condor_q` shows the job `held` instead of progressing, get the reason before
doing anything else:

```bash
condor_q -hold <cluster>.<proc>   # e.g. condor_q -hold 16677020.0
```

### What it answered

Run on 2026-09-16, execution point `b9p28p6148.cern.ch`. All three checks
passed, which is what makes `pilot` worth attempting:

- **CVMFS**: fully mounted, `unpacked.cern.ch` and `cms.cern.ch` among the
  repositories -- so the CMSSW image `pilot` asks for is reachable.
- **apptainer**: `/usr/bin/apptainer` present.
- **AFS**: `/afs/cern.ch/user/` readable, so a job can reach the working
  directory through an absolute path.

It also showed `PWD=/pool/condor/dir_1613768`, i.e. the job runs in scratch --
which is why both rules use absolute `/afs` paths for input and top-level
output files.

### CMSSW and `set -u`

Snakemake runs every shell command under `set -euo pipefail`. CMSSW's
`/opt/cms/cmsset_default.sh` reads `CMS_PATH` before assigning it, which is
fine in an ordinary shell and fatal under `nounset`:

```
/opt/cms/cmsset_default.sh: line 33: CMS_PATH: unbound variable
```

The job then exits 127 before any analysis runs, and -- because the output
file never appears -- HTCondor puts it on hold complaining about output
transfer instead, which points at entirely the wrong thing. Any rule that
sources a CMSSW environment must start with `set +u`. REANA never hit this;
its job wrapper doesn't set `-u`.

## 3. Pilot (real CMSSW, one file)

```bash
snakemake -s htcondor_direct.smk \
  --workflow-profile workflow/profiles/htcondor-direct \
  --jobs 1 -p pilot
```

Same monitoring as the smoke test (`condor_q`, `.snakemake/htcondor/.../`
log+out+err). This step takes minutes, not hours, so watch it interactively
rather than detaching.

**Verify it actually ran the analysis, not just the container:**

```bash
cat htcondor_direct_pilot_timing.txt   # DURATION_SECONDS=<N>
```

Compare `<N>` to the REANA pilot's `DURATION_SECONDS` and to the ~45 s/file
baseline measured on Kubernetes. If this file exists with a plausible number,
the full chain worked: HTCondor submission, CVMFS image, CMSSW build, XRootD
read from EOS, `cmsRun`.

## If it works

Only after `pilot` succeeds is it worth adapting the real 43-job
`analyze_chunk` rules (from `workflow/Snakefile`) to this executor: copy
their `shell:` blocks into `htcondor_direct.smk` with wildcards over
`workflow/chunk_lists/`, bump `htcondor_request_mem_mb` (the REANA run needed
8Gi -- see LEVEL4.md), and run the whole thing inside `tmux`/`nohup` since,
unlike REANA, nothing keeps it alive if lxplus drops. Ask before doing that
conversion -- it's real workflow-editing work, not a config tweak.
