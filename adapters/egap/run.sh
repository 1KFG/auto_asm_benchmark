#!/usr/bin/env bash
# iPsychonaut/EGAP adapter — external Python/conda orchestrated pipeline, pinned by
# git tag v3.4.1 commit + bioconda egap==3.4.1 (CSV input schema).
# ADR-004: never vendor; pin by immutable commit hash (+ env lockfile TBD).
# env (set by harness): BENCH_DATASET_DIR, BENCH_OUTDIR, BENCH_TOOL_MATRIX,
#   BENCH_PARAMS, BENCH_SEED, BENCH_SMOKE (1/0), BENCH_SIFS_DIR
# Contract output:
#   $BENCH_OUTDIR/assembly/*.fasta    primary assembly (one file minimum)
#   $BENCH_OUTDIR/run_manifest.json   provenance + outcome (schema run_manifest.schema.json)
#   exit codes: 0=success, 10=partial, nonzero=failure
set -euo pipefail

echo "==> EGAP adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR smoke=${BENCH_SMOKE:-0}"

DATASET_ID="${BENCH_DATASET_DIR##*/}"
READS_DIR="${BENCH_DATASET_DIR}/reads"
ASSEMBLY_OUT="${BENCH_OUTDIR}/assembly"
WORK_DIR="${BENCH_OUTDIR}/egap_work"
mkdir -p "${ASSEMBLY_OUT}" "${WORK_DIR}"

RUN_UUID=""
outcome_state="failed"
exit_code=0

finalize() {
  local state="$1"
  cat > "${BENCH_OUTDIR}/run_manifest.json" <<JSON
{
  "schema_version": "1.0",
  "run_uuid": "${RUN_UUID}",
  "dataset_id": "${DATASET_ID}",
  "pipeline_id": "egap",
  "outcome_state": "${state}",
  "exit_code": ${exit_code},
  "wall_clock_s": ${WALL_CLOCK_S:-0},
  "outputs": ${OUTPUTS_JSON:-[]},
  "metrics": {},
  "provenance": {
    "truth_accession": "${TRUTH_ACCESSION:-unknown}",
    "pipeline": {
      "id": "egap",
      "type": "conda",
      "version_pin": "${EGAP_COMMIT:-PENDING} (bioconda egap==3.4.1)",
      "params_file": "${BENCH_PARAMS}"
    },
    "databases": [
      {"name": "BUSCO lineage fungi_odb10", "version": "${EGAP_BUSCO_VERSION:-PENDING}"}
    ],
    "generator": {"seed": ${BENCH_SEED:-0}}
  }
}
JSON
}

# ---------------------------------------------------------------------------
# Smoke mode: placeholder outputs only, no conda env / EGAP run (never fires
# heavy work from the harness test path).
# ---------------------------------------------------------------------------
if [ "${BENCH_SMOKE:-0}" = "1" ]; then
  printf '>contig_smoke_1\nACGTACGTACGTACGTACGTACGTACGT\n' > "${ASSEMBLY_OUT}/${DATASET_ID}_egap_placeholder.fasta"
  RUN_UUID="smoke-egap-${DATASET_ID}-$(date +%s)"
  OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_egap_placeholder.fasta", "md5": "'$(md5sum "${ASSEMBLY_OUT}/${DATASET_ID}_egap_placeholder.fasta" | cut -d' ' -f1)'"}]'
  TRUTH_ACCESSION="none"
  NOTES="SMOKE PLACEHOLDER - not a real assembly"
  finalize "success"
  echo "==> EGAP adapter done (smoke placeholder)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Real run: resolve pins deterministically from the tool matrix (no floating).
# ---------------------------------------------------------------------------
EGAP_COMMIT="$([ -n "${BENCH_TOOL_MATRIX:-}" ] && python3 - <<PY
import yaml
m=yaml.safe_load(open("${BENCH_TOOL_MATRIX}"))
for p in m["pipelines"]:
    if p["id"]=="egap":
        print(p["execution"].get("commit","PENDING")); break
PY
)"
EGAP_COMMIT="${EGAP_COMMIT:-PENDING}"

# ---------------------------------------------------------------------------
# Probe the frozen dataset reads and build the EGAP v3.4.1 CSV row.
# Maps dataset reads into ILLUMINA_RAW_DIR + F/R read columns.
# ---------------------------------------------------------------------------
if [ ! -d "${READS_DIR}" ]; then
  echo "ERROR: no reads dir ${READS_DIR}" >&2
  RUN_UUID="fail-egap-${DATASET_ID}-$(date +%s)"
  TRUTH_ACCESSION="unknown"
  NOTES="aborted: missing reads dir"
  finalize "failed"; exit 1
fi

R1=$(find "${READS_DIR}" -maxdepth 1 \( -name '*_R1*.fastq.gz' -o -name '*_1*.fastq.gz' -o -name '*_R1*.fastq' \) | head -1 || true)
R2=$(find "${READS_DIR}" -maxdepth 1 \( -name '*_R2*.fastq.gz' -o -name '*_2*.fastq.gz' -o -name '*_R2*.fastq' \) | head -1 || true)
if [ -z "${R1}" ] || [ -z "${R2}" ]; then
  echo "ERROR: need forward+reverse Illumina reads in ${READS_DIR}" >&2
  RUN_UUID="fail-egap-${DATASET_ID}-$(date +%s)"
  TRUTH_ACCESSION="unknown"
  NOTES="aborted: paired-end reads not found"
  finalize "failed"; exit 1
fi

# Per-sample fields (dataset-dependent overrides from params; defaults for fungi).
SPECIES_ID="${EGAP_SPECIES_ID:-${DATASET_ID}}"
SAMPLE_ID="${EGAP_SAMPLE_ID:-${DATASET_ID}}"
KINGDOM="${EGAP_KINGDOM:-Funga}"
KARYOTE="${EGAP_KARYOTE:-eukaryote}"
BUSCO1="${EGAP_BUSCO1:-fungi}"
BUSCO2="${EGAP_BUSCO2:-basidiomycota}"
EST_SIZE="${EGAP_EST_SIZE:-50m}"

CSV="${WORK_DIR}/egap_input.csv"
cat > "${CSV}" <<CSVEOF
ONT_SRA,ONT_RAW_DIR,ONT_RAW_READS,ILLUMINA_SRA,ILLUMINA_RAW_DIR,ILLUMINA_RAW_F_READS,ILLUMINA_RAW_R_READS,PACBIO_SRA,PACBIO_RAW_DIR,PACBIO_RAW_READS,SPECIES_ID,SAMPLE_ID,ORGANISM_KINGDOM,ORGANISM_KARYOTE,BUSCO_1,BUSCO_2,EST_SIZE,REF_SEQ_GCA,REF_SEQ
None,None,None,None,${READS_DIR},${R1},${R2},None,None,None,${SPECIES_ID},${SAMPLE_ID},${KINGDOM},${KARYOTE},${BUSCO1},${BUSCO2},${EST_SIZE},None,None
CSVEOF

# ---------------------------------------------------------------------------
# Run EGAP (conda env must provide `EGAP` on PATH; provisioned per ADR-004 via
# pinned lockfile — env_pin egap==3.4.1 in tool_matrix.yaml).
# ---------------------------------------------------------------------------
command -v EGAP >/dev/null 2>&1 || { echo "ERROR: EGAP not on PATH (conda env missing)" >&2; RUN_UUID="fail-egap-${DATASET_ID}-$(date +%s)"; NOTES="aborted: EGAP not on PATH"; finalize "failed"; exit 1; }

START=$(date +%s)
if ! EGAP --input_csv "${CSV}" \
    --output_dir "${WORK_DIR}/egap_out" \
    --cpu_threads "${EGAP_CPU_THREADS:-8}" \
    --ram_gb "${EGAP_RAM_GB:-32}" \
    $( [ "${EGAP_DRY_RUN:-false}" = "true" ] && echo --dry_run ) \
    $( [ "${EGAP_TUI:-false}" = "true" ] && echo --tui ); then
  echo "ERROR: EGAP pipeline failed" >&2
  RUN_UUID="fail-egap-${DATASET_ID}-$(date +%s)"
  WALL_CLOCK_S=$(( $(date +%s) - START ))
  TRUTH_ACCESSION="unknown"
  NOTES="EGAP run failed"
  finalize "failed"; exit 1
fi
WALL_CLOCK_S=$(( $(date +%s) - START ))

# ---------------------------------------------------------------------------
# Collect the primary assembly fasta. EGAP's final curated + decontaminated
# assembly is written per sample as {sample_id}_decontaminated.fasta; fall back
# to any per-sample assembly fasta if that name changed.
# ---------------------------------------------------------------------------
# Collect the primary assembly fasta. EGAP's final curated + decontaminated
# assembly is written per sample as {sample_id}_decontaminated.fasta; fall back
# to any per-sample assembly fasta if that name changed.
FINAL_FASTA=$(find "${WORK_DIR}/egap_out" -name "${SAMPLE_ID}*decontaminated.fasta" -print -quit || true)
if [ -z "${FINAL_FASTA}" ]; then
  FINAL_FASTA=$(find "${WORK_DIR}/egap_out" -name "*.fasta" ! -name "*.gz" -size +0c -print -quit || true)
fi

if [ -z "${FINAL_FASTA}" ] || [ ! -s "${FINAL_FASTA}" ]; then
  echo "WARN: no final assembly fasta found under ${WORK_DIR}/egap_out; partial outcome" >&2
  RUN_UUID="partial-egap-${DATASET_ID}-$(date +%s)"
  TRUTH_ACCESSION="$(basename "${FINAL_FASTA:-unknown}")"
  NOTES="no final assembly emitted"
  finalize "partial"; exit 10
fi

OUT_FASTA="${ASSEMBLY_OUT}/${DATASET_ID}_egap.fasta"
cp "${FINAL_FASTA}" "${OUT_FASTA}"
MD5=$(md5sum "${OUT_FASTA}" | cut -d' ' -f1)
SIZE=$(stat -c%s "${OUT_FASTA}")
RUN_UUID="egap-${DATASET_ID}-$(date +%s)"
OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_egap.fasta", "md5": "'${MD5}'", "size": '${SIZE}'}]'
TRUTH_ACCESSION="none"
NOTES="EGAP v3.4.1 run complete"
finalize "success"

echo "==> EGAP adapter done: ${OUT_FASTA} ($(stat -c%s "${OUT_FASTA}") bytes)"
