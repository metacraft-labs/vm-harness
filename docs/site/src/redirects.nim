## vm-harness docs -- legacy-URL redirect generation.
##
## The CodeTracer book carries meta-refresh stubs for its old mdBook `*.html`
## deep links. vm-harness's user guide was never published under a different
## URL scheme (it is being migrated straight from in-repo Markdown to this
## isonim-docs site), so there are NO legacy URLs to preserve today.
##
## This module is the seam where that would live: if the site later needs to
## keep an old URL alive (a renamed page, a folded section), enumerate the
## (oldRelPath -> newRoute) pairs here and emit a meta-refresh stub per pair --
## GitHub Pages honours neither `_redirects` nor `.htaccess`, so a real HTML
## file at the old path is the only reliable redirect mechanism. `emitRedirects`
## is already wired into `src/build.nim` (it currently writes nothing) so adding
## a redirect later is a one-line data change, not a build-graph change.

import std/os

type
  LegacyRedirect* = object
    oldRelPath*: string  ## public-relative stub path, e.g. "old/page.html"
    newRoute*: string    ## new clean route, e.g. "/getting_started/getting-started"

const legacyRedirects*: seq[LegacyRedirect] = @[]
  ## No legacy URLs yet. Add entries here to preserve old deep links.

proc metaRefreshStub*(cleanUrl: string): string =
  ## A minimal self-contained HTML page that redirects to `cleanUrl`.
  "<!doctype html>\n<html lang=\"en\">\n<head>\n" &
  "<meta charset=\"utf-8\">\n" &
  "<meta http-equiv=\"refresh\" content=\"0; url=" & cleanUrl & "\">\n" &
  "<link rel=\"canonical\" href=\"" & cleanUrl & "\">\n" &
  "<meta name=\"robots\" content=\"noindex\">\n" &
  "<title>Redirecting…</title>\n" &
  "<script>location.replace(\"" & cleanUrl & "\");</script>\n" &
  "</head>\n<body>\n" &
  "<p>This page has moved to <a href=\"" & cleanUrl & "\">" & cleanUrl & "</a>.</p>\n" &
  "</body>\n</html>\n"

proc emitRedirects*(publicDir: string): int =
  ## Write a meta-refresh stub at every legacy path under `publicDir`.
  ## Returns the number of stubs written (currently 0).
  for r in legacyRedirects:
    let outPath = publicDir / r.oldRelPath
    createDir(outPath.parentDir())
    writeFile(outPath, metaRefreshStub(r.newRoute))
    inc result
