#!/usr/bin/env bash
# Run one adapter (adapters/<PIPELINE_ID>/run.sh) against one dataset as a
# SLURM batch job, instead of directly in an interactive shell -- ad hoc
# validation runs still need to be proper batch jobs, not stacked into
# whatever interactive allocation happens to be open (they were competing
# for the same 8 cores as everything else in that session).
#
# Required env (export before submit, or pass via --export=ALL,VAR=val):
#   PIPELINE_ID   e.g. aaftf, nf_aaftf, hifiasm_pipeline, flye_pipeline,
#                 spades_pipeline, egap
#   DATASET_ID    folder name under datasets/sim/ (or datasets/staged/)
# Optional env:
#   PARAMS_FILE   default: configs/params/<PIPELINE_ID minus _pipeline>.default.yaml
#                 (adjust per-pipeline naming: aaftf->aaftf, flye_pipeline->flye,
#                 hifiasm_pipeline->hifiasm, spades_pipeline->spades)
#   OUT_ROOT      default: results/adhoc
#   DATASET_ROOT  default: datasets/sim
#
# Submit with:
#   sbatch --export=ALL,PIPELINE_ID=egap,DATASET_ID=yarlip_sim_001 \
#     scripts/run_adapter.sbatch
#SBATCH -N 1
#SBATCH -n 8
#SBATCH --mem 64G
#SBATCH -t 1-00:00:00
#SBATCH --job-name bench_adapter
#SBATCH -o logs/slurm/adapter_%x_%j.out
#SBATCH -e logs/slurm/adapter_%x_%j.err

set -euo pipefail
REPO_ROOT=/bigdata/stajichlab/jstajich/projects/auto_asm_benchmark
cd "${REPO_ROOT}"
mkdir -p logs/slurm

: "${PIPELINE_ID:?set PIPELINE_ID (e.g. egap, hifiasm_pipeline, flye_pipeline)}"
: "${DATASET_ID:?set DATASET_ID (folder under datasets/sim/)}"
# Absolute paths throughout: nf_aaftf's Nextflow subprocess (and possibly
# others) resolve paths relative to their OWN working directory, not this
# script's -- a relative BENCH_SIFS_DIR made nf_aaftf try to `docker://` pull
# a literal relative path instead of finding the local SIF ("Another
# Nextflow instance is pulling ... requested access to the resource is
# denied"). Every other adapter validation run this session used absolute
# paths directly, which is why this only surfaced once ad hoc `bash
# adapters/*/run.sh` calls moved into this sbatch wrapper.
DATASET_ROOT="${DATASET_ROOT:-${REPO_ROOT}/datasets/sim}"
OUT_ROOT="${OUT_ROOT:-${REPO_ROOT}/results/adhoc}"
PARAMS_FILE="${PARAMS_FILE:-}"
if [ -z "${PARAMS_FILE}" ]; then
  PARAMS_FILE="$(python3 -c "
import yaml
m = yaml.safe_load(open('configs/tool_matrix.yaml'))
for p in m['pipelines']:
    if p['id'] == '${PIPELINE_ID}':
        print(p['params']['default']); break
")"
fi
PARAMS_FILE="${REPO_ROOT}/${PARAMS_FILE}"

source /etc/profile.d/modules.sh 2>/dev/null || true
module load apptainer/1.4.5

OUTDIR="${OUT_ROOT}/${PIPELINE_ID}/${DATASET_ID}"
mkdir -p "${OUTDIR}"
echo "== ${PIPELINE_ID} / ${DATASET_ID} @ $(date) =="
echo "params: ${PARAMS_FILE}"
echo "outdir: ${OUTDIR}"

BENCH_DATASET_DIR="${DATASET_ROOT}/${DATASET_ID}" \
BENCH_OUTDIR="${OUTDIR}" \
BENCH_TOOL_MATRIX="${REPO_ROOT}/configs/tool_matrix.yaml" \
BENCH_PARAMS="${PARAMS_FILE}" \
BENCH_SEED="${BENCH_SEED:-42}" \
BENCH_SIFS_DIR="${REPO_ROOT}/containers/sifs" \
  bash "${REPO_ROOT}/adapters/${PIPELINE_ID}/run.sh"

echo "== done ${PIPELINE_ID} / ${DATASET_ID} @ $(date) =="
