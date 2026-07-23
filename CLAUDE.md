# CLAUDE.md — beads-tools

Context for AI sessions maintaining this repo. Personal project (Stuart A. Malone).

## What this is

`beads-tools` is a **Claude Code plugin** packaging my [Beads](https://github.com/gastownhall/beads)
(`bd`) Dolt workflow toolkit. It is distributed through my personal marketplace
`samalone/claude-plugin-marketplace` (marketplace name `samalone-plugins`) and
installed per machine with:

```bash
claude plugin marketplace add samalone/claude-plugin-marketplace   # once
claude plugin install beads-tools@samalone-plugins
```

The marketplace tracks this repo's default branch, so a merge to `main` ships to
every machine on the next `claude plugin marketplace update`.

**This repo *is* the plugin.** A session here maintains the plugin's own code; it
is not the place to run the plugin against other projects.

## Layout

```
.claude-plugin/plugin.json      plugin manifest (name, version, $schema)
bin/bd-mode                     CLI: switch a beads project embedded <-> server mode
scripts/beads-config-audit.sh   deterministic audit/repair to my Dolt preferences (gated)
scripts/beads-hooks.sh          install/check the Dolt-sync git hooks
scripts/inject-beads-workflow.sh SessionStart injector for my beads/PR guidance
shared/beads-pr-workflow.md     the guidance that injector emits
skills/beads-config-audit/      the skill that orchestrates the audit script
hooks/hooks.json                SessionStart: symlink bd-mode into ~/.local/bin + inject
README.md                       user-facing overview
```

## Design conventions (honor these)

- **Shell:** `#!/usr/bin/env bash` + `set -euo pipefail` for the tools;
  `/usr/bin/env sh` for `inject-beads-workflow.sh` and the injected hook payloads.
- **Portability:** primary platform is macOS (BSD userland), but the plugin ships
  to all my machines — keep it Linux/GNU-safe. No `sed -i ''`, no `readlink -f`;
  write-to-temp-then-`mv`, hand-rolled symlink resolution, `timeout`/`gtimeout`
  fallback. Run `shellcheck` before committing.
- **Targets `bd` 1.1.x.** `bd` moves fast; the audit script refuses on other
  versions (exit 11) rather than running commands whose flags may have shifted.
  When bumping bd support, re-verify each `bd` subcommand with `--help`.
- **Ownership split:** the audit script/skill *installs* the desired state
  (config + git hooks); `bd-mode` *verifies* the invariant and flips the one
  mode-dependent knob (`dolt.auto-push`: on for embedded, off for server). Don't
  duplicate install logic into `bd-mode`.
- **Config edits are deterministic, not `bd config set`.** `bd config set` on
  nested YAML can write a duplicate/conflicting key. Both `bd-mode` and the audit
  normalize `dolt.auto-push` (and friends) to a single flat `key: value` line via
  awk/temp+mv, and verify at the file level.
- **The sync hooks are mode-independent** (primary durability in server mode where
  auto-push is off; a cheap guaranteed sync point in embedded). They live *outside*
  beads' own `--- BEGIN/END BEADS INTEGRATION ---` markers so `bd hooks install`
  preserves them; keep them non-blocking (never fail a git op) and origin-scoped.
- **Never destroy before durability.** Every delete (`rm -rf` a data dir, `git rm`
  a JSONL) must come after a confirmed remote push / backup. Guard `rm -rf` paths
  against empty/`..` values.

## Build / test

There is **no build**. Testing today is the first-party validator plus
(forthcoming) shell tests — see the open bead for the test suite.

```bash
claude plugin validate ./ --strict          # manifest / hooks / frontmatter
claude --plugin-dir ./                        # load the real layout locally, then /reload-plugins
bash -n bin/bd-mode scripts/*.sh              # syntax
shellcheck bin/bd-mode scripts/*.sh           # lint (bring your own; not yet in CI)
```

Automated tests (`shellcheck` + `bats` fixtures + `claude plugin validate --strict`
in CI) are **not yet built** — that's the tracked bead. Until then, exercise
changes against a throwaway `bd init` project in a `mktemp -d`, never a live repo.

## Beads

This repo uses beads (**server mode**) for its own issue tracking. Use `bd` for
all task tracking; run `bd prime` for the workflow. My global beads/PR guidance is
injected automatically. Server mode means the first `bd` call starts a per-project
server and bootstraps from `refs/dolt/data`; the sync hooks push/pull Dolt data on
git push/pull (auto-push is intentionally off in server mode).

## Git / PR workflow

My global `~/.claude/CLAUDE.md` governs this: commit freely, **don't push `main`
without permission**, open PRs only when asked, assign `samalone`, run
`~/.claude/scripts/poll-pr-reviews.sh` for AI reviews, review to convergence, and
merge with a plain `--merge` commit. Versioning tracks `main` (no version bumps
needed to ship); bump `plugin.json` `version` only for a deliberate release.
