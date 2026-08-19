#!/usr/bin/env python3
"""Probe whether a paired-end Illumina fixture contains mitochondrial reads.

AAFTF's `pipeline` subcommand unconditionally runs a NOVOPlasty mitochondrial
assembly for PE reads, and the current AAFTF release hard-crashes ("TypeError:
... not NoneType" in mito.py) whenever NOVOPlasty cannot assemble one (e.g.
datasets whose truth reference contains no mitochondrial chromosome -> zero
mito reads to assemble). There is no --skip_mito flag on the pipeline command.

This probe decides up front whether AAFTF's mito stage could possibly succeed,
so the adapter (adapters/aaftf/run.sh) can pre-place AAFTF's official
"already assembled" marker (`<basename>.mito.fasta`) and let the pipeline
advance through its real trim -> filter -> assemble -> ... steps.

Method: exact-match, canonical k-mers from the SAME bundled fungal
mito-seed.fasta that AAFTF would feed to NOVOPlasty. Real mito reads carry
perfect stretches of conserved mito sequence; a random read has essentially
zero probability of matching a 31-mer from the ~34 kb seed, so even a couple of
hits mean the mitogenome is present.

Usage: mito_probe.py --r1 READS_R1.fastq.gz [--seed mito-seed.fasta]
                      [--max-reads 300000] [--kmer 31] [--min-hit-reads 2]
                      [--min-total-hits 3]
Prints "present" or "absent" on stdout; exit 0 unless an input error occurs.
"""
import argparse
import gzip
import os
import sys

COMP = str.maketrans("ACGT", "TGCA")
AMB = set("BDEFHIJKLMNOPQRSUVWXYZ")


def revcomp(seq):
    return seq.translate(COMP)[::-1]


def canon(kmer):
    rc = revcomp(kmer)
    return kmer if kmer < rc else rc


def load_seed_kmers(seed_path, k):
    kmers = set()
    cur = []
    with open(seed_path) as fh:
        for line in fh:
            line = line.strip().upper()
            if not line or line.startswith(">"):
                continue
            cur.append(line)
    seq = "".join(cur)
    n_skipped = 0
    for i in range(len(seq) - k + 1):
        win = seq[i : i + k]
        if "N" in win or any(c in AMB for c in win):
            n_skipped += 1
            continue
        kmers.add(canon(win))
    if not kmers:
        print(f"mito_probe: no usable {k}-mers found in seed {seed_path}",
              file=sys.stderr)
        sys.exit(2)
    return kmers


def open_reads(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt")
    return open(path, "rt")


def probe(r1_path, seed_kmer_set, k, max_reads, min_hit_reads, min_total_hits):
    n_reads = 0
    hit_reads = 0
    total_hits = 0
    with open_reads(r1_path) as fh:
        while n_reads < max_reads:
            header = fh.readline()
            if not header:
                break
            seq = fh.readline().strip().upper()
            fh.readline()  # +
            fh.readline()  # qual
            n_reads += 1
            hits = 0
            for i in range(len(seq) - k + 1):
                win = seq[i : i + k]
                if "N" in win:
                    continue
                if canon(win) in seed_kmer_set:
                    hits += 1
            if hits:
                hit_reads += 1
                total_hits += hits
    present = hit_reads >= min_hit_reads and total_hits >= min_total_hits
    print(f"mito_probe: sampled {n_reads} reads, {hit_reads} mito-hit reads, "
          f"{total_hits} total k-mer hits", file=sys.stderr)
    return "present" if present else "absent"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--r1", required=True, help="Forward reads (fastq[.gz])")
    ap.add_argument("--seed", required=True, help="Mito seed FASTA")
    ap.add_argument("--kmer", type=int, default=31)
    ap.add_argument("--max-reads", type=int, default=300000)
    ap.add_argument("--min-hit-reads", type=int, default=2)
    ap.add_argument("--min-total-hits", type=int, default=3)
    args = ap.parse_args()

    if not os.path.isfile(args.r1):
        print(f"mito_probe: R1 not found: {args.r1}", file=sys.stderr)
        sys.exit(2)
    if not os.path.isfile(args.seed):
        print(f"mito_probe: seed not found: {args.seed}", file=sys.stderr)
        sys.exit(2)

    kmers = load_seed_kmers(args.seed, args.kmer)
    state = probe(args.r1, kmers, args.kmer, args.max_reads,
                  args.min_hit_reads, args.min_total_hits)
    print(state)


if __name__ == "__main__":
    main()
