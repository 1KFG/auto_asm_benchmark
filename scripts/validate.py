#!/usr/bin/env python3
"""Validate every YAML instance file against its JSON Schema (ADR-009).

Targets come from configs/repo.yaml: validation.checks maps a glob to a schema.
Exit 0 if all pass; nonzero otherwise. Also flags any PENDING version pins as
warnings (not failures) per ADR-004.

Usage:
    python3 scripts/validate.py            # validate all instances
    python3 scripts/validate.py --fail-on-pending
"""

import argparse
import glob
import sys
from pathlib import Path

import yaml
from jsonschema import Draft7Validator, FormatChecker
from jsonschema.exceptions import best_match

REPO = Path(__file__).resolve().parent.parent
REPO_YAML = REPO / "configs" / "repo.yaml"
PENDING_MARKERS = ("PENDING", "pending")


def load_repo_config():
    with open(REPO_YAML) as fh:
        return yaml.safe_load(fh)


def collect_checks(cfg):
    # checks: "kind -> schema/path (glob)"
    for line in cfg["validation"]["checks"]:
        kind, _, rest = line.partition(" -> ")
        schema_path, _, glob_str = rest.partition(" (")
        glob_str = glob_str.rstrip(")")
        yield kind.strip(), schema_path.strip(), glob_str.strip()


def validate_file(schema_file, instance_file):
    with open(schema_file) as fh:
        schema = yaml.safe_load(fh)
    with open(instance_file) as fh:
        instance = yaml.safe_load(fh)
    v = Draft7Validator(schema, format_checker=FormatChecker())
    err = best_match(list(v.iter_errors(instance)))
    return err


def find_pending(instance_file):
    """Return a list of paths to PENDING values (any depth).

    The ``archive`` subtree is exempt: it describes the eventual cold-storage
    DOI/location, which legitimately stays ``pending`` until the set is archived
    (ADR-004). Data checksums under ``datasets`` are NOT exempt.
    """
    def walk(node, path):
        hits = []
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "archive":
                    continue
                hits += walk(v, f"{path}.{k}")
        elif isinstance(node, list):
            for i, v in enumerate(node):
                hits += walk(v, f"{path}[{i}]")
        elif isinstance(node, str):
            if any(m in node for m in PENDING_MARKERS):
                if node in PENDING_MARKERS or all(tok in ("PENDING", "pending") for tok in [node]):
                    hits.append(f"{path} = {node!r}")
        return hits
    with open(instance_file) as fh:
        data = yaml.safe_load(fh)
    return walk(data, Path(instance_file).name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fail-on-pending", action="store_true", help="treat PENDING pins as errors")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    cfg = load_repo_config()
    failures = []
    checked = 0
    pending = []

    for kind, schema_path, glob_str in collect_checks(cfg):
        schema_file = REPO / schema_path
        for instance_file in glob.glob(str(REPO / glob_str), recursive=False):
            if not Path(instance_file).is_file():
                continue
            checked += 1
            err = validate_file(schema_file, instance_file)
            if err is not None:
                failures.append((instance_file, err.message))
                if args.verbose:
                    print(f"FAIL  {instance_file}\n   {err.message}")
            else:
                pending += [p for p in find_pending(instance_file) if p not in pending]
                if args.verbose:
                    print(f"ok    {instance_file}  (vs {schema_path})")

    print(f"validated {checked} instance file(s) against schemas")
    for f, msg in failures:
        print(f"  FAIL {f}: {msg}")
    for p in pending:
        print(f"  WARN unset pin: {p}")

    if failures:
        print("VALIDATION FAILED")
        sys.exit(1)
    if pending and args.fail_on_pending:
        print("VALIDATION FAILED (unset pins)")
        sys.exit(1)
    if pending:
        print(f"VALIDATION PASSED with {len(pending)} unset pin(s) (resolve before real runs)")
    else:
        print("VALIDATION PASSED (all pins set)")


if __name__ == "__main__":
    main()
