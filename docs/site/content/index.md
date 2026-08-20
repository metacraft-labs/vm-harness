---
title: vm-harness docs
description: vm-harness is a general-purpose, cross-platform VM lifecycle orchestration toolkit — one Nim library plus a vm-harness CLI that drive Hyper-V, libvirt/QEMU, Tart, UTM, WSL, Lima, and Incus through a single set of primitives.
order: 1
---
# vm-harness

:::hero title="vm-harness"
:::button href="/getting_started/getting-started" variant="primary"
Get Started
:::button href="https://github.com/metacraft-labs/vm-harness" variant="secondary"
GitHub
:::

## Overview

vm-harness is a general-purpose, cross-platform VM lifecycle orchestration
toolkit — a small Nim library plus a `vm-harness` CLI that let test code and
dev workflows drive many different hypervisors and container managers through
one set of primitives. You write against the `VmBackend` abstraction once, and
the same code runs a Hyper-V VM on Windows, a libvirt/QEMU VM on Linux, a Tart
or UTM VM on an Apple-Silicon Mac, an Incus system container, and so on.

Use the sidebar to learn the concepts, build the CLI and bring your first VM up,
work through the task-oriented guides, and look up every flag and parameter in
the reference.

## Start here

:::cards
:::card title="Getting Started" icon="/assets/img/icon__start.svg" href="/getting_started"
Learn what vm-harness is and the `VmBackend` model, then enter the dev shell,
build the CLI, and run your first in-guest assertion.
:::card title="Guides" icon="/assets/img/icon__components.svg" href="/guides"
Drive a VM from your own harness code, set up and understand each backend, and
author a reproducible guest recipe.
:::card title="Reference" icon="/assets/img/icon__style.svg" href="/reference"
Every `vm-harness` subcommand and flag, plus the documented, stable parameter
contract downstream repos build policy against.
:::

## Popular articles

:::cards variant="compact"
:::card title="Overview and concepts" href="/getting_started/overview-and-concepts"
Getting Started
:::card title="Getting started" href="/getting_started/getting-started"
Getting Started
:::card title="Driving a VM from code" href="/guides/driving-a-vm"
Guides
:::card title="Backends: setup and caveats" href="/guides/backends"
Guides
:::card title="CLI reference" href="/reference/cli-reference"
Reference
:::card title="Parameters catalog" href="/reference/parameters"
Reference
:::
