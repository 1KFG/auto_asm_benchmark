# Design Decisions (ADR)

This document records the decisions made during the initial specification (2026-08) of this framework. Each decision is a numbered ADR. Whenever the framework changes, extend this file with a new ADR rather than rewriting history.

New ADRs should be dated and increment the sequence. Each references the section of the codebase it affects.

---

## ADR-001 — Benchmark dimensions are separated (quality vs. robustness)

**Status:** Accepted.
**Context:** A benchmarking project needs to answer "which pipeline is best on clean fungal data" (quality) independently from "which pipeline survives bad data" (robustness).
**Decision:** The benchmark defines two first-class dimensions, reported separately:
- Quality dimension: clean, typical fungal data.
- Robustness/rescue dimension: contaminated, degraded, low-coverage, or otherwise problematic data.
Success metrics are computed per-dimension. Reported numbers for a pipeline are never collapsed across dimensions.
**Consequences:** No single "best pipeline" ranking across dimensions; a pipeline appears twice (once per dimension).

---

## ADR-002 — Gold-standard truth is hybrid (real finished genomes + simulated reads)

**Status:** Accepted.
**Context:** Benchmarks need exact, reproducible ground truth. Real sequencing data is realistic but uncontrolled (contamination, coverage, error are whatever nature/culture gave the depositor). Simulated reads are controllable but less realistic.
**Decision:**
- A small set of **true finished reference genomes** (see [assets/genomes.yaml](../assets/genomes.yaml)) is the backbone.
- **Clean/realistic scenarios**: real public reads (SRA/ENA) for those genomes, referenced by accession.
- **Contamination, degradation, coverage, ploidy, and single-chromosome scenarios**: reads are **simulated in-repo** from the truth reference, with spike fractions and quality profiles applied exactly as specified.
**Consequences:** The simulation tooling lives in this repository (`simulation/`), and each *frozen* version of the generated test set is archived to cold storage (Zenodo/Dryad) together with a manifest so simulation is recoverable.

---

## ADR-003 — Pipelines under test are black boxes

**Status:** Accepted.
**Context:** Existing workflows (AAFTF, stajichlab/nf-AAFTF) exist and are what users actually run. We must not fork or silently modify them.
**Decision:** Each pipeline under test is invoked atomically over a dataset. The benchmark records full provenance about each run — tool versions, parameters, reference-database versions — without altering pipeline internals.
**Consequences:** Attribution of *which step* caused a result requires deeper per-step instrumentation later; for now the black box is treated as the unit.

---

## ADR-004 — Everything version-pinned for reproducibility

**Status:** Accepted.
**Context:** Results are only comparable if runs are reproducible.
**Decision:** Two-layer pinning:
1. Every containerized tool pinned by registry **digest** (not just tag).
2. A `workflow params.yaml` records tool versions, database versions (e.g., Kraken2 DB, BUSCO lineage set), and reference genome accessions.
The parameters snapshot is emitted as `provenance.yaml` into each run's results directory.
**Consequences:** Reproducibility relies on archival of DBs and containers; these are declared in `manifests/` and referenced by checksum.

---

## ADR-005 — Nextflow DSL2 as the meta-harness; all pipelines wrap to one adapter contract

**Status:** Accepted.
**Context:** We must launch a mix of pipeline flavors (Nextflow, Snakemake, conda/pixi shell) uniformly and reproducibly, on SLURM today and potentially GCP later.
**Decision:**
- The benchmark harness is a **Nextflow DSL2** workflow (`workflows/`) as the meta-orchestrator.
- Every pipeline under test is launched through an **adapter** in `adapters/` that exposes a fixed contract:
  - input: dataset directory + `params.yaml`
  - output: a declared results directory + `run_manifest.json` (exit code, wall time, output file list)
- Adapter dispatch is selected by `type: nextflow | snakemake | conda` in the tool matrix.
**Consequences:** A `-profile local` run works without SLURM for smoke-testing; `-profile slurm` is the production path. Snakemake pipelines keep their own env pinning but are still wrapped by an adapter.

---

## ADR-006 — 3-tier storage: git (metadata) / GCP (hot) / Zenodo or Dryad (cold archive)

**Status:** Accepted.
**Context:** Raw and generated sequence data must be stored, shared, and cited, but a git repo is the wrong place for it.
**Decision:**
- **Tier 1 (git repo):** metadata only — manifests (YAML), configs, tool matrix, workflow specs, schemas, provenance schema.
- **Tier 2 (GCP GCS):** hot bucket — working copies for compute, plus generated test sets (contaminated/degraded reads, single-chromosome subsets), each registered with checksums + sizes + versions in the manifest.
- **Tier 3 (Zenodo or Dryad):** cold archive — frozen, versioned snapshots with a DOI per test-set version (the "frozen benchmark").
**Compliance:** We **never permanently re-host third-party raw reads**. SRA/ENA runs are referenced by accession and cached in the hot bucket only for compute. Our own generated reads + frozen sets are what get archived.
**Consequences:** Fetching a dataset requires a manifest; downloads are reproducible by checksum.

---

## ADR-007 — Scenario axes are independent and crossed on demand

**Status:** Accepted.
**Context:** Contamination, quality degradation, and coverage are separable axes; a full combinatorial cross can explode into hundreds of datasets per genome.
**Decision:**
- Axes: technology × coverage-tier × contamination profile × quality degradation × ploidy expectation × structural subset.
- A full cross is generated *on demand* from the simulation tooling.
- Only **canonical/default flavors** plus a pinned default contamination level, default degradation, and default coverage are archived.
**Consequences:** The archived footprint stays sane; the full grid is regenerable from the same controller.

---

## ADR-008 — Metric normalization via outcome states + weighted system score

**Status:** Accepted.
**Context:** Tools that crash, hang, or emit wrong-but-complete-looking assemblies must not distort the comparison.
**Decision:** Every dataset run is classified into one of five outcome states (see [metrics.md](metrics.md)): Success, Partial, Failed, Blocked, Skipped. Metrics are reported as a per-state table plus a single weighted system score per pipeline.
**Consequences:** Robustness (crash/wrong-answer penalties) is co-visible with raw per-dataset numbers.

---

## ADR-009 — JSON Schema + YAML, with lint-style validation

**Status:** Accepted.
**Context:** The repo must be self-consistent and machine-verifiable.
**Decision:** YAML instance files (datasets, manifests, configs, genomes) validated against JSON Schemas under `schema/`. A `make validate` command checks every YAML against its schema in CI or locally.
**Consequences:** Structure is enforced; malformed work-units fail early.

---

## ADR-010 — Backbone truth-genome registry (fungal, phase 1)

**Status:** Accepted.
**Context:** A diverse fungal host set spanning lineages and difficulty levels, favoring assemblies with chromosome/T2T-level RefSeq records and read-depth availability.
**Decision & registry:** See [assets/genomes.yaml](../assets/genomes.yaml). Phase-1 backbone:

| Archetype | Species / strain | Accession | Level |
|---|---|---|---|
| Yeast (T2T) | Yarrowia lipolytica CLIB122 | GCF_001761485.1 | Complete Genome |
| Yeast (T2T) | Candida auris B11243 | GCF_003013715.1 | Complete Genome |
| Filamentous | Aspergillus fumigatus Af293 | GCF_000002655.1 | Chromosome |
| Heavy repeat | Zymoseptoria tritici IPO323 | GCF_000219625.1 | Chromosome |
| Basidio (Tremellales) | Cryptococcus neoformans H99 | GCF_000149245.1 | Chromosome |
| Basidio (Agaricales) | Agaricus bisporus | GCA_055470795.1 | Complete Genome |
| Mucoro | Rhizopus microsporus | GCA_977110955.1 | Contig, high contiguity |

Auxiliary (cross-checks, not primary truth): Coprinopsis cinerea CC3, Ustilago maydis 521.
Excluded: Puccinia (genome too large for now) — keep list extensible.
**Consequences:** Any genome whose RefSeq record changes (level, accessions) is re-verified at dataset-curation time and the manifest updated with its exact assembly level — chromosome-level is not silently called T2T.

---

## ADR-011 — Hot-bucket dataset naming: short folder ids + registry mapping

**Status:** Accepted.
**Context:** The hot bucket is `gs://stajichlab-asm-benchmarking/`. Dataset folders should be short but informative; the full scenario tuple is too long for bucket names and shouldn't be the source of truth.
**Decision:**
- GCS folder ids follow `<genome_id>_<kind>_<NNN>` (e.g., `cryneo_sim_contam_001`).
- `genome_id` keys come from `assets/genomes.yaml`.
- `kind` is a controlled vocabulary (see `configs/repo.yaml` naming.kinds): `sim` (simulated clean), `sim_contam` (simulated + contamination), `sim_degrad` (simulated + degradation), `sim_mix` (simulated ploidy-mismatch), `sim_adapter` (simulated adapter-only spike), `sim_carryover` (simulated 3'-end adapter carryover), `sim_all` (combined stressors), `sim_chr1` (single-chromosome subset), `real` (real public reads), `real_hybrid` (real mixed technology).
- `NNN` is a zero-padded sequence number per genome+kind.
- The authoritative mapping short-folder-id -> full `dataset_id` -> GCS URI lives in `manifests/registry.yaml` (kept on the HPCC local host and mirrored into the bucket).
**Consequences:** Bucket names stay short; all meaning is recoverable through the registry + the dataset YAML it points to. Schema: `schema/registry.schema.json`.

---

## ADR-012 — Contamination removal is evaluated as an independent post-hoc step (not from the pipeline's own cleanup)

**Status:** Accepted.
**Context:** Not every pipeline under test will include a contamination-removal/cleanup stage. Judging "how well does this pipeline handle contaminated data" cannot rely on the pipeline reporting its own cleaning, because that both conflates pipelines that never try with pipelines that clean well, and trusts self-reported output.
**Decision:** Contamination removal effectiveness is measured by an **independent, post-hoc evaluation step run by the harness on every produced assembly**, in addition to any pipeline-native cleanup:
1. **Oracle mode (default for all spiked-simulated datasets):** Because the contaminant and its reference accession are declared in the dataset work-unit (`dataset.contamination.spikes[].source` + `accession`), align the produced assembly against the exact contaminant reference(s) (minimap2 against contaminant FASTA, or BLASTn) and compute: fraction of assembly bases mapping to contaminant, number/size of contaminant contigs where a contig is flagged if >= some threshold of its bases align to the contaminant, and residual reads attributable to contaminant still mapping into the production assembly.
2. **Screen mode (general, for any dataset including real-SRA):** run an external general contamination screener on the produced assembly — e.g. FCS_screen (NCBI), FCS-GX (NCBI protein-based screening), or Kraken2 contig classification — and report the fraction of assembly bases assigned to non-host taxa. Screen mode is the fallback when no contaminant oracle is known (real-read datasets).
- Both modes are emitted as **contamination metrics per assembly** (see [metrics.md](metrics.md) Family 2) and feed the `Blocked` outcome state: an assembly that flags as contaminated but whose pipeline reported success is a wrong-answer (block) unless the pipeline has a declared cleanup stage with evidence it ran.
**Consequences:** Pipelines with no cleanup stage are scored the same way as pipelines with one; the oracle removes dependence on self-reporting; screen-mode tools (FCS_screen/FCS-GX, Kraken2 DBs) must be added to the tool pinning matrix. Implementation lives in `metrics/assess_contamination.py`.

---

## ADR-013 — Genome mnemonics (3+3, no strain) + stressor kind vocabulary (supersedes ADR-011 naming)

**Status:** Accepted.
**Context:** ADR-011's folder ids and `kind` vocabulary (`clean`/`sim`/`sim_contam`/`sim_degrad`/`sim_mix`/`chrN`) no longer match the agreed stressor set, and full-length keys are unwieldy. The repo-wide rename is done once the corpus is finalized.
**Decision:**
- `genome_id` = 3+3-letter mnemonic, **no strain suffix**: backbone `yarlip` (Y. lipolytica CLIB122), `canaur` (C. auris B11243), `cryneo` (C. neoformans H99), `zymtri` (Z. tritici IPO323), `aspfum` (A. fumigatus Af293), `agabis` (A. bisporus), `rhimic` (R. microsporus); auxiliary `copcin` (Cop. cinerea CC3), `ustmay` (U. maydis 521). Old key `cnh99` → `cryneo` (no strain).
- `folder_id` = `<genome_id>_<stressor>_<NNN>`, `NNN` zero-padded per genome+stressor.
- `stressor` vocabulary (replaces ADR-011 `kind`): `sim`, `sim_contam`, `sim_degrad`, `sim_mix`, `sim_adapter`, `sim_carryover`, `sim_all`, `sim_chr1`, `real`, `real_hybrid`. (`clean` is obsolete → real datasets use `real`.)
**Consequences:** The rename propagates to `assets/genomes.yaml` keys, `manifests/registry.yaml`, all `datasets/*.yaml`, `configs/repo.yaml`, tool matrix, and docs.

---

## ADR-014 — Contamination levels, contaminant/vector composition, and adapter modeling

**Status:** Accepted.
**Context:** ADR-007 defaulted a single contamination level. The contaminant collection per species and how adapter artefacts appear in reads were both open.
**Decision:**
- Contamination/symbiont fraction tiers **lo / md / hi = 0.1% / 1% / 5%** of reads, shared by contamination spikes (`canaur`) and symbiont co-reads (`cryneo`). Each tier is its own single-tier work-unit; thresholds are only composed into the combined `sim_all` unit, never archived as a k-level cross product.
- **`canaur` contaminant cocktail**: PhiX174 (NC_001422.1) + E. coli K-12 MG1655 (NC_000913.3) + **pUC19** (vector) + **lambda** (NC_001416.1). **`cryneo`**: symbiont panel at lo/md/hi **+ lambda at fixed 1%** (v1) — no PhiX/E. coli (different biology).
- **Adapters, both representations**: (a) adapter-only reads = `sim_adapter` spike (reads carrying adapter at both ends, low fraction); (b) 3′-end adapter carryover = `sim_carryover`, modeled as a degradation kind (read pools with adapter tailing). Each is a single-tier separate unit; `sim_all` includes the adapter spike (not the carryover).
**Consequences:** `simulation/spike_contamination.py` and `simulation/degrade_quality.py` gain adapter-only and adapter-carryover modes; canaur endpoint libraries are assembled from the cocktail refs.

---

## ADR-015 — Final simulated corpus (13 work-units)

**Status:** Accepted.
**Context:** The archived canonical set must be sane-sized (ADR-007: cross on demand, archive canonicals only).
**Decision:** The simulated corpus is:
- `yarlip_sim_001`
- `canaur_sim_contam_lo_001`, `canaur_sim_contam_md_001`, `canaur_sim_contam_hi_001`
- `canaur_sim_degrad_001`
- `canaur_sim_mix_001`
- `canaur_sim_adapter_001`
- `canaur_sim_carryover_001`
- `canaur_sim_all_001`
- `cryneo_sim_contam_lo_001`, `cryneo_sim_contam_md_001`, `cryneo_sim_contam_hi_001`
- `zymtri_sim_chr1_001`

Total **13 units**. The full grid remains regenerable from the simulation controller.
**Consequences:** 9 new `datasets/*.yaml` work-units are authored and registered (alongside the renamed simulation + real units); each declares `dataset.contamination.spikes[]` with source+accession for the ADR-012 oracle.

---

## ADR-016 — Real SRA work-units (merged strain×tech; expandable later)

**Status:** Accepted.
**Context:** Real public reads give realism (ADR-002). An earlier per-tech split gave 9 units; fewer merged units were preferred. Everything is registry-level and regenerable, so units can be re-split later.
**Decision:** 6 real work-units. Merges are hybrid units (multi-tech, same strain); each can be split back into single-tech units later without breaking anything.

| folder_id | strain | accessions | tech | truth |
|---|---|---|---|---|
| `yarlip_real_001` | W29 | SRR37832827 | ONT | CLIB122 |
| `yarlip_real_002` | W29 | SRR37832855 | MGISEQ | CLIB122 |
| `cryneo_real_001` | H99 | SRR36664817 | Illumina | H99 (canonical) |
| `cryneo_real_hybrid_001` | Bt63a | SRR13201975 + SRR13201974 | hybrid (PacBio+Illumina) | H99 CNA3; Bt63a ref in NCBI/BFD/1KFG |
| `aspfum_real_hybrid_001` | ATCC 42202 | SRR28035763 + SRR28035764 | hybrid (ONT+Illumina) | Af293; ATCC 42202 finished assembly excluded (circular); CEA10 PacBio = future option |
| `aspfum_real_003` | "not af293" | ERR8084627 | PacBio | Af293 |
| `rhimic_real_001` | host R. microsporus + symbiont | SRR9029155 (+symbiont source) | Illumina | host GCF_002708625.1 + symbiont **Mycetohabitans sp. B46 GCF_037389205.1** |

**Consequences:** SRA reads are cached on demand (never archived tier 3); `manifests/registry.yaml` gains `real`/`real_hybrid` entries; **resolved open item — rhimic host truth**: NCBI verification (2026-08-17) shows SRR9029155 is a JGI *resequencing* of R. microsporus **NRRL 5546**, for which no public assembly exists; host truth anchored to **GCF_002708625.1 (ATCC 52813, the species reference genome "Rhimi1_1")** with an explicit strain-mismatch caveat, and the symbiont **Mycetohabitans sp. B46 (GCF_037389205.1)** is confirmed as the natural endosymbiont of NRRL 5546 (its BioSample records host R. microsporus, culture NRRL 5546). The previous registry accession GCA_977110955.1 (`gzRhiMicr1`, EBP-Norway) was a different strain and is dropped.

---

## ADR-017 — Real-dataset contamination scoring (extends ADR-012)

**Status:** Accepted.
**Context:** ADR-012 oracle mode needs declared spikes (simulation only). Real SRA has unknown background contamination; we need a general-screen output at run time plus a curated observed baseline so real and simulated metrics stay comparable.
**Decision:** For all real work-units, contamination is assessed at two layers:
1. **Screen mode at run time** (general): FCS_screen / FCS-GX / Kraken2 contig classification over each produced assembly; fraction of assembly bases assigned to non-host taxa reported (ADR-012 screen mode).
2. **One-time curated read-screen**: a single read-level screen (Kraken2) over the SRA reads populated at curation time into `dataset.contamination.observed`, so background contamination is known without relying on pipeline self-report.
Both feed Family-2 metrics and the `Blocked` outcome state per ADR-012.
**Consequences:** `metrics/assess_contamination.py` covers both layers; FCS_screen/FCS-GX + Kraken2 DBs join the tool pinning matrix.

---

## ADR-018 — Archiving: local-first, GCS only at explicit checkpoints (extends ADR-006)

**Status:** Accepted.
**Context:** ADR-006 defines tier 2 = hot GCS bucket. `gsutil`/`gcloud` are available on HPCC via `module load gcloudsdk` (not loaded by default), and `gs://stajichlab-asm-benchmarking/` has never been used. Continuous mirroring would add churn.
**Decision:**
- **Live = local only** on HPCC (`/bigdata`): simulated data in `datasets/sim/`, real SRA fetched/cached on demand for compute only.
- **Tier 1 (git) always carries the index** — registry, manifests, checksums.
- **Tier 2 (GCS) sync runs only at an explicit checkpoint** — i.e., *only when we decide and communicate one* (e.g., a frozen test-set version). No automated/continuous mirroring. At that point the sync runs under `module load gcloudsdk` + `gsutil rsync` — no install step needed.
**Consequences:** Nothing leaves HPCC until an agreed checkpoint; tier 3 (Zenodo/Dryad) still holds frozen versions when one is published.
