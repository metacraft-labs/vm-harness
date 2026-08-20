# Package

version       = "0.1.0"
author        = "Metacraft Labs"
description   = "vm-harness documentation site -- the vm-harness user guide ported onto isonim-docs"
license       = "MIT"
srcDir        = "src"

# Dependencies
#
# The isonim-docs framework, isonim, and the shared Nim libraries are provided
# as flake inputs (see flake.nix) and placed on the Nim `--path` by config.nims
# from the dev shell's VMH_DOCS_* env vars -- NOT as nimble path dependencies --
# so the site builds self-contained with no sibling checkouts.
requires "nim >= 2.0.0"
