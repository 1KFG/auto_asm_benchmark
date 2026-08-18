#!/usr/bin/env bash
# Launch the illumina-only benchmark run: nf_aaftf over yarlip_sim_001
# (30x ART-simulated Yarrowia CLIB122 reads, staged in datasets/sim/).
#
# Two-layer nesting is intentional (ADR-005: pipelines are black boxes):
#   1. This head job runs the harness (workflows/main.nf -profile slurm).
#   2. The harness submits RUN_NEXTFLOW_ADAPTER to SLURM (stajichlab queue).
#   3. The adapter in turn invokes the pinned stajichlab/nf_aaftf workflow
#      (-profile aaftf), which submits its own steps (epyc/short/highmem).
#
# Submit with:  sbatch scripts/launch_illumina_nf_aaftf.sbatch
#SBATCH -N 1
#SBATCH -n 8
#SBATCH --mem 16G
#SBATCH -t 2-00:00:00
#SBATCH --job-name bench_yarli_nfaaftf
#SBATCH -o logs/slurm/bench_yarli_nfaaftf_%j.out
#SBATCH -e logs/slurm/bench_yarli_nfaaftf_%j.err

set -euo pipefail
cd /bigdata/stajichlab/jstajich/projects/auto_asm_benchmark

mkdir -p logs/slurm

source /etc/profile.d/modules.sh 2>/dev/null || true
module load nextflow/25.10.4
module load apptainer/1.4.5

nextflow run workflows/main.nf \
    -profile slurm \
    --datasets yarlip_sim_001 \
    --dataset_root datasets/sim \
    --pipelines nf_aaftf \
    --outdir results/illumina_yarlip_001

echo "== harness finished (see results/illumina_yarlip_001/yarlip_sim_001/nf_aaftf) =="
