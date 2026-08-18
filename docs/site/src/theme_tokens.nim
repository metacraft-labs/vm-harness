## The Metacraft docs token layer now ships FROM the shared design system --
## this file is a thin re-export so this site's `build.nim`/`dev.nim` keep
## importing `./theme_tokens` unchanged. The design system is a pinned flake
## input (see ./flake.nix); its `nim/` dir is on the Nim path via config.nims,
## and `metacraft_docs_theme` resolves its own token files from the same Nix
## store copy via `currentSourcePath()`. Edit the tokens in the
## codetracer-design-system repo (or via the live design-system editor).
import metacraft_docs_theme
export metacraft_docs_theme
