#!/usr/bin/env python3
"""Fetch + stage host and contaminant reference FASTA files into a local refs dir.

Layout (mirrors docs/archive-strategy.md hot-bucket `refs/`):

    <out>/
        <genome_id>.fa                 host truth genome (assembly-level)
        contam/<source>.fa             contaminant reference (nucleotide accession or assembly)

Sources:
  - 'assembly' refs (hosts + P. aeruginosa PAO1): NCBI Datasets API v2alpha
  - 'nuccore'  refs (phiX, E. coli, pUC19, lambda): E-utilities efetch (fasta)

Deterministic: writes each file plus a `<name>.meta.yaml` recording accession,
source, sha256, and the exact fetch command so the ref block can be reproduced.
"""

import argparse
import gzip
import hashlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

import yaml

REFS = [
    # (local id, kind, accession)
    ("canaur", "assembly", "GCF_003013715.1"),
    ("cryneo", "assembly", "GCF_000149245.1"),
    ("zymtri", "assembly", "GCF_000219625.1"),
    ("yarlip", "assembly", "GCF_001761485.1"),
    ("symbiont", "assembly", "GCA_000006765.1"),   # P. aeruginosa PAO1 (culture contaminant)
    ("phix",   "nuccore",  "NC_001422.1"),
    ("ecoli",  "nuccore",  "NC_000913.3"),
    ("vector", "nuccore",  "L09137.2"),            # pUC19
    ("phage",  "nuccore",  "NC_001416.1"),         # lambda
]

DATASETS_API = "https://api.ncbi.nlm.nih.gov/datasets/v2alpha/genome/accession/{acc}/download?include_annotation_type=GENOME_FASTA"
EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id={acc}&rettype=fasta&retmode=text"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for blk in iter(lambda: fh.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def fetch_nuccore(acc, dest):
    req = urllib.request.Request(EUTILS.format(acc=acc), headers={"User-Agent": "benchmark/1.0"})
    with urllib.request.urlopen(req, timeout=600) as r, open(dest, "wb") as out:
        shutil.copyfileobj(r, out)


def fetch_assembly(acc, dest):
    with tempfile.TemporaryDirectory() as tmp:
        zpath = Path(tmp) / "dl.zip"
        req = urllib.request.Request(DATASETS_API.format(acc=acc), headers={"User-Agent": "benchmark/1.0"})
        with urllib.request.urlopen(req, timeout=1800) as r, open(zpath, "wb") as out:
            shutil.copyfileobj(r, out)
        with zipfile.ZipFile(zpath) as z:
            fna = next(n for n in z.namelist() if n.endswith("_genomic.fna") or n.endswith("_genomic.fna.gz"))
            data = z.read(fna)
        if fna.endswith(".gz"):
            data = gzip.decompress(data)
        with open(dest, "wb") as out:
            out.write(data)


def main():
    ap = argparse.ArgumentParser(description="Stage benchmark reference FASTA files")
    ap.add_argument("--out", type=Path, default=Path("assets/refs"), help="output refs dir")
    ap.add_argument("--force", action="store_true", help="re-fetch even if staged meta exists")
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "contam").mkdir(parents=True, exist_ok=True)

    for local_id, kind, acc in REFS:
        dest_dir = args.out if kind == "assembly" else args.out / "contam"
        dest = dest_dir / f"{local_id}.fa"
        meta = dest.with_suffix(".fa.meta.yaml")
        if dest.exists() and meta.exists() and not args.force:
            print(f"SKIP {local_id}: already staged ({dest})")
            continue

        tmp = dest.with_suffix(".fa.tmp")
        print(f"fetch {local_id}: {kind} {acc}")
        if kind == "nuccore":
            fetch_nuccore(acc, tmp)
        else:
            fetch_assembly(acc, tmp)
        os_replace(tmp, dest)

        sha = sha256(dest)
        record = {
            "ref_id": local_id,
            "kind": kind,
            "accession": acc,
            "sha256": sha,
            "fetch": DATASETS_API.format(acc=acc) if kind == "assembly" else EUTILS.format(acc=acc),
        }
        with open(meta, "w") as fh:
            yaml.safe_dump(record, fh, sort_keys=False)
        print(f"  staged {dest} (sha256={sha})")

    print("done.")


def os_replace(src, dest):
    import os
    os.replace(src, dest)


if __name__ == "__main__":
    main()
