#!/usr/bin/env bash
# RP5c1 / RP5c2 build recipe: compile a vm-harness resource/provider module or
# the RP5c1 test against reprobuild's full harness env + lib --path set, WITHOUT
# hand-maintaining a ~27-entry path list.
#
# The reprobuild --path/toolchain/vendored-hash flag set is derived from
# reprobuild's OWN ``providerCompileCommand`` (via a tiny in-tree helper),
# exactly the flags the RP1 provider-compile edge uses. This is the recipe
# RP5c2's infra recipe reuses to compile against the vm-harness resource
# interface.
#
# Usage (run from anywhere; paths are absolute):
#   build-rp5c1.sh provider   -> build the vm-harness provider binary
#   build-rp5c1.sh test       -> build + run the RP5c1 test binary
#
# Requires: run inside reprobuild's ``nix develop`` (this script enters it) so
# ``nim``, the ``*_SRC`` env (scripts/source_paths.sh), and the clang toolchain
# are present. ``VMH_INCUS_CMD`` (e.g. "sudo -n incus") selects the incus client
# for the on-incus lane.
set -euo pipefail

REPRO_ROOT="${REPRO_ROOT:-/home/zahary/m/dev/reprobuild}"
VMH_ROOT="${VMH_ROOT:-/home/zahary/m/dev/vm-harness}"
OUT="${RP5C1_OUT:-/home/zahary/rp5c1-out}"
mkdir -p "${OUT}"

PROVIDER_MODULE="${VMH_ROOT}/src/vm_harness/repro/provider_main.nim"
TEST_MODULE="${VMH_ROOT}/tests/e2e/t_rp5c1_vm_harness_provider_via_protocol.nim"

mode="${1:-test}"

# --- build the flag-printer once (inside reprobuild's tree so config.nims
#     supplies its own --path set). ---
build_flagprinter() {
  # Copy the helper source into the reprobuild tree so config.nims supplies the
  # compiler's own --path set, then build it there. Keeps the reprobuild
  # checkout otherwise untouched (the .nim source of record lives in vm-harness).
  #
  # The copy lands at the reprobuild REPO ROOT (not gitignored), so register an
  # EXIT trap to remove it — otherwise a test run leaves reprobuild's git status
  # dirty (`?? rp5c1_flagprint.nim`). The trap fires on any exit path (success,
  # error, signal) so BOTH trees are left clean.
  cp "${VMH_ROOT}/tests/e2e/rp5c1_flagprint.nim" "${REPRO_ROOT}/rp5c1_flagprint.nim"
  trap 'rm -f "${REPRO_ROOT}/rp5c1_flagprint.nim"' EXIT
  ( cd "${REPRO_ROOT}" && nix develop --command bash -c '
      source scripts/source_paths.sh
      nim c --hints:off --warnings:off \
        --nimcache:build/nimcache/rp5c1_flagprint \
        --out:build/bin/rp5c1_flagprint rp5c1_flagprint.nim' )
}

build_provider() {
  build_flagprinter
  ( cd "${REPRO_ROOT}" && nix develop --command bash -c "
      source scripts/source_paths.sh
      mapfile -t CMD < <(./build/bin/rp5c1_flagprint '${PROVIDER_MODULE}' '${OUT}/vmh-provider')
      printf '%s\n' \"\${CMD[@]}\" > '${OUT}/provider_compile_cmd.txt'
      \"\${CMD[@]}\"" )
  echo "provider binary: ${OUT}/vmh-provider"
}

build_and_run_test() {
  build_flagprinter
  # Derive the reprobuild flag set from the provider-compile command, then
  # strip the provider-only bits and re-target at the TEST module.
  ( cd "${REPRO_ROOT}" && nix develop --command bash -c "
      source scripts/source_paths.sh
      mapfile -t RAW < <(./build/bin/rp5c1_flagprint '${TEST_MODULE}' '${OUT}/ignored')
      CMD=()
      for a in \"\${RAW[@]}\"; do
        case \"\$a\" in
          --define:reproProviderMode) continue ;;
          --nimcache:*) continue ;;
          --out:*) continue ;;
          '${TEST_MODULE}') continue ;;
          --path:*/vm_harness/repro) continue ;;
          --path:*/tests/e2e) continue ;;
        esac
        CMD+=(\"\$a\")
      done
      # CMD[0] is the nim compiler + 'c'. Append test-specific flags + module.
      CMD+=(--threads:on)
      CMD+=(--nimcache:'${OUT}/nimcache-test')
      CMD+=(--out:'${OUT}/t_rp5c1')
      CMD+=('${TEST_MODULE}')
      printf '%s\n' \"\${CMD[@]}\" > '${OUT}/test_compile_cmd.txt'
      \"\${CMD[@]}\"" )
  echo "test binary: ${OUT}/t_rp5c1"
  echo "=== running RP5c1 test (VMH_INCUS_CMD=${VMH_INCUS_CMD:-incus}) ==="
  VMH_INCUS_CMD="${VMH_INCUS_CMD:-incus}" "${OUT}/t_rp5c1"
}

case "${mode}" in
  provider) build_provider ;;
  test)     build_and_run_test ;;
  *) echo "usage: build-rp5c1.sh [provider|test]" >&2; exit 2 ;;
esac
