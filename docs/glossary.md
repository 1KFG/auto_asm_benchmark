# Glossary

Canonical vocabulary for this project. When a term is ambiguous (see "related"), the canonical term wins; editors should use the canonical term and can extend the glossary via an ADR entry.

- **AABB** — the project acronym (auto asm benchmark). Used in informal shorthand and provenance labels; the canonical project name remains `auto_asm_benchmark`.
- **Truth genome / gold standard genome** — a curated, finished (T2T/chromosome-level) fungal reference used as ground truth for a host dataset. Synonymous with *backbone genome*. Compare *reference genome* (any), *truth* is specifically benchmarked-against.
- **Contaminant genome** — a non-host genome (phiX, vector, bacterium, plant, animal/human, other fungus) whose reads are spiked into a dataset, or whose representation is inflated (rDNA/mito).
- **Dataset work-unit** — one frozen, immutable benchmark input: reference genome + reads + declared scenario axes + provenance. A *unit* is one tuple of scenario axes for one genome.
- **Scenario axis** — one property a dataset varies: technology, coverage tier, quality state, contamination profile, ploidy expectation, structural subset.
- **Coverage tier** — low / medium / high target read depth for a technology.
- **Quality state** — high / medium / problematic characterization of a dataset's read quality (see scenario-matrix).
- **Contamination profile** — the set of contaminant sources + spike fractions applied to a dataset (or `none`).
- **Read simulation / the controller** — the in-repo tooling (`simulation/`) that generates reads from a truth genome and applies contamination, degradation, coverage, ploidy, and structural transformations. The *same* controller regenerates any archived dataset; its version + seed are provenance.
- **Quality degradation** — synthetic application of damage to reads: Q-score floor reduction, off-bias 3' trimming, fragment shortening, miscalling, chimeras.
- **Ploidy mismatch** — a dataset whose true ploidy (e.g., diploid/hybrid) differs from what the operator expects (haploid), or vice versa; a robustness scenario.
- **Frozen test-set version** — an immutable, versioned collection of dataset work-units, archived to cold storage with a DOI. One release of the benchmark corpus.
- **Pipeline under test (POT)** — a complete automated workflow (e.g., AAFTF, nf-AAFTF, SPAdes+polish chain) treated as an atomic unit by the benchmark.
- **Adapter / adapter contract** — a thin launcher in `adapters/` exposing a fixed input/output interface so any orchestrator flavor (nextflow/snakemake/conda/pixi) is runnable by the harness. Contract = dataset dir + params.yaml in; results dir + run_manifest.json out.
- **Meta-harness** — the Nextflow DSL2 workflow (`workflows/`) that schedules datasets over pipelines via adapters and gathers results.
- **Provenance** — the recorded identity of a run: tool names/versions, container digests, workflow commit hashes, conda lockfiles, reference-database versions, truth reference accessions, dataset id, frozen test-set version. Emitted as `provenance.yaml` per run.
- **Reference database version** — the specific release of a screening database (e.g., Kraken2 DB, BUSCO lineage `fungi_odb10`) used by a pipeline; pinned with the run.
- **Outcome state** — the five-way classification of a single dataset run: Success / Partial / Failed / Blocked / Skipped.
- **System score** — a single weighted number per pipeline per dimension aggregating its outcome states (see metrics.md).
- **Quality dimension** — the benchmark dimension over clean, typical data (controls).
- **Robustness / rescue dimension** — the benchmark dimension over problematic data (contamination, degradation, ploidy surprise).

### Ambiguity notes
- "Finished" vs "T2T" vs "complete": use precise RefSeq assembly levels in manifests (Complete Genome / Chromosome / Contig). Never call chromosome-level "T2T" unless it literally is.
- "Reads" always means the FASTQ sequence data of a dataset; "assembly" always means the product of a pipeline run.
- "Database" without qualification means a reference/classification database (Kraken2/BUSCO), not the GCP bucket.
