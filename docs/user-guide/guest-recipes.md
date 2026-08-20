# Authoring a guest recipe

vm-harness's lifecycle primitives operate on **already-existing baselines**. A
*guest recipe* is the reproducible procedure that produces one of those
baselines — a golden image or a bootstrap-ready base image for a specific
backend. Recipes live under `guest-recipes/<id>/` and are shipped alongside the
CLI (the Nix package copies them to `$out/share/vm-harness/guest-recipes/`).

Recipes are a separate concern from the lifecycle: the toolkit resets and drives
whatever baseline you point it at; the recipe is how that baseline came to
exist. Some backends (libvirt Windows, UTM Windows) consume recipe artifacts at
provision time; others (Incus, Lima) build a base image once with a standalone
recipe script.

## How a recipe is selected

The CLI resolves `--recipe <id>` to a directory under `guest-recipes/<id>/`,
searching in order (see `resolveRecipeDir` in `src/vm_harness/cli.nim`):

1. `$VMH_RECIPES_DIR/<id>` — operator escape hatch,
2. `<cwd>/guest-recipes/<id>` — running from a repo checkout,
3. `<exe-dir>/../guest-recipes/<id>` and `<exe-dir>/../../guest-recipes/<id>`,
4. `<exe-dir>/../share/vm-harness/guest-recipes/<id>` — the Nix-packaged layout.

The id must be a bare name (no path separators), and a missing directory is a
parse-time error so a typo surfaces immediately. The resolved path is threaded
into `BaselineSpec.recipeDir`; backends that consume recipe inputs read
companion artifacts relative to it. If the recipe writes build outputs and it is
shipped read-only under `/nix/store`, pass a writable `--recipe-build-dir`.

## What ships today

- **`windows-x64-base/`** — the libvirt Windows-11-on-x64 baseline: autounattend
  XML + ISO assembly, cloudbase-init config, and a sysprep/generalize path for
  producing distinct-SID clones (`build-sysprep-golden.sh`).
- **`windows-arm-base/`** — the UTM Windows-11-on-ARM golden, including an
  offline Win32-OpenSSH ARM64 fallback and a virtio-net driver fetch.
- **`linux-x64-runner/`** — the Debian **GitHub-Actions runner** Incus image
  (walk-through below).
- **`linux-nixos-runner/`** — a NixOS runner-image variant.

For the design intent of recipes, read
[`../../guest-recipes/README.md`](../../guest-recipes/README.md).

## Recipe conventions

A well-behaved recipe:

- **Is idempotent and safe to re-run.** It uses only its own throwaway build
  names and its own output alias — it never touches unrelated host
  VMs/containers/images.
- **Is parameterized by `VMH_*` environment variables**, each with a sensible
  default and a documented effect. Because consumers set these to compose
  policy, treat them as a stable contract and document them in the header (see
  the [Parameters catalog](./parameters.md)).
- **Records provenance.** Stamp the produced image with a recipe-revision
  property so a consumer can detect a stale image and rebuild it (see
  `VMH_RUNNER_RECIPE_REVISION` below).
- **Leaves a first-boot / cloud-init seam** so a per-job bootstrap (e.g. JIT
  runner registration) can be injected without rebuilding the image.

## Walk-through: the Linux runner-image recipe

`guest-recipes/linux-x64-runner/build-runner-image.sh` builds the
`vmh-linux-runner` Incus image — the Linux analog of the Windows cloudbase-init
golden. It is the reference example of a parameterized recipe. It produces a
small Debian system-container image that carries:

- **cloud-init present and enabled**, so Incus's `cloud-init.user-data` config
  key is consumed on first boot — the JIT-injection seam the Incus backend
  drives per job.
- **the GitHub Actions runner staged** under `/home/<runner>/actions-runner`
  (the exact path GARM's Linux install template treats as the *cached* runner,
  so the per-job bootstrap skips the ~200 MB download and launches
  `run.sh --jitconfig` directly).
- an **unprivileged `runner` user with passwordless sudo** (the runner refuses
  to run as root),
- the runner's **.NET runtime deps** (already present in the Debian cloud base),
- optionally the pinned **`repro` CLI** pre-warmed on PATH, and optionally
  **nested Docker** and/or **nested KVM** capabilities.

### Running it

```sh
# Default: the plain live image alias `vmh-linux-runner`.
./build-runner-image.sh

# Prefixed incus (no group access in this session):
VMH_INCUS_CMD="sudo -n incus" ./build-runner-image.sh

# Pin the runner version / supply a pre-downloaded tarball:
VMH_RUNNER_VERSION=2.335.1 ./build-runner-image.sh
VMH_RUNNER_TARBALL=/path/to/actions-runner-linux-x64-X.tar.gz ./build-runner-image.sh

# The prod nested-capability image (Docker + KVM) under a SIDE alias so the
# live image is never overwritten:
VMH_RUNNER_DOCKER=1 VMH_RUNNER_KVM=1 \
  VMH_RUNNER_ALIAS=vmh-linux-runner-nested ./build-runner-image.sh
```

### The two capability seams

The recipe has two opt-in bakes, **off by default** so the live image is
byte-unchanged unless you ask for them. They must be paired with the matching
GARM provider option so the per-job container is actually launched with the
capability enabled:

| Bake env var | What it adds to the image | Provider option that enables it at run time |
| --- | --- | --- |
| `VMH_RUNNER_DOCKER=1` | docker/moby + fuse-overlayfs + a `docker.service`/`socket` (unprivileged, fuse-overlayfs storage driver) | `incusSecurityNesting = true` (`security.nesting` + mknod/setxattr intercepts) |
| `VMH_RUNNER_KVM=1` | `qemu-system-x86` + a guest kernel | `incusNestedKvm = true` (`/dev/kvm` device + `security.nesting`) |

Baking the capability into the image and enabling the provider option are **two
halves of the same feature** — the image ships the userspace, the provider grants
the container the privilege. The prod `incus-nested` runner class needs both, so
`VMH_RUNNER_DOCKER=1 VMH_RUNNER_KVM=1` bakes them into one image. Both options,
their security posture, and every other `VMH_RUNNER_*` seam are documented in the
[Parameters catalog](./parameters.md).

### Provenance and staleness

The recipe stamps the published image with
`vmh.recipe_revision = $VMH_RUNNER_RECIPE_REVISION`. A consumer that
materializes the image (for example an infra runner-image builder unit) reads
that property and rebuilds only when the revision differs — so bumping the
recipe revision is how you force a fleet-wide image refresh.
