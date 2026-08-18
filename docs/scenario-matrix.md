# Scenario Matrix

This document enumerates the scenario axes used to define benchmark datasets. Any dataset work-unit (in `datasets/`) is a tuple of these axes. See `schema/dataset.schema.json` for the machine-readable contract.

## Axes

### A. Sequencing technology
| Code | Definition |
|---|---|
| `illumina` | short paired-end Illumina (150 bp typical) |
| `dnbseq` | short paired-end BGI DNBSEQ |
| `hifi` | PacBio HiFi (Q30+) |
| `nanopore` | Oxford Nanopore, raw basecalled |
| `nanopore_polish` | Oxford Nanopore + read polishing (e.g., racon/Medaka) |
| `hybrid` | combinations of the above (e.g., short + long), including hybrid assemblers |

### B. Coverage tier (per genome, ~30 Mb fungal reference)
| Tier | illumina/dnbseq | hifi | nanopore |
|---|---|---|---|
| low | 10x | 15x | 20x |
| medium | 30x | 30x | 50x |
| high | 60x+ | 50x+ | 100x+ |

Higher coverage is also used where genomic complexity demands it (e.g., hybrid/diploid mistaken for haploid).

### C. Quality state
| State | Definition |
|---|---|
| high | platform-appropriate read lengths; low error (HiFi Q30+, ONT >= Q20); no observed adapter/vector residuals |
| medium | realistic sub-optimal: adapter carryover, lower Q scores, moderate coverage, some chimeric/fragmented ONT |
| problematic | exact mechanisms applied synthetically: Q-score floor dropped, off-bias 3' trimming, reduced fragment lengths, aneuploidy/hybrid mix, low coverage |

Degradation is applied **synthetically** so the mechanism is known and reproducible.

### D. Contamination profile
Sources are injected at declared fractions of the host read yield. Phase-1 panel:

| Code | Source | Example reference |
|---|---|---|
| `phix` | PhiX sequencing spike-in | NC_001422.1 |
| `vector` | plasmid / cloning vector | pUC19 / pBR322 / lambda |
| `ecoli` | E. coli | NC_000913.3 |
| `env_bact` | environmental / culture bacteria | Acinetobacter, Delftia, Pseudomonas |
| `symbiont` | endosymbiont | Wolbachia; Burkholderia in Rhizopus |
| `host_plant` | host co-isolated plant DNA | depends on sample type |
| `host_animal` | host co-isolated animal/human DNA | Homo sapiens |
| `fungus_other` | different fungal class/phylum | e.g., S. cerevisiae into a basidiomycete genome |
| `rdna_mito` | rDNA / mitochondrial overrepresentation (also a "targeted assembly" scenario) | within-reference amplification |

Fraction levels: **0.1%, 1%, 5%** (%, relative to host read yield).
Analysis of "barcode index hopping" is modeled only as random non-host, non-symbiont DNA (sequencing noise).

### E. Ploidy expectation
| Expectation | Meaning |
|---|---|
| haploid | expect haploid assembly; often true for many fungi |
| diploid | expect diploid (e.g., hybrid strain, dikaryon) |
| mismatch | reads are diploid/hybrid but the operator assumed haploid (and conversely) |

Ploidy-mismatch scenarios may use higher coverage to test assemblers that resolve vs. collapse haplotypes.

### F. Structural subset
| Code | Definition |
|---|---|
| full | whole genome |
| single_chromosome | reads derived from a single reference chromosome only (tests partial-data recovery and chimerism) |

## Canonical defaults per axis (archived; see ADR-007)

- technology: `illumina` and `hifi` (start) + `nanopore` (secondary)
- coverage: `medium`
- quality: `high` for the quality dimension; `problematic` for the robustness dimension
- contamination: `none` for quality dimension; `phix@1%` as the default robustness contamination
- ploidy: `haploid` default; `mismatch` scenario generated on demand
- subset: `full`

The full combinatorial cross is regenerable from `simulation/`; only canonical flavors are archived.

## Dataset naming convention

Dataset IDs use a compact, sortable convention:

```
<genome_id>__<tech>__<cov>__<quality>__<contam>__<ploidy>__<subset>
```

e.g.:
- `yarlip__illumina__med__high__none__haploid__full`
- `cryneo__hifi__med__high__symbiont_1pct_lambda_1pct__haploid__full`
- `canaur__illumina__med__problematic__all_1pct__haploid__full`
- `zymtri__illumina__low__medium__none__haploid__chr1_only`

See `datasets/*.yaml` for concrete examples.
