# vm-harness docs site -- Nim path/define switching for the isonim-docs SSG.
#
# This consumer builds the vm-harness documentation site on top of the
# isonim-docs static-site framework. The framework, isonim, and the shared Nim
# libraries it needs (nim-everywhere, nim-faststreams, nim-stew, and isonim's
# vendored chronicles/serialization/json_serialization) live OUTSIDE this repo
# -- vm-harness is a standalone repo, so it declares them as flake INPUTS
# (see ./flake.nix) rather than relying on sibling checkouts.
#
# `nim c`'s config lookup walks up from the *project* (entry) file's own
# directory, so THIS file is what's active when compiling anything under this
# package (src/ or tests/), even though most of the code being compiled lives in
# the framework source in the Nix store. Every `--path` the framework's own
# config.nims sets up therefore has to be set up here too.
#
# SELF-CONTAINED MECHANISM: the paths are read from environment variables the
# flake's devShell exports (VMH_DOCS_*), each pointing at the corresponding
# input's Nix store source. When those env vars are unset (e.g. someone runs
# `nim c` outside the dev shell in a legacy sibling-checkout layout) we fall
# back to a sibling path, so both modes work. The design-system root is passed
# on to `theme_tokens.nim` as a compile-time define (`vmhDocsDesignSystem`)
# because it is `staticRead` there and so must be known at compile time.
import std/os

let here = currentSourcePath().parentDir()      ## .../vm-harness/docs/site
let siblingRoot = here / "../../.."              ## sibling-checkout fallback root

proc pathFor(envName, fallback: string): string =
  ## Prefer the flake-provided store path; fall back to a sibling checkout.
  if existsEnv(envName) and getEnv(envName).len > 0: getEnv(envName)
  else: fallback

let isonimSrc      = pathFor("VMH_DOCS_ISONIM_SRC",        siblingRoot / "isonim/src")
let isonimDocsSrc  = pathFor("VMH_DOCS_ISONIM_DOCS_SRC",   siblingRoot / "isonim-docs/src")
let nimEverywhere  = pathFor("VMH_DOCS_NIM_EVERYWHERE_SRC", siblingRoot / "nim-everywhere/src")
let nimFaststreams = pathFor("VMH_DOCS_NIM_FASTSTREAMS",   siblingRoot / "nim-faststreams")
let nimStew        = pathFor("VMH_DOCS_NIM_STEW",          siblingRoot / "nim-stew")
let isonimVendor   = pathFor("VMH_DOCS_ISONIM_VENDOR",     siblingRoot / "isonim/vendor")
let designSystem   = pathFor("VMH_DOCS_DESIGN_SYSTEM",     siblingRoot / "codetracer-design-system")

switch("path", isonimSrc)
switch("path", isonimDocsSrc) ## the framework (isonim-docs), a PATH dependency
switch("path", nimEverywhere)
switch("path", nimFaststreams)
switch("path", nimStew)
switch("path", isonimVendor / "chronicles")
switch("path", isonimVendor / "serialization")
switch("path", isonimVendor / "json_serialization")
switch("define", "chronicles_sinks=textlines[stderr]")
switch("define", "chronicles_runtime_filtering=on")
switch("define", "chronicles_log_level=TRACE")
# Hand the design-system root to theme_tokens.nim's compile-time `staticRead`.
switch("define", "vmhDocsDesignSystem:" & designSystem)

# Self-contained SSR: the framework's own top-level module is named `ssr`, and
# so is THIS package's thin SSR entry (src/ssr.nim) -- a bare `import ssr` there
# would resolve to itself ("module 'ssr' cannot import itself"). Expose the
# framework src under a NON-colliding local module dir (src/_framework, a
# symlink into the store, gitignored + refreshed each build) so src/ssr.nim can
# `import _framework/ssr`. POSIX only; build.nim/CI never touch ssr.nim so this
# is only needed for the `serve-docs` SSR preview.
when defined(nimscript):
  when not defined(windows):
    let fwLink = here / "src" / "framework_src"
    exec("ln -sfn '" & isonimDocsSrc & "' '" & fwLink & "' || true")
