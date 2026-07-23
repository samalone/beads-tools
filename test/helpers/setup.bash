# Shared harness for the beads-tools bats suite.
#
# Every test runs against a throwaway `bd init` project with a bare git origin —
# never a live repo. bd refuses to operate in "unsafe" temp locations (/tmp,
# /var/tmp), so fixtures live under $HOME by default; override with
# BD_TESTS_TMPDIR pointing at any bd-safe directory.
#
# Teardown stops only the fixture's own Dolt server (project-scoped
# `bd -C <proj> dolt stop --force`) — NEVER `bd dolt killall`, which is
# machine-wide and would kill a developer's real server for another project.

# This file is sourced via bats `load`; the vars/functions below are the harness
# API consumed by the .bats files, which shellcheck can't see across the load.
# shellcheck disable=SC2034  # BD_MODE/AUDIT/HOOKS_SH/INJECT_SH used by sourcing tests

# Absolute paths to the tools under test (BATS_TEST_DIRNAME = the test/ dir).
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
BD_MODE="$REPO_ROOT/bin/bd-mode"
AUDIT="$REPO_ROOT/scripts/beads-config-audit.sh"
HOOKS_SH="$REPO_ROOT/scripts/beads-hooks.sh"
INJECT_SH="$REPO_ROOT/scripts/inject-beads-workflow.sh"

# bd-safe base for fixtures (not /tmp or /var/tmp).
BD_TESTS_BASE="${BD_TESTS_TMPDIR:-$HOME}"

# Skip the whole test cleanly if a required tool is missing.
require_tools() {
    local t
    for t in bd git jq; do
        command -v "$t" >/dev/null 2>&1 || skip "required tool not found: $t"
    done
}

# make_project [--audit]
#   Create an isolated embedded bd project with a bare origin already pushed.
#   Sets PROJECT and ORIGIN. With --audit, also runs beads-config-audit so the
#   project has refs/dolt/data, sync.remote, the sync hooks, and normalized
#   config (the precondition bd-mode requires).
make_project() {
    export BEADS_DOLT_AUTO_START=0            # never auto-start a server during setup
    PROJECT="$(mktemp -d "$BD_TESTS_BASE/bdt-proj.XXXXXX")"
    ORIGIN="$PROJECT.origin.git"              # sibling of PROJECT, not nested inside it
    git init -q "$PROJECT"
    git init -q --bare "$ORIGIN"
    git -C "$PROJECT" remote add origin "$ORIGIN"
    ( cd "$PROJECT" && bd init >/dev/null 2>&1 )
    # bd dolt push needs the git remote to have an initial branch.
    git -C "$PROJECT" push -u origin HEAD >/dev/null 2>&1
    if [ "${1:-}" = "--audit" ]; then
        ( cd "$PROJECT" && "$AUDIT" . >/dev/null 2>&1 )
    fi
}

# Read a scalar from the fixture's metadata.json.
meta() { jq -r ".$1 // empty" "$PROJECT/.beads/metadata.json"; }

# The single flat dolt.auto-push line (empty if absent/duplicated).
autopush_line() { grep -E '^dolt\.auto-push:' "$PROJECT/.beads/config.yaml" || true; }

# Content signature of the issue set, stable across a byte-identical DB copy.
issue_sig() { ( cd "$PROJECT" && bd list --json 2>/dev/null | jq -Sc 'sort_by(.id) | map({id, status})' ); }

# Guarded recursive delete — refuses empty / root / $HOME.
safe_rm() {
    case "${1:-}" in
        ""|/|"$HOME"|"$HOME"/) return 0 ;;
        *) rm -rf "$1" ;;
    esac
}

# Standard teardown: stop the fixture server (scoped), remove PROJECT + ORIGIN,
# and sweep any bd-mode temp backups this run left in TMPDIR.
bdt_teardown() {
    cd "$BD_TESTS_BASE" 2>/dev/null || cd / || true   # never sit inside the dir we delete
    if [ -n "${PROJECT:-}" ] && [ -d "$PROJECT/.beads" ]; then
        ( cd "$PROJECT" && bd dolt stop --force >/dev/null 2>&1 ) || true
    fi
    safe_rm "${PROJECT:-}"
    safe_rm "${ORIGIN:-}"
    # bd-mode writes backups to ${TMPDIR:-/tmp}/bd-mode-backup-<db>-<mode>.XXXX
    local db="${BDT_DB:-}"
    if [ -n "$db" ]; then
        rm -rf "${TMPDIR:-/tmp}"/bd-mode-backup-"$db"-* 2>/dev/null || true
    fi
}
