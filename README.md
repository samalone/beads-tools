# beads-tools

A Claude Code plugin packaging my [Beads](https://github.com/gastownhall/beads)
(`bd`) Dolt workflow toolkit — the pieces I want on every dev machine.

## What's inside

| Component | What it does |
|-----------|--------------|
| **`bd-mode`** (CLI, `bin/`) | Report or switch a beads project between **embedded** and **project-server** mode, transferring the Dolt database and keeping the install equivalent. Symlinked into `~/.local/bin` on session start. |
| **`beads-hooks.sh`** (`scripts/`) | Installs git hooks that sync Dolt data with the git remote: `pre-push` → `bd dolt commit && bd dolt push` (origin), `post-merge` → `bd dolt pull`. Mode-independent, non-blocking, and preserved across `bd hooks install`. |

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

## Development / testing

CI (`.github/workflows/ci.yml`) runs the manifest validator, `shellcheck`, and
the [bats](https://github.com/bats-core/bats-core) suite on macOS **and** Linux
for every PR. To run the same checks locally (tools via Homebrew):

```bash
brew install bats-core shellcheck jq         # bd 1.1.x must already be installed

# manifest / hooks / frontmatter (non-strict: the intentional plugin-root
# CLAUDE.md warning makes --strict fail — see the CI allowlist)
claude plugin validate ./

bash -n bin/bd-mode scripts/beads-hooks.sh
shellcheck bin/bd-mode scripts/beads-hooks.sh
bats test/                                    # ~3 min; spins real bd + Dolt in throwaway fixtures
```

The bats fixtures are fully isolated: each builds a throwaway `bd init` project
with a bare git origin under `$HOME` (bd refuses `/tmp`-family "unsafe"
locations; override the base with `BD_TESTS_TMPDIR`), exercises a tool, asserts
on the result, and tears down — stopping only its **own** Dolt server, never a
machine-wide `bd dolt killall`. They never touch a live repo.
