{
  description = "vm-harness — cross-platform VM lifecycle orchestration library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        # The dev shell intentionally only pins Nim + the platform's
        # backend tooling; per-backend tools (tart, utmctl, virsh, lima)
        # are added per-platform so the shell doesn't fail on Windows
        # paths via WSL etc.
        backendTools =
          (if pkgs.stdenv.isDarwin then [
            # Tart and UTM live outside nixpkgs on macOS; the README
            # documents the `brew install` path. We still expose `qemu`
            # because Lima and UTM both lean on it.
            pkgs.qemu
          ] else if pkgs.stdenv.isLinux then [
            pkgs.libvirt
            pkgs.qemu
            pkgs.lima
          ] else [ ]);
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.nim
            pkgs.nimble
            pkgs.git
            pkgs.openssh
            pkgs.sshpass
          ] ++ backendTools;

          shellHook = ''
            export VM_HARNESS_ROOT="$PWD"
            echo "vm-harness dev shell"
            echo "  nim:    $(nim --version | head -n1)"
            echo "  nimble: $(nimble --version | head -n1)"
          '';
        };

        # The minimal fast-booting Linux golden used by the libvirt
        # per-job ephemeral-reset gate (M2). Linux-only (needs a Linux
        # kernel + module tree + qemu-img); guarded so darwin eval
        # doesn't try to build it.
        packages.golden-linux-tiny =
          if pkgs.stdenv.isLinux
          then import ./nix/golden-linux-tiny.nix { inherit pkgs; }
          else null;

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "vm-harness";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.nim ];
          buildPhase = ''
            # Nix sandboxes HOME to /homeless-shelter — Nim's default
            # nimcache at ~/.cache/nim/ is not writable. Direct nimcache
            # to the build dir (always writable) so the build doesn't
            # fail with `cannot create directory: /homeless-shelter/...`.
            nim c --hints:off --opt:speed \
              --nimcache:$TMPDIR/nimcache \
              -o:vm-harness src/vm_harness/cli.nim
          '';
          installPhase = ''
            mkdir -p $out/bin \
              $out/share/vm-harness/guest-scripts \
              $out/share/vm-harness/guest-recipes
            install -m755 vm-harness $out/bin/vm-harness
            cp -R guest-scripts/* $out/share/vm-harness/guest-scripts/
            # Recipes (autounattend.xml + helper scripts) are
            # required at runtime by the libvirt backend's
            # build-autounattend-iso step. Ship them next to the
            # binary so `--recipe windows-x64-base` resolves
            # without the operator setting VMH_RECIPES_DIR.
            cp -R guest-recipes/* $out/share/vm-harness/guest-recipes/
          '';
        };
      });
}
