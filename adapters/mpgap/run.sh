#!/usr/bin/env bash
# fmalmeida/MpGAP adapter — external Nextflow workflow, pinned by commit.
# ADR-004: never vendor; pin by immutable commit hash + container digest.
# MpGAP selects assembly mode via profile/config (sreads | lreads | hybrid).
# env: BENCH_DATASET_DIR, BENCH_OUTDIR, BENCH_PARAMS, BENCH_SEED
set -euo pipefail

echo "==> MpGAP adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR"

REPO="https://github.com/fmalmeida/MpGAP"
COMMIT="${MPGAP_COMMIT:-PENDING}"        # resolved from configs/tool_matrix.yaml at real run
CONTAINER="${MPGAP_CONTAINER:-PENDING}"  # registry digest

mkdir -p "${BENCH_OUTDIR}/assembly"

# TODO(generate): on a real run:
#   nextflow run "$REPO" -r "$COMMIT" \
#     -profile singularity \
#     --input <samplesheet.yml from dataset> \
#     --output "${BENCH_OUTDIR}/assembly" \
#     --max_cpus ... --max_memory ...
#   then copy the MpGAP consensus/primary assembly fasta into
#   ${BENCH_OUTDIR}/assembly/*.fasta

# Placeholder assembly (smoke test only).
PLACEHOLDER="${BENCH_OUTDIR}/assembly/reference_placeholder.fasta"
echo ">contig_smoke_1" > "${PLACEHOLDER}"
echo "ACGTACGTACGTACGTACGTACGTACGT" >> "${PLACEHOLDER}"

cat > "${BENCH_OUTDIR}/run_manifest.json" <<JSON
{
  "schema_version": "1.0",
  "run_uuid": "smoke-mpgap-${BENCH_DATASET_DIR##*/}-$(date +%s)",
  "dataset_id": "${BENCH_DATASET_DIR##*/}",
  "pipeline_id": "mpgap",
  "outcome_state": "success",
  "exit_code": 0,
  "wall_clock_s": 0,
  "outputs": [{"path": "assembly/reference_placeholder.fasta", "md5": "$(md5sum "${PLACEHOLDER}" | cut -d' ' -f1)", "size": $(stat -c%s "${PLACEHOLDER}")}],
  "metrics": {},
  "provenance": {
    "truth_accession": "none",
    "pipeline": {
      "id": "mpgap",
      "type": "nextflow",
      "version_pin": "${COMMIT}",
      "params_file": "${BENCH_PARAMS}"
    },
    "generator": {"seed": ${BENCH_SEED:-0}}
  }
}
JSON

echo "==> MpGAP adapter done (placeholder)."
