# CHANGES

## 2026-08-18 — Phase-1 environment pins resolved (AAFTF rebuild)

- Added fastqc, flye, racon, hifiasm, kraken2, gfatools to the AAFTF pixi/conda env; rebuilt the container and re-pinned by digest to `ghcr.io/stajichlab/aaftf@sha256:f7fd8ed3…`.
- Committed the relocked AAFTF `pixi.lock` as the `aaftf` env_pin (`adapters/aaftf/pixi.lock`).
- Pointed `nf_aaftf` and the spades/flye/hifiasm/qc_screen phase-1 pipelines at the unified AAFTF digest.
- Moved medaka (2.2.2) and nextpolish (1.4.1) to separate `quay.io/biocontainers` digest pins (kept out of the main image).
- Pinned FCS-GX (`gx` v0.5.5, in-AAFTF) and FCS-adaptor (v0.5.5 local SIF) eval tools by digest; gxdb `v0.3.0-151-g9aad15db`.
- Recorded benchmark DB versions: fungi_odb10 `2020-09-10`, Kraken2 `k2_standard_20260226`.
- `scripts/validate.py` → `VALIDATION PASSED (all pins set)`; `make validate` clean.
