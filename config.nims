# Workspace-wide Nim configuration.
#
# Ensure that ``nim r tests/...`` finds the library sources at ``src/``
# without requiring the consumer to ``nimble install`` first.

switch("path", "src")
