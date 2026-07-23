#!/usr/bin/env bats
#
# bd-mode: embedded<->server switching, rollback, and input guards.

load helpers/setup

setup() {
    require_tools
}

teardown() {
    bdt_teardown
}

# --- round trip -------------------------------------------------------------

@test "bd-mode: embedded->server->embedded flips auto-push, preserves issues" {
    make_project --audit
    ( cd "$PROJECT" && bd create --title="round trip" --type=task -p 2 >/dev/null 2>&1 )
    local before; before="$(issue_sig)"
    [ "$(meta dolt_mode)" = embedded ]
    [ "$(autopush_line)" = "dolt.auto-push: true" ]      # embedded: single-writer durability on

    run bash -c "cd '$PROJECT' && env -u BEADS_DOLT_AUTO_START '$BD_MODE' server"
    [ "$status" -eq 0 ]
    [ "$(meta dolt_mode)" = server ]
    [ "$(autopush_line)" = "dolt.auto-push: false" ]     # server: avoid concurrent auto-push
    [ -d "$PROJECT/.beads/dolt" ]
    [ ! -d "$PROJECT/.beads/embeddeddolt" ]              # old-mode data dir removed

    run bash -c "cd '$PROJECT' && env -u BEADS_DOLT_AUTO_START '$BD_MODE' embedded"
    [ "$status" -eq 0 ]
    [ "$(meta dolt_mode)" = embedded ]
    [ "$(autopush_line)" = "dolt.auto-push: true" ]
    [ -d "$PROJECT/.beads/embeddeddolt" ]
    [ ! -d "$PROJECT/.beads/dolt" ]

    # exactly one flat auto-push line, and the issue set is unchanged
    [ "$(grep -cE '^dolt\.auto-push:' "$PROJECT/.beads/config.yaml")" -eq 1 ]
    [ "$(issue_sig)" = "$before" ]
}

# --- rollback ---------------------------------------------------------------

@test "bd-mode: a failed switch rolls back mode, config, and data" {
    make_project --audit
    BDT_DB="$(meta dolt_database)"                        # for backup sweep in teardown
    ( cd "$PROJECT" && bd create --title="rollback" --type=task -p 2 >/dev/null 2>&1 )
    local before; before="$(issue_sig)"

    # Inject a post-MUTATED failure: pre-create the target data dir as a FILE so
    # `mkdir -p "$DST"` fails after the config/mode were already flipped.
    : > "$PROJECT/.beads/dolt"

    run bash -c "cd '$PROJECT' && env -u BEADS_DOLT_AUTO_START '$BD_MODE' server"
    [ "$status" -ne 0 ]
    [[ "$output" == *"rolling back to 'embedded' mode"* ]]

    # everything restored
    [ "$(meta dolt_mode)" = embedded ]
    [ "$(autopush_line)" = "dolt.auto-push: true" ]
    [ -d "$PROJECT/.beads/embeddeddolt" ]
    [ "$(issue_sig)" = "$before" ]
}

@test "bd-mode: a failed switch from server restarts the source server" {
    make_project --audit
    BDT_DB="$(meta dolt_database)"
    run bash -c "cd '$PROJECT' && env -u BEADS_DOLT_AUTO_START '$BD_MODE' server"  # server mode first
    [ "$status" -eq 0 ]
    [ "$(meta dolt_mode)" = server ]

    # Inject failure on the server->embedded switch (target = embeddeddolt).
    : > "$PROJECT/.beads/embeddeddolt"
    run bash -c "cd '$PROJECT' && env -u BEADS_DOLT_AUTO_START '$BD_MODE' embedded"
    [ "$status" -ne 0 ]
    [ "$(meta dolt_mode)" = server ]                           # rolled back to server
    # the source server was stopped to quiesce, then brought back up on rollback.
    # Exclude the "not running" substring so a down server can't pass this.
    run bd -C "$PROJECT" dolt status
    [[ "$output" == *"running"* && "$output" != *"not running"* ]]
}

# --- guards -----------------------------------------------------------------

@test "bd-mode: rejects an empty dolt_database" {
    make_project
    jq '.dolt_database=""' "$PROJECT/.beads/metadata.json" > "$PROJECT/.beads/m.tmp"
    mv "$PROJECT/.beads/m.tmp" "$PROJECT/.beads/metadata.json"
    run bash -c "cd '$PROJECT' && '$BD_MODE'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"dolt_database is empty"* ]]
}

@test "bd-mode: rejects a traversal-laden dolt_database" {
    make_project
    jq '.dolt_database="../escape"' "$PROJECT/.beads/metadata.json" > "$PROJECT/.beads/m.tmp"
    mv "$PROJECT/.beads/m.tmp" "$PROJECT/.beads/metadata.json"
    run bash -c "cd '$PROJECT' && '$BD_MODE'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected characters"* ]]
}

@test "bd-mode: no-op when already in the requested mode" {
    make_project
    run bash -c "cd '$PROJECT' && '$BD_MODE' embedded"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already in 'embedded' mode"* ]]
    [ "$(meta dolt_mode)" = embedded ]
}

@test "bd-mode: unknown argument prints usage and exits 2" {
    make_project
    run bash -c "cd '$PROJECT' && '$BD_MODE' bogus"
    [ "$status" -eq 2 ]
    [[ "$output" == *"usage:"* ]]
}
