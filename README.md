# wk

Manage long-lived LXD containers for isolated development and CI.

Each container runs **its own Docker daemon**, so services with fixed names —
`shared-ci-net`, `mysql`, `services-hive` — can exist in several containers
at once without colliding. Your code is a plain directory on the host that you
clone yourself; `wk` only mounts it.

> **Trust boundary:** containers are privileged (`security.privileged`,
> `security.nesting`, apparmor unconfined) because a nested Docker daemon needs it.
> Treat them as a **trusted local environment**, not as a multi-tenant security
> boundary.

## Why

CI scripts hard-code service, network, and volume names. If every task shares the
host's Docker daemon, two tasks fight over the same `shared-ci-net` network
and the same `mysql` container. Renaming is not an option — the names live in the
CI scripts. So the isolation boundary has to sit at the Docker daemon itself:

```
lxslot1 ──▶ docker ──▶ shared-ci-net / mysql / hive  ┐
lxslot2 ──▶ docker ──▶ shared-ci-net / mysql / hive  ├ same names, invisible to each other
lxslot3 ──▶ docker ──▶ shared-ci-net / mysql / hive  ┘
```

## Model

```
container (long-lived, built once, reused across tasks)
   └── one bound code directory (swap it whenever you like)
```

There is no "task" object. **The container is the unit of work** — to work on three
things, use three containers. What a container is currently doing is simply the
directory it has bound plus a note.

All state lives in LXD: container state comes from `lxc list`, the bound directory
from its disk device, notes and timers from `user.wk.*` config keys. wk keeps no
state files of its own.

## Requirements

- an LXD host (tested on 5.21 LTS) — wk runs **on** that host, normally as root
- `git`, `iptables` (only if you go through a proxy), `tmux` (optional, for `wk enter`)
- `docker` on the host only if you want image warm-up

## Install

```bash
git clone https://github.com/MisterRaindrop/workflow.git
cd workflow
./install.sh                 # symlinks wk, seeds /etc/wk/config.env
```

Then review the config and check the host:

```bash
$EDITOR /etc/wk/config.env
wk doctor
```

## Quick start

Build a container once — this is the slow part (Docker, tools, credentials, images):

```bash
wk new                       # or: wk new lxslot1
```

Then bind code and go:

```bash
git clone <repo> /data/src/fix-auth-bug     # you prepare the code
wk bind lxslot1 /data/src/fix-auth-bug      # mounts it, starts project services
wk enter lxslot1                            # inside; add `codex` or `claude` to launch one
```

Day to day it is just:

```bash
wk ls
wk enter lxslot1
```

From your laptop, in one line:

```bash
mosh --ssh="ssh -i ~/.ssh/id_rsa" root@<host> -- wk enter lxslot1
```

## Commands

### Everyday

```bash
wk ls                          # state / idle / memory / bound code / note
wk enter <c> [codex|claude]    # go inside — thaws or starts the container first
```

### Code

```bash
wk bind <c> <dir> [--no-up]    # mount a directory at the same path inside, start services
wk unbind <c>                  # unmount (your code is never touched)
```

`bind` mounts the directory at the **same absolute path** inside the container, so
build artefacts and debug paths match the host. It also checks the directory is
owned by `WK_CODE_UID:WK_CODE_GID` (1000:1000 by default), because builds run as
that user and cannot write otherwise. `/code` inside the container always points at
whatever is currently bound.

### Power

```bash
wk pause <c>                   # freeze: processes stay in memory, instant resume
wk start <c>                   # start (also what resumes a frozen container)
wk stop  <c>                   # stop: frees memory, loses processes inside
```

Prefer `pause`. It keeps your tmux sessions and half-finished builds alive and
resumes instantly; it just does not give memory back.

### Setup

```bash
wk new [name]                  # build a container (idempotent — safe to re-run)
wk rm [-f] <c>                 # delete a container; never touches your code
wk doctor                      # LXD, storage pool, proxy egress, memory, per-container config
wk auth [c]                    # re-seed credentials after logging in again on the host
```

Credentials are **copied** into each container, not shared. After you log in again
on the host (`codex`, `claude`, `gh`, …), run `wk auth`. A single writable
`~/.codex` shared across containers would corrupt itself.

### Troubleshooting

```bash
wk exec [--retry N] <c> <cmd>  # run a command in the container
wk dexec <c> <docker> <cmd>    # run a command in one of its Docker containers
wk up|down <c>                 # start/stop project services only
wk smoke <c>                   # services, in-network DNS, docker exec/cp, write access
wk warm <c> [--from <src>]     # load cached images, or stream them from another container
wk cache ls|prune              # list / LRU-trim the host image cache
wk note <c> [text]             # get/set the note shown in wk ls
```

`wk exec` runs in the **container**; `wk dexec` runs inside one of the Docker
containers within it. Two layers, two commands.

## Concurrency

Commands take a per-container lock. `exec` and `enter` take a *shared* one, so
several long jobs can overlap; anything that mutates the container (`bind`,
`stop`, `rm`, …) takes an *exclusive* one and will wait, then fail with a message
naming the container. This is what stops a `bind` from pulling the mount out from
under a running build.

Every write operation is recorded to journald — `journalctl -t wk`.

## Per-project services

Without any config, wk looks for the project layout (`services/mysql.yml` and the
two `docker-compose-*-ci.yml` files). To be explicit, drop a `.wk.yaml` in your
code directory:

```yaml
services:
  - services/mysql.yml
  - scripts/functions/docker-compose/docker-compose-ci.yml

networks:
  - shared-ci-net

smoke_services:
  - mysql
  - services-hive
```

## Capacity

`wk ls` samples each container's real memory footprint and records the high-water
mark; `wk new` warns before committing another container.

The number to watch is **anon + swap**, not `memory.current`. The latter includes
page cache — on a real container it read 13.3 GiB while the non-reclaimable
footprint was 1.4 GiB, a ~10x overstatement that would wrongly tell you the host is
full.

## Notes on the design

- **Images are per-container.** They change over time, and sharing a Docker daemon
  directory across containers is never safe. Host-side tar caching means the bytes
  are downloaded once and loaded from disk into each container.
- **No git worktrees.** A worktree shares `.git` and submodule state with the main
  checkout, which is a permanent source of interference. Independent clones are what
  make a container and its code truly decoupled.
- **Proxy forwarding rules are not persistent.** wk re-asserts the `DOCKER-USER`
  rules on every path that needs the network, and `wk doctor` verifies the proxy is
  actually reachable from inside a container.

Design documents: [architecture](docs/design/architecture.md) (structure) and
[lxd-slot](docs/design/lxd-slot.md) (decisions, measurements, open questions).

## License

[Apache-2.0](LICENSE)
