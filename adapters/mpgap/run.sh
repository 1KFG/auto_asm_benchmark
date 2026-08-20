#!/usr/bin/env bash
# fmalmeida/MpGAP adapter — external Nextflow multi-assembler pipeline,
# pinned by commit (ADR-004: never vendor). MpGAP publishes one assembly
# PER enabled assembler rather than auto-selecting a single best one, so to
# keep our one-primary-output-per-run contract and give a clean comparison
# point against the other short-read pipelines here, only spades is left
# enabled by default (see configs/params/mpgap.default.yaml).
#
# env (set by harness): BENCH_DATASET_DIR, BENCH_OUTDIR, BENCH_TOOL_MATRIX,
#   BENCH_PARAMS, BENCH_SEED, BENCH_SMOKE (1/0), BENCH_SIFS_DIR
# Contract output:
#   $BENCH_OUTDIR/assembly/*.fasta.gz    primary assembly (one file minimum, gzip-compressed)
#   $BENCH_OUTDIR/run_manifest.json   provenance + outcome (schema run_manifest.schema.json)
#   $BENCH_OUTDIR/mpgap_pipeline.log  step log (kept for debugging)
#   exit codes: 0=success, 10=partial, nonzero=failure
set -euo pipefail

# MpGAP's pinned commit's nextflow.config wraps includeConfig in a bare
# try/catch block (for optional nf-core custom-config loading) -- valid
# Groovy in older Nextflow config parsers, but rejected outright by modern
# ones ("Try-catch blocks cannot be mixed with config statements"). Verified
# nextflow/23.10.4 parses it fine; the cluster default (26.04.6) does not.
# Pin an older nextflow just for this adapter rather than touch the
# cluster-wide default or fork the external repo.
source /etc/profile.d/modules.sh 2>/dev/null || true
module load nextflow/23.10.4 2>/dev/null || true

echo "==> MpGAP adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR smoke=${BENCH_SMOKE:-0}"

DATASET_ID="${BENCH_DATASET_DIR##*/}"
BENCH_DATASET_DIR="$(cd "${BENCH_DATASET_DIR}" && pwd)"
READS_DIR="${BENCH_DATASET_DIR}/reads"
mkdir -p "${BENCH_OUTDIR}"
BENCH_OUTDIR="$(cd "${BENCH_OUTDIR}" && pwd)"
ASSEMBLY_OUT="${BENCH_OUTDIR}/assembly"
WORK_DIR="${BENCH_OUTDIR}/mpgap_work"
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
  "pipeline_id": "mpgap",
  "outcome_state": "${state}",
  "exit_code": ${exit_code},
  "wall_clock_s": ${WALL_CLOCK_S},
  "outputs": ${OUTPUTS_JSON},
  "metrics": ${METRICS_JSON},
  "provenance": {
    "truth_accession": "${TRUTH_ACCESSION:-none}",
    "pipeline": {
      "id": "mpgap",
      "type": "nextflow",
      "version_pin": "${MPGAP_COMMIT:-PENDING}",
      "container_pin": "${MPGAP_CONTAINER_PIN:-PENDING}",
      "params_file": "${BENCH_PARAMS}"
    },
    "databases": [],
    "generator": {"seed": ${BENCH_SEED:-0}}
  }
}
JSON
}

# ---------------------------------------------------------------------------
# Smoke mode: placeholder outputs only, no nextflow / real assembly.
# ---------------------------------------------------------------------------
if [ "${BENCH_SMOKE:-0}" = "1" ]; then
  printf '>contig_smoke_1\nACGTACGTACGTACGTACGTACGTACGT\n' > "${ASSEMBLY_OUT}/${DATASET_ID}_mpgap_placeholder.fasta"
  RUN_UUID="smoke-mpgap-${DATASET_ID}-$(date +%s)"
  OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_mpgap_placeholder.fasta", "md5": "'$(md5sum "${ASSEMBLY_OUT}/${DATASET_ID}_mpgap_placeholder.fasta" | cut -d' ' -f1)'"}]'
  TRUTH_ACCESSION="none"
  finalize "success"
  echo "==> MpGAP adapter done (smoke placeholder)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve pins from tool_matrix.yaml (never floating).
# ---------------------------------------------------------------------------
PINS="$([ -n "${BENCH_TOOL_MATRIX:-}" ] && python3 - <<PY
import yaml
m = yaml.safe_load(open("${BENCH_TOOL_MATRIX}"))
for p in m["pipelines"]:
    if p["id"] == "mpgap":
        print(p["execution"].get("repo", ""))
        print(p["execution"].get("commit", "PENDING"))
        print(p["execution"].get("container_pin", "PENDING"))
        break
PY
)"
REPO="$(printf '%s\n' "${PINS}" | sed -n 1p)"
MPGAP_COMMIT="$(printf '%s\n' "${PINS}" | sed -n 2p)"
MPGAP_CONTAINER_PIN="$(printf '%s\n' "${PINS}" | sed -n 3p)"
: "${REPO:=https://github.com/fmalmeida/MpGAP}"
: "${MPGAP_COMMIT:=PENDING}"
: "${MPGAP_CONTAINER_PIN:=PENDING}"

# ---------------------------------------------------------------------------
# Resolve params. Defaults match configs/params/mpgap.default.yaml.
# ---------------------------------------------------------------------------
read -r ORGANISM CPUS MAX_MEMORY < <(python3 - "${BENCH_PARAMS:-}" <<'PY'
import os, sys
d = {}
if len(sys.argv) > 1 and sys.argv[1] and os.path.isfile(sys.argv[1]):
    import yaml
    d = yaml.safe_load(open(sys.argv[1])) or {}
p = d.get("params", {})
print(p.get("organism", "fungus"), p.get("max_cpus", 8), p.get("max_memory", "32.GB"))
PY
)
: "${ORGANISM:=fungus}"; : "${CPUS:=8}"; : "${MAX_MEMORY:=32.GB}"
ENABLED_ASSEMBLERS="$(python3 -c "
import yaml
d = yaml.safe_load(open('${BENCH_PARAMS}')) if '${BENCH_PARAMS}' else {}
print(','.join((d or {}).get('assemble', {}).get('enable', ['spades'])))
" 2>/dev/null || echo "spades")"

# ---------------------------------------------------------------------------
# Find paired-end reads (same convention as adapters/aaftf/run.sh) and build
# the MpGAP YAML samplesheet (samplesheet.html schema).
# ---------------------------------------------------------------------------
R1=$(find "${READS_DIR}" -maxdepth 1 -name '*_R1.fastq.gz' -print -quit || true)
R2=$(find "${READS_DIR}" -maxdepth 1 -name '*_R2.fastq.gz' -print -quit || true)
if [ -z "${R1}" ] || [ -z "${R2}" ]; then
  echo "ERROR: need ${READS_DIR}/*_R1.fastq.gz + *_R2.fastq.gz" >&2
  RUN_UUID="fail-mpgap-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

SAMPLESHEET="${WORK_DIR}/samplesheet.yml"
cat > "${SAMPLESHEET}" <<YAMLEOF
samplesheet:
- id: ${DATASET_ID}
  illumina:
  - ${R1}
  - ${R2}
YAMLEOF
echo "==> samplesheet: $(cat "${SAMPLESHEET}")"

# skip_* flags for every illumina assembler NOT in ENABLED_ASSEMBLERS.
SKIP_FLAGS=""
for a in spades shovill unicycler megahit; do
  case ",${ENABLED_ASSEMBLERS}," in
    *",${a},"*) ;;
    *) SKIP_FLAGS="${SKIP_FLAGS} --skip_${a}" ;;
  esac
done

LOG="${BENCH_OUTDIR}/mpgap_pipeline.log"
: > "${LOG}"

# ---------------------------------------------------------------------------
# Run MpGAP. No -profile slurm: MpGAP ships no SLURM profile of its own (a
# gap vs. nf_AAFTF), so it runs with Nextflow's local executor, sharing this
# adapter's own SLURM allocation (see scripts/run_adapter.sbatch) directly.
# The pipeline's own singularity.config hardcodes its container digest, so
# we don't pass one explicitly -- it self-pulls into Nextflow's shared
# singularity cache on first use, same as nf_AAFTF does.
# ---------------------------------------------------------------------------
echo "==> MpGAP: organism=${ORGANISM} cpus=${CPUS} max_memory=${MAX_MEMORY} assemblers=${ENABLED_ASSEMBLERS}" | tee -a "${LOG}"
START=$(date +%s)
MPGAP_OUT="${WORK_DIR}/results"
set +e
(
  cd "${WORK_DIR}"
  nextflow run "${REPO}" -r "${MPGAP_COMMIT}" \
    -profile singularity \
    --input "${SAMPLESHEET}" \
    --output "${MPGAP_OUT}" \
    --organism "${ORGANISM}" \
    --max_cpus "${CPUS}" --max_memory "${MAX_MEMORY}" \
    ${SKIP_FLAGS} \
    >> "${LOG}" 2>&1
)
MPGAP_EXIT=$?
set -e
WALL_CLOCK_S=$(( $(date +%s) - START ))
if [ ${MPGAP_EXIT} -ne 0 ]; then
  echo "ERROR: MpGAP pipeline failed (exit ${MPGAP_EXIT}); log tail:" >&2
  tail -40 "${LOG}" >&2 || true
  RUN_UUID="fail-mpgap-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Collect the primary assembly fasta. Prefer spades_assembly.fasta (our
# default enabled assembler); fall back to any *_assembly.fasta MpGAP
# publishes under results/<id>/**.
# ---------------------------------------------------------------------------
FINAL_FASTA=$(find "${MPGAP_OUT}" -name "spades_assembly.fasta" -size +0c -print -quit || true)
if [ -z "${FINAL_FASTA}" ]; then
  FINAL_FASTA=$(find "${MPGAP_OUT}" -name "*_assembly.fasta" -size +0c -print -quit || true)
fi
if [ -z "${FINAL_FASTA}" ]; then
  echo "WARN: no final assembly fasta found under ${MPGAP_OUT}; partial outcome" >&2
  RUN_UUID="partial-mpgap-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "partial"; exit 10
fi

OUT_FASTA="${ASSEMBLY_OUT}/${DATASET_ID}_mpgap.fasta.gz"
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
RUN_UUID="mpgap-${DATASET_ID}-$(date +%s)"
OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_mpgap.fasta.gz", "md5": "'${MD5}'", "size": '${SIZE}'}]'
TRUTH_ACCESSION="none"
finalize "success"
echo "==> MpGAP adapter done: ${OUT_FASTA} (${SIZE} bytes) ${METRICS_JSON}"
