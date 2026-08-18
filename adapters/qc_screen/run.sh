#!/usr/bin/env bash
# QC/screen pipeline adapter (fastp/bbduk trim + Kraken2 screen + fastqc).
# env: BENCH_DATASET_DIR, BENCH_OUTDIR, BENCH_PARAMS, BENCH_SEED
set -euo pipefail

echo "==> qc_screen adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR"

mkdir -p "${BENCH_OUTDIR}/assembly"

# TODO(generate): fastp -i R1 -I R2 ... ; kraken2 --db ... R1 R2 ; fastqc
PLACEHOLDER="${BENCH_OUTDIR}/assembly/reference_placeholder.fasta"
echo ">contig_smoke_1" > "${PLACEHOLDER}"
echo "ACGTACGTACGTACGTACGTACGTACGT" >> "${PLACEHOLDER}"

cat > "${BENCH_OUTDIR}/run_manifest.json" <<JSON
{
  "schema_version": "1.0",
  "run_uuid": "smoke-qc_screen-${BENCH_DATASET_DIR##*/}-$(date +%s)",
  "dataset_id": "${BENCH_DATASET_DIR##*/}",
  "pipeline_id": "qc_screen",
  "outcome_state": "success",
  "exit_code": 0,
  "wall_clock_s": 0,
  "outputs": [{"path": "assembly/reference_placeholder.fasta", "md5": "$(md5sum "${PLACEHOLDER}" | cut -d' ' -f1)", "size": $(stat -c%s "${PLACEHOLDER}")}],
  "metrics": {},
  "provenance": {
    "truth_accession": "none",
    "pipeline": {
      "id": "qc_screen",
      "type": "conda",
      "version_pin": "PENDING",
      "params_file": "${BENCH_PARAMS}"
    },
    "generator": {"seed": ${BENCH_SEED:-0}}
  }
}
JSON

echo "==> qc_screen adapter done (placeholder)."
