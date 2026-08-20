## vm-harness docs -- SSG smoke + basePath test.
##
## Builds the real `content/` through the framework `buildSite` into a temp
## output dir (no client-JS bundle, to keep the test fast) and asserts the site
## renders, the landing + a couple of articles exist, and every internal
## root-relative URL carries the `/vm-harness` project-Pages prefix.
##
## Run from the site package root: `nim c -r --hints:off tests/test_site_builds.nim`.

import std/[os, strutils, unittest]
import build_site
import core/docs_tokens
import ../src/docs_config
import ../src/theme_tokens

suite "vm-harness docs site builds":
  # Package root is one dir up from tests/, so paths resolve like `just build`.
  setup:
    setCurrentDir(currentSourcePath().parentDir().parentDir())
  let outDir = getTempDir() / "vmh-docs-test-public"

  test "renders every page and applies the /vm-harness basePath":
    let tokensCss = emitTokensCss(metacraftDocsTokenLayer(), designSystemTokens())
    let n = buildSite(outDir = outDir, contentDir = "content",
                      cfg = vmhDocsConfig(), docsTokensCss = tokensCss)
    check n >= 11  # index + 3 section indexes + 7 migrated pages

    # Landing + section indexes + a couple of articles are emitted as
    # clean-URL <route>/index.html.
    check fileExists(outDir / "index.html")
    check fileExists(outDir / "getting_started" / "index.html")
    check fileExists(outDir / "getting_started" / "getting-started" / "index.html")
    check fileExists(outDir / "guides" / "backends" / "index.html")
    check fileExists(outDir / "reference" / "cli-reference" / "index.html")

    # basePath: internal root-relative links are prefixed; external links aren't.
    let home = readFile(outDir / "index.html")
    check "href=\"/vm-harness/" in home
    check "href=\"https://github.com/metacraft-labs/vm-harness\"" in home
    # No un-prefixed internal doc link should leak through.
    check "href=\"/getting_started/" notin home

  teardown:
    removeDir(outDir)
