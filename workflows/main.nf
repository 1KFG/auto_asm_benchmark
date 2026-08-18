#!/usr/bin/env nextflow

// auto_asm_benchmark — Nextflow DSL2 meta-harness
//
// Benchmarks a set of pipelines-under-test (adapters) over a set of frozen
// benchmark datasets. Each pipeline is run atomically through its adapter
// (see ADR-005). Output: one results dir per run keyed by run uuid, with
// run_manifest.json + provenance.yaml + metrics.
//
// Run (harness smoke test on local tiny fixtures):
//   nextflow run workflows/main.nf \
//     -profile test \
//     --dataset_root datasets/staged \
//     --datasets yarli_clean_001 \
//     --pipelines aaftf
//
// Production on SLURM:  -profile slurm

nextflow.enable.dsl = 2

include { runPipeline } from './modules/pipeline'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
params.tool_matrix        = 'configs/tool_matrix.yaml'
params.dataset_manifest   = 'manifests/registry.yaml'
params.outdir             = 'results'
params.datasets           = null      // optional filter: comma list of folder_ids
params.pipelines          = null      // optional filter: comma list of pipeline ids
params.dataset_root       = null      // local dir hosting <folder_id>/ (reads, refs); overrides gs:// URIs
params.truth_fasta_lookup = 'assets/genomes.yaml'

// ---------------------------------------------------------------------------
// Input reading
// ---------------------------------------------------------------------------
// Parse the YAML manifests inside a small process so the driver needs no
// groovy yaml dependency. Emits one JSON object per (dataset, pipeline) pair.
process LOAD_MANIFEST {
  input:
  tuple path(manifest), path(tool_matrix)

  output:
  path "pairs.jsonl"

  script:
  def ds_filter = params.datasets ? params.datasets.tokenize(',').collect{it.trim()} : []
  def pl_filter = params.pipelines ? params.pipelines.tokenize(',').collect{it.trim()} : []
  """
  python3 - <<'PY'
  import json, sys, yaml
  m = yaml.safe_load(open("$manifest"))
  t = yaml.safe_load(open("$tool_matrix"))
  entries = m.get("entries", []) or []
  ds_filter = json.loads('${groovy.json.JsonOutput.toJson(ds_filter)}')
  pl_filter = json.loads('${groovy.json.JsonOutput.toJson(pl_filter)}')
  datasets = [
      {"folder_id": e["folder_id"], "dataset_id": e["dataset_id"],
       "uri": e["uri"], "seed_root": int(e.get("seed_root", 0))}
      for e in entries
      if (not ds_filter) or e["folder_id"] in ds_filter
  ]
  pipelines = [
      p for p in t.get("pipelines", []) if p.get("enabled", True)
  ]
  if pl_filter:
      pipelines = [p for p in pipelines if p["id"] in pl_filter]
  if not datasets:
      sys.exit("no datasets matched filter $ds_filter")
  if not pipelines:
      sys.exit("no pipelines matched filter $pl_filter")
  with open("pairs.jsonl", "w") as fh:
      for ds in datasets:
          for pl in pipelines:
              fh.write(json.dumps({"dataset": ds, "pipeline": pl}) + "\\n")
  PY
  """
}

// ---------------------------------------------------------------------------
// Workflow
// ---------------------------------------------------------------------------
workflow {
  Channel
    .fromList([[file(params.dataset_manifest, checkIfExists: true),
                file(params.tool_matrix, checkIfExists: true)]])
    .set { manifest_ch }

  LOAD_MANIFEST(manifest_ch)
    .splitText { it }
    .map { it -> new groovy.json.JsonSlurper().parseText(it) }
    // build the dispatch tuple; resolve local files + dataset dir here
    .map { j ->
      def ds = j.dataset
      def pl = j.pipeline
      def adapter = file(pl.execution.adapter, checkIfExists: true)
      def params_f = file(pl.params.default, checkIfExists: true)
      def tm = file(params.tool_matrix, checkIfExists: true)
      def ds_dir = resolveDatasetDir(ds)
      [ds, pl, adapter, params_f, tm, ds_dir]
    }
    .set { dispatch_ch }

  runPipeline(dispatch_ch)

  runPipeline.out.manifests
    .map { folder_id, pl_id, mf -> "results: ${folder_id}/${pl_id} ${mf}" }
    .view { it }
}

def resolveDatasetDir(ds) {
  // If the dataset URI is gs://, map repo's DS fetch into a local dir, or
  // fail loudly rather than fetching lazily at runtime (ADR-005).
  def uri = ds.uri
  if (uri.startsWith('gs://')) {
    if (!params.dataset_root) {
      throw new Exception("dataset ${ds.folder_id} is on GCS (${uri}); set --dataset_root to a local dir with <folder_id>/")
    }
    return file("${params.dataset_root}/${ds.folder_id}", checkIfExists: true)
  }
  // plain local path
  return file(uri, checkIfExists: true)
}
