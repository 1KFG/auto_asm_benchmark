# Metrics

This document defines what the benchmark measures on each assembly and how results are normalized and compared. Metric computation tooling lives in `metrics/`; the machine-readable contract is embedded in the schema and in run manifests.

## Metric families

### Family 1 — Contiguity & correctness (vs. truth genome)
Computed only when a truth reference is available (always true for our simulated ground truth):
- QUAST-style stats: N50 / NG50, L50 / LG50, contig count, total length, largest contig
- Assembled fraction of the reference genome; number of reference chromosomes reconstructed to chromosome scale
- Misassembly count (assembly vs. truth alignment)
- BUSCO completeness on `fungi_odb10` lineage; single-copy / duplicated fractions; **BUSCO lineage database version recorded**
- rDNA + mitochondrial presence and completeness when those are scenario axes

### Family 2 — Ploidy / architecture honesty
- Expected chromosome/copy number vs. reported
- For mismatch scenarios: quality of ploidy inference (read-depth distribution, k-mer spectra)
- Contamination removal, evaluated **post-hoc and independent of any pipeline cleanup stage** (ADR-012):
  - **Oracle mode** (all spiked-simulated datasets): align produced assembly to the declared contaminant reference(s) (`dataset.contamination.spikes[].accession`). Metrics:
    - fraction of assembly bases aligning to contaminant (residual contamination fraction)
    - number + total bp of contigs flagged as contaminant (contig flagged when >= c_min contiguous bases align to contaminant; c_min threshold in `configs/repo.yaml`)
    - residual contaminant reads still mapping into the produced assembly
  - **Screen mode** (any dataset, incl. real-SRA): external general screener on the produced assembly — FCS_screen (NCBI), FCS-GX (protein-based), or Kraken2 contig classification — reporting fraction of assembly bases assigned to non-host taxa. Fallback when no contaminant oracle exists.
  - Feeds the `Blocked` outcome state: success-but-contaminated-assembly = wrong answer (unless the pipeline ships a cleanup stage with evidence it ran)

### Family 3 — Read-level QC recall
- How much of the true signal survives trimming/filtering vs. what was removed
- Mean genome coverage + **per-base coverage histogram** — assemblies that collapse haplotypes look different from those that keep them uncollapsed
- **% of input reads mapping back to the produced assembly** (computed contamination-aware: reads attributable to contaminant sources are excluded when interpreting host assembly)

### Family 4 — Resource & performance
- Wall clock time, peak RSS, CPU-hours, peak disk, per pipeline per dataset

## Outcome states

Runs are not directly comparable if one crashed. Each dataset run is classified into one of five states:

| State | Code | Meaning |
|---|---|---|
| Success | ✅ | Normal completion, expected output produced |
| Partial | ⚠️ | Completed with a degraded result (e.g., <= 50% of reference chromosomes reconstructed) |
| Failed | ❌ | Crashed, hung, or produced empty output |
| Blocked | 🚫 | Completed but validation caught a problem the pipeline let through (e.g., assembly-level contamination the tool did not flag) — "passed something wrong" |
| Skipped | ⏭ | Not applicable to this dataset |

## Reporting

Metrics are delivered **per-state**: a table per outcome state, never merged into one average. Additionally, a single **system score** is computed per pipeline per dimension:

```
system_score = sum( w_s * n_success + w_p * n_partial
                  - w_f * n_failed - w_b blocked_penalty ) / total_datasets
```

where `w_s > w_p > 0` and `w_f, w_b` are penalties such that crashes and (especially) block/wrong-answer outcomes are heavily penalized. Exact weighting constants are declared in `configs/repo.yaml` so they are auditable and tunable.

## Where metrics are emitted

Each run's results directory contains `metrics/*.json` (machine-readable, one JSON per family) and the run manifest (`run_manifest.json`) that ties metrics to provenance (tool versions, parameters, DB versions, truth reference accession). A summary aggregation script (`metrics/summarize_results.py`) folds many runs into the per-state tables and system scores.
