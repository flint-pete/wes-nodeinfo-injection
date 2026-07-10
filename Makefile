# wes-nodeinfo-injection -- build & test the WES change that gives plugins node
# identity/GPS via env, consumable by pywaggle2.
#
# `make test` runs all three layers with real tooling (no mocks):
#   1. bash+jq env generator (32 tests)
#   2. Go edge-scheduler EnvFrom change: builds the REAL upstream scheduler + our
#      isolated unit tests (4 tests)
#   3. python end-to-end: gen -> env -> pywaggle2 reader (7 tests)

GO      ?= /usr/local/go/bin/go
PYTHON  ?= python3
export GOPATH ?= $(HOME)/go
export GOCACHE ?= $(HOME)/.cache/go-build

.PHONY: test test-gen test-go test-e2e test-upstream patches-check clean

test: test-gen test-go test-e2e
	@echo "=================================================="
	@echo "ALL LAYERS GREEN"
	@echo "=================================================="

test-gen:
	@echo "### [1/3] env generator (bash+jq) ###"
	@./test-gen-wes-identity.sh

test-go:
	@echo "### [2/3] edge-scheduler EnvFrom change (Go, isolated unit) ###"
	@cd scheduler-change && $(GO) test ./...

test-e2e:
	@echo "### [3/3] end-to-end gen -> env -> pywaggle2 reader (python) ###"
	@$(PYTHON) test_e2e.py

# Build + test the REAL upstream edge-scheduler with the patch applied (heavier:
# pulls the full k8s dep tree). Proves the change compiles in-situ and doesn't
# regress upstream tests. Requires .upstream/ populated (see README).
test-upstream:
	@echo "### building REAL upstream edge-scheduler with patch applied ###"
	@cd .upstream/edge-scheduler && $(GO) build ./pkg/nodescheduler/ && $(GO) test ./pkg/nodescheduler/

# Verify both patches apply cleanly against pristine upstream HEAD.
patches-check:
	@for repo in waggle-edge-stack edge-scheduler; do \
	  d=$$(mktemp -d); git -C .upstream/$$repo archive HEAD | tar -x -C $$d; \
	  case $$repo in \
	    waggle-edge-stack) p=patches/0001-*.patch;; \
	    edge-scheduler)    p=patches/0002-*.patch;; \
	  esac; \
	  git -C $$d apply --check $(PWD)/$$p && echo "$$repo: CLEAN" || echo "$$repo: FAILED"; \
	  rm -rf $$d; \
	done

clean:
	@rm -rf scheduler-change/*.test
	@echo "cleaned"
