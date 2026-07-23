#!/usr/bin/env bats
#
# beads-config-audit.sh: idempotence, judgment gates, and config normalization.

load helpers/setup

setup() {
    require_tools
}

teardown() {
    bdt_teardown
}

# --- idempotence ------------------------------------------------------------

@test "audit: is idempotent and leaves a clean tree on the second run" {
    make_project
    run bash -c "cd '$PROJECT' && '$AUDIT' ."
    [ "$status" -eq 0 ]

    # interactions.jsonl is untracked but kept on disk
    run git -C "$PROJECT" ls-files --error-unmatch .beads/interactions.jsonl
    [ "$status" -ne 0 ]
    [ -f "$PROJECT/.beads/interactions.jsonl" ]

    # exactly one sync block in each hook (no accumulation)
    [ "$(grep -c 'BEGIN BEADS-TOOLS SYNC' "$PROJECT/.beads/hooks/pre-push")" -eq 1 ]
    [ "$(grep -c 'BEGIN BEADS-TOOLS SYNC' "$PROJECT/.beads/hooks/post-merge")" -eq 1 ]

    run bash -c "cd '$PROJECT' && '$AUDIT' ."
    [ "$status" -eq 0 ]
    [[ "$output" == *"no changes to commit"* ]]
    [ -z "$(git -C "$PROJECT" status --porcelain)" ]         # working tree clean
}

# --- gates (assert nothing destructive ran before the gate) -----------------

@test "audit: gate 10 when there is no .beads directory" {
    local d; d="$(mktemp -d "$BD_TESTS_BASE/bdt-bare.XXXXXX")"
    git init -q "$d"
    run bash -c "cd '$d' && '$AUDIT' ."
    [ "$status" -eq 10 ]
    safe_rm "$d"
}

@test "audit: gate 12 when the backend is not dolt" {
    make_project
    local head; head="$(git -C "$PROJECT" rev-parse HEAD)"
    jq '.backend="sqlite" | .database="sqlite"' "$PROJECT/.beads/metadata.json" > "$PROJECT/.beads/m.tmp"
    mv "$PROJECT/.beads/m.tmp" "$PROJECT/.beads/metadata.json"
    run bash -c "cd '$PROJECT' && '$AUDIT' ."
    [ "$status" -eq 12 ]
    [ -d "$PROJECT/.beads/embeddeddolt" ]                     # data untouched
    [ "$(git -C "$PROJECT" rev-parse HEAD)" = "$head" ]       # no commit made
}

@test "audit: gate 15 when there is no durability remote" {
    export BEADS_DOLT_AUTO_START=0
    PROJECT="$(mktemp -d "$BD_TESTS_BASE/bdt-noremote.XXXXXX")"
    git init -q "$PROJECT"
    fixture_identity "$PROJECT"
    ( cd "$PROJECT" && bd init >/dev/null 2>&1 )             # no origin, no push
    # Tolerate an unborn HEAD (bd init may not commit without a prior commit):
    # capture "" then compare "" afterward — the point is that no NEW commit was made.
    local head; head="$(git -C "$PROJECT" rev-parse --verify -q HEAD || true)"
    run bash -c "cd '$PROJECT' && '$AUDIT' ."
    [ "$status" -eq 15 ]
    [ -d "$PROJECT/.beads/embeddeddolt" ]                     # durability data intact
    [ "$(git -C "$PROJECT" rev-parse --verify -q HEAD || true)" = "$head" ]  # stopped before any commit
}

@test "audit: does not fold pre-existing staged changes into its commit" {
    make_project
    # The user stages an unrelated change before running the audit.
    echo "hello" > "$PROJECT/UNRELATED.txt"
    git -C "$PROJECT" add UNRELATED.txt
    run bash -c "cd '$PROJECT' && '$AUDIT' ."
    [ "$status" -eq 0 ]
    # The audit's own commit must NOT contain the user's unrelated file...
    run git -C "$PROJECT" show --stat --format= HEAD
    [[ "$output" != *"UNRELATED.txt"* ]]
    # ...and that change is preserved on disk (just no longer staged).
    [ -f "$PROJECT/UNRELATED.txt" ]
    run git -C "$PROJECT" status --porcelain UNRELATED.txt
    [[ -n "$output" ]]                                        # still a pending change
}

@test "audit: gate 20 (ambiguous config) is not deterministically reproducible" {
    skip "ensure_config always converges to a single flat line on bd 1.1.x; no reliable fixture to force gate 20"
}

# --- config normalization ---------------------------------------------------

@test "audit: normalizes dolt.auto-push to one flat line, sparing other blocks" {
    make_project
    # Seed messy representations: a nested child under dolt:, a stale flat line,
    # and a same-named leaf under an unrelated block that must survive.
    # (bd's config.yaml has no trailing newline; separate before appending.)
    printf '\n' >> "$PROJECT/.beads/config.yaml"
    cat >> "$PROJECT/.beads/config.yaml" <<'EOF'
dolt:
  auto-push: false
dolt.auto-push: false
other:
  auto-push: keepme
EOF
    run bash -c "cd '$PROJECT' && '$AUDIT' ."
    [ "$status" -eq 0 ]

    # exactly one flat line, set to the embedded value
    [ "$(grep -cE '^dolt\.auto-push:' "$PROJECT/.beads/config.yaml")" -eq 1 ]
    run grep -qxF "dolt.auto-push: true" "$PROJECT/.beads/config.yaml"
    [ "$status" -eq 0 ]
    # no nested dolt child left behind
    run grep -nE '^dolt:[[:space:]]*$' "$PROJECT/.beads/config.yaml"
    [ "$status" -ne 0 ]
    # the unrelated block's leaf is untouched, and sync.remote survives
    run grep -qE '^[[:space:]]+auto-push: keepme' "$PROJECT/.beads/config.yaml"
    [ "$status" -eq 0 ]
    run grep -qE '^sync\.remote:' "$PROJECT/.beads/config.yaml"
    [ "$status" -eq 0 ]
}
