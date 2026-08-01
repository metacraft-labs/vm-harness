{
  description = "vm-harness — cross-platform VM lifecycle orchestration library";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{
      flake-parts,
      git-hooks,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, system, ... }:
        let
          backendTools =
            if pkgs.stdenv.isDarwin then
              [
                # Tart and UTM live outside nixpkgs on macOS; the README
                # documents the Homebrew install path.
                pkgs.lima
                pkgs.qemu
              ]
            else if pkgs.stdenv.isLinux then
              [
                pkgs.libvirt
                pkgs.qemu
                pkgs.lima
              ]
            else
              [ ];

          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./.;
            hooks.just-lint = {
              enable = true;
              name = "just lint";
              entry = "${pkgs.writeShellScript "vm-harness-just-lint" ''
                export PATH=${
                  pkgs.lib.makeBinPath [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.just
                    pkgs.nim
                    pkgs.nixfmt
                  ]
                }:$PATH
                exec ${pkgs.just}/bin/just lint
              ''}";
              language = "system";
              pass_filenames = false;
            };
          };

          vm-harness = pkgs.stdenv.mkDerivation {
            pname = "vm-harness";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.nim ];
            buildPhase = ''
              runHook preBuild
              # Nix sandboxes HOME to /homeless-shelter. Keep Nim's cache in
              # the writable build directory.
              nim c --hints:off --opt:speed \
                --nimcache:$TMPDIR/nimcache \
                -o:vm-harness src/vm_harness/cli.nim
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin \
                $out/share/vm-harness/guest-scripts \
                $out/share/vm-harness/guest-recipes
              install -m755 vm-harness $out/bin/vm-harness
              cp -R guest-scripts/* $out/share/vm-harness/guest-scripts/
              cp -R guest-recipes/* $out/share/vm-harness/guest-recipes/
              runHook postInstall
            '';
            meta = {
              description = "Cross-platform VM lifecycle orchestration";
              homepage = "https://github.com/metacraft-labs/vm-harness";
              license = pkgs.lib.licenses.mit;
              mainProgram = "vm-harness";
              platforms = [
                "x86_64-linux"
                "aarch64-linux"
                "x86_64-darwin"
                "aarch64-darwin"
              ];
            };
          };
        in
        {
          packages = {
            default = vm-harness;
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
            # The fast-booting libvirt test golden needs a Linux kernel,
            # module tree, and qemu-img, so it is not exported on Darwin.
            golden-linux-tiny = import ./nix/golden-linux-tiny.nix { inherit pkgs; };
          };

          checks = {
            inherit pre-commit-check;
            package-build = vm-harness;
          };

          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.git
              pkgs.just
              pkgs.nim
              pkgs.nimble
              pkgs.nixfmt
              pkgs.openssh
              pkgs.pre-commit
              pkgs.sshpass
              # guest-recipes/*/fetch-iso.sh use xorriso to validate that a
              # Windows ISO carries a UEFI El Torito boot record.
              pkgs.xorriso
            ]
            ++ backendTools;

            shellHook = ''
              ${pre-commit-check.shellHook}
              export VM_HARNESS_ROOT="$PWD"
              echo "vm-harness dev shell"
              echo "  nim:    $(nim --version | head -n1)"
              echo "  nimble: $(nimble --version | head -n1)"
            '';
          };
        };
    };
}
