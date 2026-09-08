"""Real Linux graph builds must select PCRE without a caller PATH override.

Run with REPRO_BIN pointing to the native repro CLI, from a base environment
without pcre-config. This is intentionally separate from the Nim test graph:
it tests that graph's bootstrap and launches three independent narrow builds.
No VM or hypervisor is involved. Evidence is retained in the printed directory.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    if not sys.platform.startswith("linux"):
        raise RuntimeError("the PCRE native graph gate requires Linux")
    env = os.environ.copy()
    if shutil.which("pcre-config", path=env.get("PATH")):
        raise RuntimeError("run this gate from a base environment without pcre-config")
    repro = env.get("REPRO_BIN") or shutil.which("repro")
    if not repro:
        raise RuntimeError("REPRO_BIN must select a built native repro CLI")
    repro = str(Path(repro).resolve(strict=True))
    source = Path(__file__).resolve().parents[2]
    evidence = Path(tempfile.mkdtemp(prefix="vmh-pcre-native-graph-"))
    project = evidence / "vm-harness"
    project.mkdir()
    print(f"PCRE graph evidence: {evidence}", flush=True)
    for name in ("repro.nim", "config.nims"):
        shutil.copy2(source / name, project / name)
    for name in ("src", "tools", "tests", "guest-scripts", "guest-recipes"):
        shutil.copytree(source / name, project / name,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.exe",
                                                     "build", "nimcache", "*.o"))

    def run(args, label, runtime_env=env, expected=0):
        completed = subprocess.run(args, cwd=project, env=runtime_env,
                                   text=True, capture_output=True, timeout=900)
        (evidence / f"{label}.stdout").write_text(completed.stdout)
        (evidence / f"{label}.stderr").write_text(completed.stderr)
        if completed.returncode != expected:
            raise RuntimeError(f"{label}: exit {completed.returncode}\n"
                               f"{completed.stdout}\n{completed.stderr}")
        return completed

    nim = shutil.which("nim", path=env.get("PATH"))
    if not nim:
        raise RuntimeError("the native graph bootstrap environment must provide Nim")
    missing = run([nim, "check", "--hints:off", "src/vm_harness/cli.nim"],
                  "missing-pcre-fails-closed", expected=1)
    if "require pcre-config on the compile action PATH" not in missing.stderr:
        raise RuntimeError("missing PCRE did not produce the expected build error")

    # Separate invocations prevent another selected edge from supplying a
    # missing identity through the union of a whole-graph tool environment.
    for label, target, output in (
        ("cli", "vm_harness.cli.build", "build/bin/vm-harness"),
        ("bench", "vm_harness.snapshot_revert_bench.build",
         "build/bin/vm-harness-bench-snapshot-revert"),
        ("test", "vm_harness.test_build.t_durable_media", "build/test-bin/t_durable_media"),
    ):
        print(f"Building narrow graph target: {target}", flush=True)
        run([repro, "build", ".#" + target, "--tool-provisioning=nix", "--daemon=off",
             "--progress=quiet", "--measure=none",
             f"--action-cache-root={evidence / 'cache'}",
             f"--write-report={evidence / (label + '-report.json')}"], label)
        if not (project / output).is_file():
            raise RuntimeError(f"{label}: graph did not produce {output}")

    clean_runtime = env.copy()
    clean_runtime.pop("LD_LIBRARY_PATH", None)
    result = run([str(project / "build/bin/vm-harness"), "instance", "status",
                  "pcre-runtime-probe", "--state-dir", str(evidence / "state"),
                  "--log-format", "json"], "status-without-ld", clean_runtime)
    status = json.loads(result.stdout)
    assert status["state"] == "absent" and status["receipt_exists"] is False, status
    clean_runtime["VMH_TEST_CLI"] = str(project / "build/bin/vm-harness")
    run([str(project / "build/test-bin/t_durable_media")], "test-without-ld", clean_runtime)
    binary = project / "build/bin/vm-harness"
    # Path mode also supports declared pinned Nix fallback for missing tools.
    # Verify that metadata bootstrapping does not prevent that resolution.
    run([repro, "build", ".#vm_harness.cli.build",
         "--tool-provisioning=path", "--daemon=off", "--progress=quiet",
         "--measure=none", f"--action-cache-root={evidence / 'cache'}"],
        "path-mode-pinned-fallback")
    result = run([str(binary), "instance", "status", "pcre-runtime-probe",
                  "--state-dir", str(evidence / "state"), "--log-format", "json"],
                 "path-status-without-ld", clean_runtime)
    assert json.loads(result.stdout)["state"] == "absent", result.stdout
    run([str(project / "build/test-bin/t_durable_media")],
        "path-test-without-ld", clean_runtime)
    print(f"CLI: {binary}", flush=True)
    print(f"SHA-256: {hashlib.sha256(binary.read_bytes()).hexdigest()}", flush=True)
    print("PASS: native graph outputs launch without LD_LIBRARY_PATH", flush=True)


if __name__ == "__main__":
    main()
