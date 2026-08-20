{
  description = "vm-harness docs — self-contained dev shell for the isonim-docs-powered docs site";

  # SELF-CONTAINED: vm-harness is a standalone repo, so this docs site declares
  # the whole isonim-docs framework toolchain + source as flake INPUTS rather
  # than relying on sibling checkouts (the way codetracer/docs/book-isonim does).
  # Everything the SSG needs to compile — the framework source, isonim, the
  # shared Nim libraries, and the shared design system — is fetched by Nix and
  # exposed to `nim` on the `--path` (see the shellHook below + ../site/config.nims).
  inputs = {
    # isonim owns the Nim toolchain (nim 2.2.4, node, just, …) via its dev
    # shell, and its nixpkgs/flake-utils pins are reused so versions match the
    # rest of the framework byte-for-byte.
    isonim.url = "github:metacraft-labs/isonim/dev";

    # The static-site framework this site consumes. Its isonim follows ours so
    # there is exactly one isonim in the closure.
    isonim-docs.url = "github:metacraft-labs/isonim-docs/main";
    isonim-docs.inputs.isonim.follows = "isonim";

    # Shared Nim libraries the framework/isonim source depends on. Consumed as
    # plain SOURCE (flake = false) — we only need their `src/` on the Nim path,
    # not their build outputs, and this keeps the closure minimal.
    nim-everywhere = {
      url = "github:metacraft-labs/nim-everywhere/dev";
      flake = false;
    };
    nim-faststreams = {
      url = "github:metacraft-labs/nim-faststreams";
      flake = false;
    };
    nim-stew = {
      url = "github:status-im/nim-stew";
      flake = false;
    };

    # The shared Metacraft docs design system (DTCG token JSON). Provides the
    # `--docs-*` token values so vm-harness docs look identical to the
    # CodeTracer / isonim-docs sites. Consumed as source (staticRead at compile
    # time — see src/theme_tokens.nim).
    codetracer-design-system = {
      url = "github:metacraft-labs/codetracer-design-system";
      flake = false;
    };
  };

  outputs =
    { self, isonim, isonim-docs, nim-everywhere, nim-faststreams, nim-stew
    , codetracer-design-system }:
    let
      # Reuse isonim's own nixpkgs + flake-utils pins so the toolchain versions
      # (nim 2.2.4, node, …) are byte-for-byte identical to isonim's dev shell.
      inherit (isonim.inputs) flake-utils nixpkgs;
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true; # mirror isonim's flake (claude-agent-acp compat)
        };
      in
      {
        devShells.default = pkgs.mkShell {
          # Inherit the entire isonim toolchain (nim/nimble/node/just/…). This
          # site adds no tools of its own — the SSG builds with plain
          # `nim c` / `nim js` + node, all of which isonim's shell provides.
          inputsFrom = [ isonim.devShells.${system}.default ];

          # CRUCIAL — make the framework SOURCE available with NO sibling repos.
          # We export the store path of each input as a VMH_DOCS_* env var;
          # config.nims reads them and adds the corresponding `--path:` (and
          # passes the design-system root on as the `vmhDocsDesignSystem`
          # compile-time define). When these are unset (legacy sibling-checkout
          # layout) config.nims falls back to sibling paths, so both modes work.
          shellHook = ''
            export VMH_DOCS_ISONIM_SRC="${isonim}/src"
            export VMH_DOCS_ISONIM_DOCS_SRC="${isonim-docs}/src"
            export VMH_DOCS_NIM_EVERYWHERE_SRC="${nim-everywhere}/src"
            export VMH_DOCS_NIM_FASTSTREAMS="${nim-faststreams}"
            export VMH_DOCS_NIM_STEW="${nim-stew}"
            export VMH_DOCS_ISONIM_VENDOR="${isonim}/vendor"
            export VMH_DOCS_DESIGN_SYSTEM="${codetracer-design-system}"
            echo "vm-harness docs dev shell — framework source from Nix store (isonim-docs + isonim), nim $(nim --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
          '';
        };
      }
    );
}
