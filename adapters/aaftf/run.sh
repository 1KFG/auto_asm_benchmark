#!/usr/bin/env bash
# AAFTF adapter — fixed contract wrapper for the `aaftf` pipeline entry.
# See docs/design-decisions.md ADR-005 for the adapter contract and
# workflows/modules/adapter_conda.nf for env vars passed by the harness.
#
# Expected env (set by harness):
#   BENCH_ADAPTER_TYPE, BENCH_DATASET_DIR, BENCH_OUTDIR,
#   BENCH_TOOL_MATRIX, BENCH_PARAMS, BENCH_SEED
#
# Contract output:
#   $BENCH_OUTDIR/assembly/*.fasta        primary assembly (one file minimum)
#   $BENCH_OUTDIR/run_manifest.json       provenance + outcome (schema run_manifest.schema.json)
#   exit codes: 0=success, 10=partial, nonzero=failure
set -euo pipefail

echo "==> AAFTF adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR params=$BENCH_PARAMS"

# Resolve the dataset reads locally (GCS uri -> local copy; harness/TODO in real run).
# For local smoke tests, $BENCH_DATASET_DIR may already be a local path.
DATASET_LOCAL="${DATASET_LOCAL:-$BENCH_DATASET_DIR}"
READS_DIR="${DATASET_LOCAL}/reads"

# AAFTF pipeline (conceptual; pins from configs/params/aaftf.default.yaml):
#  1. PCR duplicate/quality trim
#  2. error-correct/digest contamination
#  3. assemble + polish
#  4. annotate (optional)
# TODO(generate): implement actual aaftf.pl invocation once env pins resolved.

mkdir -p "${BENCH_OUTDIR}/assembly"

# Placeholder assembly (NOT a real assembly — smoke test only).
PLACEHOLDER="${BENCH_OUTDIR}/assembly/reference_placeholder.fasta"
echo ">contig_smoke_1" > "${PLACEHOLDER}"
echo "ACGTACGTACGTACGTACGTACGTACGT" >> "${PLACEHOLDER}"

# Write run_manifest.json (schema run_manifest.schema.json)
cat > "${BENCH_OUTDIR}/run_manifest.json" <<JSON
{
  "schema_version": "1.0",
  "run_uuid": "smoke-aaftf-${BENCH_DATASET_DIR##*/}-$(date +%s)",
  "dataset_id": "${BENCH_DATASET_DIR##*/}",
  "pipeline_id": "aaftf",
  "outcome_state": "success",
  "exit_code": 0,
  "wall_clock_s": 0,
  "outputs": [{"path": "assembly/reference_placeholder.fasta", "md5": "$(md5sum "${PLACEHOLDER}" | cut -d' ' -f1)", "size": $(stat -c%s "${PLACEHOLDER}")}],
  "metrics": {},
  "provenance": {
    "truth_accession": "none",
    "pipeline": {
      "id": "aaftf",
      "type": "conda",
      "version_pin": "PENDING",
      "params_file": "${BENCH_PARAMS}"
    },
    "generator": {"seed": ${BENCH_SEED:-0}}
  }
}
JSON

echo "==> AAFTF adapter done (placeholder)."
