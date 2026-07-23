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

```text
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

There is **no build**. CI (`.github/workflows/ci.yml`) runs three layers on a
macOS + Linux matrix for every PR; run them locally with:

```bash
# manifest / hooks / frontmatter. NON-strict on purpose: the intentional
# plugin-root CLAUDE.md triggers a "not loaded as project context" warning that
# makes --strict FAIL. CI allowlists exactly that one warning and fails on any
# other, so don't add --strict here.
claude plugin validate ./
claude --plugin-dir ./                        # load the real layout locally, then /reload-plugins
bash -n bin/bd-mode scripts/*.sh              # syntax (+ `sh -n` for inject-beads-workflow.sh)
shellcheck bin/bd-mode scripts/*.sh           # lint  (+ `-s sh` for the POSIX injector)
bats test/                                     # ~3 min; isolated bd + Dolt fixtures
```

The `bats` suite lives under `test/` (shared harness in `test/helpers/setup.bash`)
and is fully isolated: each test builds a throwaway `bd init` project with a bare
git origin under `$HOME` (bd rejects `/tmp`-family "unsafe" locations; override
the base with `BD_TESTS_TMPDIR`), exercises a tool, asserts, and tears down —
stopping only its own Dolt server, **never** a machine-wide `bd dolt killall`.
Never exercise changes against a live repo. Install the local tools with
`brew install bats-core shellcheck` (bd 1.1.x must already be present).

## Beads

This repo uses beads (**server mode**) for its own issue tracking. Use `bd` for
all task tracking; run `bd prime` for the workflow. My global beads/PR guidance is
injected automatically. Server mode means the first `bd` call starts a per-project
server and bootstraps from `refs/dolt/data`; the sync hooks push/pull Dolt data on
git push/pull (auto-push is intentionally off in server mode).

## Git / PR workflow

My global `~/.claude/CLAUDE.md` is authoritative and — per the managed Beads
block's own rule that explicit user instructions override it — takes precedence
over that block here. Under it: committing without asking is permitted, but
**never push `main` without permission**, open PRs only when asked, assign
`samalone`, run `~/.claude/scripts/poll-pr-reviews.sh` for AI reviews, review to
convergence, and merge with a plain `--merge` commit. Versioning tracks `main`
(no version bumps needed to ship); bump `plugin.json` `version` only for a
deliberate release.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
