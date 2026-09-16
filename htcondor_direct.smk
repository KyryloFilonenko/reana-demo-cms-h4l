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
    # Every path here goes through {input.*} / {output}, never an absolute one
    # baked in at parse time. With shared-fs-usage none the plugin transfers
    # these into the job's scratch directory and transfers the output back, so
    # the names Snakemake hands the shell are the ones that resolve there.
    input:
        smoke="htcondor_direct_smoke.txt",
        data="data",
        code="code",
        calibration_file="workflow/calibration_file.txt",
    output:
        "htcondor_direct_pilot_timing.txt",
    threads: 1
    container:
        "/cvmfs/unpacked.cern.ch/registry.hub.docker.com/cmsopendata/cmssw_5_3_32:latest"
    resources:
        htcondor_request_mem_mb=8192,
        htcondor_request_disk_mb=16384,
    shell:
        # WORKDIR pins the directory Snakemake started in, because the build
        # below cds several levels deep and {input.*} / {output} are relative
        # to where it began.
        "WORKDIR=$(pwd) "
        "&& mkdir -p work_htcondor_direct_pilot "
        "&& cd work_htcondor_direct_pilot "
        "&& source /opt/cms/cmsset_default.sh "
        "&& scramv1 project CMSSW CMSSW_5_3_32 "
        "&& cd CMSSW_5_3_32/src "
        "&& eval `scramv1 runtime -sh` "
        "&& cp -r $WORKDIR/{input.code}/HiggsExample20112012 . "
        "&& cd HiggsExample20112012/HiggsDemoAnalyzer "
        "&& scram b "
        "&& cd ../Level4 "
        "&& cp $WORKDIR/{input.calibration_file} this_chunk_index.txt "
        "&& sed "
        "-e 's|/home/cms-opendata/CMSSW_5_3_32/src/Demo/DemoAnalyzer/datasets/CMS_Run2012C_DoubleMuParked_AOD_22Jan2013-v1_10000_file_index.txt|this_chunk_index.txt|' "
        "-e \"s|/home/cms-opendata/CMSSW_5_3_32/src/Demo/DemoAnalyzer/datasets/Cert_190456-208686_8TeV_22Jan2013ReReco_Collisions12_JSON.txt|$WORKDIR/{input.data}/Cert_190456-208686_8TeV_22Jan2013ReReco_Collisions12_JSON.txt|\" "
        "-e \"s|'HiggsDemoAnalyzer'|'HiggsDemoAnalyzerGit'|\" "
        "demoanalyzer_cfg_level4data.py > demoanalyzer_cfg_pilot.py "
        "&& START=$(date +%s) "
        "&& cmsRun demoanalyzer_cfg_pilot.py "
        "&& END=$(date +%s) "
        '&& echo "DURATION_SECONDS=$((END-START))" | tee $WORKDIR/{output}'
