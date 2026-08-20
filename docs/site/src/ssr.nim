## vm-harness docs -- thin SSR entry (one-shot preview via `just serve-docs`).
##
## Calls the framework's own `renderRoute` with this site's `content/` dir and
## its own `DocsConfig`, passing NO explicit manifest -- letting the framework's
## default (`buildManifestFromContent`) auto-discover the route table.
##
## The framework's own top-level module is ALSO named `ssr`, so a bare
## `import ssr` here would clash with THIS file. config.nims exposes the
## framework src under a non-colliding local module dir (`src/framework_src`, a
## gitignored symlink into the Nix store), which we import from here.

when defined(js):
  {.error: "ssr.nim is a C-target (server-side) entry point".}

import "framework_src/ssr" as frameworkSsr
import ./docs_config

proc renderRoute*(path: string; contentDir = "content"): tuple[status: int, html: string] =
  frameworkSsr.renderRoute(path, contentDir, cfg = vmhDocsConfig())

when isMainModule:
  let (status, html) = renderRoute("/")
  echo "SSR smoke: GET / -> ", status, " (", html.len, " bytes)"
