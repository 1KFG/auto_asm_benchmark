#!/usr/bin/env python3
"""Spike contaminant reads into a host FASTQ at exact fractions (of host yield).

Deterministic given a seed. Reads from the contaminant FASTQ are subsampled
(or up-sampled with replacement) so that the number of contaminant bases is
`fraction * host_bases`, matching schema semantics ("fraction of host read
yield"). Output is an interleaved FASTQ unless --separate is given, in which
case host and contaminant reads are written to separate files.
"""

import argparse
import random
import sys
from pathlib import Path

try:
    from .degrade_quality import _open, _open_out
except ImportError:  # running as a standalone script (python simulation/spike_contamination.py)
    from degrade_quality import _open, _open_out


def count_bases(fastq):
    n = 0
    length = 0
    with _open(fastq) as fh:
        for header in fh:
            seq = fh.readline().strip()
            fh.readline()
            fh.readline()
            n += 1
            length += len(seq)
    return n, length


def selected_records_deduped(cont_recs, take_idx):
    """Return (header, seq, plus, qual) for each index in take_idx, appending
    "_repN" to the header of every repeat past the first when up-sampling
    with replacement picks the same source read more than once.

    take_idx must be sorted (both callers already sort it), so repeats of
    the same index are adjacent and a running counter suffices -- no need
    to pre-count occurrences across the whole list.

    Without this, two reads with byte-identical headers/sequences land in
    the output whenever a small contaminant genome (e.g. a 48kb phage,
    ADR-014) can't produce enough distinct reads at depth to hit the
    requested spike fraction. flye hard-errors on duplicate read IDs;
    found regenerating cryneo_sim_contam_hi_001 after fixing the
    cross-source collision in simulation/controller.py's vcat() -- that
    fix cut ~1055 duplicate IDs down to ~287, all from this same-source
    replacement-sampling case.
    """
    out = []
    prev_idx = None
    occurrence = 0
    for i in take_idx:
        occurrence = occurrence + 1 if i == prev_idx else 0
        prev_idx = i
        h, s, p, q = cont_recs[i]
        if occurrence:
            name, _, rest = h[1:].rstrip("\n").partition(" ")
            h = f"@{name}_rep{occurrence}" + (f" {rest}\n" if rest else "\n")
        out.append((h, s, p, q))
    return out


def read_records(fastq):
    with _open(fastq) as fh:
        for header in fh:
            seq = fh.readline().strip()
            plus = fh.readline().strip()
            qual = fh.readline().strip()
            yield header, seq, plus, qual


def target_contaminant_count(host_bases, cont_bases, cont_n, fraction):
    if cont_n <= 0 or cont_bases <= 0:
        return 0
    bases_wanted = fraction * host_bases
    return int(round(bases_wanted / (cont_bases / cont_n)))


def sample_contaminant_reads(cont_fastq, out_fastq, host_bases, fraction, seed):
    """Write a deterministic `fraction * host_bases` subset of cont reads to a new file.

    Same selection semantics as spike_fastq() (subsample, or up-sample with
    replacement when the pool is smaller than needed) but WITHOUT re-writing the
    host stream. The controller uses this per-mate: calling it twice with the
    same seed (once on the R1 pool, once on the R2 pool of paired simulation)
    yields the same contaminant indices on both mates, preserving pairing.
    """
    rng = random.Random(seed)
    cont_n, cont_bases = count_bases(cont_fastq)
    if host_bases <= 0 or cont_bases <= 0:
        return 0, cont_n
    n_take = target_contaminant_count(host_bases, cont_bases, cont_n, fraction)
    cont_recs = list(read_records(cont_fastq))
    if n_take > len(cont_recs):
        take_idx = sorted(rng.choices(range(len(cont_recs)), k=n_take))
    else:
        take_idx = sorted(rng.sample(range(len(cont_recs)), n_take))
    out = _open_out(out_fastq)
    for h, s, p, q in selected_records_deduped(cont_recs, take_idx):
        out.write(f"{h}{s}\n{p}\n{q}\n")
    out.close()
    return n_take, cont_n


def spike_fastq(host_fastq, cont_fastq, out_fastq, fraction, seed, separate=False):
    rng = random.Random(seed)
    host_n, host_bases = count_bases(host_fastq)
    cont_n, cont_bases = count_bases(cont_fastq)
    if host_bases <= 0:
        raise ValueError("host FASTQ has no bases")
    n_take = target_contaminant_count(host_bases, cont_bases, cont_n, fraction)

    cont_recs = list(read_records(cont_fastq))
    if n_take <= cont_n:
        take_idx = sorted(rng.sample(range(cont_n), n_take))
    else:
        take_idx = sorted(rng.choices(range(cont_n), k=n_take))
    contaminant_selected = selected_records_deduped(cont_recs, take_idx)

    if separate:
        host_out = _open_out(str(out_fastq).replace(".fastq", ".host.fastq"))
    else:
        host_out = _open_out(out_fastq)
    with _open(host_fastq) as fh:
        for header in fh:
            seq = fh.readline().strip()
            plus = fh.readline().strip()
            qual = fh.readline().strip()
            host_out.write(f"{header}{seq}\n{plus}\n{qual}\n")
    host_out.close()

    if separate:
        cont_out = _open_out(str(out_fastq).replace(".fastq", ".contam.fastq"))
    else:
        cont_out = _open_out(out_fastq)
        with _open(host_fastq) as fh:  # rewrite host portion first
            for header in fh:
                seq = fh.readline().strip()
                plus = fh.readline().strip()
                qual = fh.readline().strip()
                cont_out.write(f"{header}{seq}\n{plus}\n{qual}\n")
    for h, s, p, q in contaminant_selected:
        cont_out.write(f"{h}{s}\n{p}\n{q}\n")
    cont_out.close()
    return n_take, cont_n


def main():
    ap = argparse.ArgumentParser(description="Spike contaminant reads into host FASTQ.")
    ap.add_argument("host_fastq", type=Path)
    ap.add_argument("cont_fastq", type=Path)
    ap.add_argument("out_fastq", type=Path)
    ap.add_argument("--fraction", type=float, required=True)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--separate", action="store_true", help="write contaminant reads to a separate file")
    args = ap.parse_args()
    n_take, cont_n = spike_fastq(args.host_fastq, args.cont_fastq, args.out_fastq,
                                 args.fraction, args.seed, separate=args.separate)
    print(f"spike_fastq: spiked {n_take} of {cont_n} contaminant reads at fraction "
          f"{args.fraction} -> {args.out_fastq}", file=sys.stderr)


if __name__ == "__main__":
    main()
