# Automatic Assembly Benchmarking Boom
Assembly workflow benchmarking system to standardize and compare tools for assembling genomes automatically from short and long read and hybrids, provide performance timing, resource usage, and quality of assemblies achieved on comparable datasets.

Two independent benchmark dimensions (see [docs/design-decisions.md](docs/design-decisions.md) ADR-001):

- **Quality** — how well a pipeline assembles clean, typical data.
- **Robustness / rescue** — how well a pipeline survives *and* catches **contaminated, degraded, ploidy-mismatch, low-coverage, and single-chromosome** inputs.

## Quick start

```bash
# validate every YAML instance against its JSON schema (ADR-009)
make validate            # exits 1 if any instance fails; warns on PENDING pins

# unit tests (simulation transforms + metric prototypes, no external deps)
make test

# smoke-test the Nextflow meta-harness end-to-end (tiny fixtures, placeholder pipelines)
make fixtures && make smoke
```

## Layout

```
assets/genomes.yaml            truth-genome registry (fungal, phase 1)
configs/repo.yaml              storage, system-score weights, contamination assessment
configs/tool_matrix.yaml       pipelines-under-test + eval tools (all version-pinned)
configs/params/*.yaml          canonical per-pipeline parameter sets
datasets/*.yaml                frozen benchmark work-units (one per dataset)
manifests/testset_*.yaml       frozen test-set manifest (checksums + DOI)
manifests/registry.yaml        short folder id <-> dataset_id <-> GCS URI (ADR-011)
schema/*.schema.json           JSON Schemas for every YAML instance
simulation/                    seeded dataset generator (reads, spikes, degradation, subsets)
adapters/<pipeline>/run.sh     adapter contract wrappers (black-box; ADR-003/005)
workflows/                     Nextflow DSL2 meta-harness (ADR-005)
metrics/                       post-run metric + contamination assessment + summarizer (ADR-008/012)
tests/                         unit tests
```

## Key design decisions

| # | Decision |
|---|---|
| 001 | Quality and robustness/rescue are separate benchmark dimensions |
| 002 | Ground truth = real finished genomes + in-repo simulated reads |
| 003 | Pipelines are black boxes |
| 004 | Everything version-pinned (containers by digest, commits, lockfiles, DB versions) |
| 005 | Nextflow DSL2 meta-harness; every pipeline wraps to one adapter contract |
| 006 | 3-tier storage: git / GCP hot (`gs://stajichlab-asm-benchmarking/`) / Zenodo-Dryad cold |
| 007 | Scenario axes independent, crossed on demand |
| 008 | 5 outcome states (Success/Partial/Failed/Blocked/Skipped) + weighted system score |
| 009 | JSON Schema + YAML, `make validate` |
| 010 | Backbone truth-genome registry (fungal, phase 1) |
| 011 | Hot-bucket dataset naming: `<genome_id>_<kind>_<NNN>` + registry mapping |
| 012 | Contamination removal scored post-hoc (oracle + screen), independent of pipeline cleanup |

Full text: [docs/design-decisions.md](docs/design-decisions.md). See also
[docs/overview.md](docs/overview.md), [docs/datasets-overview.md](docs/datasets-overview.md),
[docs/metrics.md](docs/metrics.md), [docs/scenario-matrix.md](docs/scenario-matrix.md),
[docs/archive-strategy.md](docs/archive-strategy.md),
[docs/glossary.md](docs/glossary.md).

## Status

Phase 1 (fungal-first) scaffold. All version pins in `configs/tool_matrix.yaml` are now
resolved to immutable digests/commits/lockfiles; `make validate` passes cleanly.

- **AAFTF container rebuilt + verified by digest** (`ghcr.io/stajichlab/aaftf@sha256:f7fd8ed3…`):
  added fastqc, flye, racon, hifiasm, kraken2, gfatools; `AAFTF --version` and
  `gfatools gfa2fa` confirmed in-image.
- **medaka / nextpolish** stay out of the main image, pinned to separate
  `quay.io/biocontainers` digests (flye_pipeline `pins`).
- **FCS screens pinned**: FCS-GX via `gx` v0.5.5 (inside AAFTF) with gxdb
  `v0.3.0-151-g9aad15db`; FCS-adaptor v0.5.5 local SIF asset.
- **Benchmark DB versions recorded**: fungi_odb10 `2020-09-10`, Kraken2 `k2_standard_20260226`.

Real dataset generation requires simulator binaries (wgsim/art_illumina/pbsim/badread),
provisioned per-run — see `simulation/simulate_reads.py --dry-run`.
