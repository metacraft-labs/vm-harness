## vm-harness docs -- the shared Metacraft docs token layer.
##
## Binds every `--docs-*` CSS custom property the isonim-docs framework
## components consume to its light + dark value, loaded from the SHARED
## `codetracer-design-system` docs token set -- the exact same design system
## the CodeTracer / isonim-docs sites use, so vm-harness docs look identical.
## The emitted CSS (via `emitTokensCss`) is prepended onto `assets/style.css`
## by `src/build.nim` through `buildSite(docsTokensCss = ...)`.
##
## SELF-CONTAINED MECHANISM: the design-system root comes from the
## `vmhDocsDesignSystem` compile-time define that `config.nims` sets from the
## flake devShell's `VMH_DOCS_DESIGN_SYSTEM` env var (the input's Nix store
## path). We must know it at COMPILE time because the token JSON is `staticRead`
## (embedded in the binary). The default is a sibling-checkout path, so a
## legacy workspace build still works when the define is absent.

import std/os
import core/[tokens, docs_tokens]

export docs_tokens.emitTokensCss

const designSystemRoot {.strdefine: "vmhDocsDesignSystem".} =
  currentSourcePath().parentDir().parentDir() / "../../../codetracer-design-system"
  ## Fallback = sibling checkout; the flake devShell overrides this via
  ## `-d:vmhDocsDesignSystem:${codetracer-design-system}` so it resolves from
  ## the Nix store with no sibling present.

proc designSystemTokens*(): TokenSet =
  ## Loads the canonical Metacraft brand/alias/mapped DTCG token set so the
  ## layer's `bkToken` bindings resolve to concrete primitives.
  loadTokens(
    designSystemRoot / "brand" / "brand.json",
    designSystemRoot / "alias" / "alias.json",
    designSystemRoot / "mapped" / "mapped.json")

const docsDesignSystemJson = staticRead(
  designSystemRoot / "docs" / "codetracer-docs.tokens.json")
  ## The shared docs design system, embedded at compile time -- the single
  ## source of truth for the --docs-* tokens.

proc metacraftDocsTokenLayer*(): DocsTokenLayer =
  ## The docs token layer, loaded from the shared design system.
  loadDocsTokenLayer(docsDesignSystemJson)

const docsDesignSystemPath* = designSystemRoot / "docs" / "codetracer-docs.tokens.json"
  ## Runtime path to the shared token file -- the dev server WATCHES it so
  ## design-system edits hot-reload with no rebuild (when it points at a live
  ## checkout via the sibling-isonim override).

proc docsTokensCssLive*(): string =
  ## Re-reads the shared design system FROM DISK and emits its token CSS -- the
  ## dev server calls this per request + on file change.
  emitTokensCss(loadDocsTokenLayer(readFile(docsDesignSystemPath)),
                designSystemTokens())
