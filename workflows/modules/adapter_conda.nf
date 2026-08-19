// Adapter executor for `conda` / shell / pixi-type pipelines (type: conda).
// Contract: each pipeline ships a fixed run.sh at pl.execution.adapter that:
//   reads $BENCH_DATASET_DIR (resolved read dir), $BENCH_OUTDIR,
//   $BENCH_TOOL_MATRIX, $BENCH_PARAMS
//   writes $BENCH_OUTDIR/assembly/*.fasta[.gz] and $BENCH_OUTDIR/run_manifest.json
//   (gzip-compressed where the adapter supports it, to save space)
//   returns 0 on success (partial), 10 on partial, nonzero on failure.
//
// IMPORTANT: never activate arbitrary user envs on the driver — env
// provisioning (pixi/conda/container) is declared in pl.execution and resolved
// by a pinned lockfile or digest at run time (ADR-004).

process RUN_CONDA_ADAPTER {
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
    export BENCH_ADAPTER_TYPE=conda
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
