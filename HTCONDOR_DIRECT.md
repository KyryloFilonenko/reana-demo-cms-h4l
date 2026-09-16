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

**This is unverified.** It has not been run against CERN's HTCondor pool. The
`smoke` step below exists specifically to find out, cheaply, whether it even
works before trusting it with a 4h chunk.

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
- **Assumes a shared filesystem** between lxplus and the execution point
  (`workflow/profiles/htcondor-direct/config.yaml` doesn't set
  `--shared-fs-usage none`). Whether that assumption holds for CERN's pool is
  exactly what `smoke` checks.

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

Separate venv from the REANA one, so the two don't fight over the `snakemake`
version:

```bash
python3 -m venv ~/.virtualenvs/htcondor-direct
source ~/.virtualenvs/htcondor-direct/bin/activate
pip install "snakemake>=8.6" snakemake-executor-plugin-htcondor
```

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
cat results/htcondor_direct_smoke.txt
```

Read `results/htcondor_direct_smoke.txt`:

- `--- cvmfs ---` should list `cms.cern.ch`, `unpacked.cern.ch`, etc. If it
  says `no /cvmfs` -- the execution point has no CVMFS and `pilot` cannot
  work as written.
- `--- apptainer/singularity ---` must find one of the two, or `pilot`'s
  `container:` directive has nothing to run the image with.
- If `results/htcondor_direct_smoke.txt` never appears locally even though
  `condor_history` shows the job Completed -- the filesystem is **not**
  actually shared between lxplus and the execution point. Stop here and
  switch the profile to `shared-fs-usage: none` (file-transfer mode) before
  trying `pilot`; that's a different, more involved setup (see the plugin's
  own docs on `--htcondor-shared-fs-prefixes`).

Only move on if all three checks above pass.

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
cat results/htcondor_direct_pilot_timing.txt   # DURATION_SECONDS=<N>
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
