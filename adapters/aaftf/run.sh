#!/usr/bin/env bash
# AAFTF adapter — runs the canonical `AAFTF pipeline` (trim -> mito -> filter
# -> assemble(spades) -> vecscreen -> sourpurge -> rmdup -> polish(pilon) ->
# sort -> assess) inside the pinned AAFTF Singularity image (ADR-004).
#
# AAFTF is declared type: conda / env_management: pixi in tool_matrix (its
# runtime env is a pixi env), but here it is provisioned as the equivalent
# content-addressed SIF built from the SAME pixi.lock + git commit (see
# adapters/aaftf/ and build_sif.sh in the AAFTF repo). Keeps runtime immutable.
#
# Expected env (set by harness, workflows/modules/adapter_conda.nf):
#   BENCH_ADAPTER_TYPE, BENCH_DATASET_DIR, BENCH_OUTDIR, BENCH_TOOL_MATRIX,
#   BENCH_PARAMS, BENCH_SEED, BENCH_SMOKE (1/0), BENCH_SIFS_DIR
#
# Contract output:
#   $BENCH_OUTDIR/assembly/*.fasta        primary assembly (one file minimum)
#   $BENCH_OUTDIR/run_manifest.json       provenance + outcome (schema run_manifest.schema.json)
#   $BENCH_OUTDIR/aaftf_pipeline.log      AAFTF step log (kept for debugging)
#   exit codes: 0=success, 10=partial, nonzero=failure
set -euo pipefail

echo "==> AAFTF adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR smoke=${BENCH_SMOKE:-0}"

DATASET_ID="${BENCH_DATASET_DIR##*/}"
# Resolve to absolute paths up-front: later steps cd into WORK_DIR so relative
# subpaths would otherwise be misresolved from there.
BENCH_DATASET_DIR="$(cd "${BENCH_DATASET_DIR}" && pwd)"
READS_DIR="${BENCH_DATASET_DIR}/reads"
mkdir -p "${BENCH_OUTDIR}"
BENCH_OUTDIR="$(cd "${BENCH_OUTDIR}" && pwd)"
ASSEMBLY_OUT="${BENCH_OUTDIR}/assembly"
WORK_DIR="${BENCH_OUTDIR}/aaftf_work"
mkdir -p "${ASSEMBLY_OUT}" "${WORK_DIR}"

RUN_UUID=""
exit_code=0
WALL_CLOCK_S=0
OUTPUTS_JSON='[]'
METRICS_JSON='{}'
MITO_STATE="unknown"

finalize() {
  local state="$1"
  cat > "${BENCH_OUTDIR}/run_manifest.json" <<JSON
{
  "schema_version": "1.0",
  "run_uuid": "${RUN_UUID}",
  "dataset_id": "${DATASET_ID}",
  "pipeline_id": "aaftf",
  "outcome_state": "${state}",
  "exit_code": ${exit_code},
  "wall_clock_s": ${WALL_CLOCK_S},
  "outputs": ${OUTPUTS_JSON},
  "metrics": ${METRICS_JSON},
  "provenance": {
    "truth_accession": "${TRUTH_ACCESSION:-none}",
    "pipeline": {
      "id": "aaftf",
      "type": "conda",
      "env_management": "pixi",
      "version_pin": "${AAFTF_VERSION_PIN:-PENDING}",
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
  printf '>contig_smoke_1\nACGTACGTACGTACGTACGTACGTACGT\n' > "${ASSEMBLY_OUT}/${DATASET_ID}_aaftf_placeholder.fasta"
  RUN_UUID="smoke-aaftf-${DATASET_ID}-$(date +%s)"
  OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_aaftf_placeholder.fasta", "md5": "'$(md5sum "${ASSEMBLY_OUT}/${DATASET_ID}_aaftf_placeholder.fasta" | cut -d' ' -f1)'"}]'
  TRUTH_ACCESSION="none"
  finalize "success"
  echo "==> AAFTF adapter done (smoke placeholder)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the pinned SIF (content-addressed; ADR-004). Candidates, in order:
#   1. exact match for tool_matrix.yaml's container_pin digest
#   2. most-recently-pulled sibling content-addressed SIF in the repo cache
#      (fallback for dev use without a tool_matrix; NOT used when the pin
#      resolved, since a digest is a content hash, not a monotonic version —
#      sorting by filename or mtime can silently pick an older stale SIF)
#   3. cluster shared cache (fast symlink to AAFTF-latest.sif)
# ---------------------------------------------------------------------------
SIFS_DIR="${BENCH_SIFS_DIR:-${BENCH_OUTDIR}/../../containers/sifs}"
AAFTF_CONTAINER_PIN="$([ -n "${BENCH_TOOL_MATRIX:-}" ] && python3 - <<PY
import yaml
m = yaml.safe_load(open("${BENCH_TOOL_MATRIX}"))
for p in m["pipelines"]:
    if p["id"] == "aaftf":
        print(p["execution"].get("container_pin", "")); break
PY
)"
PIN_DIGEST="${AAFTF_CONTAINER_PIN##*sha256:}"
PINNED_SIF="${SIFS_DIR}/ghcr.io_stajichlab_aaftf__${PIN_DIGEST:0:12}.sif"
SIF_CANDIDATES=(
  "${PINNED_SIF}"
  $(ls -t "${SIFS_DIR}"/ghcr.io_stajichlab_aaftf__*.sif 2>/dev/null | head -1 || true)
  "/bigdata/stajichlab/shared/lib/singularity_cache/AAFTF-latest.sif"
  "/bigdata/stajichlab/shared/lib/singularity_cache/AAFTF.sif"
)
AAFTF_SIF=""
for c in "${SIF_CANDIDATES[@]}"; do
  if [ -n "${c}" ] && [ -f "${c}" ]; then AAFTF_SIF="${c}"; break; fi
done
if [ -z "${AAFTF_SIF}" ]; then
  echo "ERROR: pinned AAFTF.sif not found (checked ${SIF_CANDIDATES[*]})" >&2
  RUN_UUID="fail-aaftf-${DATASET_ID}-$(date +%s)"
  TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
echo "==> using AAFTF SIF: ${AAFTF_SIF}"

# ---------------------------------------------------------------------------
# Resolve canonical params (threads / memory / AAFTF_DB / phylum). Defaults
# match configs/params/aaftf.default.yaml; per-dataset overrides via env.
# ---------------------------------------------------------------------------
read -r AAFTF_CPUS AAFTF_MEM_GB AAFTF_DB AAFTF_TAXID < <(python3 - "${BENCH_PARAMS:-}" <<'PY'
import os, sys
d = {}
if len(sys.argv) > 1 and sys.argv[1] and os.path.isfile(sys.argv[1]):
    import yaml
    d = yaml.safe_load(open(sys.argv[1])) or {}
t = d.get("threads", 8)
m = d.get("memory_gb", 32)
db = d.get("aaftf_db", "/bigdata/stajichlab/shared/lib/AAFTF_DB")
print(f"{t} {m} {db} {d.get('phylum','')}")
PY
)
: "${AAFTF_CPUS:=8}"
: "${AAFTF_MEM_GB:=32}"
: "${AAFTF_DB:=/bigdata/stajichlab/shared/lib/AAFTF_DB}"
: "${AAFTF_TAXID:=}"

# Phylum for the AAFTF sourpurge step (sourmash LCA purge keeps reads of the
# target phylum). Per-dataset lookup by folder_id prefix; override with
# AAFTF_PHYLUM. Fall back to the Fungi default Ascomycota with a warning.
declare -A PHYLA=(
  [yarlip]=Ascomycota [canaur]=Ascomycota [zymtri]=Ascomycota
  [aspfum]=Ascomycota [cryneo]=Basidiomycota [rhimic]=Mucoromycota
  [rhizopus]=Mucoromycota
)
PREFIX="${DATASET_ID%%_*}"
PHYLUM="${AAFTF_PHYLUM:-${AAFTF_TAXID:-${PHYLA[$PREFIX]:-}}}"
if [ -z "${PHYLUM}" ]; then
  echo "WARN: no phylum known for dataset '${DATASET_ID}'; defaulting to Ascomycota" >&2
  PHYLUM="Ascomycota"
fi

if [ ! -d "${AAFTF_DB}" ]; then
  echo "ERROR: AAFTF_DB not found at ${AAFTF_DB} (override with params.aaftf_db)" >&2
  RUN_UUID="fail-aaftf-${DATASET_ID}-$(date +%s)"
  TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Probe the frozen dataset reads (paired-end Illumina fixture).
# ---------------------------------------------------------------------------
R1_NAME=$(find "${READS_DIR}" -maxdepth 1 -name '*_R1.fastq.gz' -printf '%f' -quit || true)
R2_NAME=$(find "${READS_DIR}" -maxdepth 1 -name '*_R2.fastq.gz' -printf '%f' -quit || true)
if [ -z "${R1_NAME}" ] || [ -z "${R2_NAME}" ]; then
  echo "ERROR: need ${READS_DIR}/*_R1.fastq.gz + *_R2.fastq.gz" >&2
  RUN_UUID="fail-aaftf-${DATASET_ID}-$(date +%s)"
  TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
R1="${READS_DIR}/${R1_NAME}"
R2="${READS_DIR}/${R2_NAME}"
BASE="${DATASET_ID}_aaftf"

# ---------------------------------------------------------------------------
# Mito-stage presence probe (NOVOPlasty).
# `AAFTF pipeline` unconditionally runs a mitochondrial NOVOPlasty assembly for
# PE reads, and current AAFTF hard-crashes (mito.py: open(None)) whenever
# NOVOPlasty cannot produce a contig. Datasets whose truth reference has no
# mitochondrial chromosome (e.g. yarlip_sim_001) contain zero mito reads, so
# NOVOPlasty can never succeed there. We k-mer probe the reads with AAFTF's OWN
# bundled mito seed (extracted from the pinned SIF, byte-identical to what the
# tool uses) and, when mito is absent, pre-place the pipeline's official
# "already assembled" marker `$BASE.mito.fasta` so the real trim -> filter ->
# assemble -> ... steps still run. The marker also serves as a FILTER
# screen_local ref where its single base contributes no k=27 matches, i.e. it
# screens nothing (verified against AAFTF/filter.py + bbduk k=27). The probe
# outcome is recorded in the manifest ("mito"). See scripts/mito_probe.py.
# ---------------------------------------------------------------------------
PROBE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/mito_probe.py"
singularity exec "${AAFTF_SIF}" cat /opt/AAFTF/AAFTF/data/mito-seed.fasta \
  > "${WORK_DIR}/mito-seed.fasta"
MITO_STATE="$(python3 "${PROBE}" --r1 "${R1}" --seed "${WORK_DIR}/mito-seed.fasta" \
  | tail -1)"
case "${MITO_STATE}" in
  present)
    echo "==> mito probe: mitochondrial reads present; AAFTF mito stage enabled"
    ;;
  absent)
    echo "==> mito probe: no mitochondrial reads; marking AAFTF mito stage done"
    printf '>no_mito_assembly\nA\n' > "${WORK_DIR}/${BASE}.mito.fasta"
    ;;
  *)
    echo "WARN: mito probe returned '${MITO_STATE}'; proceeding without placeholder" >&2
    MITO_STATE="unknown"
    ;;
esac

# ---------------------------------------------------------------------------
# Run the canonical AAFTF pipeline inside the pinned SIF.
# AAFTF writes ${BASE}.* intermediates + ${BASE}.final.fasta into the CWD, so
# we run from WORK_DIR. --AAFTF_DB is host path (auto-mounted); --sourdb the
# sourmash LCA taxonomy DB; -p the target phylum for contamination purge.
#
# Deliberately no -w/--workdir: `AAFTF pipeline` reuses that single directory
# across filter/assemble/vecscreen/sourpurge/rmdup/polish, but filter.py only
# deletes it when the caller did NOT supply -w (custom_workdir guard in
# AAFTF/filter.py). With a custom -w, the leftover directory from the filter
# step already exists by the time assemble.py runs, and assemble.py treats
# any pre-existing workdir as evidence of a prior run and switches to
# `spades.py --restart-from last`, which then fails outright with no
# checkpoint to resume ("params.txt not found"). Omitting -w lets each step
# fall back to its own private uuid-named scratch dir under CWD, so no step
# ever sees another step's leftover directory.
# ---------------------------------------------------------------------------
run_aaftf_pipeline() {
  (
    cd "${WORK_DIR}"
    singularity exec "${AAFTF_SIF}" AAFTF pipeline \
      -l "${R1}" -r "${R2}" \
      -o "${BASE}" \
      -c "${AAFTF_CPUS}" -m "${AAFTF_MEM_GB}" \
      -ml 75 -mc 500 \
      --AAFTF_DB "${AAFTF_DB}" \
      --sourdb "${AAFTF_DB}/genbank-k31.lca.json.gz" \
      -p "${PHYLUM}" \
      > "${BENCH_OUTDIR}/aaftf_pipeline.log" 2>&1
  )
}

echo "==> AAFTF pipeline: reads=${R1_NAME},${R2_NAME} cpus=${AAFTF_CPUS} mem=${AAFTF_MEM_GB}GB phylum=${PHYLUM}"
START=$(date +%s)
set +e
run_aaftf_pipeline
AAFTF_EXIT=$?

# Fallback: even when the probe said present/unknown, the mito stage can still
# crash if NOVOPlasty can't extend a divergent mitogenome from the seed. If the
# crash signature is the mito open(None) bug, mark mito done (placeholder) and
# re-run: AAFTF's step-level resume semantics then skip trim+mito and redo
# filter -> assemble -> ... .
if [ ${AAFTF_EXIT} -ne 0 ] \
  && rg -q 'AAFTF/mito\.py' "${BENCH_OUTDIR}/aaftf_pipeline.log" 2>/dev/null \
  && [ ! -f "${WORK_DIR}/${BASE}.mito.fasta" ]; then
  echo "==> AAFTF mito stage crashed (no mito assembled); marking mito done and re-running pipeline"
  printf '>no_mito_assembly\nA\n' > "${WORK_DIR}/${BASE}.mito.fasta"
  MITO_STATE="${MITO_STATE}-then-skipped"
  run_aaftf_pipeline
  AAFTF_EXIT=$?
fi
set -e
WALL_CLOCK_S=$(( $(date +%s) - START ))

# ---------------------------------------------------------------------------
# Collect the final sorted/renamed assembly.
# ---------------------------------------------------------------------------
FINAL_FASTA="${WORK_DIR}/${BASE}.final.fasta"
if [ ${AAFTF_EXIT} -eq 0 ] && [ -s "${FINAL_FASTA}" ]; then
  OUT_FASTA="${ASSEMBLY_OUT}/${DATASET_ID}_aaftf.fasta"
  cp "${FINAL_FASTA}" "${OUT_FASTA}"
  MD5=$(md5sum "${OUT_FASTA}" | cut -d' ' -f1)
  SIZE=$(stat -c%s "${OUT_FASTA}")
  # Real (cheap) assembly metrics from the final fasta, proving the metrics
  # path end-to-end: n_contigs, total_length, N50, largest.
  METRICS_JSON=$(MITO_STATE="${MITO_STATE}" python3 - "$OUT_FASTA" <<'PY'
import json, os, sys
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
print(json.dumps({
  "mito": os.environ.get("MITO_STATE", "unknown"),
  "assembly": {"n_contigs": n, "total_length": total,
               "N50": n50, "largest_contig": lengths[0] if lengths else 0}
}))
PY
)
  RUN_UUID="aaftf-${DATASET_ID}-$(date +%s)"
  OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_aaftf.fasta", "md5": "'${MD5}'", "size": '${SIZE}'}]'
  TRUTH_ACCESSION="none"
  finalize "success"
  echo "==> AAFTF adapter done: ${OUT_FASTA} (${SIZE} bytes) ${METRICS_JSON}"
  exit 0
fi

if [ ${AAFTF_EXIT} -eq 0 ]; then
  # pipeline ran but no final assembly — partial outcome (last 30 log lines)
  echo "WARN: AAFTF pipeline exited 0 but no final assembly ${FINAL_FASTA}" >&2
  tail -30 "${BENCH_OUTDIR}/aaftf_pipeline.log" >&2 || true
  RUN_UUID="partial-aaftf-${DATASET_ID}-$(date +%s)"
  TRUTH_ACCESSION="none"
  finalize "partial"; exit 10
fi

echo "ERROR: AAFTF pipeline failed (exit ${AAFTF_EXIT}); log tail:" >&2
tail -30 "${BENCH_OUTDIR}/aaftf_pipeline.log" >&2 || true
RUN_UUID="fail-aaftf-${DATASET_ID}-$(date +%s)"
TRUTH_ACCESSION="none"
finalize "failed"; exit ${AAFTF_EXIT}
