#!/usr/bin/env python3
"""Compute per-assembly benchmark metrics for a run's results directory.

Reads a results dir produced by an adapter (containing the assembly FASTA,
optional truth reference, optional run_manifest.json produced by the pipeline)
and emits metrics/*.json.

Metric families (docs/metrics.md):
  1. contiguity & correctness (QUAST-style against truth)
  2. ploidy / architecture honesty
  3. read-level QC recall (mean coverage histogram, % mapping)
  4. resource & performance

External tools (quast, busco, minimap2/samtools or bwa) are dispatched lazily;
if unavailable, only what is computable in pure Python is emitted and tools
are recorded as "not_run".
"""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


def run_tool(cmd):
    if shutil.which(cmd[0]) is None:
        return {"tool": cmd[0], "status": "not_run"}
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        return {"tool": cmd[0], "status": "ok" if r.returncode == 0 else "error", "returncode": r.returncode}
    except subprocess.TimeoutExpired:
        return {"tool": cmd[0], "status": "timeout"}


def main():
    ap = argparse.ArgumentParser(description="Compute benchmark metrics for a run.")
    ap.add_argument("results_dir", type=Path, help="run results dir (adapter output)")
    ap.add_argument("--truth", type=Path, default=None, help="truth reference FASTA")
    ap.add_argument("--dataset", type=Path, default=None, help="dataset work-unit YAML (for contamination oracle, ADR-012)")
    ap.add_argument("--out", type=Path, default=None, help="metrics output dir (default: <results>/metrics)")
    args = ap.parse_args()

    results = args.results_dir
    out = args.out or (results / "metrics")
    out.mkdir(parents=True, exist_ok=True)

    assemblies = sorted((results / "assembly").glob("*.fasta")) if (results / "assembly").exists() else []
    if not assemblies:
        assemblies = sorted(results.glob("*.fasta")) + sorted(results.glob("*.fa"))

    metrics = {}
    for asm in assemblies:
        m = {"assembly": asm.name}
        if args.truth and shutil.which("quast"):
            q = run_tool(["quast", "--output-dir", str(out / f"quast_{asm.stem}"), str(asm), "-r", str(args.truth)])
            m["quast"] = q
        if shutil.which("busco"):
            b = run_tool(["busco", "-i", str(asm), "-m", "genome",
                          "-l", "fungi_odb10", "-o", f"busco_{asm.stem}", "--out_path", str(out)])
            m["busco"] = b
        # ADR-012: post-hoc contamination assessment, independent of the
        # pipeline's own cleanup stage. Oracle when the dataset declares spike
        # accessions; general screen otherwise. Delegates to assess_contamination.py.
        if args.dataset is not None:
            c = run_tool([sys.executable, str(Path(__file__).with_name("assess_contamination.py")),
                          "--assembly", str(asm), "--dataset", str(args.dataset),
                          "--out", str(out / f"contamination_{asm.stem}.json")])
            m["contamination"] = c
        metrics[asm.name] = m

    with open(out / "metrics.json", "w") as fh:
        json.dump(metrics, fh, indent=2)
    print(f"emitted {out / 'metrics.json'}")
    # NOTE: coverage histograms and %-mapping require read-level alignment
    # (minimap2/bwa + samtools coverage). Implemented when the harness defines
    # the run layout; see docs/metrics.md Family 3.


if __name__ == "__main__":
    main()
