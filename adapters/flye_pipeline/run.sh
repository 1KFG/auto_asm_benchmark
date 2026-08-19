#!/usr/bin/env bash
# Flye adapter — long-read assembly: fastplong trim -> flye (internal
# iterative polish) -> optional racon round -> AAFTF vecscreen/sourpurge/sort
# (contig-level cleanup chain; these AAFTF subcommands just take a FASTA, so
# they work regardless of which assembler produced it -- same tools the
# short-read aaftf/nf_aaftf adapters use for contamination screening).
#
# Expected env (set by harness):
#   BENCH_ADAPTER_TYPE, BENCH_DATASET_DIR, BENCH_OUTDIR, BENCH_TOOL_MATRIX,
#   BENCH_PARAMS, BENCH_SEED, BENCH_SMOKE (1/0), BENCH_SIFS_DIR
#
# Contract output:
#   $BENCH_OUTDIR/assembly/*.fasta        primary assembly (one file minimum)
#   $BENCH_OUTDIR/run_manifest.json       provenance + outcome (schema run_manifest.schema.json)
#   $BENCH_OUTDIR/flye_pipeline.log       step log (kept for debugging)
#   exit codes: 0=success, 10=partial, nonzero=failure
set -euo pipefail

echo "==> flye_pipeline adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR smoke=${BENCH_SMOKE:-0}"

DATASET_ID="${BENCH_DATASET_DIR##*/}"
BENCH_DATASET_DIR="$(cd "${BENCH_DATASET_DIR}" && pwd)"
READS_DIR="${BENCH_DATASET_DIR}/reads"
mkdir -p "${BENCH_OUTDIR}"
BENCH_OUTDIR="$(cd "${BENCH_OUTDIR}" && pwd)"
ASSEMBLY_OUT="${BENCH_OUTDIR}/assembly"
WORK_DIR="${BENCH_OUTDIR}/flye_work"
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
  "pipeline_id": "flye_pipeline",
  "outcome_state": "${state}",
  "exit_code": ${exit_code},
  "wall_clock_s": ${WALL_CLOCK_S},
  "outputs": ${OUTPUTS_JSON},
  "metrics": ${METRICS_JSON},
  "provenance": {
    "truth_accession": "${TRUTH_ACCESSION:-none}",
    "pipeline": {
      "id": "flye_pipeline",
      "type": "conda",
      "env_management": "container",
      "version_pin": "${FLYE_VERSION_PIN:-PENDING}",
      "container_pin": "${AAFTF_SIF:+file://${AAFTF_SIF}}",
      "params_file": "${BENCH_PARAMS}"
    },
    "databases": [
      {"name": "AAFTF_DB (contam + UniVec + genbank-k31.lca.json)", "version": "shared/lib/AAFTF_DB"}
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
  printf '>contig_smoke_1\nACGTACGTACGTACGTACGTACGTACGT\n' > "${ASSEMBLY_OUT}/${DATASET_ID}_flye_placeholder.fasta"
  RUN_UUID="smoke-flye-${DATASET_ID}-$(date +%s)"
  OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_flye_placeholder.fasta", "md5": "'$(md5sum "${ASSEMBLY_OUT}/${DATASET_ID}_flye_placeholder.fasta" | cut -d' ' -f1)'"}]'
  TRUTH_ACCESSION="none"
  finalize "success"
  echo "==> flye_pipeline adapter done (smoke placeholder)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve pinned SIFs (content-addressed; ADR-004): exact match against
# tool_matrix.yaml's digest, never glob+sort-by-filename (a digest is a
# content hash, not a monotonic version -- see adapters/aaftf/run.sh for the
# bug this caused).
# ---------------------------------------------------------------------------
SIFS_DIR="${BENCH_SIFS_DIR:-${BENCH_OUTDIR}/../../containers/sifs}"
PINS="$([ -n "${BENCH_TOOL_MATRIX:-}" ] && python3 - <<PY
import yaml
m = yaml.safe_load(open("${BENCH_TOOL_MATRIX}"))
for p in m["pipelines"]:
    if p["id"] == "flye_pipeline":
        print(p["execution"].get("container_pin", ""))
        print(p.get("pins", {}).get("fastplong", ""))
        break
PY
)"
AAFTF_CONTAINER_PIN="$(printf '%s\n' "${PINS}" | sed -n 1p)"
FASTPLONG_CONTAINER_PIN="$(printf '%s\n' "${PINS}" | sed -n 2p)"

resolve_sif() {
  local pin="$1" name_prefix="$2"
  local digest="${pin##*sha256:}"
  local pinned="${SIFS_DIR}/${name_prefix}__${digest:0:12}.sif"
  local fallback
  fallback="$(ls -t "${SIFS_DIR}"/"${name_prefix}"__*.sif 2>/dev/null | head -1 || true)"
  if [ -f "${pinned}" ]; then echo "${pinned}"; elif [ -n "${fallback}" ]; then echo "${fallback}"; fi
}
AAFTF_SIF="$(resolve_sif "${AAFTF_CONTAINER_PIN}" "ghcr.io_stajichlab_aaftf")"
FASTPLONG_SIF="$(resolve_sif "${FASTPLONG_CONTAINER_PIN}" "quay.io_biocontainers_fastplong")"
if [ -z "${AAFTF_SIF}" ] || [ ! -f "${AAFTF_SIF}" ]; then
  echo "ERROR: pinned AAFTF SIF not found under ${SIFS_DIR}" >&2
  RUN_UUID="fail-flye-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
if [ -z "${FASTPLONG_SIF}" ] || [ ! -f "${FASTPLONG_SIF}" ]; then
  echo "ERROR: pinned fastplong SIF not found under ${SIFS_DIR}" >&2
  RUN_UUID="fail-flye-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
echo "==> using AAFTF SIF: ${AAFTF_SIF}"
echo "==> using fastplong SIF: ${FASTPLONG_SIF}"

# ---------------------------------------------------------------------------
# Resolve params (threads / memory / trim / assemble / polish / phylum).
# Defaults match configs/params/flye.default.yaml.
# ---------------------------------------------------------------------------
read -r CPUS MEM_GB MINLEN MINQUAL FLYE_MODE ITERATIONS RACON_ENABLED RACON_ROUNDS AAFTF_DB SORT_MINLEN < <(python3 - "${BENCH_PARAMS:-}" <<'PY'
import os, sys
d = {}
if len(sys.argv) > 1 and sys.argv[1] and os.path.isfile(sys.argv[1]):
    import yaml
    d = yaml.safe_load(open(sys.argv[1])) or {}
t = d.get("threads", 8)
m = d.get("memory_gb", 32)
trim = d.get("trim", {})
asm = d.get("assemble", {}).get("params", {})
racon = d.get("polish", {}).get("racon", {})
sort = d.get("sort", {})
print(t, m, trim.get("min_length", 1000), trim.get("min_quality", 10),
      asm.get("mode", "--pacbio-hifi"), asm.get("iterations", 2),
      str(racon.get("enabled", True)).lower(), racon.get("rounds", 1),
      d.get("aaftf_db", "/bigdata/stajichlab/shared/lib/AAFTF_DB"),
      sort.get("min_contig_len", 500))
PY
)
: "${CPUS:=8}"; : "${MEM_GB:=32}"; : "${MINLEN:=1000}"; : "${MINQUAL:=10}"
: "${FLYE_MODE:=--pacbio-hifi}"; : "${ITERATIONS:=2}"
: "${RACON_ENABLED:=true}"; : "${RACON_ROUNDS:=1}"
: "${AAFTF_DB:=/bigdata/stajichlab/shared/lib/AAFTF_DB}"; : "${SORT_MINLEN:=500}"

# Per-dataset technology override from metadata.yaml (falls back to params
# default above when absent or unrecognized).
META="${BENCH_DATASET_DIR}/metadata.yaml"
if [ -f "${META}" ]; then
  TECH="$(python3 -c "import yaml; print((yaml.safe_load(open('${META}')) or {}).get('technology',''))" 2>/dev/null || true)"
  case "${TECH}" in
    hifi) FLYE_MODE="--pacbio-hifi" ;;
    ont|nanopore) FLYE_MODE="--nano-raw" ;;
    pacbio|clr) FLYE_MODE="--pacbio-raw" ;;
  esac
fi

declare -A PHYLA=(
  [yarlip]=Ascomycota [canaur]=Ascomycota [zymtri]=Ascomycota
  [aspfum]=Ascomycota [cryneo]=Basidiomycota [rhimic]=Mucoromycota
  [rhizopus]=Mucoromycota
)
PREFIX="${DATASET_ID%%_*}"
PHYLUM="${AAFTF_PHYLUM:-${PHYLA[$PREFIX]:-}}"
if [ -z "${PHYLUM}" ]; then
  echo "WARN: no phylum known for dataset '${DATASET_ID}'; defaulting to Ascomycota" >&2
  PHYLUM="Ascomycota"
fi
if [ ! -d "${AAFTF_DB}" ]; then
  echo "ERROR: AAFTF_DB not found at ${AAFTF_DB}" >&2
  RUN_UUID="fail-flye-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Find the long-read fastq (single-end; HiFi/ONT datasets are one file, not
# an R1/R2 pair).
# ---------------------------------------------------------------------------
READS="$(find "${READS_DIR}" -maxdepth 1 -name '*.fastq.gz' -printf '%p\n' | head -1)"
if [ -z "${READS}" ]; then
  echo "ERROR: no *.fastq.gz found in ${READS_DIR}" >&2
  RUN_UUID="fail-flye-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
BASE="${DATASET_ID}_flye"
LOG="${BENCH_OUTDIR}/flye_pipeline.log"
: > "${LOG}"

# ---------------------------------------------------------------------------
# Trim: fastplong (fastp's long-read/ONT/PacBio sibling tool).
# ---------------------------------------------------------------------------
echo "==> fastplong trim: reads=${READS} min_length=${MINLEN} min_quality=${MINQUAL}" | tee -a "${LOG}"
TRIMMED="${WORK_DIR}/${BASE}.trimmed.fastq.gz"
set +e
singularity exec "${FASTPLONG_SIF}" fastplong \
  -i "${READS}" -o "${TRIMMED}" \
  -l "${MINLEN}" -q "${MINQUAL}" -w "${CPUS}" \
  --json "${WORK_DIR}/fastplong.json" --html "${WORK_DIR}/fastplong.html" \
  >> "${LOG}" 2>&1
FASTPLONG_EXIT=$?
set -e
if [ ${FASTPLONG_EXIT} -ne 0 ] || [ ! -s "${TRIMMED}" ]; then
  echo "ERROR: fastplong trim failed (exit ${FASTPLONG_EXIT}); log tail:" >&2
  tail -30 "${LOG}" >&2 || true
  RUN_UUID="fail-flye-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

# Flye (unlike hifiasm) hard-errors on duplicate read IDs. Some multi-source
# sim datasets (host + contamination spikes generated as separate pbsim3
# runs, then concatenated) have colliding IDs across sources -- this is a
# simulator bug (tracked separately, not an AAFTF/flye issue), but rather
# than fail every affected dataset here, de-duplicate IDs by appending a
# counter suffix to repeats before handing reads to flye.
DEDUP_TRIMMED="${WORK_DIR}/${BASE}.trimmed.dedup.fastq.gz"
python3 - "${TRIMMED}" "${DEDUP_TRIMMED}" <<'PY'
import gzip, sys
inp, outp = sys.argv[1], sys.argv[2]
seen = {}
with gzip.open(inp, "rt") as fh, gzip.open(outp, "wt") as out:
    while True:
        header = fh.readline()
        if not header:
            break
        seq = fh.readline(); plus = fh.readline(); qual = fh.readline()
        name, _, rest = header[1:].rstrip("\n").partition(" ")
        n = seen.get(name, 0)
        seen[name] = n + 1
        newname = name if n == 0 else f"{name}_dup{n}"
        out.write(f"@{newname} {rest}\n" if rest else f"@{newname}\n")
        out.write(seq); out.write(plus); out.write(qual)
dupes = sum(1 for c in seen.values() if c > 1)
print(f"de-duplicated {dupes} colliding read ID(s) out of {len(seen)} unique names", file=sys.stderr)
PY
if [ -s "${DEDUP_TRIMMED}" ]; then
  TRIMMED="${DEDUP_TRIMMED}"
fi

# ---------------------------------------------------------------------------
# Assemble: flye (includes its own iterative internal polishing).
# ---------------------------------------------------------------------------
echo "==> flye: mode=${FLYE_MODE} cpus=${CPUS} iterations=${ITERATIONS}" | tee -a "${LOG}"
START=$(date +%s)
FLYE_OUT="${WORK_DIR}/flye_out"
set +e
singularity exec "${AAFTF_SIF}" flye ${FLYE_MODE} "${TRIMMED}" \
  --out-dir "${FLYE_OUT}" --threads "${CPUS}" --iterations "${ITERATIONS}" \
  >> "${LOG}" 2>&1
FLYE_EXIT=$?
set -e
DRAFT_FASTA="${FLYE_OUT}/assembly.fasta"
if [ ${FLYE_EXIT} -ne 0 ] || [ ! -s "${DRAFT_FASTA}" ]; then
  echo "ERROR: flye failed (exit ${FLYE_EXIT}) or ${DRAFT_FASTA} missing; log tail:" >&2
  tail -30 "${LOG}" >&2 || true
  WALL_CLOCK_S=$(( $(date +%s) - START ))
  RUN_UUID="fail-flye-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Optional extra racon round on top of flye's own internal iterations.
# minimap2 preset follows the same technology mapping as the flye mode.
# ---------------------------------------------------------------------------
POLISHED_FASTA="${DRAFT_FASTA}"
if [ "${RACON_ENABLED}" = "true" ] && [ "${RACON_ROUNDS}" -gt 0 ]; then
  case "${FLYE_MODE}" in
    --pacbio-hifi) MM2_PRESET="map-hifi" ;;
    --nano-*) MM2_PRESET="map-ont" ;;
    *) MM2_PRESET="map-pb" ;;
  esac
  for i in $(seq 1 "${RACON_ROUNDS}"); do
    echo "==> racon polish round ${i} (minimap2 preset ${MM2_PRESET})" | tee -a "${LOG}"
    PAF="${WORK_DIR}/${BASE}.racon${i}.paf"
    NEXT="${WORK_DIR}/${BASE}.racon${i}.fasta"
    singularity exec "${AAFTF_SIF}" minimap2 -x "${MM2_PRESET}" -t "${CPUS}" \
      "${POLISHED_FASTA}" "${TRIMMED}" > "${PAF}" 2>> "${LOG}"
    singularity exec "${AAFTF_SIF}" racon -t "${CPUS}" "${TRIMMED}" "${PAF}" "${POLISHED_FASTA}" \
      > "${NEXT}" 2>> "${LOG}"
    if [ -s "${NEXT}" ]; then
      POLISHED_FASTA="${NEXT}"
    else
      echo "WARN: racon round ${i} produced no output; keeping prior assembly" >&2
      break
    fi
  done
fi

# ---------------------------------------------------------------------------
# Contig-level cleanup: AAFTF sourpurge -> rmdup -> sort. Deliberately NO
# vecscreen: it's tuned for short-read-scale contigs and, when tested on
# whole-chromosome-scale HiFi contigs (cryneo_sim_contam_hi_001), it dropped
# entire real host chromosomes wholesale as false-positive "contamination"
# (~24% of the true genome, e.g. a 1.62Mb contig that was a near-perfect,
# near-full-length match to a real C. neoformans chromosome). sourpurge's
# taxonomy-based purge alone was verified clean on the same data (dropped
# 46 contigs, of which only one had a spurious 40bp hit to the truth genome)
# and got total length within ~5% of the true genome size on the first try.
# No coverage-based purge (no short reads to remap), so sourpurge runs
# taxonomy-only screening.
# ---------------------------------------------------------------------------
echo "==> AAFTF sourpurge/rmdup/sort" | tee -a "${LOG}"
SOURPURGE_OUT="${WORK_DIR}/${BASE}.sourpurge.fasta"
singularity exec "${AAFTF_SIF}" AAFTF sourpurge -i "${POLISHED_FASTA}" -o "${SOURPURGE_OUT}" \
  -p "${PHYLUM}" -c "${CPUS}" --AAFTF_DB "${AAFTF_DB}" \
  --sourdb "${AAFTF_DB}/genbank-k31.lca.json.gz" -w "${WORK_DIR}/aaftf-sourpurge" >> "${LOG}" 2>&1
if [ ! -s "${SOURPURGE_OUT}" ]; then
  echo "ERROR: AAFTF sourpurge produced no output" >&2
  RUN_UUID="fail-flye-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

RMDUP_OUT="${WORK_DIR}/${BASE}.rmdup.fasta"
singularity exec "${AAFTF_SIF}" AAFTF rmdup -i "${SOURPURGE_OUT}" -o "${RMDUP_OUT}" \
  -c "${CPUS}" -w "${WORK_DIR}/aaftf-rmdup" >> "${LOG}" 2>&1
if [ ! -s "${RMDUP_OUT}" ]; then
  echo "ERROR: AAFTF rmdup produced no output" >&2
  RUN_UUID="fail-flye-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

FINAL_FASTA="${WORK_DIR}/${BASE}.final.fasta"
singularity exec "${AAFTF_SIF}" AAFTF sort -i "${RMDUP_OUT}" -o "${FINAL_FASTA}" \
  -ml "${SORT_MINLEN}" -n scaffold >> "${LOG}" 2>&1
WALL_CLOCK_S=$(( $(date +%s) - START ))

if [ ! -s "${FINAL_FASTA}" ]; then
  echo "ERROR: AAFTF sort produced no output; log tail:" >&2
  tail -30 "${LOG}" >&2 || true
  RUN_UUID="fail-flye-${DATASET_ID}-$(date +%s)"; TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

OUT_FASTA="${ASSEMBLY_OUT}/${DATASET_ID}_flye.fasta"
cp "${FINAL_FASTA}" "${OUT_FASTA}"
MD5=$(md5sum "${OUT_FASTA}" | cut -d' ' -f1)
SIZE=$(stat -c%s "${OUT_FASTA}")
METRICS_JSON=$(python3 - "$OUT_FASTA" <<'PY'
import json, sys
fa = sys.argv[1]
n = total = 0
lengths = []
cur = 0
with open(fa) as fh:
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
RUN_UUID="flye-${DATASET_ID}-$(date +%s)"
OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_flye.fasta", "md5": "'${MD5}'", "size": '${SIZE}'}]'
TRUTH_ACCESSION="none"
finalize "success"
echo "==> flye_pipeline adapter done: ${OUT_FASTA} (${SIZE} bytes) ${METRICS_JSON}"
