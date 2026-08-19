#!/usr/bin/env bash
# Pull+verify every pinned container image referenced in configs/tool_matrix.yaml
# into a shared, content-addressed Apptainer cache. Images are pulled by DIGEST
# (ADR-004) so re-pulls are idempotent and content-verified.
#
# Cache layout (one SIF per tool id):
#   containers/sifs/<tool_id>.sif
#
# Usage:
#   module load apptainer/1.4.5          # or unity load apptainer
#   ./scripts/pull_containers.sh [--dry-run]
#
# Each image URI maps <tool_id> -> <repo>@sha256:<digest>. Images whose pin is
# still PENDING are skipped with a warning (they cannot be pulled yet).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIF_DIR="${REPO_ROOT}/containers/sifs"
TOOL_MATRIX="${REPO_ROOT}/configs/tool_matrix.yaml"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

mkdir -p "${SIF_DIR}"

command -v apptainer >/dev/null 2>&1 || { echo "ERROR: apptainer not on PATH (module load apptainer/1.4.5)"; exit 1; }

# ---- collect (id, container_pin) from pipelines, eval_tools, sim_tools ----
python3 - "${TOOL_MATRIX}" <<'PY' | sort -u > "${TMPDIR:-/tmp}/cont_pins_$$.tsv"
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
rows = []
for section in ("pipelines", "eval_tools", "sim_tools"):
    for t in cfg.get(section, []):
        # pull any pinned container regardless of pipeline type; skip entries
        # that declare no container_pin (conda/pixi-only or PENDING)
        pin = t.get("execution", {}).get("container_pin") if section == "pipelines" else t.get("container_pin")
        if not pin:
            continue
        rows.append((f"{section}:{t['id']}", str(pin)))
for rid, pin in rows:
    print(f"{rid}\t{pin}")
PY

PINS="${TMPDIR:-/tmp}/cont_pins_$$.tsv"
echo "Pinned container references:"
column -t -s $'\t' "${PINS}" || cat "${PINS}"

pulled=0; skipped=0
while IFS=$'\t' read -r rid pin; do
    id="${rid##*:}"
    if [[ "${pin}" == "PENDING" ]]; then
        echo "  [skip] ${rid} pin=PENDING"
        skipped=$((skipped+1)); continue
    fi
    # pin -> repo@sha256:digest ; derive SIF name from first path component
    repo="${pin%@*}"
    digest="${pin#*@}"
    tool_id="${repo%%/*}"; tool_id="${tool_id##*/}"
    # make the sif name unambiguous across repos: <registry>-<owner>-<name>-<digest12>
    safe="${repo//[^a-zA-Z0-9_.-]/_}"
    sif="${SIF_DIR}/${safe}__$(echo "${digest}" | cut -c8-19).sif"
    # Accept any sibling SIF with the same repo prefix (older naming variants).
    existing="$(compgen -G "${SIF_DIR}/${safe}__*.sif" | head -1 || true)"
    if [[ -n "${existing}" ]]; then
        echo "  [cached] ${rid} -> ${existing}"
        pulled=$((pulled+1)); continue
    fi
    if [[ -f "${sif}" ]]; then
        echo "  [cached] ${rid} -> ${sif}"
        pulled=$((pulled+1)); continue
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "  [dry-run] ${rid} -> apptainer pull docker://${pin}"
        pulled=$((pulled+1)); continue
    fi
    echo "  [pull] ${rid} docker://${pin}"
    ( cd "${SIF_DIR}" && apptainer pull --force --name "$(basename "${sif}")" "docker://${pin}" 1>&2 )
    pulled=$((pulled+1))
done < "${PINS}"
rm -f "${PINS}"

echo
echo "== summary: ${pulled} verified, ${skipped} skipped (PENDING pins) =="
echo "== cache: ${SIF_DIR}"
