## RP5c1 / RP5c2 build helper: print reprobuild's provider-compile command for
## a module. Copied into the reprobuild tree at build time by build-rp5c1.sh so
## that reprobuild's config.nims supplies the compiler's own --path set; the
## printed command is exactly the RP1 provider-compile edge's invocation, from
## which build-rp5c1.sh derives the vm-harness provider/test compile.
import repro_interface_artifacts
import os
let modulePath = paramStr(1)
let outBin = paramStr(2)
let cmd = providerCompileCommand(modulePath, outBin, getCurrentDir())
for c in cmd: echo c
