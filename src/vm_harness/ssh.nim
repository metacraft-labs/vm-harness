## SSH command payloads are interpreted by the remote login shell, not argv.
import std/[strutils, tables]
import ./types

proc quoteSshConfigValue*(value: string): string =
  if value.find({'\0', '\r', '\n'}) >= 0:
    raise newException(ValueError, "SSH option values cannot contain NUL or newlines")
  if value.find({' ', '\t', '"', '\\'}) >= 0:
    "\"" & value.replace("\\", "\\\\").replace("\"", "\\\"") & "\""
  else: value

proc quotePosixShellArg*(arg: string): string =
  if '\0' in arg:
    raise newException(ValueError, "SSH arguments cannot contain NUL")
  "'" & arg.replace("'", "'\"'\"'") & "'"

proc formatSshCommand*(cmd: openArray[string]; guestOs: GuestOs): string =
  for arg in cmd:
    if '\0' in arg:
      raise newException(ValueError, "SSH arguments cannot contain NUL")
    if result.len > 0: result.add(' ')
    case guestOs
    of goLinux, goMacos: result.add(quotePosixShellArg(arg))
    of goWindows: result.add('"' & arg.replace("\"", "\\\"") & '"')

proc formatSshEnvironment*(env: Table[string, string];
                           guestOs: GuestOs): string =
  for key, value in env:
    if key.len == 0 or key[0] notin {'a'..'z', 'A'..'Z', '_'}:
      raise newException(ValueError, "invalid environment name: " & key)
    for c in key:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        raise newException(ValueError, "invalid environment name: " & key)
    case guestOs
    of goLinux, goMacos:
      result.add(key & "=" & quotePosixShellArg(value) & " ")
    of goWindows:
      # Retain the established Windows command shape, but refuse shell syntax.
      if value.find({'\0', '\r', '\n', '"', '&', '|', '<', '>', '^', '%'}) >= 0:
        raise newException(ValueError, "unsafe Windows SSH environment value")
      result.add("set \"" & key & "=" & value & "\" && ")
