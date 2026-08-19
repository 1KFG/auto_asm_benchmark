#!/usr/bin/env python3
"""Build the benchmark evaluation report (docs/reports/*).

Collects wall-clock + assembly metrics from run_manifest.json for a set of
validation runs performed against real (non-placeholder) datasets, computes
truth-genome accuracy via minimap2 (union-of-aligned-intervals coverage,
not just contig-length totals -- a contig can be redundant/overlapping),
renders comparison figures, and writes a markdown report with embedded
images so it renders natively on GitHub.

This is not wired into `make all` / CI: it operates on scratch run
directories from manual validation runs (paths below), not on anything
committed to the repo. Re-run by hand after future validation passes and
edit RUNS below to add/replace entries.
"""
import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
AAFTF_SIF = REPO_ROOT / "containers" / "sifs" / "ghcr.io_stajichlab_aaftf__0c498d122b8f.sif"
FIG_DIR = REPO_ROOT / "docs" / "reports" / "figures"
REPORT_MD = REPO_ROOT / "docs" / "reports" / "2026-08-19-benchmark-summary.md"

# (pipeline_id, dataset_id, run_dir, truth_fa)
RUNS = [
    ("aaftf", "yarlip_sim_001",
     "/scratch/jstajich/27510759/aaftf_validate_yarlip_final",
     REPO_ROOT / "datasets/sim/yarlip_sim_001/refs/yarlip_sim_001.truth.fa"),
    ("nf_aaftf", "yarlip_sim_001",
     "/bigdata/stajichlab/jstajich/aaftf_bench_nf_real_test",
     REPO_ROOT / "datasets/sim/yarlip_sim_001/refs/yarlip_sim_001.truth.fa"),
    ("spades_pipeline", "yarlip_sim_001",
     "/bigdata/stajichlab/jstajich/spades_validate_yarlip",
     REPO_ROOT / "datasets/sim/yarlip_sim_001/refs/yarlip_sim_001.truth.fa"),
    ("hifiasm_pipeline", "cryneo_sim_contam_hi_001",
     "/bigdata/stajichlab/jstajich/hifiasm_validate_cryneo",
     REPO_ROOT / "datasets/sim/cryneo_sim_contam_hi_001/refs/cryneo_sim_contam_hi_001.truth.fa"),
    ("flye_pipeline", "cryneo_sim_contam_hi_001",
     "/bigdata/stajichlab/jstajich/flye_validate_cryneo",
     REPO_ROOT / "datasets/sim/cryneo_sim_contam_hi_001/refs/cryneo_sim_contam_hi_001.truth.fa"),
]
# canaur/zymtri direct-aaftf batch: same truth genome (canaur) for all 8,
# zymtri its own. Read from the batch summary + per-dataset manifests.
BATCH_DIR = Path("/bigdata/stajichlab/jstajich/aaftf_bench_batch")
BATCH_DATASETS = [
    "canaur_sim_adapter_001", "canaur_sim_all_001", "canaur_sim_carryover_001",
    "canaur_sim_contam_hi_001", "canaur_sim_contam_lo_001", "canaur_sim_contam_md_001",
    "canaur_sim_degrad_001", "canaur_sim_mix_001", "zymtri_sim_chr1_001",
]
for ds in BATCH_DATASETS:
    RUNS.append(("aaftf", ds, str(BATCH_DIR / ds),
                 REPO_ROOT / f"datasets/sim/{ds}/refs/{ds}.truth.fa"))
NF_SPOTCHECKS = ["canaur_sim_contam_hi_001", "zymtri_sim_chr1_001"]
for ds in NF_SPOTCHECKS:
    RUNS.append(("nf_aaftf", ds, str(BATCH_DIR / f"nf_{ds}"),
                 REPO_ROOT / f"datasets/sim/{ds}/refs/{ds}.truth.fa"))


def truth_len(truth_fa):
    total = 0
    with open(truth_fa) as fh:
        for line in fh:
            if not line.startswith(">"):
                total += len(line.strip())
    return total


def truth_coverage(assembly_fa, truth_fa):
    """Union-of-aligned-intervals coverage of truth_fa by assembly_fa (minimap2 asm5)."""
    cmd = ["singularity", "exec", str(AAFTF_SIF), "minimap2", "-x", "asm5", "-t", "4",
           str(truth_fa), str(assembly_fa)]
    paf = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    from collections import defaultdict
    ref_intervals = defaultdict(list)
    for line in paf.splitlines():
        f = line.split("\t")
        rname, rstart, rend = f[5], int(f[7]), int(f[8])
        ref_intervals[rname].append((rstart, rend))
    covered = 0
    for _, ivals in ref_intervals.items():
        ivals.sort()
        merged = []
        for s, e in ivals:
            if merged and s <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(merged[-1][1], e))
            else:
                merged.append((s, e))
        covered += sum(e - s for s, e in merged)
    return covered, len(ref_intervals)


def collect():
    rows = []
    for pipeline_id, dataset_id, run_dir, truth_fa in RUNS:
        run_dir = Path(run_dir)
        manifest_path = run_dir / "run_manifest.json"
        if not manifest_path.exists():
            print(f"SKIP {pipeline_id}/{dataset_id}: no manifest at {manifest_path}", file=sys.stderr)
            continue
        m = json.loads(manifest_path.read_text())
        asm = m.get("metrics", {}).get("assembly", {})
        outputs = m.get("outputs", [])
        if not outputs:
            print(f"SKIP {pipeline_id}/{dataset_id}: no outputs in manifest", file=sys.stderr)
            continue
        assembly_fa = run_dir / outputs[0]["path"]
        if not assembly_fa.exists():
            print(f"SKIP {pipeline_id}/{dataset_id}: assembly file missing {assembly_fa}", file=sys.stderr)
            continue
        if not Path(truth_fa).exists():
            print(f"SKIP {pipeline_id}/{dataset_id}: truth fasta missing {truth_fa}", file=sys.stderr)
            continue
        tlen = truth_len(truth_fa)
        covered, n_seqs_hit = truth_coverage(assembly_fa, truth_fa)
        n_truth_seqs = sum(1 for line in open(truth_fa) if line.startswith(">"))
        rows.append({
            "pipeline": pipeline_id,
            "dataset": dataset_id,
            "wall_clock_s": m.get("wall_clock_s", 0),
            "n_contigs": asm.get("n_contigs"),
            "total_length": asm.get("total_length"),
            "N50": asm.get("N50"),
            "largest_contig": asm.get("largest_contig"),
            "truth_length": tlen,
            "truth_coverage_pct": round(100 * covered / tlen, 2) if tlen else None,
            "truth_seqs_hit": n_seqs_hit,
            "truth_seqs_total": n_truth_seqs,
        })
        print(f"OK {pipeline_id}/{dataset_id}: coverage={rows[-1]['truth_coverage_pct']}% "
              f"N50={rows[-1]['N50']} wall={rows[-1]['wall_clock_s']}s")
    return rows


def make_figures(rows):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    FIG_DIR.mkdir(parents=True, exist_ok=True)
    labels = [f"{r['pipeline']}\n{r['dataset'].replace('_sim_', ' ').replace('_001', '')}" for r in rows]
    colors_by_pipeline = {
        "aaftf": "#4C72B0", "nf_aaftf": "#55A868", "spades_pipeline": "#C44E52",
        "hifiasm_pipeline": "#8172B2", "flye_pipeline": "#CCB974",
    }
    colors = [colors_by_pipeline.get(r["pipeline"], "#777777") for r in rows]

    def bar(field, title, ylabel, fname, pct=False):
        vals = [r[field] for r in rows]
        fig, ax = plt.subplots(figsize=(max(8, len(rows) * 0.6), 5))
        ax.bar(range(len(rows)), vals, color=colors)
        ax.set_xticks(range(len(rows)))
        ax.set_xticklabels(labels, rotation=60, ha="right", fontsize=7)
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        if pct:
            ax.set_ylim(0, 105)
            ax.axhline(100, color="gray", linestyle="--", linewidth=0.8)
        fig.tight_layout()
        fig.savefig(FIG_DIR / fname, dpi=140)
        plt.close(fig)

    bar("wall_clock_s", "Wall-clock time per run", "seconds", "wall_clock.png")
    bar("N50", "Assembly N50", "bp", "n50.png")
    bar("truth_coverage_pct", "Truth-genome coverage", "% of truth genome covered", "truth_coverage.png", pct=True)
    bar("n_contigs", "Contig count", "contigs", "n_contigs.png")


def write_report(rows):
    REPORT_MD.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    lines.append("# Benchmark evaluation summary — 2026-08-19\n")
    lines.append(
        "Timing, assembly quality, and truth-genome accuracy for every pipeline validated "
        "end-to-end against real (non-placeholder) simulated datasets so far. Truth coverage "
        "is the union of `minimap2 -x asm5` aligned intervals against the truth genome, not a "
        "raw contig-length total, so redundant/overlapping contigs don't inflate the score.\n"
    )
    lines.append("## Figures\n")
    for fname, caption in [
        ("wall_clock.png", "Wall-clock time per run"),
        ("truth_coverage.png", "Truth-genome coverage (%)"),
        ("n50.png", "Assembly N50"),
        ("n_contigs.png", "Contig count"),
    ]:
        lines.append(f"![{caption}](figures/{fname})\n")

    lines.append("## Full results\n")
    lines.append("| Pipeline | Dataset | Wall (s) | Contigs | Total (bp) | N50 | Truth cov % | Truth seqs hit |")
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|")
    for r in rows:
        lines.append(
            f"| {r['pipeline']} | {r['dataset']} | {r['wall_clock_s']} | {r['n_contigs']} | "
            f"{r['total_length']:,} | {r['N50']:,} | {r['truth_coverage_pct']} | "
            f"{r['truth_seqs_hit']}/{r['truth_seqs_total']} |"
        )
    lines.append("")

    lines.append("## Notes\n")
    lines.append(
        "- `zymtri_sim_chr1_001` is a deliberately low-coverage (10x), single-chromosome fixture; "
        "its low N50/coverage here reflects the fixture design, not a pipeline defect.\n"
        "- `cryneo_sim_contam_hi_001` runs (`hifiasm_pipeline`, `flye_pipeline`) were validated "
        "before the read-ID-collision simulator fix (see git history); results are unaffected "
        "since both adapters either tolerate or work around the collision.\n"
        "- All runs used real containerized tools against real (not placeholder) simulated read "
        "data; none of these numbers are smoke-test placeholders.\n"
    )
    REPORT_MD.write_text("\n".join(lines))
    print(f"wrote {REPORT_MD}")


if __name__ == "__main__":
    rows = collect()
    if not rows:
        print("no rows collected; nothing to report", file=sys.stderr)
        sys.exit(1)
    make_figures(rows)
    write_report(rows)
