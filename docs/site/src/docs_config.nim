## vm-harness docs -- this site's own `DocsConfig`.
##
## The vm-harness user guide ported onto isonim-docs, themed with the shared
## Metacraft docs design system (`theme_tokens.nim` + `assets/style.css`).
## Hosted as a GitHub *project* Pages site at
## https://metacraft-labs.github.io/vm-harness/ , so `basePath` is `/vm-harness`
## (the framework prefixes every internal root-relative URL with it) and
## `baseUrl` carries the same subpath for absolute canonical/sitemap URLs.

import core/config

proc vmhDocsConfig*(): DocsConfig =
  DocsConfig(
    siteTitle: "vm-harness docs",
    siteDescription: "Documentation for vm-harness -- a general-purpose, " &
      "cross-platform VM lifecycle orchestration toolkit (library + CLI).",
    defaultRoute: "/",
    stylesheetHref: "/assets/style.css",
    baseUrl: "https://metacraft-labs.github.io/vm-harness",
    # GitHub project Pages subpath hosting: the site is served under
    # /vm-harness, so every internal root-relative URL the SSG emits is
    # prefixed with it (see core/base_path). `baseUrl` includes the same
    # subpath so canonical/sitemap URLs stay correct.
    basePath: "/vm-harness",
    # Three top-level sidebar sections, in this order (the framework otherwise
    # sorts sections alphabetically).
    sectionOrder: @["getting_started", "guides", "reference"],
    footerHtml: "Built by <a href=\"https://github.com/metacraft-labs\">metacraft-labs</a>",
    # Ship + inject the compiled client app on every page (theme toggle, live
    # search, sidebar collapse). The bundle is `src/main.nim`; the asset-hash
    # pass rewrites this placeholder to the cache-busted filename.
    appScriptHref: defaultAppScriptUrl,
    # Render all sidebar sections default-expanded so links are navigable on a
    # plain page load even before/without the client JS.
    expandAllNavSections: true,
    # Single right-aligned header nav button.
    headerLinks: @[
      (label: "GitHub", href: "https://github.com/metacraft-labs/vm-harness"),
    ],
    # Github link at the bottom of the left sidebar (monochrome chrome icon,
    # inverts in dark mode).
    sidebarLinks: @[
      (label: "Github", href: "https://github.com/metacraft-labs/vm-harness",
       icon: "/assets/img/icon__github.svg"),
    ],
    # Move the theme toggle into the sidebar-bottom pill.
    sidebarThemeToggle: true,
    # "Need some help?" block above the content-column footer.
    needHelp: (
      heading: "Need some help?",
      links: @[
        (label: "Open an issue", href: "https://github.com/metacraft-labs/vm-harness/issues",
         icon: "/assets/img/icon__support.svg"),
        (label: "Browse the reference", href: "/reference/cli-reference",
         icon: "/assets/img/icon__faq.svg"),
      ],
    ),
  )
