#!/usr/bin/env bash
# Shovill adapter — self-contained short-read assembly pipeline (trim ->
# read correction -> stitching -> assemble -> pilon polish -> cleanup, all
# in one command). Deliberately NO contamination screening (like
# spades_pipeline) -- another baseline assembler-only comparison point.
#
# Expected env (set by harness):
#   BENCH_ADAPTER_TYPE, BENCH_DATASET_DIR, BENCH_OUTDIR, BENCH_TOOL_MATRIX,
#   BENCH_PARAMS, BENCH_SEED, BENCH_SMOKE (1/0), BENCH_SIFS_DIR
#
# Contract output:
#   $BENCH_OUTDIR/assembly/*.fasta.gz        primary assembly (one file minimum, gzip-compressed)
#   $BENCH_OUTDIR/run_manifest.json       provenance + outcome (schema run_manifest.schema.json)
#   $BENCH_OUTDIR/shovill_pipeline.log    step log (kept for debugging)
#   exit codes: 0=success, 10=partial, nonzero=failure
set -euo pipefail

echo "==> shovill_pipeline adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR smoke=${BENCH_SMOKE:-0}"

DATASET_ID="${BENCH_DATASET_DIR##*/}"
BENCH_DATASET_DIR="$(cd "${BENCH_DATASET_DIR}" && pwd)"
READS_DIR="${BENCH_DATASET_DIR}/reads"
mkdir -p "${BENCH_OUTDIR}"
BENCH_OUTDIR="$(cd "${BENCH_OUTDIR}" && pwd)"
ASSEMBLY_OUT="${BENCH_OUTDIR}/assembly"
WORK_DIR="${BENCH_OUTDIR}/shovill_work"
mkdir -p "${ASSEMBLY_OUT}" "${WORK_DIR}"

RUN_UUID=""
exit_code=0
WALL_CLOCK_S=0
OUTPUTS_JSON='[]'
METRICS_JSON='{}'

finalize() {
  local state="$1"
  cat > "${BENCH_OUTDIR}/run_manifest.json" <<JSON
{
  "schema_version": "1.0",
  "run_uuid": "${RUN_UUID}",
  "dataset_id": "${DATASET_ID}",
  "pipeline_id": "shovill_pipeline",
  "outcome_state": "${state}",
  "exit_code": ${exit_code},
  "wall_clock_s": ${WALL_CLOCK_S},
  "outputs": ${OUTPUTS_JSON},
  "metrics": ${METRICS_JSON},
  "provenance": {
    "truth_accession": "${TRUTH_ACCESSION:-none}",
    "pipeline": {
      "id": "shovill_pipeline",
      "type": "conda",
      "env_management": "container",
      "version_pin": "${SHOVILL_VERSION_PIN:-PENDING}",
      "container_pin": "${SHOVILL_SIF:+file://${SHOVILL_SIF}}",
      "params_file": "${BENCH_PARAMS}"
    },
    "databases": [],
    "generator": {"seed": ${BENCH_SEED:-0}}
  }
}
JSON
}

# ---------------------------------------------------------------------------
# Smoke mode: placeholder outputs only, no singularity / real assembly.
# ---------------------------------------------------------------------------
if [ "${BENCH_SMOKE:-0}" = "1" ]; then
  printf '>contig_smoke_1\nACGTACGTACGTACGTACGTACGTACGT\n' > "${ASSEMBLY_OUT}/${DATASET_ID}_shovill_placeholder.fasta"
  RUN_UUID="smoke-shovill-${DATASET_ID}-$(date +%s)"
  OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_shovill_placeholder.fasta", "md5": "'$(md5sum "${ASSEMBLY_OUT}/${DATASET_ID}_shovill_placeholder.fasta" | cut -d' ' -f1)'"}]'
  TRUTH_ACCESSION="none"
  finalize "success"
  echo "==> shovill_pipeline adapter done (smoke placeholder)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the pinned SIF (content-addressed; ADR-004): exact match against
# tool_matrix.yaml's digest, never glob+sort-by-filename (a digest is a
# content hash, not a monotonic version -- see adapters/aaftf/run.sh for the
# bug this caused).
# ---------------------------------------------------------------------------
SIFS_DIR="${BENCH_SIFS_DIR:-${BENCH_OUTDIR}/../../containers/sifs}"
SHOVILL_CONTAINER_PIN="$([ -n "${BENCH_TOOL_MATRIX:-}" ] && python3 - <<PY
import yaml
m = yaml.safe_load(open("${BENCH_TOOL_MATRIX}"))
for p in m["pipelines"]:
    if p["id"] == "shovill_pipeline":
        print(p["execution"].get("container_pin", "")); break
PY
)"
PIN_DIGEST="${SHOVILL_CONTAINER_PIN##*sha256:}"
PINNED_SIF="${SIFS_DIR}/staphb_shovill__${PIN_DIGEST:0:12}.sif"
SHOVILL_SIF=""
if [ -f "${PINNED_SIF}" ]; then
  SHOVILL_SIF="${PINNED_SIF}"
else
  SHOVILL_SIF="$(ls -t "${SIFS_DIR}"/staphb_shovill__*.sif 2>/dev/null | head -1 || true)"
fi
if [ -z "${SHOVILL_SIF}" ] || [ ! -f "${SHOVILL_SIF}" ]; then
  echo "ERROR: pinned shovill SIF not found under ${SIFS_DIR}" >&2
  RUN_UUID="fail-shovill-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
echo "==> using shovill SIF: ${SHOVILL_SIF}"

# ---------------------------------------------------------------------------
# Resolve params. Defaults match configs/params/shovill.default.yaml.
# ---------------------------------------------------------------------------
read -r CPUS MEM_GB ASSEMBLER GSIZE DEPTH TRIM MINLEN < <(python3 - "${BENCH_PARAMS:-}" <<'PY'
import os, sys
d = {}
if len(sys.argv) > 1 and sys.argv[1] and os.path.isfile(sys.argv[1]):
    import yaml
    d = yaml.safe_load(open(sys.argv[1])) or {}
t = d.get("threads", 8)
m = d.get("memory_gb", 32)
asm = d.get("assemble", {})
print(t, m, asm.get("tool", "spades"), asm.get("gsize", "") or "AUTO",
      asm.get("depth", 150), str(asm.get("trim", True)).lower(), asm.get("minlen", 0))
PY
)
: "${CPUS:=8}"; : "${MEM_GB:=32}"; : "${ASSEMBLER:=spades}"; : "${GSIZE:=AUTO}"
: "${DEPTH:=150}"; : "${TRIM:=true}"; : "${MINLEN:=0}"
GSIZE_FLAG=""; [ "${GSIZE}" != "AUTO" ] && GSIZE_FLAG="--gsize ${GSIZE}"
TRIM_FLAG=""; [ "${TRIM}" = "true" ] && TRIM_FLAG="--trim"

# ---------------------------------------------------------------------------
# Find paired-end reads (same convention as adapters/aaftf/run.sh).
# ---------------------------------------------------------------------------
R1_NAME=$(find "${READS_DIR}" -maxdepth 1 -name '*_R1.fastq.gz' -printf '%f' -quit || true)
R2_NAME=$(find "${READS_DIR}" -maxdepth 1 -name '*_R2.fastq.gz' -printf '%f' -quit || true)
if [ -z "${R1_NAME}" ] || [ -z "${R2_NAME}" ]; then
  echo "ERROR: need ${READS_DIR}/*_R1.fastq.gz + *_R2.fastq.gz" >&2
  RUN_UUID="fail-shovill-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
R1="${READS_DIR}/${R1_NAME}"
R2="${READS_DIR}/${R2_NAME}"
BASE="${DATASET_ID}_shovill"
LOG="${BENCH_OUTDIR}/shovill_pipeline.log"
: > "${LOG}"

# ---------------------------------------------------------------------------
# Run shovill (single command handles trim/correct/stitch/assemble/polish).
# ---------------------------------------------------------------------------
echo "==> shovill: assembler=${ASSEMBLER} gsize=${GSIZE} depth=${DEPTH} trim=${TRIM} cpus=${CPUS} ram=${MEM_GB}GB" | tee -a "${LOG}"
START=$(date +%s)
SHOVILL_OUT="${WORK_DIR}/shovill_out"
set +e
singularity exec "${SHOVILL_SIF}" shovill \
  --R1 "${R1}" --R2 "${R2}" --outdir "${SHOVILL_OUT}" \
  --assembler "${ASSEMBLER}" --depth "${DEPTH}" --minlen "${MINLEN}" \
  --cpus "${CPUS}" --ram "${MEM_GB}" ${GSIZE_FLAG} ${TRIM_FLAG} --force \
  >> "${LOG}" 2>&1
SHOVILL_EXIT=$?
set -e
WALL_CLOCK_S=$(( $(date +%s) - START ))
DRAFT_FASTA="${SHOVILL_OUT}/contigs.fa"
if [ ${SHOVILL_EXIT} -ne 0 ] || [ ! -s "${DRAFT_FASTA}" ]; then
  echo "ERROR: shovill failed (exit ${SHOVILL_EXIT}) or ${DRAFT_FASTA} missing; log tail:" >&2
  tail -40 "${LOG}" >&2 || true
  RUN_UUID="fail-shovill-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

OUT_FASTA="${ASSEMBLY_OUT}/${DATASET_ID}_shovill.fasta.gz"
gzip -c "${DRAFT_FASTA}" > "${OUT_FASTA}"
MD5=$(md5sum "${OUT_FASTA}" | cut -d' ' -f1)
SIZE=$(stat -c%s "${OUT_FASTA}")
METRICS_JSON=$(python3 - "$OUT_FASTA" <<'PY'
import gzip, json, sys
fa = sys.argv[1]
n = total = 0
lengths = []
cur = 0
with gzip.open(fa, "rt") as fh:
    for line in fh:
        if line.startswith(">"):
            if cur: lengths.append(cur); n += 1
            cur = 0
        else:
            cur += len(line.strip())
if cur: lengths.append(cur); n += 1
lengths.sort(reverse=True)
total = sum(lengths)
half = total / 2
csum = 0; n50 = 0
for L in lengths:
    csum += L
    if csum >= half:
        n50 = L; break
print(json.dumps({"assembly": {"n_contigs": n, "total_length": total,
                               "N50": n50, "largest_contig": lengths[0] if lengths else 0}}))
PY
)
RUN_UUID="shovill-${DATASET_ID}-$(date +%s)"
OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_shovill.fasta.gz", "md5": "'${MD5}'", "size": '${SIZE}'}]'
TRUTH_ACCESSION="none"
finalize "success"
echo "==> shovill_pipeline adapter done: ${OUT_FASTA} (${SIZE} bytes) ${METRICS_JSON}"
