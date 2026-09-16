# Variant B: drive HTCondor straight from Snakemake's own
# snakemake-executor-plugin-htcondor, with no REANA involved at all --
# https://snakemake.github.io/snakemake-plugin-catalog/plugins/executor/htcondor.html
#
# This exists to check whether REANA's two htcondorcern bugs on this server
# (see LEVEL4.md, "Later: analyze_chunk on HTCondor") are REANA-side or
# CERN-pool-side: this plugin submits its own job wrapper and container
# invocation, independent of reana-job-controller, so it may simply not hit
# them. It is UNVERIFIED -- run smoke first. See HTCONDOR_DIRECT.md for setup,
# invocation and how to check that a job actually ran.
#
# Run from the repository root:
#   snakemake -s htcondor_direct.smk --workflow-profile workflow/profiles/htcondor-direct \
#       --jobs 1 -p smoke
#   snakemake -s htcondor_direct.smk --workflow-profile workflow/profiles/htcondor-direct \
#       --jobs 1 -p pilot
#
# `pilot` mirrors reana_htcondor_pilot.yaml: the same CMSSW steps as a real
# analyze_chunk job, over the single AOD file listed in
# workflow/calibration_file.txt, so problems surface in minutes, not after a
# 4h chunk.

JSON_2012 = "Cert_190456-208686_8TeV_22Jan2013ReReco_Collisions12_JSON.txt"


rule all:
    input:
        "htcondor_direct_pilot_timing.txt",


rule smoke:
    # No container, no CMSSW -- just: does condor_submit from lxplus via this
    # plugin reach an execution point at all, and does it have CVMFS and
    # apptainer/singularity (both required by `pilot`)?
    #
    # The output deliberately sits at the top level rather than in results/.
    # HTCondor runs the job in a scratch directory on the execution point and
    # transfers back new files from the *top level* of it; a file written into
    # a subdirectory is silently left behind, which is what the first
    # successful run of this rule did -- "Job was successful" followed by
    # "missing locally". Outputs in subdirectories need --shared-fs-usage
    # none; see HTCONDOR_DIRECT.md.
    output:
        "htcondor_direct_smoke.txt",
    threads: 1
    resources:
        htcondor_request_mem_mb=512,
        htcondor_request_disk_mb=1024,
    shell:
        "{{ hostname; date; id; echo PWD=$(pwd); "
        "echo '--- cvmfs ---'; ls /cvmfs/ 2>&1 || echo 'no /cvmfs'; "
        "echo '--- apptainer/singularity ---'; "
        "(command -v apptainer || command -v singularity) 2>&1 || echo 'neither found'; "
        "echo '--- afs ---'; ls /afs/cern.ch/user/ 2>&1 | head -3 || echo 'no /afs'; "
        "}} > htcondor_direct_smoke.txt"


rule pilot:
    # Reads its inputs through absolute /afs paths and writes its output at
    # the top level, for the reasons the smoke rule established: the job runs
    # in /pool/condor/dir_NNN on the execution point, which can see both
    # /cvmfs and /afs but shares no working directory with the access point.
    # Relative input paths would resolve inside the scratch directory and find
    # nothing; an output in results/ would never be transferred back.
    input:
        smoke="htcondor_direct_smoke.txt",
        data="data",
        code="code",
        calibration_file="workflow/calibration_file.txt",
    output:
        "htcondor_direct_pilot_timing.txt",
    params:
        submitdir=workflow.basedir,
    threads: 1
    container:
        "/cvmfs/unpacked.cern.ch/registry.hub.docker.com/cmsopendata/cmssw_5_3_32:latest"
    resources:
        htcondor_request_mem_mb=8192,
        htcondor_request_disk_mb=16384,
    shell:
        # With should_transfer_files NO the job runs in Iwd, so $(pwd) is the
        # repository on AFS and the output can simply be written back into it.
        "OUTDIR=$(pwd) "
        "&& mkdir -p work_htcondor_direct_pilot "
        "&& cd work_htcondor_direct_pilot "
        "&& source /opt/cms/cmsset_default.sh "
        "&& scramv1 project CMSSW CMSSW_5_3_32 "
        "&& cd CMSSW_5_3_32/src "
        "&& eval `scramv1 runtime -sh` "
        "&& cp -r {params.submitdir}/code/HiggsExample20112012 . "
        "&& cd HiggsExample20112012/HiggsDemoAnalyzer "
        "&& scram b "
        "&& cd ../Level4 "
        "&& cp {params.submitdir}/workflow/calibration_file.txt this_chunk_index.txt "
        "&& sed "
        "-e 's|/home/cms-opendata/CMSSW_5_3_32/src/Demo/DemoAnalyzer/datasets/CMS_Run2012C_DoubleMuParked_AOD_22Jan2013-v1_10000_file_index.txt|this_chunk_index.txt|' "
        "-e \"s|/home/cms-opendata/CMSSW_5_3_32/src/Demo/DemoAnalyzer/datasets/Cert_190456-208686_8TeV_22Jan2013ReReco_Collisions12_JSON.txt|{params.submitdir}/data/Cert_190456-208686_8TeV_22Jan2013ReReco_Collisions12_JSON.txt|\" "
        "-e \"s|'HiggsDemoAnalyzer'|'HiggsDemoAnalyzerGit'|\" "
        "demoanalyzer_cfg_level4data.py > demoanalyzer_cfg_pilot.py "
        "&& START=$(date +%s) "
        "&& cmsRun demoanalyzer_cfg_pilot.py "
        "&& END=$(date +%s) "
        '&& echo "DURATION_SECONDS=$((END-START))" | tee $OUTDIR/htcondor_direct_pilot_timing.txt'
