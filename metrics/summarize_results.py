#!/usr/bin/env python3
"""Aggregate run results into per-state tables + weighted system scores.

Input: a directory tree of benchmark results (one subdir per run containing a
valid run_manifest.json with outcome_state + resource fields), or a results
summary file. Emits tables as JSON/Markdown.

System score (docs/metrics.md):
  system_score = (w_s:n_success + w_p:n_partial - w_f:n_failed - w_b:n_blocked) / n_total
"""

import argparse
import json
import sys
from pathlib import Path

import yaml

DEFAULT_WEIGHTS = {"w_success": 1.0, "w_partial": 0.5, "w_failed_penalty": 1.0, "w_blocked_penalty": 2.0}

STATE_LABELS = {"success": "✅", "partial": "⚠️", "failed": "❌", "blocked": "🚫", "skipped": "⏭"}


def collect_run_manifests(root):
    found = []
    for p in sorted(Path(root).rglob("run_manifest.json")):
        with open(p) as fh:
            found.append(json.load(fh))
    return found


def load_weights(repo_yaml=None):
    if repo_yaml and Path(repo_yaml).exists():
        with open(repo_yaml) as fh:
            cfg = yaml.safe_load(fh)
        return {k: cfg.get("system_score", {}).get(k, v) for k, v in DEFAULT_WEIGHTS.items()}
    return dict(DEFAULT_WEIGHTS)


def main():
    ap = argparse.ArgumentParser(description="Summarize benchmark results by outcome state + system score.")
    ap.add_argument("results_root", type=Path, help="directory tree containing run_manifest.json files")
    ap.add_argument("--weights-from", default="configs/repo.yaml")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of table")
    args = ap.parse_args()

    runs = collect_run_manifests(args.results_root)
    if not runs:
        sys.exit(f"no run_manifest.json found under {args.results_root}")
    w = load_weights(args.weights_from)

    # group by pipeline, then by outcome state
    tbl = {}
    for r in runs:
        pid = r["pipeline_id"]
        state = r["outcome_state"]
        d = tbl.setdefault(pid, {})
        d[state] = d.get(state, 0) + 1
        d["_total"] = d.get("_total", 0) + 1
        d["_wall"] = d.get("_wall", 0.0) + r.get("wall_clock_s", 0)

    rows = []
    for pid, d in sorted(tbl.items()):
        total = d["_total"]
        score = (w["w_success"] * d.get("success", 0)
                 + w["w_partial"] * d.get("partial", 0)
                 - w["w_failed_penalty"] * d.get("failed", 0)
                 - w["w_blocked_penalty"] * d.get("blocked", 0)) / total
        rows.append({"pipeline": pid, "total": total, **{s: d.get(s, 0) for s in STATE_LABELS},
                     "system_score": round(score, 3), "wall_s": round(d["_wall"], 1)})

    if args.json:
        print(json.dumps(rows, indent=2))
        return

    hdr = ["pipeline", "total", *list(STATE_LABELS.values()), "system_score", "wall_s"]
    print(" | ".join(hdr))
    print(" | ".join(["---"] * len(hdr)))
    for r in rows:
        print(" | ".join(str(r[k]) for k in ["pipeline", "total", *list(STATE_LABELS.keys()), "system_score", "wall_s"]))


if __name__ == "__main__":
    main()
