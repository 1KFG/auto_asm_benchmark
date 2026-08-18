#!/usr/bin/env bash
# hifiasm pipeline adapter (HiFi-only assembly).
# env: BENCH_DATASET_DIR, BENCH_OUTDIR, BENCH_PARAMS, BENCH_SEED
set -euo pipefail

echo "==> hifiasm_pipeline adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR"

mkdir -p "${BENCH_OUTDIR}/assembly"

# TODO(generate): hifiasm -o out reads.fq [-1 for haploid truth] && gfa2fa
PLACEHOLDER="${BENCH_OUTDIR}/assembly/reference_placeholder.fasta"
echo ">contig_smoke_1" > "${PLACEHOLDER}"
echo "ACGTACGTACGTACGTACGTACGTACGT" >> "${PLACEHOLDER}"

cat > "${BENCH_OUTDIR}/run_manifest.json" <<JSON
{
  "schema_version": "1.0",
  "run_uuid": "smoke-hifiasm_pipeline-${BENCH_DATASET_DIR##*/}-$(date +%s)",
  "dataset_id": "${BENCH_DATASET_DIR##*/}",
  "pipeline_id": "hifiasm_pipeline",
  "outcome_state": "success",
  "exit_code": 0,
  "wall_clock_s": 0,
  "outputs": [{"path": "assembly/reference_placeholder.fasta", "md5": "$(md5sum "${PLACEHOLDER}" | cut -d' ' -f1)", "size": $(stat -c%s "${PLACEHOLDER}")}],
  "metrics": {},
  "provenance": {
    "truth_accession": "none",
    "pipeline": {
      "id": "hifiasm_pipeline",
      "type": "conda",
      "version_pin": "PENDING",
      "params_file": "${BENCH_PARAMS}"
    },
    "generator": {"seed": ${BENCH_SEED:-0}}
  }
}
JSON

echo "==> hifiasm_pipeline adapter done (placeholder)."
