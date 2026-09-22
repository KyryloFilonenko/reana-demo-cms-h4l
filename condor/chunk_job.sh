#!/bin/bash
# One analyze_chunk job, run by HTCondor with no Snakemake supervising it.
#
# lxplus9 kills tmux/screen sessions on logout, which kills any long-running
# Snakemake dispatcher with them -- a 43-chunk run cannot be supervised from
# there. HTCondor jobs, on the other hand, survive logout by design, so the
# chunks are submitted as plain jobs and collected afterwards. See
# HTCONDOR_DIRECT.md, "Variant A2: no live dispatcher".
#
# Usage (HTCondor calls it; arguments come from condor/chunks.txt):
#   chunk_job.sh <dataset> <chunk_id>
#
# Self-contained on purpose: everything it needs is transferred in, the AOD
# files come from eospublic over XRootD (CMS open data is public, no
# credential), and nothing is read from AFS. A job that needs no credential
# can't be removed when one lapses, which is what ended the last attempt.

set -eo pipefail

DATASET=$1
CHUNK_ID=$2

if [ -z "$DATASET" ] || [ -z "$CHUNK_ID" ]; then
    echo "usage: $0 <dataset> <chunk_id>" >&2
    exit 2
fi

IMAGE=/cvmfs/unpacked.cern.ch/registry.hub.docker.com/cmsopendata/cmssw_5_3_32:latest
SCRATCH=${_CONDOR_SCRATCH_DIR:-$(pwd)}
OUTPUT="chunk__${DATASET}__${CHUNK_ID}.root"

case "$DATASET" in
    *Run2011A) JSON=Cert_160404-180252_7TeV_ReRecoNov08_Collisions11_JSON.txt ;;
    *Run2012B | *Run2012C) JSON=Cert_190456-208686_8TeV_22Jan2013ReReco_Collisions12_JSON.txt ;;
    *)
        echo "no validation JSON known for dataset $DATASET" >&2
        exit 2
        ;;
esac

# Re-enter the script inside the container rather than nesting a bash -c.
# --bind of the scratch directory is required, not optional: apptainer binds
# the working directory by default but cannot create that mount point inside
# a read-only unpacked CVMFS image, and silently runs somewhere else instead.
if [ -z "${IN_CMSSW_CONTAINER:-}" ]; then
    echo "=== $(date) $(hostname) submitting into container ==="
    echo "dataset=$DATASET chunk=$CHUNK_ID json=$JSON scratch=$SCRATCH"
    export IN_CMSSW_CONTAINER=1
    exec apptainer exec \
        --bind /cvmfs \
        --bind "$SCRATCH" \
        --pwd "$SCRATCH" \
        "$IMAGE" "$SCRATCH/chunk_job.sh" "$DATASET" "$CHUNK_ID"
fi

echo "=== $(date) inside container, pwd=$(pwd) ==="

# CMSSW's cmsset_default.sh reads CMS_PATH before assigning it, which is fatal
# under `set -u`. Nothing below relies on nounset.
set +u

source /opt/cms/cmsset_default.sh
scramv1 project CMSSW CMSSW_5_3_32
cd CMSSW_5_3_32/src
eval "$(scramv1 runtime -sh)"

cp -r "$SCRATCH/code/HiggsExample20112012" .
cd HiggsExample20112012/HiggsDemoAnalyzer
scram b
cd ../Level4

cp "$SCRATCH/${CHUNK_ID}.txt" this_chunk_index.txt

sed -e "s|/home/cms-opendata/CMSSW_5_3_32/src/Demo/DemoAnalyzer/datasets/CMS_Run2012C_DoubleMuParked_AOD_22Jan2013-v1_10000_file_index.txt|this_chunk_index.txt|" \
    -e "s|/home/cms-opendata/CMSSW_5_3_32/src/Demo/DemoAnalyzer/datasets/Cert_190456-208686_8TeV_22Jan2013ReReco_Collisions12_JSON.txt|$SCRATCH/$JSON|" \
    -e "s|'HiggsDemoAnalyzer'|'HiggsDemoAnalyzerGit'|" \
    demoanalyzer_cfg_level4data.py > demoanalyzer_cfg_chunk.py

START=$(date +%s)
cmsRun demoanalyzer_cfg_chunk.py
END=$(date +%s)
echo "=== cmsRun finished in $((END - START)) s ==="

# Top level of the scratch directory, which is the only place HTCondor
# transfers new files back from.
cp ./*.root "$SCRATCH/$OUTPUT"
ls -l "$SCRATCH/$OUTPUT"
echo "=== $(date) done ==="
