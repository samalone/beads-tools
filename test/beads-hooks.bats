#!/usr/bin/env bats
#
# beads-hooks.sh: idempotent install, origin-scoped sync, marker safety.

load helpers/setup

setup() {
    require_tools
    make_project
    HD="$PROJECT/.beads/hooks"
}

teardown() {
    bdt_teardown
}

@test "hooks: install is byte-idempotent" {
    run bash -c "'$HOOKS_SH' install '$PROJECT/.beads'"
    [ "$status" -eq 0 ]
    local a; a="$(cat "$HD/pre-push" "$HD/post-merge")"
    run bash -c "'$HOOKS_SH' install '$PROJECT/.beads'"
    [ "$status" -eq 0 ]
    local b; b="$(cat "$HD/pre-push" "$HD/post-merge")"
    [ "$a" = "$b" ]                                          # no drift on reinstall
    [ "$(grep -c 'BEGIN BEADS-TOOLS SYNC' "$HD/pre-push")" -eq 1 ]
    [ "$(grep -c 'BEGIN BEADS-TOOLS SYNC' "$HD/post-merge")" -eq 1 ]
}

@test "hooks: check succeeds after install, fails when a section is missing" {
    bash -c "'$HOOKS_SH' install '$PROJECT/.beads'" >/dev/null
    run bash -c "'$HOOKS_SH' check '$PROJECT/.beads'"
    [ "$status" -eq 0 ]

    # remove our block from pre-push -> check must fail
    grep -v 'BEADS-TOOLS SYNC' "$HD/pre-push" > "$HD/pp.tmp" && mv "$HD/pp.tmp" "$HD/pre-push"
    run bash -c "'$HOOKS_SH' check '$PROJECT/.beads'"
    [ "$status" -ne 0 ]
}

@test "hooks: pre-push is origin-scoped and skips other remotes" {
    bash -c "'$HOOKS_SH' install '$PROJECT/.beads'" >/dev/null
    # A non-origin remote name must not trigger a Dolt push (case falls through).
    run bash -c "cd '$PROJECT' && sh '$HD/pre-push' upstream git@example.com:x/y.git"
    [ "$status" -eq 0 ]
    [[ "$output" != *"pushed Dolt issue data"* ]]
}

@test "hooks: our block survives a 'bd hooks install' and stays outside beads markers" {
    bash -c "'$HOOKS_SH' install '$PROJECT/.beads'" >/dev/null
    ( cd "$PROJECT" && bd hooks install --beads >/dev/null 2>&1 ) || true
    run bash -c "'$HOOKS_SH' check '$PROJECT/.beads'"
    [ "$status" -eq 0 ]
    # if beads writes its own integration markers, ours must not be nested inside
    if grep -q 'BEGIN BEADS INTEGRATION' "$HD/pre-push"; then
        run awk '
            /BEGIN BEADS INTEGRATION/ { inb=1 }
            /BEGIN BEADS-TOOLS SYNC/ && inb { print "NESTED"; exit }
            /END BEADS INTEGRATION/   { inb=0 }
        ' "$HD/pre-push"
        [[ "$output" != *"NESTED"* ]]
    fi
}

@test "hooks: refuses to rewrite a file with unbalanced markers" {
    bash -c "'$HOOKS_SH' install '$PROJECT/.beads'" >/dev/null
    # leave a lone BEGIN marker (no END) — stripping it would truncate the hook
    printf '\n# --- BEGIN BEADS-TOOLS SYNC (managed by beads-tools) ---\n' >> "$HD/pre-push"
    run bash -c "'$HOOKS_SH' install '$PROJECT/.beads'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unbalanced beads-tools markers"* ]]
}
