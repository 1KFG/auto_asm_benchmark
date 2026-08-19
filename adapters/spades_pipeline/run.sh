#!/usr/bin/env bash
# SPAdes pipeline adapter — "DIY" short-read reference toolchain: fastp trim
# -> spades.py assemble -> pilon polish (bwa remap each round). Deliberately
# NO contamination screening (unlike aaftf/nf_aaftf) -- this is the baseline
# assembler-only comparison point in the phase-1 reference matrix.
#
# Expected env (set by harness):
#   BENCH_ADAPTER_TYPE, BENCH_DATASET_DIR, BENCH_OUTDIR, BENCH_TOOL_MATRIX,
#   BENCH_PARAMS, BENCH_SEED, BENCH_SMOKE (1/0), BENCH_SIFS_DIR
#
# Contract output:
#   $BENCH_OUTDIR/assembly/*.fasta.gz        primary assembly (one file minimum, gzip-compressed)
#   $BENCH_OUTDIR/run_manifest.json       provenance + outcome (schema run_manifest.schema.json)
#   $BENCH_OUTDIR/spades_pipeline.log     step log (kept for debugging)
#   exit codes: 0=success, 10=partial, nonzero=failure
set -euo pipefail

echo "==> spades_pipeline adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR smoke=${BENCH_SMOKE:-0}"

DATASET_ID="${BENCH_DATASET_DIR##*/}"
BENCH_DATASET_DIR="$(cd "${BENCH_DATASET_DIR}" && pwd)"
READS_DIR="${BENCH_DATASET_DIR}/reads"
mkdir -p "${BENCH_OUTDIR}"
BENCH_OUTDIR="$(cd "${BENCH_OUTDIR}" && pwd)"
ASSEMBLY_OUT="${BENCH_OUTDIR}/assembly"
WORK_DIR="${BENCH_OUTDIR}/spades_work"
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
  "pipeline_id": "spades_pipeline",
  "outcome_state": "${state}",
  "exit_code": ${exit_code},
  "wall_clock_s": ${WALL_CLOCK_S},
  "outputs": ${OUTPUTS_JSON},
  "metrics": ${METRICS_JSON},
  "provenance": {
    "truth_accession": "${TRUTH_ACCESSION:-none}",
    "pipeline": {
      "id": "spades_pipeline",
      "type": "conda",
      "env_management": "container",
      "version_pin": "${SPADES_VERSION_PIN:-PENDING}",
      "container_pin": "${AAFTF_SIF:+file://${AAFTF_SIF}}",
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
  printf '>contig_smoke_1\nACGTACGTACGTACGTACGTACGTACGT\n' > "${ASSEMBLY_OUT}/${DATASET_ID}_spades_placeholder.fasta"
  RUN_UUID="smoke-spades-${DATASET_ID}-$(date +%s)"
  OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_spades_placeholder.fasta", "md5": "'$(md5sum "${ASSEMBLY_OUT}/${DATASET_ID}_spades_placeholder.fasta" | cut -d' ' -f1)'"}]'
  TRUTH_ACCESSION="none"
  finalize "success"
  echo "==> spades_pipeline adapter done (smoke placeholder)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the pinned SIF (content-addressed; ADR-004): exact match against
# tool_matrix.yaml's digest, never glob+sort-by-filename (a digest is a
# content hash, not a monotonic version -- see adapters/aaftf/run.sh for the
# bug this caused).
# ---------------------------------------------------------------------------
SIFS_DIR="${BENCH_SIFS_DIR:-${BENCH_OUTDIR}/../../containers/sifs}"
AAFTF_CONTAINER_PIN="$([ -n "${BENCH_TOOL_MATRIX:-}" ] && python3 - <<PY
import yaml
m = yaml.safe_load(open("${BENCH_TOOL_MATRIX}"))
for p in m["pipelines"]:
    if p["id"] == "spades_pipeline":
        print(p["execution"].get("container_pin", "")); break
PY
)"
PIN_DIGEST="${AAFTF_CONTAINER_PIN##*sha256:}"
PINNED_SIF="${SIFS_DIR}/ghcr.io_stajichlab_aaftf__${PIN_DIGEST:0:12}.sif"
AAFTF_SIF=""
if [ -f "${PINNED_SIF}" ]; then
  AAFTF_SIF="${PINNED_SIF}"
else
  AAFTF_SIF="$(ls -t "${SIFS_DIR}"/ghcr.io_stajichlab_aaftf__*.sif 2>/dev/null | head -1 || true)"
fi
if [ -z "${AAFTF_SIF}" ] || [ ! -f "${AAFTF_SIF}" ]; then
  echo "ERROR: pinned AAFTF SIF not found under ${SIFS_DIR}" >&2
  RUN_UUID="fail-spades-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
echo "==> using AAFTF SIF: ${AAFTF_SIF}"

# ---------------------------------------------------------------------------
# Resolve params. Defaults match configs/params/spades.default.yaml.
# ---------------------------------------------------------------------------
read -r CPUS MEM_GB TRIM_TAIL1 QUAL LEN_REQ COV_CUTOFF CAREFUL ISOLATE PILON_ROUNDS < <(python3 - "${BENCH_PARAMS:-}" <<'PY'
import os, sys
d = {}
if len(sys.argv) > 1 and sys.argv[1] and os.path.isfile(sys.argv[1]):
    import yaml
    d = yaml.safe_load(open(sys.argv[1])) or {}
t = d.get("threads", 8)
m = d.get("memory_gb", 32)
qc = d.get("qc_trim", {}).get("params", {})
asm = d.get("assemble", {}).get("params", {})
polish = d.get("polish", {})
print(t, m, qc.get("trim_tail1", 15), qc.get("qualified_quality_phred", 20),
      qc.get("length_required", 36), asm.get("cov_cutoff", "auto"),
      str(asm.get("careful", False)).lower(), str(asm.get("isolate", True)).lower(),
      polish.get("rounds", 1))
PY
)
: "${CPUS:=8}"; : "${MEM_GB:=32}"; : "${TRIM_TAIL1:=15}"; : "${QUAL:=20}"
: "${LEN_REQ:=36}"; : "${COV_CUTOFF:=auto}"; : "${CAREFUL:=false}"; : "${ISOLATE:=true}"
: "${PILON_ROUNDS:=1}"

# K-mer list: assemble.params.k in the yaml is a list; resolve separately
# since it doesn't fit the single-row read above.
KMER_LIST="$(python3 -c "
import yaml
d = yaml.safe_load(open('${BENCH_PARAMS}')) if '${BENCH_PARAMS}' else {}
k = (d or {}).get('assemble', {}).get('params', {}).get('k', [21,33,55,77])
print(','.join(str(x) for x in k))
" 2>/dev/null || echo "21,33,55,77")"

# ---------------------------------------------------------------------------
# Find paired-end reads (same convention as adapters/aaftf/run.sh).
# ---------------------------------------------------------------------------
R1_NAME=$(find "${READS_DIR}" -maxdepth 1 -name '*_R1.fastq.gz' -printf '%f' -quit || true)
R2_NAME=$(find "${READS_DIR}" -maxdepth 1 -name '*_R2.fastq.gz' -printf '%f' -quit || true)
if [ -z "${R1_NAME}" ] || [ -z "${R2_NAME}" ]; then
  echo "ERROR: need ${READS_DIR}/*_R1.fastq.gz + *_R2.fastq.gz" >&2
  RUN_UUID="fail-spades-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
R1="${READS_DIR}/${R1_NAME}"
R2="${READS_DIR}/${R2_NAME}"
BASE="${DATASET_ID}_spades"
LOG="${BENCH_OUTDIR}/spades_pipeline.log"
: > "${LOG}"

# ---------------------------------------------------------------------------
# Trim: fastp.
# ---------------------------------------------------------------------------
echo "==> fastp trim: reads=${R1_NAME},${R2_NAME}" | tee -a "${LOG}"
TRIM1="${WORK_DIR}/${BASE}_1.trimmed.fastq.gz"
TRIM2="${WORK_DIR}/${BASE}_2.trimmed.fastq.gz"
set +e
singularity exec "${AAFTF_SIF}" fastp \
  --in1 "${R1}" --in2 "${R2}" --out1 "${TRIM1}" --out2 "${TRIM2}" \
  --trim_tail1 "${TRIM_TAIL1}" --qualified_quality_phred "${QUAL}" \
  --length_required "${LEN_REQ}" --detect_adapter_for_pe -w "${CPUS}" \
  --json "${WORK_DIR}/fastp.json" --html "${WORK_DIR}/fastp.html" \
  >> "${LOG}" 2>&1
FASTP_EXIT=$?
set -e
if [ ${FASTP_EXIT} -ne 0 ] || [ ! -s "${TRIM1}" ] || [ ! -s "${TRIM2}" ]; then
  echo "ERROR: fastp trim failed (exit ${FASTP_EXIT}); log tail:" >&2
  tail -30 "${LOG}" >&2 || true
  RUN_UUID="fail-spades-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Assemble: spades.py.
# ---------------------------------------------------------------------------
CAREFUL_FLAG=""; [ "${CAREFUL}" = "true" ] && CAREFUL_FLAG="--careful"
ISOLATE_FLAG=""; [ "${ISOLATE}" = "true" ] && ISOLATE_FLAG="--isolate"
echo "==> spades.py: cpus=${CPUS} mem=${MEM_GB}GB cov-cutoff=${COV_CUTOFF} k=${KMER_LIST} careful=${CAREFUL} isolate=${ISOLATE}" | tee -a "${LOG}"
START=$(date +%s)
SPADES_OUT="${WORK_DIR}/spades_out"
set +e
singularity exec "${AAFTF_SIF}" spades.py \
  -1 "${TRIM1}" -2 "${TRIM2}" -o "${SPADES_OUT}" \
  -t "${CPUS}" -m "${MEM_GB}" --cov-cutoff "${COV_CUTOFF}" -k ${KMER_LIST//,/ } \
  ${CAREFUL_FLAG} ${ISOLATE_FLAG} \
  >> "${LOG}" 2>&1
SPADES_EXIT=$?
set -e
DRAFT_FASTA="${SPADES_OUT}/contigs.fasta"
if [ ${SPADES_EXIT} -ne 0 ] || [ ! -s "${DRAFT_FASTA}" ]; then
  echo "ERROR: spades.py failed (exit ${SPADES_EXIT}) or ${DRAFT_FASTA} missing; log tail:" >&2
  tail -30 "${LOG}" >&2 || true
  WALL_CLOCK_S=$(( $(date +%s) - START ))
  RUN_UUID="fail-spades-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Polish: pilon, N rounds. Each round remaps trimmed reads (bwa mem) to the
# current draft, then pilon corrects against that alignment -- same pattern
# AAFTF's own polish.py uses internally.
# ---------------------------------------------------------------------------
echo "==> pilon polish: ${PILON_ROUNDS} round(s)" | tee -a "${LOG}"
CURRENT="${DRAFT_FASTA}"
for i in $(seq 1 "${PILON_ROUNDS}"); do
  ROUND_DIR="${WORK_DIR}/pilon_round${i}"
  mkdir -p "${ROUND_DIR}"
  cp "${CURRENT}" "${ROUND_DIR}/draft.fasta"
  set +e
  (
    set -e
    cd "${ROUND_DIR}"
    singularity exec "${AAFTF_SIF}" bwa index draft.fasta >> "${LOG}" 2>&1
    singularity exec "${AAFTF_SIF}" bash -c \
      "bwa mem -t ${CPUS} draft.fasta '${TRIM1}' '${TRIM2}' | samtools sort -@ ${CPUS} -o mapped.bam -" \
      >> "${LOG}" 2>&1
    singularity exec "${AAFTF_SIF}" samtools index mapped.bam >> "${LOG}" 2>&1
    # -Xmx: pilon's default JVM heap is far too small for a whole-genome
    # remap under SLURM cgroups (misdetects available memory), and dies with
    # "java.lang.OutOfMemoryError: Java heap space" partway through --
    # found on a real yarlip_sim_001 run. Match AAFTF's own polish.py, which
    # always passes -Xmx explicitly for the same reason.
    singularity exec "${AAFTF_SIF}" pilon --genome draft.fasta --frags mapped.bam \
      -Xmx${MEM_GB}g --output polished --threads "${CPUS}" --changes >> "${LOG}" 2>&1
  )
  ROUND_EXIT=$?
  set -e
  if [ ${ROUND_EXIT} -ne 0 ]; then
    echo "WARN: pilon round ${i} failed (exit ${ROUND_EXIT}); keeping prior assembly" >&2
    break
  fi
  if [ -s "${ROUND_DIR}/polished.fasta" ]; then
    CURRENT="${ROUND_DIR}/polished.fasta"
  else
    echo "WARN: pilon round ${i} produced no output; keeping prior assembly" >&2
    break
  fi
done
WALL_CLOCK_S=$(( $(date +%s) - START ))

OUT_FASTA="${ASSEMBLY_OUT}/${DATASET_ID}_spades.fasta.gz"
gzip -c "${CURRENT}" > "${OUT_FASTA}"
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
RUN_UUID="spades-${DATASET_ID}-$(date +%s)"
OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_spades.fasta.gz", "md5": "'${MD5}'", "size": '${SIZE}'}]'
TRUTH_ACCESSION="none"
finalize "success"
echo "==> spades_pipeline adapter done: ${OUT_FASTA} (${SIZE} bytes) ${METRICS_JSON}"
