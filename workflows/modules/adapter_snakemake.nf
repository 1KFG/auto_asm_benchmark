// Adapter executor for snakemake-type pipelines (type: snakemake).
// Same contract as adapter_conda.nf; the pipeline ships its own Snakefile +
// run.sh wrapper. The run.sh is responsible for pinned env provisioning.

process RUN_SNAKEMAKE_ADAPTER {
    tag "${pl.id}|${ds.folder_id}"
    label 'benchmark'
    stageInMode 'copy'

    publishDir path: { "${params.outdir}/${ds.folder_id}/${pl.id}" },
        mode: 'copy', overwrite: true, pattern: '{assembly/*.fasta,run_manifest.json}'

    input:
    tuple val(ds), val(pl), path(adapter), path(params_file), path(tool_matrix), path(dataset_dir)

    output:
    tuple val(ds.folder_id), val(pl.id), path("${pl.id}__${ds.folder_id}/run_manifest.json"), emit: manifest
    tuple val(ds.folder_id), val(pl.id), path("${pl.id}__${ds.folder_id}/assembly/*.fasta"), emit: assembly

    script:
    """
    set -euo pipefail
    export BENCH_ADAPTER_TYPE=snakemake
    export BENCH_DATASET_DIR="${dataset_dir}"
    export BENCH_OUTDIR="${pl.id}__${ds.folder_id}"
    export BENCH_TOOL_MATRIX="${tool_matrix}"
    export BENCH_PARAMS="${params_file}"
    export BENCH_SEED="${ds.seed_root}"
    export BENCH_SMOKE="${params.smoke ? '1' : '0'}"
    export BENCH_SIFS_DIR="${params.sifs_dir}"

    mkdir -p "\$BENCH_OUTDIR"
    bash "${adapter}"
    """
}
