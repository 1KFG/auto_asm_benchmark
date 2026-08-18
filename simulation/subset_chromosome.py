#!/usr/bin/env python3
"""Extract a single chromosome (or named subset) from a reference FASTA.

Used to build "single-chromosome-only" datasets: reads are then simulated from
the subset so partial-data recovery and chimerism can be benchmarked.
"""

import argparse
import hashlib
import sys
from pathlib import Path

from .simulate_reads import fasta_records


def subset_fasta(fasta, out_fasta, chrom_name):
    found = False
    with open(out_fasta, "w") as out:
        for name, seq in fasta_records(fasta):
            if name == chrom_name:
                out.write(f">{name}\n{seq}\n")
                found = True
                break
    if not found:
        available = [n for n, _ in fasta_records(fasta)]
        raise SystemExit(f"chromosome '{chrom_name}' not found. Available: {sorted(available)}")
    return out_fasta


def list_chromosomes(fasta):
    return [n for n, _ in fasta_records(fasta)]


def main():
    ap = argparse.ArgumentParser(description="Extract a single chromosome from a reference FASTA.")
    ap.add_argument("fasta", type=Path)
    ap.add_argument("chrom", nargs="?", help="chromosome name; omit to list")
    ap.add_argument("-o", "--out", type=Path, help="output FASTA (default: <chrom>.fa)")
    args = ap.parse_args()
    chrs = list_chromosomes(args.fasta)
    if not args.chrom:
        print("\n".join(chrs))
        sys.exit(0)
    out = args.out or (Path(args.fasta).parent / f"{args.chrom}.fa")
    subset_fasta(args.fasta, out, args.chrom)


if __name__ == "__main__":
    main()
