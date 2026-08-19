// Adapter executor for external Nextflow pipelines (type: nextflow).
// External published workflows (e.g. stajichlab/nf-AAFTF) are invoked with
// `nextflow run` pinned to an immutable commit hash + container digest
// (ADR-004). Nothing is vendored; the run.sh sets the exact revision.

process RUN_NEXTFLOW_ADAPTER {
    tag "${pl.id}|${ds.folder_id}"
    label 'benchmark'
    stageInMode 'copy'

    publishDir path: { "${params.outdir}/${ds.folder_id}/${pl.id}" },
        mode: 'copy', overwrite: true, pattern: '{assembly/*.fasta,assembly/*.fasta.gz,run_manifest.json}'

    input:
    tuple val(ds), val(pl), path(adapter), path(params_file), path(tool_matrix), path(dataset_dir)

    output:
    tuple val(ds.folder_id), val(pl.id), path("${pl.id}__${ds.folder_id}/run_manifest.json"), emit: manifest
    tuple val(ds.folder_id), val(pl.id), path("${pl.id}__${ds.folder_id}/assembly/*.{fasta,fasta.gz}"), emit: assembly

    script:
    """
    set -euo pipefail
    export BENCH_ADAPTER_TYPE=nextflow
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
