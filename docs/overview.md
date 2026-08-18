# Overview

## Purpose

`auto_asm_benchmark` is a framework for **benchmarking automated genome assembly and QC workflows** on fungal sequence data. It answers two independent questions in one reproducible harness:

1. **Quality dimension (control)** — given *clean, typical* fungal data (short-read Illumina/DNBSEQ, long-read PacBio HiFi, Nanopore with/without polishing, and hybrid mixes), how good is the final assembly produced by each pipeline?
2. **Robustness/rescue dimension (stress)** — given *problematic* fungal data (contamination from reagent, host, symbiont, or cross-species; degraded quality; coverage shortfalls; ploidy surprises), how well does each pipeline still work, and how well can it be rescued?

These dimensions are reported **separately** so that a tool that is excellent-but-fragile is not conflated with one that is mediocre-but-unshakeable.

The project is fungal-first but explicitly extensible to other lineages.

## Design principles

- **Truth-first.** Every benchmark rests on a small set of high-quality ("gold standard") fungal genomes. Truth is either a curated finished reference, or *synthetically generated reads* from that reference so contamination fractions, coverage, and quality are exactly what we declare them to be.
- **Metadata in, data out.** The repository holds *metadata and tooling only*. Raw reads are never hosted here; datasets are referenced by accession and cached only for compute. Generated test sets are frozen, versioned, and archived to cold storage.
- **Black-box pipelines.** The tool under test is a complete pipeline run atomically (e.g., AAFTF, nf_AAFTF). The benchmark records everything *about* the run (versions, parameters, database versions) without modifying the pipeline.
- **Reproducible execution.** Everything is launched from pinned versions — container digests, workflow commit hashes, conda lockfiles, database versions — for any orchestrator (Nextflow, Snakemake, or plain conda/pixi), wrapped to a single adapter contract.
- **More detail beats less.** Metrics and outcome states are rich by design; statistics are reported per-state, not flattened into a single misleading average.

## Scope of a dataset "work unit"

A benchmark unit (see [datasets/](../datasets/)) defines:

- source genome (backbone truth reference or contaminant)
- sequencing technology + coverage tier
- quality state (clean / degraded)
- contamination profile (none, or specific spiked sources at declared fractions)
- ploidy expectation vs. reality
- any structural modification (e.g., single-chromosome-only subset)

Each unit is a golden, frozen, downloadable artifact after generation.

## The pipeline-under-test (POT) matrix

Pipelines are declared in [configs/tool_matrix.yaml](../configs/tool_matrix.yaml). Each is benchmarked as an atomic unit over the dataset corpus. A pipeline may be:

- a Nextflow workflow (@stajichlab/nf-AAFTF, nf-core style)
- a Snakemake workflow
- a conda/pixi shell workflow (e.g., AAFTF)

All are wrapped by [adapters/](../adapters/) to a common contract and executed by the harness in [workflows/](../workflows/).

## Current status (2026-08-18)

- All version pins in `configs/tool_matrix.yaml` resolved to immutable identifiers; `make validate` passes.
- AAFTF pinned by digest (`ghcr.io/stajichlab/aaftf@sha256:f7fd8ed3…`) after a rebuild adding fastqc, flye, racon, hifiasm, kraken2, and gfatools — verified in-container (`AAFTF --version`, `gfatools gfa2fa`).
- medaka (2.2.2) and nextpolish (1.4.1) run from separate pinned `quay.io/biocontainers` images.
- FCS contamination screens pinned: FCS-GX via `gx` (v0.5.5, gxdb `v0.3.0-151-g9aad15db`) and FCS-adaptor v0.5.5 local SIF.
- Benchmark DB versions recorded: fungi_odb10 `2020-09-10`, Kraken2 `k2_standard_20260226`.

## Document map

- [design-decisions.md](design-decisions.md) — ADR-style record of every decision in this project's spec
- [datasets-overview.md](datasets-overview.md) — the current test datasets: content, generation tools + params, goals
- [scenario-matrix.md](scenario-matrix.md) — enumeration of scenario axes and defaults
- [metrics.md](metrics.md) — metric families, outcome states, system scores
- [archive-strategy.md](archive-strategy.md) — three-tier storage (git / GCP / Zenodo-Dryad)
- [glossary.md](glossary.md) — canonical vocabulary
