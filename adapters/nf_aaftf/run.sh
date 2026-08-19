#!/usr/bin/env bash
# stajichlab/nf_aaftf adapter — external Nextflow workflow, pinned by commit.
# ADR-004: never vendor; pin by immutable commit hash + container digest.
# Real run: `nextflow run $REPO -r $COMMIT -profile aaftf` from a scratch dir,
# with samples.csv + reads under --indir, and the pinned AAFTF.sif passed as
# --aaftf_sif. Collects results/sort/<sample>.sorted.fasta.
# env (set by harness): BENCH_DATASET_DIR, BENCH_OUTDIR, BENCH_TOOL_MATRIX,
#   BENCH_PARAMS, BENCH_SEED, BENCH_SMOKE (1/0), BENCH_SIFS_DIR
# Contract output:
#   $BENCH_OUTDIR/assembly/*.fasta    primary assembly (one file minimum)
#   $BENCH_OUTDIR/run_manifest.json   provenance + outcome (schema run_manifest.schema.json)
#   exit codes: 0=success, 10=partial, nonzero=failure
set -euo pipefail

echo "==> nf_aaftf adapter: dataset=$BENCH_DATASET_DIR out=$BENCH_OUTDIR smoke=${BENCH_SMOKE:-0}"

REPO="https://github.com/stajichlab/nf_AAFTF"
DATASET_ID="${BENCH_DATASET_DIR##*/}"
# Resolve staged dirs to absolute paths up-front: later steps `cd` into
# WORK_DIR, so relative subpaths would otherwise be misresolved from there
# (and `ln -sf` of a relative READ_DIR target within the subshell too).
BENCH_DATASET_DIR="$(cd "${BENCH_DATASET_DIR}" && pwd)"
READS_DIR="${BENCH_DATASET_DIR}/reads"
mkdir -p "${BENCH_OUTDIR}"
BENCH_OUTDIR="$(cd "${BENCH_OUTDIR}" && pwd)"
ASSEMBLY_OUT="${BENCH_OUTDIR}/assembly"
WORK_DIR="${BENCH_OUTDIR}/nf_aaftf_work"
mkdir -p "${ASSEMBLY_OUT}" "${WORK_DIR}"

RUN_UUID=""
exit_code=0
OUTPUTS_JSON='[]'
METRICS_JSON='{}'

finalize() {
  local state="$1"
  cat > "${BENCH_OUTDIR}/run_manifest.json" <<JSON
{
  "schema_version": "1.0",
  "run_uuid": "${RUN_UUID}",
  "dataset_id": "${DATASET_ID}",
  "pipeline_id": "nf_aaftf",
  "outcome_state": "${state}",
  "exit_code": ${exit_code},
  "wall_clock_s": ${WALL_CLOCK_S:-0},
  "outputs": ${OUTPUTS_JSON},
  "metrics": ${METRICS_JSON},
  "provenance": {
    "truth_accession": "${TRUTH_ACCESSION:-none}",
    "pipeline": {
      "id": "nf_aaftf",
      "type": "nextflow",
      "version_pin": "${NF_AAFTF_COMMIT:-PENDING}",
      "container_pin": "${AAFTF_SIF:+file://${AAFTF_SIF}}",
      "params_file": "${BENCH_PARAMS}"
    },
    "databases": [
      {"name": "BUSCO lineage fungi_odb10", "version": "PENDING"}
    ],
    "generator": {"seed": ${BENCH_SEED:-0}}
  }
}
JSON
}

# ---------------------------------------------------------------------------
# Smoke mode: placeholder outputs only, no nested Nextflow / SLURM submission.
# ---------------------------------------------------------------------------
if [ "${BENCH_SMOKE:-0}" = "1" ]; then
  printf '>contig_smoke_1\nACGTACGTACGTACGTACGTACGTACGT\n' > "${ASSEMBLY_OUT}/${DATASET_ID}_nf_aaftf_placeholder.fasta"
  RUN_UUID="smoke-nfaaftf-${DATASET_ID}-$(date +%s)"
  OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_nf_aaftf_placeholder.fasta", "md5": "'$(md5sum "${ASSEMBLY_OUT}/${DATASET_ID}_nf_aaftf_placeholder.fasta" | cut -d' ' -f1)'"}]'
  TRUTH_ACCESSION="none"
  finalize "success"
  echo "==> nf_aaftf adapter done (smoke placeholder)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Real run: resolve the committed pins from the tool matrix (never floating).
# ---------------------------------------------------------------------------
NF_AAFTF_PINS="$([ -n "${BENCH_TOOL_MATRIX:-}" ] && python3 - <<PY
import yaml
m=yaml.safe_load(open("${BENCH_TOOL_MATRIX}"))
for p in m["pipelines"]:
    if p["id"]=="nf_aaftf":
        print(p["execution"].get("commit","PENDING"));
        print(p["execution"].get("container_pin","PENDING")); break
PY
)"
NF_AAFTF_COMMIT="$(printf '%s\n' "${NF_AAFTF_PINS}" | sed -n 1p)"
NF_AAFTF_CONTAINER="$(printf '%s\n' "${NF_AAFTF_PINS}" | sed -n 2p)"
: "${NF_AAFTF_COMMIT:=PENDING}"
: "${NF_AAFTF_CONTAINER:=PENDING}"

# Local pinned SIF (content-addressed in the repo cache built by
# scripts/pull_containers.sh) or fall back to the cluster shared cache path
# used by nf_AAFTF's own aaftf profile default.
#
# Prefer the exact filename derived from tool_matrix.yaml's container_pin
# digest. Sorting the glob by filename (or even mtime) to guess "newest" is
# unreliable — a digest is a content hash, not a monotonic version, so a
# lexicographic sort can pick an OLDER stale SIF over the pinned one whenever
# the new digest's hex prefix happens to sort earlier than an old one still
# present in the cache (observed: old digest "d467..." > new digest
# "0c49..." lexicographically, silently running the wrong container).
SIFS_DIR="${BENCH_SIFS_DIR:-${BENCH_OUTDIR}/../../containers/sifs}"
PIN_DIGEST="${NF_AAFTF_CONTAINER##*sha256:}"
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
  RUN_UUID="fail-nfaaftf-${DATASET_ID}-$(date +%s)"
  TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
echo "==> using AAFTF SIF: ${AAFTF_SIF}"

# ---------------------------------------------------------------------------
# Probe the frozen dataset reads (paired-end Illumina fixture).
# ---------------------------------------------------------------------------
if [ ! -d "${READS_DIR}" ]; then
  echo "ERROR: no reads dir ${READS_DIR}" >&2
  RUN_UUID="fail-nfaaftf-${DATASET_ID}-$(date +%s)"
  TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi
R1_NAME=$(find "${READS_DIR}" -maxdepth 1 -name '*_R1.fastq.gz' -printf '%f' -quit || true)
R2_NAME=$(find "${READS_DIR}" -maxdepth 1 -name '*_R2.fastq.gz' -printf '%f' -quit || true)
if [ -z "${R1_NAME}" ] || [ -z "${R2_NAME}" ]; then
  echo "ERROR: need ${READS_DIR}/*_R1.fastq.gz + *_R2.fastq.gz" >&2
  RUN_UUID="fail-nfaaftf-${DATASET_ID}-$(date +%s)"
  TRUTH_ACCESSION="none"
  finalize "failed"; exit 1
fi

# ── samples.csv (sample,read_1,read_2[,taxid]) ──────────────────────────
# nf_aaftf resolves reads as ${params.indir}/${read_1}, so we pass --indir
# pointing at the dataset reads dir and use relative filenames. taxid 4751 =
# Fungi fallback; per-dataset override via NF_AAFTF_TAXID.
TAXID="${NF_AAFTF_TAXID:-4751}"
CSV="${WORK_DIR}/samples.csv"
printf 'sample,read_1,read_2,taxid\n%s,%s,%s,%s\n' \
  "${DATASET_ID}" "${R1_NAME}" "${R2_NAME}" "${TAXID}" > "${CSV}"
echo "==> samples.csv: $(cat "${CSV}")"

# ── Run nested Nextflow workflow (pinned commit) ────────────────────────
# No -c overlay needed: nf_AAFTF's own conf/profile_aaftf.config already
# binds the host AAFTF_DB to /opt/aaftf_db (single, correct spelling) now
# that the upstream aaaftf typo is fixed (both in the AAFTF image and in
# nf_AAFTF's FILTER/SOURPURGE/VECSCREEN modules). An earlier overlay config
# duplicated that bind via a separate -c file, but at the point Nextflow
# parses a -c file, ${params.taxondb} isn't resolved yet relative to the
# profile's own params block, so it came through as the literal string
# "null" and broke the mount ("unable to add null to mount list").
#
# Profile override for cheap dev validation: NF_AAFTF_PROFILE=test with
# NF_AAFTF_EXTRA="-stub-run --n_test 2" exercises the wiring end-to-end without
# SLURM/containers/DBs (nf_AAFTF's own conf/test.config); default profile
# 'aaftf' is the real SLURM + singularity run.
#
# --vector_screen_method vecscreen overrides the profile's own default
# ('fcs_screen'). fcs_screen shells out to NCBI's run_fcsadaptor.sh, which
# launches a SECOND singularity container from inside the AAFTF container
# (nested containerization) — but singularity/apptainer isn't installed
# inside the AAFTF image, so it always fails ("cleaned_sequences/... not
# found" — run_fcsadaptor.sh silently produced no output). vecscreen (plain
# BLASTN against UniVec + contaminant DBs, all inside the one container) is
# nf_AAFTF's other documented vector-screening option and needs no nesting.
START=$(date +%s)
(
  cd "${WORK_DIR}"
  ln -sf "${READS_DIR}" "${WORK_DIR}/reads"
  nextflow run "${REPO}" -r "${NF_AAFTF_COMMIT}" \
    -profile "${NF_AAFTF_PROFILE:-aaftf}" \
    --samples "${WORK_DIR}/samples.csv" \
    --indir "${WORK_DIR}/reads" \
    --outdir "${WORK_DIR}/results" \
    --aaftf_sif "${AAFTF_SIF}" \
    --vector_screen_method vecscreen \
    ${NF_AAFTF_EXTRA:-} \
    $( [ -n "${NF_AAFTF_RESUME:-}" ] && echo "-resume" )
)
NF_EXIT=$?
WALL_CLOCK_S=$(( $(date +%s) - START ))
if [ ${NF_EXIT} -ne 0 ]; then
  echo "ERROR: nf_aaftf nextflow run failed (exit ${NF_EXIT})" >&2
  RUN_UUID="fail-nfaaftf-${DATASET_ID}-$(date +%s)"
  TRUTH_ACCESSION="none"
  finalize "failed"; exit ${NF_EXIT}
fi

# ---------------------------------------------------------------------------
# Collect results/sort/<sample>.sorted.fasta (SORT module publishDir).
# ---------------------------------------------------------------------------
SORTED_FASTA=$(find "${WORK_DIR}/results/sort" -name "*.sorted.fasta" -print -quit 2>/dev/null || true)
if [ -z "${SORTED_FASTA}" ] || [ ! -s "${SORTED_FASTA}" ]; then
  echo "WARN: no *.sorted.fasta found under ${WORK_DIR}/results/sort; partial outcome" >&2
  RUN_UUID="partial-nfaaftf-${DATASET_ID}-$(date +%s)"
  TRUTH_ACCESSION="none"
  finalize "partial"; exit 10
fi

OUT_FASTA="${ASSEMBLY_OUT}/${DATASET_ID}_nf_aaftf.fasta"
cp "${SORTED_FASTA}" "${OUT_FASTA}"
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
RUN_UUID="nfaaftf-${DATASET_ID}-$(date +%s)"
OUTPUTS_JSON='[{"path": "assembly/'${DATASET_ID}'_nf_aaftf.fasta", "md5": "'${MD5}'", "size": '${SIZE}'}]'
TRUTH_ACCESSION="none"
finalize "success"

echo "==> nf_aaftf adapter done: ${OUT_FASTA} ($(stat -c%s "${OUT_FASTA}") bytes)"
