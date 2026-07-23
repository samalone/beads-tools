#!/usr/bin/env bats
#
# beads-config-audit.sh JSONL / secret hygiene (review finding B3).

load helpers/setup

setup() {
    require_tools
    make_project
}

teardown() {
    bdt_teardown
}

@test "hygiene: a tracked issues.jsonl is removed and gitignored" {
    printf '{"id":"x"}\n' > "$PROJECT/.beads/issues.jsonl"
    git -C "$PROJECT" add -f .beads/issues.jsonl
    git -C "$PROJECT" commit -q -m "seed tracked issues.jsonl"

    run bash -c "cd '$PROJECT' && '$AUDIT' ."
    [ "$status" -eq 0 ]

    run git -C "$PROJECT" ls-files --error-unmatch .beads/issues.jsonl
    [ "$status" -ne 0 ]                                       # untracked
    [ ! -f "$PROJECT/.beads/issues.jsonl" ]                   # and removed (regenerable)
    grep -qxF 'issues.jsonl' "$PROJECT/.beads/.gitignore"
}

@test "hygiene: interactions.jsonl is untracked but kept on disk" {
    run bash -c "cd '$PROJECT' && '$AUDIT' ."
    [ "$status" -eq 0 ]
    run git -C "$PROJECT" ls-files --error-unmatch .beads/interactions.jsonl
    [ "$status" -ne 0 ]
    [ -f "$PROJECT/.beads/interactions.jsonl" ]
    grep -qxF 'interactions.jsonl' "$PROJECT/.beads/.gitignore"
}

@test "hygiene: DB dir, credential key, and *.db are gitignored and never tracked" {
    printf 'secret\n' > "$PROJECT/.beads/.beads-credential-key"
    run bash -c "cd '$PROJECT' && '$AUDIT' ."
    [ "$status" -eq 0 ]

    local gi="$PROJECT/.beads/.gitignore"
    grep -qxF 'embeddeddolt/' "$gi"
    grep -qxF '.beads-credential-key' "$gi"
    grep -qxF '*.db' "$gi"

    # nothing sensitive got staged/committed
    run git -C "$PROJECT" ls-files --error-unmatch .beads/.beads-credential-key
    [ "$status" -ne 0 ]
    [ -z "$(git -C "$PROJECT" ls-files .beads/embeddeddolt)" ]
}
