#!/usr/bin/env bats
#
# inject-beads-workflow.sh: emit the shared guidance only in beads projects.
# Pure/fast — no bd, no Dolt.

load helpers/setup

setup() {
    command -v git >/dev/null 2>&1 || skip "git not found"
    [ -f "$REPO_ROOT/shared/beads-pr-workflow.md" ] || skip "shared doc missing"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"          # where the shared doc lives
    # inject is pure shell (no bd), so use the system temp — deliberately NOT
    # under $HOME, whose own .beads dir would be found by the up-walk and break
    # the negative case.
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/bdt-inj.XXXXXX")"
}

teardown() {
    cd "$BD_TESTS_BASE" 2>/dev/null || cd / || true
    safe_rm "${WORK:-}"
}

@test "inject: emits the shared doc when a .beads dir is present" {
    mkdir -p "$WORK/.beads"
    run env CLAUDE_PROJECT_DIR="$WORK" sh "$INJECT_SH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Beads — session guidance"* ]]
}

@test "inject: emits the shared doc from a nested subdirectory (walks up)" {
    mkdir -p "$WORK/.beads" "$WORK/a/b/c"
    run env CLAUDE_PROJECT_DIR="$WORK/a/b/c" sh "$INJECT_SH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Beads — session guidance"* ]]
}

@test "inject: emits nothing and exits 0 when no .beads is found" {
    # Guard against an unexpected .beads on an ancestor path (e.g. a stray one in
    # the temp root) so the negative assertion is meaningful.
    local d="$WORK"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        [ -d "$d/.beads" ] && skip "ancestor $d has a .beads dir"
        d="$(dirname "$d")"
    done
    run env CLAUDE_PROJECT_DIR="$WORK" sh "$INJECT_SH"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "inject: drains stdin without blocking" {
    mkdir -p "$WORK/.beads"
    run bash -c "printf '{\"hook\":\"payload\"}' | env CLAUDE_PROJECT_DIR='$WORK' sh '$INJECT_SH'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Beads — session guidance"* ]]
}
