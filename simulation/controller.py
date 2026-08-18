#!/usr/bin/env python3
"""Benchmark dataset generator controller.

Reads a dataset work-unit (datasets/*.yaml) and produces the frozen dataset
folder under the hot-bucket layout (local staging dir, then sync to GCS):

    <out>/<folder_id>/
        refs/<truth>.fa           (subset if single-chromosome)
        reads/<folder_id>[_R1|_R2|].fastq.gz  (paired-end) | <folder_id>.fastq.gz (single-end)
        metadata.yaml             (dataset yaml + generator version + seed + hashes)

Pipeline (deterministic per dataset seed):
  1. resolve truth + contaminant reference fastas from assets/refs
  2. optional single-chromosome subset
  3. simulate host reads (ART for illumina/dnbseq, pbsim3-sample for HiFi)
  4. apply contamination spikes (spike_contamination.py, per-mate paired-aware)
  5. apply degradation (degrade_quality.py)
  6. compute per-file checksums; write metadata.yaml

Real-read (`source_reads.type: real_sra`) datasets are only *referenced* by
accession (never re-hosted); the controller caches them for compute on demand.

Simulators run pinned Apptainer SIFs from containers/sifs (see configs/tool_matrix.yaml
sim_tools): every SIF invocation must run from a module-loaded apptainer.
"""

import argparse
import gzip
import hashlib
import shutil
import subprocess
import sys
import yaml
from pathlib import Path

from simulation import spike_contamination as spk
from simulation.degrade_quality import degrade_fastq
from simulation.simulate_reads import build_command, merge_pbsim_fastq, COVERAGE_DEFAULTS, READ_LEN
from simulation.subset_chromosome import subset_fasta

REPO_ROOT = Path(__file__).resolve().parent.parent
REGISTRY_YAML = REPO_ROOT / "manifests" / "registry.yaml"
HIFI_PROFILE_ID = "ecoli_hifi"

# technology -> (sif digest prefix, simulator binary inside the SIF)
SIM_TOOL_ROLE = {
    "art":  ("ab044ce2994ce7", "art_illumina"),
    "pbsim": ("70d2ee306d7d", "pbsim"),
}
TECH_TOOL = {"illumina": "art", "dnbseq": "art", "hifi": "pbsim"}

CONTROLLER_VERSION = "0.1.0"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for blk in iter(lambda: fh.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def folder_id_for(dataset_id):
    """Map dataset_id -> short folder id via manifests/registry.yaml (registry is source of truth)."""
    reg = yaml.safe_load(REGISTRY_YAML.open())
    for e in reg.get("entries", []):
        if e.get("dataset_id") == dataset_id:
            return e["folder_id"]
    return None


def build_ref_index(refs_dir):
    """Scan assets/refs/**/*.fa(.meta.yaml); return {ref_id -> path} and {accession -> path}."""
    by_ref, by_acc = {}, {}
    for meta in refs_dir.glob("**/*.fa.meta.yaml"):
        fa = Path(str(meta)[: -len(".meta.yaml")])
        if not fa.exists():
            continue
        m = yaml.safe_load(meta.open())
        if m.get("ref_id"):
            by_ref[m["ref_id"]] = fa
        if m.get("accession"):
            by_acc[m["accession"]] = fa
    return by_ref, by_acc


def resolve_contaminant(spike, by_ref, by_acc):
    acc = spike.get("accession")
    if acc and acc in by_acc:
        return by_acc[acc]
    src = spike.get("source")
    if src and src in by_ref:
        return by_ref[src]
    raise SystemExit(
        f"cannot resolve contaminant spike {spike!r} — need a staged ref "
        f"(seen {sorted(set(list(by_ref) + list(by_acc)))})")


def find_sif(sifs_dir, digest_prefix):
    for p in sifs_dir.glob(f"*{digest_prefix}*.sif"):
        return p.resolve()  # absolute: simulator runs with cwd=work (scratch), relative paths would break
    raise SystemExit(f"no SIF for digest {digest_prefix} in {sifs_dir} (run scripts/pull_containers.sh)")


def vcat(out_path, *in_paths):
    """Concatenate plain-text FASTQ files into one (keeps sequencing order)."""
    with open(out_path, "wb") as out:
        for p in in_paths:
            with open(p, "rb") as fh:
                shutil.copyfileobj(fh, out)
    return out_path


def gzip_fastq(in_path, out_path):
    with open(in_path, "rb") as src, gzip.GzipFile(str(out_path), "wb", compresslevel=6) as dst:
        shutil.copyfileobj(src, dst, 1 << 20)
    return out_path


def run(cmd, *, cwd=None, dry_run=False):
    if dry_run:
        print("DRY-RUN:", " ".join(str(c) for c in cmd))
        return 0
    subprocess.run(cmd, check=True, cwd=cwd)


def apptainer_base(sif):
    # /bigdata is bound by default; $SCRATCH (/scratch) is node-local NVMe and needs an
    # explicit bind so simulator tools (ART/pbsim3) can write their outputs there.
    return ["apptainer", "exec", "-B", "/scratch", str(sif)]


def sim_host_reads(ds, truth_fa, work, sif, dry_run):
    """Simulate host reads -> work/host.fq (single) or work/host1.fq + work/host2.fq (paired)."""
    tech = ds["technology"]
    cov = int(ds["coverage_targets"]["coverage_x"])
    seed = ds["source_reads"]["seed"]
    digest, binary = SIM_TOOL_ROLE[TECH_TOOL[tech]]
    base = apptainer_base(sif)
    paired = tech in ("illumina", "dnbseq")
    rlen = READ_LEN.get(tech, 150)
    if paired:
        prefix = work / "host"
        cmd = base + [binary, "-ss", "HS25", "-i", str(truth_fa), "-o", str(prefix),
                      "-l", str(rlen), "-f", str(cov), "-m", "350", "-s", "50",
                      "-p", "-na", "-rs", str(seed)]
        run(cmd, dry_run=dry_run)
        return prefix, paired
    # HiFi: pbsim3 sample-based method
    prepare_hifi_profile(work)
    prefix = work / "host_"
    cmd = base + ["pbsim", "--strategy", "wgs", "--genome", str(truth_fa),
                  "--method", "sample", "--sample-profile-id", HIFI_PROFILE_ID,
                  "--depth", str(cov), "--seed", str(seed), "--prefix", str(prefix)]
    run(cmd, dry_run=dry_run, cwd=work)
    if not dry_run:
        merge_pbsim_fastq(str(prefix), str(work / "host.fq"))
    return prefix, paired


def prepare_hifi_profile(work):
    """Materialize sample_profile_<id>.fastq/.stats in work/ from assets/hifi_profile gz."""
    prof_dir = REPO_ROOT / "assets" / "hifi_profile"
    fq_gz = prof_dir / "ecoli_ccs_profile.fastq.gz"
    st_gz = prof_dir / f"sample_profile_{HIFI_PROFILE_ID}.stats.gz"
    target_fq = work / f"sample_profile_{HIFI_PROFILE_ID}.fastq"
    target_st = work / f"sample_profile_{HIFI_PROFILE_ID}.stats"
    if not target_fq.exists():
        with gzip.GzipFile(str(fq_gz), "rb") as src, open(target_fq, "wb") as dst:
            shutil.copyfileobj(src, dst)
    if not target_st.exists():
        with gzip.GzipFile(str(st_gz), "rb") as src, open(target_st, "wb") as dst:
            shutil.copyfileobj(src, dst)


def simulate_contaminant(spike, work, i, tech, cov, seed, truth_ref, sif, dry_run):
    """Simulate one contaminant pool -> (work/cont_<i>1.fq, work/cont_<i>2.fq) or (work/cont_<i>.fq,)."""
    src = spike.get("source", f"spike{i}")
    paired = tech in ("illumina", "dnbseq")
    if paired:
        prefix = work / f"cont_{i}_{src}"
        cmd = apptainer_base(sif) + ["art_illumina",
               "-ss", "HS25", "-i", str(truth_ref), "-o", str(prefix),
               "-l", "150", "-f", str(cov), "-m", "350", "-s", "50",
               "-p", "-na", "-rs", str(seed)]
        run(cmd, dry_run=dry_run)
        return [Path(f"{prefix}1.fq"), Path(f"{prefix}2.fq")]
    prefix = work / f"cont_{i}_{src}_"
    prepare_hifi_profile(work)
    cmd = apptainer_base(sif) + ["pbsim",
           "--strategy", "wgs", "--genome", str(truth_ref),
           "--method", "sample", "--sample-profile-id", HIFI_PROFILE_ID,
           "--depth", str(cov), "--seed", str(seed), "--prefix", str(prefix)]
    run(cmd, dry_run=dry_run, cwd=work)
    out = work / f"cont_{i}_{src}.fq"
    if not dry_run:
        merge_pbsim_fastq(str(prefix), str(out))
    return [out]


def generate(ds, args):
    folder_id = args.folder_id or folder_id_for(ds["dataset_id"])
    if not folder_id:
        folder_id = f"{ds['genome']}_{ds['dataset_id'].split('__')[-1].split('__')[0]}_auto"
        print("WARN: no registry entry for", ds["dataset_id"], "-> folder_id", folder_id, file=sys.stderr)
    tech = ds["technology"]
    cov = int(ds["coverage_targets"].get("coverage_x", COVERAGE_DEFAULTS[ds["coverage"]][tech]))
    seed = ds["source_reads"]["seed"]
    paired = tech in ("illumina", "dnbseq")

    work = args.work / folder_id
    work.mkdir(parents=True, exist_ok=True)
    final_dir = args.out / folder_id
    (final_dir / "reads").mkdir(parents=True, exist_ok=True)
    (final_dir / "refs").mkdir(parents=True, exist_ok=True)

    # 1. host truth (optional chromosome subset)
    by_ref, by_acc = build_ref_index(args.refs)
    host_fa = by_ref.get(ds["genome"])
    if host_fa is None:
        host_fa = by_acc.get(ds["genome"], args.refs / f"{ds['genome']}.fa")
    if not host_fa.exists():
        raise SystemExit(f"host reference not staged: {host_fa}")
    truth_fa = work / "truth.fa"
    if ds.get("subset", {}).get("mode") == "single_chromosome":
        subset_fasta(host_fa, truth_fa, ds["subset"]["chromosome"])
    else:
        shutil.copy(host_fa, truth_fa)

    # 2. host reads
    sif = find_sif(args.sifs, SIM_TOOL_ROLE[TECH_TOOL[tech]][0])

    prefix, paired = sim_host_reads(ds, truth_fa, work, sif, args.dry_run)
    if paired:
        host_mates = [Path(f"{prefix}1.fq"), Path(f"{prefix}2.fq")]
    else:
        host_mates = [work / "host.fq"]

    # 3. contamination spikes (fraction of host read yield, per-mate, pair-preserving)
    spikes = (ds.get("contamination") or {}).get("spikes") or []
    if spikes:
        host_bases = [spk.count_bases(m)[1] for m in host_mates] if not args.dry_run else [0] * len(host_mates)
        selected = [[] for _ in host_mates]   # sampled contaminant file per mate
        for i, spike in enumerate(spikes):
            cont_ref = resolve_contaminant(spike, by_ref, by_acc)
            cont_mates = simulate_contaminant(spike, work, i, tech, cov, seed, cont_ref, sif, args.dry_run)
            for m, (cont_m, hb) in enumerate(zip(cont_mates, host_bases)):
                sample_path = work / f"cont_{i}_sample{m}.fq"
                if not args.dry_run:
                    spk.sample_contaminant_reads(str(cont_m), str(sample_path), hb,
                                                 spike["fraction"], seed)
                selected[m].append(sample_path)
        merged = [work / f"merged_m{m}.fq" for m in range(len(host_mates))]
        for m in range(len(host_mates)):
            if not args.dry_run:
                vcat(merged[m], host_mates[m], *selected[m])
            else:
                merged[m] = None
    else:
        merged = [work / f"merged_m{m}.fq" for m in range(len(host_mates))]
        for m in range(len(host_mates)):
            if not args.dry_run:
                shutil.copyfile(host_mates[m], merged[m])

    # 4. degradation (applied to the pooled host+contaminant stream, per mate, same seed)
    mechs = ds.get("degradation") or []
    degraded = [work / f"degraded_m{m}.fq" for m in range(len(host_mates))]
    if mechs and not args.dry_run:
        for m in range(len(host_mates)):
            degrade_fastq(merged[m], degraded[m], mechs, seed)
    elif mechs and args.dry_run:
        print("DRY-RUN: degrade_fastq", *[str(m) for m in merged], "->", *[str(d) for d in degraded],
              "seed", seed)

    # 5. final frozen layout
    files = {}
    if args.dry_run:
        print("OK (dry-run) " + folder_id)
        return folder_id, {}
    shutil.copy(truth_fa, final_dir / "refs" / f"{folder_id}.truth.fa")
    for m in range(len(host_mates)):
        if paired:
            out_name = f"{folder_id}_R{m + 1}.fastq.gz"
        else:
            out_name = f"{folder_id}.fastq.gz"
        src = degraded[m] if mechs else merged[m]
        dst = final_dir / "reads" / out_name
        gzip_fastq(src, dst)
        files[out_name] = sha256_file(dst)

    # 6. metadata.yaml
    files_meta = []
    for name, h in files.items():
        readside = "reads" if name.endswith(".fastq.gz") else "refs"
        p = final_dir / readside / name
        files_meta.append({"path": f"{readside}/{name}", "sha256": h, "size": p.stat().st_size})
    truth_name = f"{folder_id}.truth.fa"
    truth_path = final_dir / "refs" / truth_name
    files_meta.append({"path": f"refs/{truth_name}",
                       "sha256": sha256_file(truth_path), "size": truth_path.stat().st_size})

    metadata = dict(ds)
    metadata.update({
        "folder_id": folder_id,
        "testset_version": "2026.08.1",
        "seed": seed,
        "read_layout": "paired" if paired else "single",
        "coverage_x": cov,
        "generator": {"controller_version": CONTROLLER_VERSION,
                      "simulators": {"art_illumina": "3.19.15", "pbsim": "3.0.5-sample"},
                      "hifi_profile_id": HIFI_PROFILE_ID if tech == "hifi" else None},
        "files": sorted(files_meta, key=lambda x: x["path"]),
    })
    meta_out = final_dir / "metadata.yaml"
    if not args.dry_run:
        meta_out.write_text(yaml.safe_dump(metadata, sort_keys=False))

    dur = " (dry-run)" if args.dry_run else ""
    print(f"OK {folder_id}: {tech} {cov}x paired={paired} spikes={len(spikes)} "
          f"degrade={len(mechs)} {files}{dur}")
    return folder_id, files


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="Generate a frozen benchmark dataset work-unit.")
    ap.add_argument("dataset_yaml", type=Path)
    ap.add_argument("--out", type=Path, default=REPO_ROOT / "datasets" / "sim",
                    help="where frozen dataset folders are written (default datasets/sim)")
    ap.add_argument("--refs", type=Path, default=REPO_ROOT / "assets" / "refs",
                    help="reference fasta staging (assets/refs)")
    ap.add_argument("--sifs", type=Path, default=REPO_ROOT / "containers" / "sifs",
                    help="apptainer SIF dir (containers/sifs)")
    ap.add_argument("--work", type=Path, default=None,
                    help="intermediate scratch dir (default: $SCRATCH if set, else local_staging/)")
    ap.add_argument("--folder-id", default=None, help="override short folder id")
    ap.add_argument("--skip-sim", action="store_true", help="only write metadata (real-read dataset)")
    ap.add_argument("--dry-run", action="store_true", help="print commands without running simulators")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.work is None:
        import os
        args.work = Path(os.environ.get("SCRATCH", REPO_ROOT / "local_staging")) / "gen"
    with open(args.dataset_yaml) as fh:
        ds = yaml.safe_load(fh)
    if args.skip_sim or ds["source_reads"]["type"] != "simulated":
        print("real_read dataset — controller only caches by accession (not generated here)")
        return 0
    generate(ds, args)


if __name__ == "__main__":
    sys.exit(main())
