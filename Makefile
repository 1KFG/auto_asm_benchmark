PYTHON := python3
SCRIPTS := scripts

.PHONY: help validate check-pins lint schema smoke fixtures test clean containers all

help:
	@echo "Targets:"
	@echo "  validate   - validate all YAML instances against their JSON schemas (pins as warnings)"
	@echo "  check-pins - like validate, but FAIL on any PENDING pin (used pre-release)"
	@echo "  lint       - py_compile all python tools + bash -n all shell scripts"
	@echo "  schema     - validate schema files themselves are valid JSON"
	@echo "  fixtures   - generate tiny local fixture datasets for smoke tests"
	@echo "  smoke      - end-to-end harness smoke test: run 1 dataset x all adapters (placeholder pipelines)"
	@echo "  test       - run unittest suite in tests/"
	@echo "  containers - dry-run pull plan for all pinned container images (needs apptainer for real pull)"
	@echo "  clean      - remove nextflow work dirs and test artifacts"

all: validate check-pins lint schema test

validate:
	$(PYTHON) $(SCRIPTS)/validate.py

check-pins:
	$(PYTHON) $(SCRIPTS)/validate.py --fail-on-pending

lint:
	@echo "== py_compile =="
	$(PYTHON) -m py_compile simulation/*.py metrics/*.py scripts/*.py
	@echo "== bash -n =="
	@bash -n adapters/*/run.sh scripts/*.sh && echo "adapters + scripts OK"

containers:
	@bash -n scripts/pull_containers.sh && bash scripts/pull_containers.sh --dry-run

schema:
	@for s in schema/*.json; do $(PYTHON) -c "import json,sys; json.load(open('$$s'))" || exit 1; done
	@echo "all schemas are valid JSON"

test:
	$(PYTHON) -m unittest discover -s tests -v

fixtures:
	$(PYTHON) scripts/make_smoke_fixtures.py datasets/staged

smoke: fixtures
	@test -n "$$(command -v nextflow)" || { echo "nextflow not found"; exit 1; }
	nextflow run workflows/main.nf -profile test \
		--datasets yarlip_sim_001 \
		--dataset_root datasets/staged

clean:
	rm -rf work .nextflow results-test
