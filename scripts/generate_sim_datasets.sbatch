#!/usr/bin/env bash
# Generate the 13 simulated benchmark dataset work-units (zero-stressor + ADR-013
# stressor corpus) via simulation/controller.py into the frozen hot-bucket layout.
#
# One array task per dataset YAML; simulators (ART 3.19.15, pbsim3 3.0.5) run from
# pinned Apptainer SIFs. Intermediate files go to node-local $SCRATCH; final frozen
# folders are written to datasets/sim/ on /bigdata and persist after the job ends.
#
# Submit with:  sbatch --array=1-13 scripts/generate_sim_datasets.sbatch
#SBATCH -N 1
#SBATCH -n 4
#SBATCH --cpus-per-task=4
#SBATCH --mem 16G
#SBATCH -t 12:00:00
#SBATCH --job-name gendatasets
#SBATCH -o logs/slurm/gendatasets_%A_%a.out
#SBATCH -e logs/slurm/gendatasets_%A_%a.err

set -euo pipefail
cd /bigdata/stajichlab/jstajich/projects/auto_asm_benchmark
mkdir -p logs/slurm

source /etc/profile.d/modules.sh 2>/dev/null || true
module load apptainer/1.4.5

DATASETS=(
  datasets/yarlip__illumina__med__high__none__haploid__full.yaml
  datasets/canaur__illumina__med__high__cocktail_0p1pct__haploid__full.yaml
  datasets/canaur__illumina__med__high__cocktail_1pct__haploid__full.yaml
  datasets/canaur__illumina__med__high__cocktail_5pct__haploid__full.yaml
  datasets/canaur__illumina__med__problematic__none__haploid__full.yaml
  datasets/canaur__illumina__med__high__none__mismatch__full.yaml
  datasets/canaur__illumina__med__problematic__adapter_spike__haploid__full.yaml
  datasets/canaur__illumina__med__problematic__adapter_carryover__haploid__full.yaml
  datasets/canaur__illumina__med__problematic__all_1pct__haploid__full.yaml
  datasets/cryneo__hifi__med__high__symbiont_0p1pct_lambda_1pct__haploid__full.yaml
  datasets/cryneo__hifi__med__high__symbiont_1pct_lambda_1pct__haploid__full.yaml
  datasets/cryneo__hifi__med__high__symbiont_5pct_lambda_1pct__haploid__full.yaml
  datasets/zymtri__illumina__low__medium__none__haploid__chr1_only.yaml
)
IDX=$((SLURM_ARRAY_TASK_ID - 1))
YAML="${DATASETS[$IDX]}"
echo "== [$SLURM_ARRAY_TASK_ID] $YAML @ $(date) =="

python3 -m simulation.controller "$YAML" \
    --out /bigdata/stajichlab/jstajich/projects/auto_asm_benchmark/datasets/sim \
    --sifs /bigdata/stajichlab/jstajich/projects/auto_asm_benchmark/containers/sifs \
    --work "${SCRATCH:?}/gen" \
  > "logs/slurm/gendatasets_${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}.log" 2>&1

cat "logs/slurm/gendatasets_${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}.log"
echo "== done [$SLURM_ARRAY_TASK_ID] $(date) =="
