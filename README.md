# wk

A CLI tool for managing isolated development environments using git worktrees and Docker Compose.

Each worktree gets its own container with a unique SSH port, automatic wake-on-access, and idle monitoring.

## Prerequisites

- bash 4+
- git
- docker compose v2
- [yq](https://github.com/mikefarah/yq) (YAML parsing)
- [fzf](https://github.com/junegunn/fzf) (interactive selection, optional)
- [gh](https://cli.github.com/) (GitHub CLI, optional — for `pr:NNN` and CI status)

## Install

```bash
git clone https://github.com/liuxiaoyu/workflow.git
cd workflow
./install.sh
```

This symlinks `wk` into `~/.local/bin`. Pass a custom path if needed:

```bash
./install.sh /usr/local/bin
```

For auto-cd after `wk new`, add the shell function printed by `install.sh` to your `~/.zshrc` or `~/.bashrc`.

## Setup

Create a `.wk.yaml` in your project root:

```yaml
# Where to create worktrees (optional, this is the default)
# Available variables:
#   {{ repo_path }}          — absolute path of the main repo
#   {{ repo }}               — directory name of the main repo
#   {{ branch | sanitize }}  — branch name with / replaced by -
path: "{{ repo_path }}/../{{ repo }}-{{ branch | sanitize }}"

# Custom commands — each entry becomes `wk <name>`
# Add as many as you need. The command runs inside the container via docker exec.
commands:
  build:   "make -j$(nproc)"
  test:    "make test"
  deploy:  "scripts/deploy.sh"
  lint:    "npm run lint"
  migrate: "python manage.py migrate"
  # wk build   → docker exec <container> bash -c "make -j$(nproc)"
  # wk lint    → docker exec <container> bash -c "npm run lint"
  # ... any name works

# Auto-pause idle containers (optional)
# Requires `wk watch` to be running in the background.
watch:
  interval: 10m        # how often to check
  idle_timeout: 4h     # pause containers idle longer than this
```

Your `docker-compose.yml` needs no changes. `wk new` copies it, then patches the project name, hostname, and SSH port automatically.

## Quick Start

```bash
# Create an isolated environment for a branch
wk new feature/my-work

# List all environments
wk ls

# SSH into the container
wk ssh

# Run a project command inside the container
wk build
wk test

# Execute any command in the container
wk exec make clean

# Remove when done
wk rm feature/my-work
```

## Commands

### Environment Lifecycle

```bash
wk new <branch>           # Create worktree + start container
wk new pr:123             # Create from a GitHub PR
wk new feat --copy-cache  # Copy .cache/ from main worktree
wk rm [branch]            # Stop container + remove worktree
wk rm -f [branch]         # Force remove (skip uncommitted check)
```

### Environment Operations

```bash
wk ls                     # List all worktrees with status
wk ssh [branch]           # SSH into container (auto-wakes)
wk exec [branch] <cmd>    # Run command in container (auto-wakes)
```

### Project Commands

```bash
wk build                  # Run "build" from .wk.yaml
wk test                   # Run "test" from .wk.yaml
wk <any-name>             # Run any command defined in .wk.yaml
```

### Metadata

```bash
wk var set note "fixing auth bug"   # Attach a note (shown in wk ls)
wk var get note                     # Read it back
```

### Monitoring

```bash
wk watch                  # Start background monitor (auto-pause idle containers)
wk watch status           # Show monitor state + idle times
wk watch stop             # Stop monitor
```

## How It Works

```
wk new feature/x
  ├── git worktree add ../project-feature-x
  ├── git submodule update --init
  ├── Copy docker-compose.yml → .wk/docker-compose.yml
  ├── Patch: name / hostname / SSH port / volume paths
  ├── docker compose up -d
  └── Checkout submodule to same branch (if exists on remote)
```

- **Port allocation**: `SSH_PORT = 10000 + hash(branch) % 9000` — deterministic, no registry needed
- **Auto-wake**: `wk ssh` / `wk exec` / project commands automatically unpause or start stopped containers
- **Idle monitoring**: `wk watch` periodically pauses containers idle beyond the configured timeout
- **Safety**: `wk rm` checks for uncommitted changes before removing (use `-f` to override)

## License

[Apache-2.0](LICENSE)
