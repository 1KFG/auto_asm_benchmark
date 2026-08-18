#!/usr/bin/env python3
"""Deterministic read-quality degradation transforms for benchmark datasets.

Applies synthetic damage to FASTQ reads so "problematic" datasets are exactly
reproducible from a seed. Pure-Python and dependency-light so it can run in
tests and in constrained compute nodes.

Supports mechanisms (schema/dataset.schema.json `degradation`):
  qscore_floor      : clamp Q scores below a floor (raise to floor).
  offbias_trim      : trim a window of bases from the 3' end (counts re-scored).
  miscall_rate      : random base substitution at a given per-base rate.
  fragment_shorten  : truncate reads to a shorter mean length (coverage loss).
  chimeras          : stitch two reads together at a given rate.
  coverage_drop     : drop a fraction of reads.
  adapter_only      : a fraction of reads are replaced by adapter-dimers
                      (solon: pure adapter sequence, both ends).
  adapter_carryover : a fraction of reads have adapter bases tailing the
                      3' end (bases_from_3 of the adapter appended).

Every operation is drawn from a seeded RNG so outputs are reproducible.
"""

import argparse
import gzip
import random
import sys
from pathlib import Path

QUAL_CHARS = "!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHI"
BASE = {"A", "C", "G", "T", "N"}
BASE_ALT = {b: list(BASE - {b}) for b in BASE}

# TruSeq universal adapter (single-end read1 partial; P5+read2 partial):
# 5'-AGATCGGAAGAGCACACGTCTGAACTCCAGTCAC-3'
ADAPTER_FWD = "AGATCGGAAGAGCACACGTCTGAACTCCAGTCAC"
_COMPL = str.maketrans("ACGTNacgtn", "TGCANtgcan")


def _open(path):
    return gzip.open(path, "rt") if str(path).endswith(".gz") else open(path, "rt")


def _open_out(path):
    return gzip.open(path, "wt") if str(path).endswith(".gz") else open(path, "wt")


def _q_floor(qual, floor):
    # QUAL_CHARS is indexed by phred score (QUAL_CHARS[0] == '!', Q=33+0)
    # clamp to the max representable score: simulators (e.g. ART HiSeq2500) can
    # emit Q up to 41-42, beyond the QUAL_CHARS table's upper bound.
    maxq = len(QUAL_CHARS) - 1
    return "".join(QUAL_CHARS[min(max(ord(c) - 33, floor), maxq)] for c in qual)


def _offbias_trim(seq, qual, trim_bp, win):
    if trim_bp <= 0:
        return seq, qual
    n = min(trim_bp, max(0, len(seq) - win))
    return seq[: len(seq) - n], qual[: len(qual) - n]


def _miscall(seq, qual, rate, rng):
    out = []
    for c in seq:
        if c != "N" and rng.random() < rate:
            out.append(rng.choice(BASE_ALT[c]))
        else:
            out.append(c)
    return "".join(out)


def _fragment_shorten(seq, qual, mean_bp, rng):
    n = min(len(seq) - 1, max(1, int(rng.expovariate(1.0 / mean_bp))))
    return seq[:n], qual[:n]


def _revcomp(seq):
    return seq.translate(_COMPL)[::-1]


def _adapter_dimer(n):
    """A read-size adapter dimer (adapter + reverse-complement adapter)."""
    dimer = ADAPTER_FWD + _revcomp(ADAPTER_FWD)
    if n <= 0:
        return ""
    return (dimer * (n // len(dimer) + 1))[:n]


def _adapter_only(seq, qual, _rng):
    """Replace a read with pure adapter dimer (models adapter-only dimers)."""
    n = len(seq)
    return _adapter_dimer(n), ("I" * n)


def _adapter_carryover(seq, qual, bases):
    """Append `bases` bp of adapter to the 3' end of the read."""
    if bases <= 0:
        return seq, qual
    tail = ADAPTER_FWD[:bases]
    return seq + tail, qual + ("I" * bases)


def degrade_fastq(in_path, out_path, mechanisms, seed):
    """Transform reads in `in_path` per `mechanisms`, write to `out_path`."""
    rng = random.Random(seed)
    n_in = n_out = 0
    with _open(in_path) as fh_in, _open_out(out_path) as fh_out:
        while True:
            header = fh_in.readline()
            if not header:
                break
            seq = fh_in.readline().strip()
            plus = fh_in.readline()
            qual = fh_in.readline().strip()
            n_in += 1
            drop = False
            for mech in mechanisms:
                m = mech["mechanism"]
                p = mech.get("params", {})
                if m == "coverage_drop" and rng.random() < p.get("fraction", 0.0):
                    drop = True
                    break
                if m == "qscore_floor":
                    qual = _q_floor(qual, p.get("floor", 0))
                elif m == "offbias_trim":
                    seq, qual = _offbias_trim(seq, qual, p.get("bases_from_3", 0), p.get("window_size", 4))
                elif m == "miscall_rate":
                    seq = _miscall(seq, qual, p.get("rate", 0.0), rng)
                elif m == "fragment_shorten":
                    seq, qual = _fragment_shorten(seq, qual, p.get("mean_fragment_bp", 150), rng)
                elif m == "adapter_only":
                    if rng.random() < p.get("fraction", 0.01):
                        seq, qual = _adapter_only(seq, qual, rng)
                elif m == "adapter_carryover":
                    if rng.random() < p.get("fraction", 0.1):
                        seq, qual = _adapter_carryover(seq, qual, p.get("bases_from_3", 25))
                elif m == "chimeras":
                    # resolved at the read-pair level by mixing; single-read stub kept for schema compatibility
                    pass
            if drop:
                continue
            fh_out.write(f"{header}{seq}\n{plus}{qual}\n")
            n_out += 1
    return n_in, n_out


def main():
    ap = argparse.ArgumentParser(description="Apply synthetic quality degradation to FASTQ.")
    ap.add_argument("in_fastq", type=Path)
    ap.add_argument("out_fastq", type=Path)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--qscore-floor", type=int, default=None)
    ap.add_argument("--offbias-trim", type=int, default=None)
    ap.add_argument("--offbias-window", type=int, default=4)
    ap.add_argument("--miscall-rate", type=float, default=None)
    ap.add_argument("--mean-fragment-bp", type=float, default=None)
    ap.add_argument("--drop-fraction", type=float, default=None)
    ap.add_argument("--adapter-only-fraction", type=float, default=None)
    ap.add_argument("--carryover-fraction", type=float, default=None)
    ap.add_argument("--carryover-bases", type=int, default=25)
    args = ap.parse_args()

    mechs = []
    if args.qscore_floor is not None:
        mechs.append({"mechanism": "qscore_floor", "params": {"floor": args.qscore_floor}})
    if args.offbias_trim is not None:
        mechs.append({"mechanism": "offbias_trim", "params": {"bases_from_3": args.offbias_trim, "window_size": args.offbias_window}})
    if args.miscall_rate is not None:
        mechs.append({"mechanism": "miscall_rate", "params": {"rate": args.miscall_rate}})
    if args.mean_fragment_bp is not None:
        mechs.append({"mechanism": "fragment_shorten", "params": {"mean_fragment_bp": args.mean_fragment_bp}})
    if args.drop_fraction is not None:
        mechs.append({"mechanism": "coverage_drop", "params": {"fraction": args.drop_fraction}})
    if args.adapter_only_fraction is not None:
        mechs.append({"mechanism": "adapter_only", "params": {"fraction": args.adapter_only_fraction}})
    if args.carryover_fraction is not None:
        mechs.append({"mechanism": "adapter_carryover", "params": {"fraction": args.carryover_fraction, "bases_from_3": args.carryover_bases}})

    n_in, n_out = degrade_fastq(args.in_fastq, args.out_fastq, mechs, args.seed)
    print(f"degrade_fastq: {n_in} -> {n_out} reads ({args.out_fastq})", file=sys.stderr)


if __name__ == "__main__":
    main()
