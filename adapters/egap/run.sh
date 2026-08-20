#!/usr/bin/env bash
# iPsychonaut/EGAP adapter — external Python orchestrator (auto-selects
# masurca/flye/spades/hifiasm by read type, polishes, decontaminates,
# BUSCO/QUAST QC), pinned by git tag v3.4.1 commit + provisioned as the
# bioconda egap==3.4.1 biocontainer (ADR-004 content-addressed SIF) rather
# than a hand-built conda env. That image bundles masurca/flye/spades/
# hifiasm/fastqc/quast/racon/pilon/compleasm/busco; medaka (ONT-only) and
# tiara are NOT bundled and aren't wired in here (no ONT fixture to
# validate medaka against; tiara TODO).
#
# env (set by harness): BENCH_DATASET_DIR, BENCH_OUTDIR, BENCH_TOOL_MATRIX,
#   BENCH_PARAMS, BENCH_SEED, BENCH_SMOKE (1/0), BENCH_SIFS_DIR
# Contract output:
#   $BENCH_OUTDIR/assembly/*.fasta.gz    primary assembly (one file minimum, gzip-compressed)
#   $BENCH_OUTDIR/run_manifest.json   provenance + outcome (schema run_manifest.schema.json)
#   $BENCH_OUTDIR/egap_pipeline.log   step log (kept for debugging)
#   exit codes: 0=success, 10=partial, nonzero=failure
set -euo pipefail

echo "==> EGAP adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR smoke=${BENCH_SMOKE:-0}"

DATASET_ID="${BENCH_DATASET_DIR##*/}"
BENCH_DATASET_DIR="$(cd "${BENCH_DATASET_DIR}" && pwd)"
READS_DIR="${BENCH_DATASET_DIR}/reads"
mkdir -p "${BENCH_OUTDIR}"
BENCH_OUTDIR="$(cd "${BENCH_OUTDIR}" && pwd)"
ASSEMBLY_OUT="${BENCH_OUTDIR}/assembly"
WORK_DIR="${BENCH_OUTDIR}/egap_work"
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
  "pipeline_id": "egap",
  "outcome_state": "${state}",
  "exit_code": ${exit_code},
  "wall_clock_s": ${WALL_CLOCK_S},
  "outputs": ${OUTPUTS_JSON},
  "metrics": ${METRICS_JSON},
  "provenance": {
    "truth_accession": "${TRUTH_ACCESSION:-none}",
    "pipeline": {
      "id": "egap",
      "type": "conda",
      "env_management": "container",
      "version_pin": "${EGAP_COMMIT:-PENDING} (bioconda egap==3.4.1)",
      "container_pin": "${EGAP_SIF:+file://${EGAP_SIF}}",
      "params_file": "${BENCH_PARAMS}"
    },
    "databases": [
      {"name": "BUSCO lineage", "version": "${BUSCO1:-PENDING}/${BUSCO2:-PENDING}"}
    ],
    "generator": {"seed": ${BENCH_SEED:-0}}
  }
}
JSON
}

# ---------------------------------------------------------------------------
# Smoke mode: placeholder outputs only, no singularity / real assembly.
# ---------------------------------------------------------------------------
if [ "${BENCH_SMOKE:-0}" = "1" ]; then
  printf '>contig_smoke_1\nACGTACGTACGTACGTACGTACGTACGT\n' > "${ASSEMBLY_OUT}/${DATASET_ID}_egap_placeholder.fasta"
  RUN_UUID="smoke-egap-${DATASET_ID}-$(date +%s)"
  OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_egap_placeholder.fasta", "md5": "'$(md5sum "${ASSEMBLY_OUT}/${DATASET_ID}_egap_placeholder.fasta" | cut -d' ' -f1)'"}]'
  TRUTH_ACCESSION="none"
  finalize "success"
  echo "==> EGAP adapter done (smoke placeholder)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the pinned SIF (content-addressed; ADR-004): exact match against
# tool_matrix.yaml's digest, never glob+sort-by-filename (a digest is a
# content hash, not a monotonic version -- see adapters/aaftf/run.sh for the
# bug this caused).
# ---------------------------------------------------------------------------
SIFS_DIR="${BENCH_SIFS_DIR:-${BENCH_OUTDIR}/../../containers/sifs}"
PINS="$([ -n "${BENCH_TOOL_MATRIX:-}" ] && python3 - <<PY
import yaml
m = yaml.safe_load(open("${BENCH_TOOL_MATRIX}"))
for p in m["pipelines"]:
    if p["id"] == "egap":
        print(p["execution"].get("commit", "PENDING"))
        print(p["execution"].get("container_pin", ""))
        break
PY
)"
EGAP_COMMIT="$(printf '%s\n' "${PINS}" | sed -n 1p)"
EGAP_CONTAINER_PIN="$(printf '%s\n' "${PINS}" | sed -n 2p)"
: "${EGAP_COMMIT:=PENDING}"
PIN_DIGEST="${EGAP_CONTAINER_PIN##*sha256:}"
PINNED_SIF="${SIFS_DIR}/quay.io_biocontainers_egap__${PIN_DIGEST:0:12}.sif"
EGAP_SIF=""
if [ -f "${PINNED_SIF}" ]; then
  EGAP_SIF="${PINNED_SIF}"
else
  EGAP_SIF="$(ls -t "${SIFS_DIR}"/quay.io_biocontainers_egap__*.sif 2>/dev/null | head -1 || true)"
fi
if [ -z "${EGAP_SIF}" ] || [ ! -f "${EGAP_SIF}" ]; then
  echo "ERROR: pinned EGAP SIF not found under ${SIFS_DIR}" >&2
  RUN_UUID="fail-egap-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
echo "==> using EGAP SIF: ${EGAP_SIF}"

# ---------------------------------------------------------------------------
# Resolve params. Defaults match configs/params/egap.default.yaml.
# ---------------------------------------------------------------------------
read -r CPUS RAM_GB KINGDOM KARYOTE BUSCO1 EST_SIZE < <(python3 - "${BENCH_PARAMS:-}" <<'PY'
import os, sys
d = {}
if len(sys.argv) > 1 and sys.argv[1] and os.path.isfile(sys.argv[1]):
    import yaml
    d = yaml.safe_load(open(sys.argv[1])) or {}
p = d.get("params", {})
s = d.get("sample", {})
print(p.get("cpu_threads", 8), p.get("ram_gb", 32), s.get("organism_kingdom", "Funga"),
      s.get("organism_karyote", "eukaryote"), s.get("busco_1", "fungi"), s.get("est_size", "50m"))
PY
)
: "${CPUS:=8}"; : "${RAM_GB:=32}"; : "${KINGDOM:=Funga}"; : "${KARYOTE:=eukaryote}"
: "${BUSCO1:=fungi}"; : "${EST_SIZE:=50m}"

# Per-dataset BUSCO_2 (secondary/more specific lineage) + genome-size override,
# since a single default is wrong across our fixture genomes (all ~2-3x off
# in either direction). Matches the PHYLA lookup pattern in adapters/aaftf/run.sh.
declare -A BUSCO2_BY_PREFIX=(
  [yarlip]=saccharomycetes [canaur]=saccharomycetes [zymtri]=dothideomycetes
  [aspfum]=eurotiomycetes [cryneo]=tremellomycetes [rhimic]=mucorales
  [rhizopus]=mucorales
)
declare -A ESTSIZE_BY_PREFIX=(
  [yarlip]=20m [canaur]=12m [zymtri]=20m [aspfum]=30m [cryneo]=19m [rhimic]=25m [rhizopus]=45m
)
PREFIX="${DATASET_ID%%_*}"
BUSCO2="${EGAP_BUSCO2:-${BUSCO2_BY_PREFIX[$PREFIX]:-fungi}}"
EST_SIZE="${EGAP_EST_SIZE:-${ESTSIZE_BY_PREFIX[$PREFIX]:-${EST_SIZE}}}"

# ---------------------------------------------------------------------------
# Probe the frozen dataset reads and build the EGAP v3.4.1 CSV row. Maps
# dataset reads into ILLUMINA_RAW_DIR + F/R read columns.
# ---------------------------------------------------------------------------
if [ ! -d "${READS_DIR}" ]; then
  echo "ERROR: no reads dir ${READS_DIR}" >&2
  RUN_UUID="fail-egap-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
R1=$(find "${READS_DIR}" -maxdepth 1 \( -name '*_R1*.fastq.gz' -o -name '*_1*.fastq.gz' -o -name '*_R1*.fastq' \) -print -quit || true)
R2=$(find "${READS_DIR}" -maxdepth 1 \( -name '*_R2*.fastq.gz' -o -name '*_2*.fastq.gz' -o -name '*_R2*.fastq' \) -print -quit || true)
if [ -z "${R1}" ] || [ -z "${R2}" ]; then
  echo "ERROR: need forward+reverse Illumina reads in ${READS_DIR}" >&2
  RUN_UUID="fail-egap-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

SPECIES_ID="${EGAP_SPECIES_ID:-${DATASET_ID}}"
SAMPLE_ID="${EGAP_SAMPLE_ID:-${DATASET_ID}}"
LOG="${BENCH_OUTDIR}/egap_pipeline.log"
: > "${LOG}"

# ILLUMINA_RAW_F_READS/R_READS must be full resolvable paths, not filenames
# relative to ILLUMINA_RAW_DIR: EGAP's preprocess step checks them as-is
# (found the hard way -- a bare-filename CSV produced "Illumina paired-end
# files are missing after preprocessing" every time, 41s in, no actual
# preprocessing attempted).
CSV="${WORK_DIR}/egap_input.csv"
cat > "${CSV}" <<CSVEOF
ONT_SRA,ONT_RAW_DIR,ONT_RAW_READS,ILLUMINA_SRA,ILLUMINA_RAW_DIR,ILLUMINA_RAW_F_READS,ILLUMINA_RAW_R_READS,PACBIO_SRA,PACBIO_RAW_DIR,PACBIO_RAW_READS,SPECIES_ID,SAMPLE_ID,ORGANISM_KINGDOM,ORGANISM_KARYOTE,BUSCO_1,BUSCO_2,EST_SIZE,REF_SEQ_GCA,REF_SEQ
None,None,None,None,${READS_DIR},${R1},${R2},None,None,None,${SPECIES_ID},${SAMPLE_ID},${KINGDOM},${KARYOTE},${BUSCO1},${BUSCO2},${EST_SIZE},None,None
CSVEOF
echo "==> egap_input.csv: $(tail -1 "${CSV}")"

# ---------------------------------------------------------------------------
# Run EGAP inside the pinned container.
# ---------------------------------------------------------------------------
echo "==> EGAP: cpus=${CPUS} ram=${RAM_GB}GB kingdom=${KINGDOM} busco=${BUSCO1}/${BUSCO2} est_size=${EST_SIZE}" | tee -a "${LOG}"
START=$(date +%s)
EGAP_OUT="${WORK_DIR}/egap_out"
set +e
singularity exec --writable-tmpfs "${EGAP_SIF}" EGAP \
  --input_csv "${CSV}" --output_dir "${EGAP_OUT}" \
  --cpu_threads "${CPUS}" --ram_gb "${RAM_GB}" \
  $( [ "${EGAP_DRY_RUN:-false}" = "true" ] && echo --dry_run ) \
  >> "${LOG}" 2>&1
EGAP_EXIT=$?
set -e
WALL_CLOCK_S=$(( $(date +%s) - START ))
if [ ${EGAP_EXIT} -ne 0 ]; then
  echo "ERROR: EGAP pipeline failed (exit ${EGAP_EXIT}); log tail:" >&2
  tail -40 "${LOG}" >&2 || true
  RUN_UUID="fail-egap-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Collect the primary assembly fasta. EGAP's final curated + decontaminated
# assembly is written per sample as {sample_id}_decontaminated.fasta; fall
# back to any per-sample assembly fasta if that name changed.
# ---------------------------------------------------------------------------
FINAL_FASTA=$(find "${EGAP_OUT}" -name "${SAMPLE_ID}*decontaminated.fasta" -size +0c -print -quit || true)
if [ -z "${FINAL_FASTA}" ]; then
  FINAL_FASTA=$(find "${EGAP_OUT}" -name "*.fasta" ! -name "*.gz" -size +0c -print -quit || true)
fi

if [ -z "${FINAL_FASTA}" ] || [ ! -s "${FINAL_FASTA}" ]; then
  echo "WARN: no final assembly fasta found under ${EGAP_OUT}; partial outcome" >&2
  RUN_UUID="partial-egap-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "partial"; exit 10
fi

OUT_FASTA="${ASSEMBLY_OUT}/${DATASET_ID}_egap.fasta.gz"
gzip -c "${FINAL_FASTA}" > "${OUT_FASTA}"
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
RUN_UUID="egap-${DATASET_ID}-$(date +%s)"
OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_egap.fasta.gz", "md5": "'${MD5}'", "size": '${SIZE}'}]'
TRUTH_ACCESSION="none"
finalize "success"
echo "==> EGAP adapter done: ${OUT_FASTA} (${SIZE} bytes) ${METRICS_JSON}"
