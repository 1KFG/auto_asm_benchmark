// Pipeline dispatch module: routes [dataset, pipeline] pairs to the correct
// adapter executor based on pl.type. Each pair carries staged files so the
// adapter can run from a Nextflow work dir (paths are resolved relative to
// the repo at pairing time, copied into the job).

include { RUN_CONDA_ADAPTER } from './adapter_conda'
include { RUN_SNAKEMAKE_ADAPTER } from './adapter_snakemake'
include { RUN_NEXTFLOW_ADAPTER } from './adapter_nextflow'

workflow runPipeline {
    take: pairs   // channel of [ds, pl, adapter, params, tool_matrix, dataset_dir]

    main:
    pairs
        .branch { ds, pl, adapter, params_f, tool_matrix, dataset_dir ->
            conda:     pl.type == 'conda'
            snakemake: pl.type == 'snakemake'
            nextflow:  pl.type == 'nextflow'
        }
        .set { branches }

    RUN_CONDA_ADAPTER(branches.conda)
    RUN_SNAKEMAKE_ADAPTER(branches.snakemake)
    RUN_NEXTFLOW_ADAPTER(branches.nextflow)

    emit:
    manifests = RUN_CONDA_ADAPTER.out.manifest \
        .mix(RUN_SNAKEMAKE_ADAPTER.out.manifest) \
        .mix(RUN_NEXTFLOW_ADAPTER.out.manifest)
    assemblies = RUN_CONDA_ADAPTER.out.assembly \
        .mix(RUN_SNAKEMAKE_ADAPTER.out.assembly) \
        .mix(RUN_NEXTFLOW_ADAPTER.out.assembly)
}
