{
  description = "vm-harness — cross-platform VM lifecycle orchestration library";

  inputs = {
    # nixos-modules is this repo's only upstream flake: nixpkgs, flake-parts and
    # git-hooks all come through it, and so does the org's single reprobuild
    # pin. Keep the lock fresh rather than adding a reprobuild input here.
    nixos-modules.url = "github:metacraft-labs/nixos-modules/dev";
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
          # The vTPM gate's Linux guest (kernel + busybox initramfs). Only
          # meaningful on Linux, where the gate runs.
          guest-linux-tpm =
            if pkgs.stdenv.isLinux then import ./nix/guest-linux-tpm.nix { inherit pkgs; } else null;

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
                # The QemuBootBackend boots UEFI guests through
                # `-drive if=pflash` and needs an edk2 firmware pair;
                # `OVMF.fd` carries no binaries, it is here so the pair
                # is realised in the store and the shellHook can name it
                # exactly (see VMH_OVMF_CODE / VMH_OVMF_VARS below).
                pkgs.OVMF.fd
                # swtpm backs QEMU's `-tpmdev emulator`. The
                # qemu_windows_arm backend already drives a full swtpm
                # lifecycle and its `probeAvailability` fails without
                # this on PATH; the libvirt backend's vTPM support needs
                # the same binary.
                pkgs.swtpm
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
            # The vTPM gate's guest: a stock kernel plus a busybox
            # initramfs that reports what it sees of /dev/tpm0. Same
            # reason it is Linux-only.
            inherit guest-linux-tpm;
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
              ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                # Pin the firmware pair src/vm_harness/firmware.nim resolves
                # to. Its last-resort fallback is a /nix/store glob whose
                # winner is the lexically greatest store hash, which is not a
                # stable choice; naming the flake's own OVMF makes a UEFI boot
                # gate assert against the firmware this shell pins. Respects an
                # operator override.
                export VMH_OVMF_CODE="''${VMH_OVMF_CODE:-${pkgs.OVMF.fd}/FV/OVMF_CODE.fd}"
                export VMH_OVMF_VARS="''${VMH_OVMF_VARS:-${pkgs.OVMF.fd}/FV/OVMF_VARS.fd}"
                # The vTPM gate's guest, pinned the same way. Naming the
                # store path here is what lets
                # tests/integration/t_guest_sees_tpm_device.nim run with
                # no network and no build step of its own: entering the
                # shell realises it once. Respects an operator override.
                export VMH_TPM_GUEST_DIR="''${VMH_TPM_GUEST_DIR:-${guest-linux-tpm}}"
              ''}
              echo "vm-harness dev shell"
              echo "  nim:    $(nim --version | head -n1)"
              echo "  nimble: $(nimble --version | head -n1)"
            '';
          };
        };
    };
}
