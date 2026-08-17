## vm-harness docs -- thin SSG entry.
##
## Calls the framework's own `buildSite` with this site's `content/` dir and its
## own `DocsConfig`, passing NO explicit manifest -- letting the framework's
## default (`buildManifestFromContent`) auto-discover the route table (and its
## nav order, via each page's `order:` front matter) from the migrated
## vm-harness user guide.
##
## The shared Metacraft docs token layer (`theme_tokens.metacraftDocsTokenLayer`)
## is emitted to CSS and PREPENDED onto `assets/style.css` via
## `buildSite(docsTokensCss = ...)`, and the vendored theme binaries (Geist
## woff2, chrome icons) under `static/` are copied verbatim into `public/assets/`
## AFTER the hash/purge pass so the stylesheet's `url(/assets/...)` refs and the
## content's `/assets/...` image refs resolve to real files.
##
## `DocsConfig.basePath` ("/vm-harness", set in docs_config) makes `buildSite`
## prefix every internal root-relative URL for GitHub project-Pages hosting.

when defined(js):
  {.error: "build.nim is a C-target (SSG) entry; not for the JS target".}

import std/os
import build_site
import core/docs_tokens
import ./docs_config
import ./theme_tokens
import ./redirects

when isMainModule:
  let tokensCss = emitTokensCss(metacraftDocsTokenLayer(), designSystemTokens())
  let n = buildSite(contentDir = "content", cfg = vmhDocsConfig(),
                    docsTokensCss = tokensCss,
                    # Compile this site's own JS mount entry (embeds THIS site's
                    # content) into the hashed `assets/app.js` the pages
                    # reference via `vmhDocsConfig().appScriptHref`.
                    clientEntry = "src/main.nim")
  if dirExists("static"):
    copyDir("static", "public" / "assets")
  # Emit any legacy-URL redirect stubs (none today). Runs AFTER buildSite (which
  # wipes+rebuilds public/) and after the static copy so nothing is clobbered.
  let stubs = emitRedirects("public")
  echo "SSG: rendered ", n, " static pages into ./public/"
  echo "SSG: emitted ", stubs, " legacy-URL redirect stubs into ./public/"
