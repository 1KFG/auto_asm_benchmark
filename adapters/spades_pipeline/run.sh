#!/usr/bin/env bash
# SPAdes pipeline adapter (short-read assembly + Pilon).
# env: BENCH_DATASET_DIR, BENCH_OUTDIR, BENCH_PARAMS, BENCH_SEED
set -euo pipefail

echo "==> spades_pipeline adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR"

mkdir -p "${BENCH_OUTDIR}/assembly"

# TODO(generate): spades.py --isolate -1 <R1> -2 <R2> -t ... -o spades_out && pilon
PLACEHOLDER="${BENCH_OUTDIR}/assembly/reference_placeholder.fasta"
echo ">contig_smoke_1" > "${PLACEHOLDER}"
echo "ACGTACGTACGTACGTACGTACGTACGT" >> "${PLACEHOLDER}"

cat > "${BENCH_OUTDIR}/run_manifest.json" <<JSON
{
  "schema_version": "1.0",
  "run_uuid": "smoke-spades_pipeline-${BENCH_DATASET_DIR##*/}-$(date +%s)",
  "dataset_id": "${BENCH_DATASET_DIR##*/}",
  "pipeline_id": "spades_pipeline",
  "outcome_state": "success",
  "exit_code": 0,
  "wall_clock_s": 0,
  "outputs": [{"path": "assembly/reference_placeholder.fasta", "md5": "$(md5sum "${PLACEHOLDER}" | cut -d' ' -f1)", "size": $(stat -c%s "${PLACEHOLDER}")}],
  "metrics": {},
  "provenance": {
    "truth_accession": "none",
    "pipeline": {
      "id": "spades_pipeline",
      "type": "conda",
      "version_pin": "PENDING",
      "params_file": "${BENCH_PARAMS}"
    },
    "generator": {"seed": ${BENCH_SEED:-0}}
  }
}
JSON

echo "==> spades_pipeline adapter done (placeholder)."
