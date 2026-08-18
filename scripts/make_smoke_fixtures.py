#!/usr/bin/env python3
"""Generate tiny deterministic fixture datasets for the harness smoke test.

These are NOT benchmark datasets; they only exercise the adapter + harness
plumbing (reads are tiny synthetic fragments). Benchmark datasets come from
simulation/controller.py + pinned simulator binaries.
"""

import argparse
import gzip
import random
from pathlib import Path


def seq(rng, n):
    return "".join(rng.choice("ACGT") for _ in range(n))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path, help="staging root (folder_id subdirs created)")
    ap.add_argument("--seed", type=int, default=20260801)
    args = ap.parse_args()

    fixtures = {
        "yarlip_sim_001": 20260801,
        "canaur_sim_contam_lo_001": 20260802,
        "canaur_sim_contam_md_001": 20260803,
        "canaur_sim_contam_hi_001": 20260804,
        "canaur_sim_degrad_001": 20260805,
        "canaur_sim_mix_001": 20260806,
        "canaur_sim_adapter_001": 20260807,
        "canaur_sim_carryover_001": 20260808,
        "canaur_sim_all_001": 20260809,
        "cryneo_sim_contam_lo_001": 20260810,
        "cryneo_sim_contam_md_001": 20260811,
        "cryneo_sim_contam_hi_001": 20260812,
        "zymtri_sim_chr1_001": 20260813,
        "yarlip_real_001": 20260901,
        "yarlip_real_002": 20260902,
        "cryneo_real_001": 20260903,
        "cryneo_real_hybrid_001": 20260904,
        "aspfum_real_hybrid_001": 20260905,
        "aspfum_real_003": 20260906,
        "rhimic_real_001": 20260907,
    }
    for folder_id, seed in fixtures.items():
        rng = random.Random(seed)
        ds = args.out / folder_id
        (ds / "reads").mkdir(parents=True, exist_ok=True)
        (ds / "refs").mkdir(parents=True, exist_ok=True)

        with open(ds / "refs" / f"{folder_id}.truth.fa", "w") as f:
            f.write(f">ctg1\n{seq(rng, 2000)}\n")
            f.write(f">ctg2\n{seq(rng, 1800)}\n")

        reads = [(f"r{i}/1", seq(rng, 100)) for i in range(6)]
        reads += [(f"r{i}/2", seq(rng, 100)) for i in range(6)]
        for r in (1, 2):
            with gzip.open(ds / "reads" / f"{folder_id}_R{r}.fastq.gz", "wt") as f:
                for j in range(0, len(reads), 2):
                    idx = j + r - 1
                    h, s = reads[idx]
                    f.write(f"@{h}\n{s}\n+\n{'I' * len(s)}\n")
    print(f"wrote {args.out} with {len(fixtures)} fixture dataset(s)")


if __name__ == "__main__":
    main()
