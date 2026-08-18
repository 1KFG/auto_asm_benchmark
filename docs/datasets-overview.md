# Dataset Overview

This document is the canonical description of the benchmark **test datasets**: what
they are, how they were generated (tools + parameters), which scripts produce them,
and what goal each one serves in the benchmark's two dimensions (ADR-001).

The ground-truth host genomes live in [`assets/genomes.yaml`](../assets/genomes.yaml)
(the *backbone truth-genome registry*). Contaminant genomes are declared per-dataset
in each `datasets/*.yaml`. Scenario axes and the dataset naming convention are defined
in [`scenario-matrix.md`](scenario-matrix.md). Folder-id ↔ dataset-id mapping lives in
[`manifests/registry.yaml`](../manifests/registry.yaml).

## Corpus at a glance (test-set 2026.08.1: 13 simulated + 7 real)

| folder_id | dataset_id | tech | goal | materialized? |
|---|---|---|---|---|
| `yarlip_sim_001` | `yarlip__illumina__med__high__none__haploid__full` | Illumina 150bp PE | **Quality / control** (clean, whole genome) | ✅ **YES** — full-size data on disk |
| `canaur_sim_contam_lo_001` | `canaur__illumina__med__high__cocktail_0p1pct__haploid__full` | Illumina 150bp PE | Contamination spike (tier lo) | ⏳ declared, not generated |
| `canaur_sim_contam_md_001` | `canaur__illumina__med__high__cocktail_1pct__haploid__full` | Illumina 150bp PE | Contamination spike (tier md) | ⏳ declared, not generated |
| `canaur_sim_contam_hi_001` | `canaur__illumina__med__high__cocktail_5pct__haploid__full` | Illumina 150bp PE | Contamination spike (tier hi) | ⏳ declared, not generated |
| `canaur_sim_degrad_001` | `canaur__illumina__med__problematic__none__haploid__full` | Illumina 150bp PE | Quality degradation (qscore floor + off-bias trim) | ⏳ declared, not generated |
| `canaur_sim_mix_001` | `canaur__illumina__med__high__none__mismatch__full` | Illumina 150bp PE | Ploidy mismatch (declared haploid, actual heterozygous) | ⏳ declared, not generated |
| `canaur_sim_adapter_001` | `canaur__illumina__med__problematic__adapter_spike__haploid__full` | Illumina 150bp PE | Adapter-dimer spike (adapter-only reads) | ⏳ declared, not generated |
| `canaur_sim_carryover_001` | `canaur__illumina__med__problematic__adapter_carryover__haploid__full` | Illumina 150bp PE | 3'-end adapter carryover | ⏳ declared, not generated |
| `canaur_sim_all_001` | `canaur__illumina__med__problematic__all_1pct__haploid__full` | Illumina 150bp PE | Combined: contam 1% + degrad + adapter spike | ⏳ declared, not generated |
| `cryneo_sim_contam_lo_001` | `cryneo__hifi__med__high__symbiont_0p1pct_lambda_1pct__haploid__full` | PacBio HiFi | Long-read symbiont spike (lo tier) | ⏳ declared, not generated |
| `cryneo_sim_contam_md_001` | `cryneo__hifi__med__high__symbiont_1pct_lambda_1pct__haploid__full` | PacBio HiFi | Long-read symbiont spike (md tier) | ⏳ declared, not generated |
| `cryneo_sim_contam_hi_001` | `cryneo__hifi__med__high__symbiont_5pct_lambda_1pct__haploid__full` | PacBio HiFi | Long-read symbiont spike (hi tier) | ⏳ declared, not generated |
| `zymtri_sim_chr1_001` | `zymtri__illumina__low__medium__none__haploid__chr1_only` | Illumina 150bp PE | Single-chromosome subset | ⏳ declared, not generated |
| `yarlip_real_001` | `yarlip__nanopore__high__medium__none__haploid__full` | ONT | Real long reads, W29 (truth CLIB122) | 🔗 cached on demand (SRA SRR37832827) |
| `yarlip_real_002` | `yarlip__dnbseq__medium__medium__none__haploid__full` | BGI MGISEQ | Real short reads, W29 (truth CLIB122) | 🔗 cached on demand (SRA SRR37832855) |
| `cryneo_real_001` | `cryneo__illumina__high__medium__none__haploid__full` | Illumina | Real short reads, H99 | 🔗 cached on demand (SRA SRR36664817) |
| `cryneo_real_hybrid_001` | `cryneo__hybrid__high__medium__none__haploid__full` | PacBio + Illumina | Real hybrid, Bt63a (truth H99 CNA3) | 🔗 cached on demand (SRA SRR13201975+1974) |
| `aspfum_real_hybrid_001` | `aspfum__hybrid__high__medium__none__haploid__full` | ONT + Illumina | Real hybrid, ATCC 42202 (truth Af293) | 🔗 cached on demand (SRA SRR28035763+5764) |
| `aspfum_real_003` | `aspfum__hifi__medium__medium__none__haploid__full` | PacBio | Real PacBio, not-af293 strain (truth Af293) | 🔗 cached on demand (ENA ERR8084627) |
| `rhimic_real_001` | `rhimic__illumina__high__medium__symbiont__haploid__full` | Illumina | Real host+symbiont, NRRL 5546 | 🔗 cached on demand (SRA SRR9029155) |

> ⚠️ `datasets/staged/` contains **smoke-test fixtures only** (tiny synthetic reads,
> ~340 B per file, from `scripts/make_smoke_fixtures.py`). They exercise the harness
> plumbing — they are **not** benchmark data and must never be treated as such.
> Real-SRA reads are **never re-hosted** (ADR-018): only the accessions and local cache
> pointers exist.

## 1. The one fully-generated simulated dataset: `yarlip_sim_001`

**Full ID:** `yarlip__illumina__med__high__none__haploid__full`
(regenerated from `yarli_clean_001`; the unit is **simulated clean**, not real.)

### Goal
The **quality-dimension control**: clean, typical, *whole-genome* fungal short-read
data at medium coverage. This is the happy path every pipeline must assemble well.
It is the reference point that all robustness datasets are deliberately made
worse than.

### Content (full-size data on disk)
- `datasets/sim/yarlip_sim_001/reads/yarlip_sim_001_R1.fastq.gz` — 206,910,993 B
- `datasets/sim/yarlip_sim_001/reads/yarlip_sim_001_R2.fastq.gz` — 216,454,205 B
- `datasets/sim/yarlip_sim_001/refs/yarlip_sim_001.truth.fa` — truth reference
  (Yarrowia lipolytica CLIB122, T2T "Complete Genome")

### Truth reference
`Yarrowia lipolytica` strain CLIB122, **RefSeq GCF_001761485.1 / ASM176148v1**
("Complete Genome"). The truth FASTA contains the 6 chromosomes
`NC_090770.1 … NC_090775.1` (chr 1A–1F), 20,500,066 bp total — exactly matching
`assets/genomes.yaml → yarlip`.

### How reads were generated
Reads are **simulated** deterministically from the truth reference so the source is exact
and reproducible (seed 20260801). Mates are 150 bp; read headers are ART-style
(`@NC_090770.1-451560/1`); measured properties:

- read pairs (per mate): 2,049,960 → **~30×** coverage (2 × 2.05M × 150 bp / 20.5 Mb)
- read length: **150 bp**
- insert size ~350 bp (ART `-m 350`, `-s 50`) — inferred from generation parameters

**Tool:** `art_illumina` (ART v3.19.15, pinned `quay.io/biocontainers/art@sha256:…570a39ee` in `configs/tool_matrix.yaml` → `sim_tools.art`).

**Command (equivalent to `simulation/simulate_reads.py` build_command for `art`):**
```bash
art_illumina -ss HS25 \
  -i  datasets/sim/yarlip_sim_001/refs/yarlip_sim_001.truth.fa \
  -o  <out_prefix> -l 150 -f 30 -m 350 -s 50 -p -na -rs 20260801
```
Coverage 30× = the "medium" Illumina tier; quality `high` (no degradation, no spike).

### Generating / reproducing (links)
| What | Script / file |
|---|---|
| Read simulator dispatch + dry-run | `simulation/simulate_reads.py` (backend detection, `--dry-run`, command builder) |
| Dataset orchestrator (stub/wiring) | `simulation/controller.py` |
| Truth-genome registry (Yarrowia entry) | `assets/genomes.yaml` |
| Simulator pin (ART container) | `configs/tool_matrix.yaml` → `sim_tools.art` |
| Run it through the harness (SLURM) | `scripts/launch_illumina_nf_aaftf.sbatch` |
| Work-unit declaration | `datasets/yarlip__illumina__med__high__none__haploid__full.yaml` |
| Registry / manifest entries | `manifests/registry.yaml`, `manifests/testset_2026.08.1.yaml` |

## 2. Declared simulation robustness units (12 more)

These work-units are **frozen in YAML** (`datasets/*.yaml`) and listed in the
registry + test-set manifest, but the read data has **not been generated yet**
(`source_reads.generator` = `PENDING`, checksums are placeholders). See the matrix
in section 0 and `docs/scenario-matrix.md` for the full cross.

### 2a. `canaur` short-read stressor family (9 units)
Host: `Candida auris` B11243 (GCF_003013715.1, "Complete Genome", 12.25 Mb). The
contamination cocktail (PhiX174 NC_001422.1 + E. coli NC_000913.3 + pUC19 L09137.2 +
phage λ NC_001416.1) is split 4-ways per tier: lo = 0.00025 each (0.1% total),
md = 0.0025 each (1%), hi = 0.0125 each (5%).

- `canaur_sim_contam_lo/md/hi_001` — contamination tiers only
- `canaur_sim_degrad_001` — qscore_floor floor=15 + offbias_trim 25 bp from 3', window 4
- `canaur_sim_mix_001` — ploidy: expected haploid, actual heterozygous
- `canaur_sim_adapter_001` — adapter-only dimer reads spiked at 1%
- `canaur_sim_carryover_001` — 3'-end adapter carryover on 10% of reads
- `canaur_sim_all_001` — combined: md contam + degradation + adapter spike
  (thresholds composed only here, per ADR-014 — no k-level cross product is archived)

### 2b. `cryneo` long-read (HiFi) contamination family (3 units)
Host: `Cryptococcus neoformans` H99 (GCF_000149245.1, CNA3, 18.89 Mb). Biological
symbiont contaminant plus phage λ fixed at 1%: lo = symbiont 0.1%, md = 1%, hi = 5%.

### 2c. `zymtri_sim_chr1_001` — single-chromosome structural subset
Host: `Zymoseptoria tritici` IPO323 (GCF_000219625.1, MYCGR v2.0, 21 chromosomes,
39.69 Mb). Illumina 10× (`low`), `fragment_shorten` mean 200 bp, `chr1_only` subset
(chr1 id pinned at generation).

## 3. Real / hybrid units (7)

Real SRA/ENA reads, **never re-hosted** (ADR-018); cached locally on demand from
scheduled/downloaded accessions. The one-time read-screen populates
`contamination.observed` per ADR-017. See ADR-016 for truth-confidence notes
(e.g. `rhimic_real_001` anchors host truth to GCF_002708625.1 ATCC 52813 despite the
strain mismatch, with Mycetohabitans sp. B46 GCF_037389205.1 as the endosymbiont).

- `yarlip_real_001` (ONT, SRR37832827) & `yarlip_real_002` (MGISEQ, SRR37832855) — truth CLIB122
- `cryneo_real_001` (Illumina, SRR36664817) & `cryneo_real_hybrid_001` (SRR13201975+1974) — truth H99 CNA3
- `aspfum_real_hybrid_001` (ONT+Illumina, SRR28035763+5764) & `aspfum_real_003` (PacBio, ERR8084627) — truth Af293
- `rhimic_real_001` (Illumina, SRR9029155) — host+symbiont, truth ATCC 52813 (+B46)

## 4. Generation toolchain (what runs to produce the simulated units above)

| Transform | Script | Tool(s) invoked | Status |
|---|---|---|---|
| Resolve truth/contaminant refs | `simulation/controller.py` | NCBI `datasets` CLI (optional) | stub (wiring TODO) |
| Single-chromosome subset | `simulation/subset_chromosome.py` | python (pure) | ✅ implemented + unit-tested |
| Read simulation | `simulation/simulate_reads.py` | `art_illumina` ↓, `wgsim`/`dwgsim` →, `pbsim3`/`simlord` / `badread` | ✅ dispatch implemented (`--dry-run`); needs simulators installed |
| Contamination spike | `simulation/spike_contamination.py` | python (pure, `--separate` option) | ✅ implemented + unit-tested |
| Quality degradation | `simulation/degrade_quality.py` | python (pure) | ✅ implemented + unit-tested (adapter mechanisms TODO) |
| Smoke fixtures (NOT benchmark) | `scripts/make_smoke_fixtures.py` | python (pure) | ✅ used by `make fixtures` |

Simulator binaries are **provisioned per-run**, never vendored (see
[docs/archive-strategy.md](archive-strategy.md)). For short reads the pinned backend
is `art` (container digest in `configs/tool_matrix.yaml` → `sim_tools.art`); for HiFi
`pbsim3`; for ONT `badread`. Use `python3 simulation/simulate_reads.py --dry-run` to
print the exact commands without executing.

Parameters are otherwise declared **in the dataset YAML** (coverage tier, degradation
mechanisms + params, spike sources + fractions, ploidy) and the numeric defaults live
in `simulation/simulate_reads.py::COVERAGE_DEFAULTS` / `READ_LEN`.

## 5. Dataset lineage & provenance files

- `datasets/*.yaml` — frozen work-unit declarations (schema `schema/dataset.schema.json`)
- `manifests/registry.yaml` — folder_id ↔ dataset_id ↔ GCS URI ↔ seed (ADR-011)
- `manifests/testset_2026.08.1.yaml` — frozen test-set manifest (checksums, DOI pending)
- `assets/genomes.yaml` — truth genome registry (host references + phase-2 notes)
- `configs/tool_matrix.yaml` — `sim_tools` (read generators) + `eval_tools` pins

## 6. Next steps to fully realize the corpus

1. Implement the adapter degradation mechanisms in `simulation/degrade_quality.py`
   (`adapter_only`, `adapter_carryover`) needed by `canaur_sim_adapter/carryover/all_001`.
2. Generate the 12 simulated robustness datasets via
   `python3 simulation/simulate_reads.py …` (+ `spike_contamination.py`,
   `degrade_quality.py`, `subset_chromosome.py`), stage under `datasets/sim/`, and
   record real checksums in `manifests/testset_2026.08.1.yaml`.
3. Pin remaining contaminant accessions and the `zymtri` chr1 id.
4. Download + run the curated read-screen (ADR-017) on the 7 real units; populate
   `contamination.observed` once, then cache locally.
5. Fill the remaining PENDING pins (simulator env, DB versions) so
   `make check-pins` passes.
