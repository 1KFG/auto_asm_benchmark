#!/usr/bin/env python3
"""Dispatch read simulation to the appropriate external simulator.

Reads a reference FASTA and a scenario (technology + coverage) and produces a
FASTQ by invoking an external simulator. The simulator binary is resolved from
PATH (or $SIMULATORS_DIR). No simulator ships in this repo — they're installed
in the compute environment / container per docs/archive-strategy.md.

Supported backends (detected lazily):
  short (illumina/dnbseq): wgsim, dwgsim, art_illumina, mason_simulator
  hifi                   : pbsim3 (--hmm) / pbsim, badread (no), simLord
  nanopore               : badread (default), NanoSim, pbsim3

Use --dry-run to print the exact command without executing (useful when no
simulator is present, e.g. in tests or CI).
"""

import argparse
import glob
import hashlib
import shutil
import subprocess
import sys
from pathlib import Path

COVERAGE_DEFAULTS = {
    "low":    {"illumina": 10, "dnbseq": 10, "hifi": 15, "nanopore": 20, "nanopore_polish": 20},
    "medium": {"illumina": 30, "dnbseq": 30, "hifi": 30, "nanopore": 50, "nanopore_polish": 50},
    "high":   {"illumina": 60, "dnbseq": 60, "hifi": 50, "nanopore": 100, "nanopore_polish": 100},
}

READ_LEN = {"illumina": 150, "dnbseq": 150, "hifi": 15000, "nanopore": 8000, "nanopore_polish": 8000}


def genome_length(fasta):
    total = 0
    with open(fasta) as fh:
        for line in fh:
            if not line.startswith(">"):
                total += len(line.strip())
    return total


def fasta_records(fasta):
    cur_name = None
    cur_seq = []
    with open(fasta) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith(">"):
                if cur_name is not None:
                    yield cur_name, "".join(cur_seq)
                cur_name = line[1:].split()[0]
                cur_seq = []
            else:
                cur_seq.append(line)
    if cur_name is not None:
        yield cur_name, "".join(cur_seq)


def candidate_backends(tech, prefer=None):
    """Ordered candidate simulator names for a technology (unchecked)."""
    if tech in ("illumina", "dnbseq"):
        base = ["wgsim", "dwgsim", "art_illumina", "mason_simulator"]
    elif tech == "hifi":
        base = ["pbsim3", "pbsim", "simlord"]
    else:  # nanopore / nanopore_polish
        base = ["badread", "pbsim3", "NanoSim"]
    if prefer:
        return [prefer] + [c for c in base if c != prefer]
    return base


def pick_backend(tech, prefer=None):
    for c in candidate_backends(tech, prefer):
        if shutil.which(c):
            return c
    return None


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for blk in iter(lambda: fh.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def build_command(backend, fasta, out_fastq, tech, cov, seed, outdir,
                  sample_profile=None, sample_profile_id=None):
    glen = genome_length(fasta)
    rlen = READ_LEN.get(tech, 150)
    n_reads = max(1, int(round(cov * glen / rlen)))
    cmd = None
    if backend in ("wgsim", "dwgsim"):
        params = (["-d", "350", "-s", "50", "-N", str(n_reads // 2),
                   "-e", "0.005", "-r", "0.01", "-R", "0.0", "-1", str(rlen), "-2", str(rlen)]
                  if backend == "wgsim" else
                  ["-e", "0.005", "-r", "0.01", "-C", "350", "-1", str(rlen), "-2", str(rlen)])
        seed_prefix = ["-S", str(seed)] if backend == "wgsim" else ["--seed", str(seed)]
        cmd = [backend] + seed_prefix + params + [fasta,
                  str(out_fastq).replace(".fastq", "_1.fastq"),
                  str(out_fastq).replace(".fastq", "_2.fastq")]
    elif backend == "art_illumina":
        cmd = [backend, "-ss", "HS25", "-i", fasta, "-o", str(out_fastq),
               "-l", str(rlen), "-f", str(cov), "-m", "350", "-s", "50",
               "-p", "-na", "-rs", str(seed)]
    elif backend in ("pbsim3", "pbsim"):
        # pbsim3 v3.0.5 (yukiteruono rewrite). Output is NOT a single FASTQ:
        # per-reference-file `{prefix}_000N.fq.gz` members must be merged by
        # the caller (controller) via merge_pbsim_fastq().
        # HiFi uses the sample-based method benchmarked against a real CCS
        # read set (see assets/hifi_profile/); a generic QSHMM/ERRHMM is NOT a
        # HiFi model, so the legacy `--hmm_model P6C4` path is not used.
        cmd = ["pbsim", "--strategy", "wgs", "--genome", fasta,
               "--method", "sample",
               "--depth", str(cov), "--seed", str(seed),
               "--prefix", str(out_fastq)]
        if sample_profile:
            cmd += ["--sample", sample_profile]
        if sample_profile_id:
            cmd += ["--sample-profile-id", sample_profile_id]
    elif backend == "badread":
        glen_mb = glen / 1e6
        # characteristic-ribosome is a placeholder profile that produces decent
        # error-containing nanopore-like reads
        cmd = [backend, "simulate", "--reference", fasta,
               "--quantity", f"{cov}x", "--length", "minlen 8000 mean 12000 maxlen 40000",
               "--error", "uniform 12", "--seed", str(seed),
               "--output", str(out_fastq), "--pairs", "ion:inner 0.4 outer 0.6"]
    elif backend == "simlord":
        cmd = [backend, "--read-reference", fasta, "--coverage", str(cov),
               "--seed", str(seed), "--no-sam", "-o", str(out_fastq)]
    elif backend == "NanoSim":
        cmd = [backend, "simulator", "--seed", str(seed), "--fasta", fasta,
               "--number", str(n_reads), "--output", str(out_fastq)]
    if cmd is None:
        raise ValueError("no command builder for backend: %s" % backend)
    return cmd


def merge_pbsim_fastq(prefix, out_fastq):
    """Merge pbsim3 per-contig `{prefix}_####.fq.gz` into a single plain FASTQ.

    pbsim3 v3.0.5 WGS writes one `_000N.fq.gz` (plus .maf.gz/.ref) per input
    FASTA record. Concatenate the members in numeric order and decompress, so
    downstream spike/degrade/checksum steps see one stream.
    """
    import gzip
    members = sorted(glob.glob(f"{prefix}_*.fq.gz"),
                     key=lambda p: int(p.rsplit("_", 1)[1].split(".")[0]))
    if not members:
        raise FileNotFoundError(f"no pbsim3 outputs matching {prefix}_*.fq.gz")
    with open(out_fastq, "wb") as out:
        for m in members:
            with gzip.open(m, "rb") as fh:
                shutil.copyfileobj(fh, out)
    return out_fastq


def main():
    ap = argparse.ArgumentParser(description="Simulate reads for a benchmark dataset.")
    ap.add_argument("fasta", type=Path, help="truth reference FASTA")
    ap.add_argument("out_fastq", type=Path, help="output FASTQ (R1/R2 suffixes added for paired)")
    ap.add_argument("--technology", choices=sorted(COVERAGE_DEFAULTS["low"].keys()), required=True)
    ap.add_argument("--coverage", type=str, choices=["low", "medium", "high"], required=True)
    ap.add_argument("--cov-x", type=int, default=None, help="override numeric coverage")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--backend", default=None, help="prefer a specific simulator binary")
    ap.add_argument("--dry-run", action="store_true", help="print command(s) without running")
    args = ap.parse_args()

    cov = args.cov_x or COVERAGE_DEFAULTS[args.coverage][args.technology]
    backend = pick_backend(args.technology, args.backend)
    if backend is None:
        sys.stderr.write("no simulator available for technology=%s; install one or use --dry-run\n"
                         % args.technology)
        if not args.dry_run:
            sys.exit(2)

    cmd = build_command(backend, str(args.fasta), str(args.out_fastq),
                        args.technology, cov, args.seed, str(args.out_fastq.parent))
    print("BACKEND:", backend, file=sys.stderr)
    print("COVERAGE:", cov, "x;", "GENOME:", genome_length(args.fasta), "bp", file=sys.stderr)
    if args.dry_run:
        print(" ".join(cmd))
        out = str(args.out_fastq).replace(".fastq", "_1.fastq") + "\n" + \
              str(args.out_fastq).replace(".fastq", "_2.fastq") + "\n"
        print(out, end="")
        sys.exit(0)
    subprocess.run(cmd, check=True)
    print(f"simulated -> {args.out_fastq} (sha256={_sha256(args.out_fastq)})", file=sys.stderr)


if __name__ == "__main__":
    main()
