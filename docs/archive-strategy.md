# Archive Strategy (3-tier)

This project keeps sequence data out of git. Data lives in three tiers; the repository is the *index* (metadata + manifests) that points at the other two.

```
┌─────────────────────────────────────────────────────────────┐
│ Tier 1  git repo (this repo)                                │
│          metadata only: manifests, configs, tool matrix,    │
│          schemas, workflow specs, provenance schema          │
├─────────────────────────────────────────────────────────────┤
│ Tier 2  GCP GCS (hot bucket)                                 │
│          working copies for compute, generated test sets     │
│          (contaminated/degraded reads, single-chromosome     │
│          subsets), each declared with checksum+size+version  │
├─────────────────────────────────────────────────────────────┤
│ Tier 3  Zenodo or Dryad (cold archive)                       │
│          frozen, versioned snapshots of a test-set version,  │
│          one DOI per version (the "frozen benchmark")         │
└─────────────────────────────────────────────────────────────┘
```

## Policy rules

1. **Never permanently re-host third-party raw reads.** SRA/ENA runs are referenced by accession in manifests and cached in the hot bucket only for compute. No accession-owned data is mirrored to tier 3.
2. **Only our own generated artifacts are archived** to tier 3: simulated reads, degraded reads, contamination spike libraries, single-chromosome subsets, plus the frozen manifests describing them.
3. **Checksums everywhere.** Every generated file registered in a manifest carries its block checksum + size + generator version + generation command, so any tier-2 object is reproducible and verifiable from tier-1 metadata.
4. **Bucket config lives in configs, not in code.** `configs/repo.yaml` holds bucket names/paths; no credentials are committed.

## Directory layout on GCP (proposed)

```
gs://stajichlab-asm-benchmarking/
├── datasets/            # generated work-units, keyed by SHORT folder id
│   └── <genome-id>_<kind>_<NNN>/
│       ├── reads/       # host + contaminant reads (checksummed fastq)
│       ├── refs/        # reference / contaminant fasta used
│       └── metadata.yaml  # -> full dataset_id, schema version, generator version+seed
├── refs/                # fetched reference/contaminant genomes (cached, by accession)
├── cache/               # downloaded third-party reads (by SRA/ENA accession)
└── results/             # optional: mirror of run results off-cluster
```

## Dataset naming on the hot bucket

Short, informative folder ids — the human-readable name AND the full scenario
tuple are linked by a registry, never by relying on the folder name alone.

Scheme: `<genome_id>_<stressor>_<NNN>` — e.g. `canaur_sim_contam_001`.

`genome_id` is a 3+3-letter mnemonic with no strain suffix, keyed from `assets/genomes.yaml` (ADR-013). `stressor` is a controlled vocabulary (ADR-013):

| stressor | meaning |
|---|---|
| `sim` | simulated clean reads |
| `sim_contam` | simulated + contamination spike (tier lo/md/hi = 0.1%/1%/5%, ADR-014) |
| `sim_degrad` | simulated + quality degradation |
| `sim_mix` | hybrid/diploid (ploidy mismatch) reads |
| `sim_adapter` | simulated + adapter-only reads at both ends (spike) |
| `sim_carryover` | simulated + 3′-end adapter carryover (degradation kind) |
| `sim_all` | simulated combined unit (includes the adapter spike) |
| `sim_chr1` | single-chromosome structural subset |
| `real` | real public reads (quality-control scenario) |
| `real_hybrid` | real reads, one strain, multiple technologies merged (ADR-016) |

Tier-2 sync to GCS happens **only at an explicit checkpoint** (ADR-018); run under `module load gcloudsdk` + `gsutil rsync`.

`NNN` is a zero-padded sequence number per genome+kind. The authoritative
mapping short-folder-id -> full `dataset_id` -> GCS URI lives in
`manifests/registry.yaml` (schema-managed metadata kept on the HPCC local host
and mirrored into the bucket).

## Cold archive (Zenodo / Dryad)

- One Zenodo **record (DOI) per frozen test-set version**.
- The record bundles: all generated FASTQ + reference subsets + the frozen `manifests/<testset_version>.yaml` + the generator commit hash.
- The manifest's `archive` block records the DOI so any dataset in git can be traced to its frozen archive copy.

## GCP profile for execution

Tier-2 storage is paired with a `-profile gcp` Nextflow stub (see `workflows/nextflow.config`) that uses `gs://` paths; the default production target is a local SLURM cluster (HPCC). Cloud execution is an explicit, later offload path, not the default.
