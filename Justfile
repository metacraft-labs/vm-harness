set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    just lint

build:
    mkdir -p build/bin test-logs
    nim c --hints:off -o:build/bin/vm-harness src/vm_harness/cli.nim 2>&1 | tee test-logs/build.log
    nim c --hints:off --path:src -o:build/bin/vm-harness-bench-snapshot-revert tools/bench/snapshot_revert_bench.nim 2>&1 | tee -a test-logs/build.log

test:
    mkdir -p test-logs
    bash scripts/run-tests.sh 2>&1 | tee test-logs/test.log

t: test

test-host:
    mkdir -p test-logs
    bash scripts/run-host-tests.sh 2>&1 | tee test-logs/test-host.log

lint:
    mkdir -p test-logs
    nim check --hints:off --path:src src/vm_harness/cli.nim 2>&1 | tee test-logs/lint.log
    nixfmt --check flake.nix nix/*.nix 2>&1 | tee -a test-logs/lint.log

format:
    find src tests tools -type f -name '*.nim' -exec nimpretty {} +
    nixfmt flake.nix nix/*.nix

fmt: format

nix-build:
    mkdir -p test-logs
    nix build .#default 2>&1 | tee test-logs/nix-build.log
