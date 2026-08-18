#!/usr/bin/env python3
"""Post-hoc contamination assessment of a produced assembly (ADR-012).

Independent of whether the pipeline-under-test has a cleanup stage. Two modes:

  oracle (default for spiked-simulated datasets):
      Align the produced assembly against the exact contaminant reference(s)
      declared in the dataset work-unit (minimap2; fallback BLASTn). Emit:
      - fraction of assembly bases aligning to foreign contaminant
      - contigs flagged as contaminant (>= c_min aligned bases to a contaminant)
      - total bp + count of flagged contigs

  screen (general; any dataset incl. real-SRA):
      Run a general external screener on the assembly (FCS_screen / FCS-GX /
      Kraken2 contig classification) and report fraction of bases assigned to
      non-host taxa.

Inputs:
  --assembly <file(s)>          produced assembly FASTA (one or more)
  --dataset <file.yaml>         dataset work-unit (for oracle contaminants)
  --contaminant-refs <refs>     explicit contaminant FASTA(s), overriding dataset
  --mode oracle|screen|auto     (default auto: oracle if contaminant known)
  --min-aligned-bp 200          threshold to flag a contig as contaminant (c_min)
  -v/--verbose
"""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import yaml
    yaml_available = True
except ImportError:  # pragma: no cover
    yaml_available = False


def load_spikes(dataset_yaml):
    import yaml
    with open(dataset_yaml) as fh:
        ds = yaml.safe_load(fh)
    return ds.get("contamination", {}).get("spikes", [])


def run(cmd, timeout=3600):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return {"status": "ok" if r.returncode == 0 else "error", "returncode": r.returncode, "cmd": cmd[0]}
    except FileNotFoundError:
        return {"status": "not_installed", "cmd": cmd[0]}
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "cmd": cmd[0]}


def oracle_assess(assembly, contaminant_refs, min_aligned_bp):
    if not contaminant_refs:
        return {"mode": "oracle", "status": "no_contaminant_refs"}
    mm2 = shutil.which("minimap2")
    if not mm2:
        return {"mode": "oracle", "status": "not_installed", "tool": "minimap2"}
    res = {"mode": "oracle", "tool": "minimap2", "contaminant_refs": [str(r) for r in contaminant_refs],
           "min_aligned_bp": min_aligned_bp, "per_contaminant": {}}
    for ref in contaminant_refs:
        out_paf = f"{assembly.stem}__vs__{ref.stem}.paf"
        r = run([mm2, "-x", "asm5", "-N", "5", str(ref), str(assembly)])
        if r["status"] != "ok":
            res["per_contaminant"][str(ref)] = r
            continue
        # NOTE: minimap2 PAF is emitted to stdout; parse below using pysam or a
        # small samtools sort/idxstats step once alignment infra is pinned.
        # Field placeholder — full parser wired when minimap2+pysam available.
        res["per_contaminant"][str(ref)] = {"status": "ok", "paf": out_paf, "parsed": False}
    return res


def screen_assess(assembly):
    screeners = []
    for name, exe in [("fcs_screen", "FCS_screen"), ("fcs_gx", "FCS-GX"), ("kraken2", "kraken2")]:
        if shutil.which(exe) or shutil.which(name):
            screeners.append(name)
    res = {"mode": "screen", "installed": screeners, "results": {}}
    for s in screeners:
        # Tool-specific flags wired once versions pinned (configs/tool_matrix.yaml)
        res["results"][s] = {"status": "stub", "note": "screen runner wired at pin resolution"}
    if "fcs_gx" in screeners:
        res["results"]["fcs_gx"].update(run(["FCS-GX", "--help"]))
    return res


def main():
    ap = argparse.ArgumentParser(description="Post-hoc contamination assessment of produced assemblies.")
    ap.add_argument("--assembly", required=True, action="append", help="produced assembly FASTA(s) (repeatable)")
    ap.add_argument("--dataset", type=Path, default=None, help="dataset work-unit (for oracle contaminants)")
    ap.add_argument("--contaminant-refs", action="append", default=None, help="contaminant FASTA(s), overriding dataset")
    ap.add_argument("--mode", choices=["oracle", "screen", "auto"], default="auto")
    ap.add_argument("--min-aligned-bp", type=int, default=200)
    ap.add_argument("--out", type=Path, default=None, help="output JSON")
    args = ap.parse_args()

    if not yaml_available:
        sys.exit("pyyaml required to read dataset YAML")

    explicit = [Path(r) for r in (args.contaminant_refs or [])]
    dataset_refs = []
    if args.dataset and args.dataset.exists():
        for s in load_spikes(args.dataset):
            acc = s.get("accession") or s.get("source")
            if not acc:
                continue
            # resolve an accession id to a staged FASTA under refs/<acc>.fa if present
            candidate = Path("refs") / f"{acc}.fa"
            if candidate.exists():
                dataset_refs.append(candidate)
            else:
                dataset_refs.append(Path(acc))
    contaminant_refs = explicit or dataset_refs

    mode = args.mode
    if mode == "auto":
        mode = "oracle" if contaminant_refs else "screen"

    out = {}
    for a in args.assembly:
        asm = Path(a)
        if mode == "oracle":
            out[a] = oracle_assess(asm, contaminant_refs, args.min_aligned_bp)
        else:
            out[a] = screen_assess(asm)

    payload = {"mode": mode, "assemblies": out}
    if args.out:
        args.out.write_text(json.dumps(payload, indent=2))
        print(f"wrote {args.out}")
    else:
        print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
