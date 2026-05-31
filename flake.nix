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

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "vm-harness";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.nim ];
          buildPhase = ''
            nim c --hints:off --opt:speed -o:vm-harness src/vm_harness/cli.nim
          '';
          installPhase = ''
            mkdir -p $out/bin $out/share/vm-harness/guest-scripts
            install -m755 vm-harness $out/bin/vm-harness
            cp -R guest-scripts/* $out/share/vm-harness/guest-scripts/
          '';
        };
      });
}
