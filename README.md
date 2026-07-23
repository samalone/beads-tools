# beads-tools

A Claude Code plugin packaging my [Beads](https://github.com/gastownhall/beads)
(`bd`) Dolt workflow toolkit — the pieces I want on every dev machine.

## What's inside

| Component | What it does |
|-----------|--------------|
| **`bd-mode`** (CLI, `bin/`) | Report or switch a beads project between **embedded** and **project-server** mode, transferring the Dolt database and keeping the install equivalent. Symlinked into `~/.local/bin` on session start. |
| **`beads-config-audit`** (skill + `scripts/beads-config-audit.sh`) | Deterministic audit + repair to my single-user Dolt preferences (export off, remote + `refs/dolt/data`, mode-appropriate `dolt.auto-push`, backup git-push off, sync hooks). The skill orchestrates the script and handles the judgment gates. |
| **`beads-hooks.sh`** (`scripts/`) | Installs git hooks that sync Dolt data with the git remote: `pre-push` → `bd dolt commit && bd dolt push` (origin), `post-merge` → `bd dolt pull`. Mode-independent, non-blocking, and preserved across `bd hooks install`. |
| **Workflow injector** (`scripts/inject-beads-workflow.sh` + `shared/`) | A SessionStart hook that injects my beads/PR-workflow guidance, but only in projects that use beads. Auto-registers on install — no per-machine `settings.json` entry. |

## Install (per machine)

```bash
claude plugin marketplace add samalone/claude-plugin-marketplace   # once, if not already added
claude plugin install beads-tools@samalone-plugins
```

Update later with `claude plugin marketplace update` (the marketplace tracks this
repo's default branch).

## `bd-mode` usage

```bash
bd-mode            # report the current mode
bd-mode server     # switch to project-server mode
bd-mode embedded   # switch to embedded mode
```

Before switching it verifies the audit config, ensures `refs/dolt/data` is
current, makes a temporary backup, transfers the database (no `bd init`), flips
`dolt.auto-push` to match the mode, verifies issue-set equivalence, and rolls
back on any failure.

## Design notes

- **Ownership split:** the audit script/skill *installs* the desired state
  (config + hooks); `bd-mode` *verifies* the invariant and flips the one
  mode-dependent knob (`auto-push`).
- **The sync hooks are mode-independent** on purpose: the primary durability
  path in server mode (where `auto-push` is off), and a cheap guaranteed
  sync-point in embedded mode.
- Targets **bd 1.1.x**; the audit script refuses on other versions rather than
  running commands whose flags may have shifted.
