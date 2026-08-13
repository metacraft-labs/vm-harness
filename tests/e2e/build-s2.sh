#!/usr/bin/env bash
# S2 (network-primitive) gate — build + run the network/attachment e2e test
# against reprobuild's full harness env + lib --path set.
#
# Reuses the RP5c1/RP5c2 recipe: the reprobuild --path/toolchain/vendored-hash
# flag set is DERIVED from reprobuild's own providerCompileCommand (via the
# rp5c1_flagprint helper), exactly the flags the RP1 provider-compile edge uses.
# We then strip the provider-only bits and re-target at the S2 test module,
# adding vm-harness's own `src` + `tests/e2e` on --path (the test imports the
# REAL resources.nim driver + the incus backend, so this lane is NOT no-closure
# — the on-incus assertions need the incus helpers).
#
# Requires: run inside reprobuild's `nix develop` (this script enters it) so
# `nim`, the `*_SRC` env, and the toolchain are present. `VMH_INCUS_CMD`
# (e.g. "sudo -n incus") selects the incus client for the on-incus lane.
set -euo pipefail

REPRO_ROOT="${REPRO_ROOT:-/home/zahary/m/dev/reprobuild}"
VMH_ROOT="${VMH_ROOT:-/home/zahary/m/dev/vm-harness}"
OUT="${S2_OUT:-/home/zahary/s2-out}"
mkdir -p "${OUT}"

# The recipe used only to DERIVE the reprobuild flag set (any provider-mode
# module works; reuse RP5c2's recipe which is already wired for the flagprinter).
FLAG_SRC="${VMH_ROOT}/src/vm_harness/repro/provider_main.nim"
TEST_MODULE="${VMH_ROOT}/tests/e2e/t_s2_network_and_attachment.nim"

build_flagprinter() {
  cp "${VMH_ROOT}/tests/e2e/rp5c1_flagprint.nim" "${REPRO_ROOT}/rp5c1_flagprint.nim"
  trap 'rm -f "${REPRO_ROOT}/rp5c1_flagprint.nim"' EXIT
  ( cd "${REPRO_ROOT}" && nix develop --command bash -c '
      source scripts/source_paths.sh
      nim c --hints:off --warnings:off \
        --nimcache:build/nimcache/rp5c1_flagprint \
        --out:build/bin/rp5c1_flagprint rp5c1_flagprint.nim' )
}

build_and_run_test() {
  build_flagprinter
  ( cd "${REPRO_ROOT}" && nix develop --command bash -c "
      source scripts/source_paths.sh
      mapfile -t RAW < <(./build/bin/rp5c1_flagprint '${FLAG_SRC}' '${OUT}/ignored')
      CMD=()
      for a in \"\${RAW[@]}\"; do
        case \"\$a\" in
          --define:reproProviderMode) continue ;;
          --nimcache:*) continue ;;
          --out:*) continue ;;
          '${FLAG_SRC}') continue ;;
        esac
        CMD+=(\"\$a\")
      done
      # The test imports the REAL vm-harness resources + incus backend, so put
      # vm-harness src + tests/e2e on --path.
      CMD+=(--path:'${VMH_ROOT}/src')
      CMD+=(--threads:on)
      CMD+=(--nimcache:'${OUT}/nimcache-test')
      CMD+=(--out:'${OUT}/t_s2')
      CMD+=('${TEST_MODULE}')
      printf '%s\n' \"\${CMD[@]}\" > '${OUT}/test_compile_cmd.txt'
      \"\${CMD[@]}\"" )
  echo "test binary: ${OUT}/t_s2"
  echo "=== running S2 test (VMH_INCUS_CMD=${VMH_INCUS_CMD:-incus}) ==="
  VMH_INCUS_CMD="${VMH_INCUS_CMD:-incus}" "${OUT}/t_s2"
}

build_and_run_test
