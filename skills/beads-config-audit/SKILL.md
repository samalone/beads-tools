---
name: beads-config-audit
description: >-
    Audit and repair a project's Beads (bd) configuration to my preferred
    single-user Dolt workflow. Use this whenever I ask to check, fix, update,
    verify, or migrate a project's Beads setup — for example after I upgrade the
    bd binary, when I first set up beads in a project, when bd commands behave
    oddly or the database seems corrupted or out of date, or when I say my
    config preferences have changed. It turns off issues.jsonl auto-export,
    ensures a refs/dolt/data remote plus mode-appropriate dolt.auto-push,
    disables the branch-polluting backup git-push, installs the Dolt sync git
    hooks, and confirms everything works. Don't wait for me to spell out each
    step — invoke this whenever the task is "get this project's Beads config into
    my preferred state."
---

# Beads config audit

The deterministic work is done by a bundled shell script; your job is to run it,
handle the judgment **gates** it can't decide on its own, and write the report.
This keeps the mechanical steps reliable (no skipped verifications, guaranteed
ordering) while reserving your expertise for the parts that actually need it.

## Run the script

```
${CLAUDE_PLUGIN_ROOT}/scripts/beads-config-audit.sh [--allow-migrate] [--no-commit] [project-dir]
```

It audits + repairs to my preferred state (below) and commits the `.beads`
changes. On success it prints `OK: …`. On a gate it prints `GATE(<code>): …` to
stderr and exits non-zero — **that is where you come in.**

## The preferred state it enforces (for context)

- `issues.jsonl` export **off**, file removed, gitignored. `interactions.jsonl`
  kept but untracked + gitignored.
- A Dolt remote on `refs/dolt/data` (git origin), first push done.
- `dolt.auto-push` **on** for embedded, **off** for server (concurrent
  auto-push to a git remote can corrupt history).
- `backup.git-push` **off**; `dolt.auto-commit` left at bd's default (on).
- Git hooks installed: `pre-push` → `bd dolt commit && bd dolt push` (origin),
  `post-merge` → `bd dolt pull`. Mode-independent, non-blocking. (These are the
  counterpart to auto-push, and the *only* durability-on-push in server mode.)
- Schema matched to the installed bd; DB dir / credential / legacy `*.db`
  gitignored and never tracked.

## Handling the gates (exit codes)

Each gate needs a decision the script deliberately won't make. Do **not** force
past one blindly.

- **10 — not a beads project.** No `.beads`. Confirm the target dir with me.
- **11 — unsupported bd version.** The script targets bd 1.1.x. On a newer bd,
  its command/flag assumptions may be stale (bd moves fast): re-verify the
  affected commands with `bd <cmd> --help`, update the script if needed, or
  tell me — don't hand-run the old procedure.
- **12 — suspected pre-Dolt / no Dolt data dir.** A 0.x or JSONL-centric layout
  needs a real pre-Dolt → Dolt migration, not this audit. **Stop and tell me.**
- **13 — pending schema migration.** If the DB has **no remote**, it's safe to
  migrate here: rerun with `--allow-migrate` (the script backs up, then
  migrates). If it **has a remote**, migrate deliberately as the single
  designated migrator (`bd migrate` → `bd dolt push`), and remember other clones
  must adopt it via `bd bootstrap`, not migrate themselves. If you can't tell
  whether other clones exist, **ask me** before migrating.
- **15 — durability gap.** No git origin, or the first `bd dolt push` failed
  (often: the GitHub repo has no branches yet). Establish the remote (create/push
  an initial branch — that needs my OK to push) and rerun. The script stops
  before any JSONL removal precisely so nothing is lost here.
- **20 — config file ambiguous.** `bd config set` can leave a key in two
  conflicting forms; the script normalizes to one flat line but bailed because it
  couldn't verify a single clean representation. Open `.beads/config.yaml`, and
  for the named key confirm it appears **exactly once** (flat `ns.key:` at col 0
  *or* one nested child under `ns:` — not both), delete the stale duplicate, then
  rerun.

## Advisories (not gates)

The script proceeds but prints `NOTE:` lines — relay them. The main one:
**server mode** — auto-push was left off by design; if this isn't a deliberate
concurrent-agent setup, offer to switch it back to embedded (`bd-mode embedded`).

## Report

Summarize the deltas (mode, schema, each config before/after, hooks, JSONL
cleanup) and surface any gate you hit or `NOTE:` the script emitted — especially
server mode or a migration you deferred. Don't narrate every command; give me
the deltas and the open questions.
