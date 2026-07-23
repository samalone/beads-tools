#!/usr/bin/env bash
#
# beads-config-audit.sh — deterministic audit + repair of a Beads (bd) project to
# the single-user Dolt workflow. This is the mechanical core; the companion
# `beads-config-audit` skill wraps it and handles the judgment gates below.
#
# Usage:  beads-config-audit.sh [--allow-migrate] [--no-commit] [project-dir]
#
# Exit codes (the skill/human handles the non-zero "gates"):
#   0   audited & clean
#   2   usage error
#   10  not a beads project (no .beads dir)
#   11  unsupported bd version (this script targets bd 1.1.x)
#   12  suspected pre-Dolt (0.x) / no Dolt data directory — needs migration, not this
#   13  pending schema migration — rerun with --allow-migrate (no remote) or migrate deliberately
#   15  durability gap — no git origin, or first `bd dolt push` failed
#   20  config file ambiguous after edit — needs a hand review
#
set -euo pipefail

PROG=beads-config-audit
ALLOW_MIGRATE=0
DO_COMMIT=1
PROJECT=""

# ---------------------------------------------------------------------------
die()   { printf '%s: error: %s\n'  "$PROG" "$*" >&2; exit 1; }
gate()  { local code="$1"; shift; printf '\nGATE(%s): %s\n' "$code" "$*" >&2; exit "$code"; }
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
note()  { printf 'NOTE: %s\n' "$*"; }
ok()    { printf '  ✓ %s\n' "$*"; }
head_() { printf '\n== %s ==\n' "$*"; }

need()  { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --allow-migrate) ALLOW_MIGRATE=1 ;;
        --no-commit)     DO_COMMIT=0 ;;
        -h|--help) printf 'usage: %s [--allow-migrate] [--no-commit] [project-dir]\n' "$PROG"; exit 0 ;;
        -*) die "unknown flag: $1" ;;
        *)  PROJECT="$1" ;;
    esac
    shift
done

need bd; need git; need jq
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ---------------------------------------------------------------------------
# 1. Identify the project
# ---------------------------------------------------------------------------
head_ "Identify"
[ -n "$PROJECT" ] || PROJECT="$PWD"
# Canonicalize to an absolute path: BEADS_DIR/META/CFG are derived from it and
# must stay valid after we `cd "$REPO_ROOT"` below (a relative arg would break).
PROJECT=$(cd "$PROJECT" 2>/dev/null && pwd) || die "cannot resolve project directory: $PROJECT"
BEADS_DIR="$PROJECT/.beads"
[ -d "$BEADS_DIR" ] || gate 10 "no .beads directory under $PROJECT"
REPO_ROOT=$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null) || die "not a git repository: $PROJECT"
cd "$REPO_ROOT"
META="$BEADS_DIR/metadata.json"
CFG="$BEADS_DIR/config.yaml"

VER=$(bd version 2>/dev/null | awk '{print $3; exit}')
case "$VER" in 1.1.*) ok "bd $VER" ;; *) gate 11 "unsupported bd version '$VER' (targets 1.1.x); re-verify commands before proceeding" ;; esac

[ -f "$META" ] || gate 12 "no $META — not a Dolt-backed beads project"
BACKEND=$(jq -r '.backend // .database // empty' "$META")
[ "$BACKEND" = dolt ] || gate 12 "backend='$BACKEND' (expected dolt) — possible pre-Dolt layout, needs migration not audit"
MODE=$(jq -r '.dolt_mode // "embedded"' "$META")
DB=$(jq -r '.dolt_database // empty' "$META")
DATA_DIR=$(bd -C "$REPO_ROOT" dolt show 2>/dev/null | awk -F': *' '/Data:/{print $2; exit}')
[ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ] || gate 12 "Dolt data dir not found (reported: '${DATA_DIR:-none}') — possible pre-Dolt/corrupt, stopping"
ok "mode=$MODE  database=$DB"
ok "data dir=$DATA_DIR"
[ "$MODE" = server ] && note "SERVER mode: auto-push will be left OFF. If this isn't a deliberate concurrent-agent setup, consider switching back to embedded (bd-mode embedded)."

# ---------------------------------------------------------------------------
# 2. Schema / migration state
# ---------------------------------------------------------------------------
head_ "Schema"
# Capture the output first, then match with a here-string. Do NOT pipe the bd
# call straight into `grep -q`: under `set -o pipefail`, grep -q matches on an
# early line of bd's multi-line output and closes the pipe, bd then dies with
# SIGPIPE, and pipefail makes the whole pipeline non-zero — inverting the test
# into a spurious gate-13. (Deterministic on fresh embedded inits; see bd-dqp.)
_schema=$(bd -C "$REPO_ROOT" migrate --dry-run 2>&1) || true
if grep -q 'Version matches' <<<"$_schema"; then
    ok "schema matches bd $VER"
else
    # Positively confirm "no remote" before auto-migrating: a FAILED remote
    # lookup must NOT be read as "no remote" (that would migrate a possibly
    # remote-backed DB). Only the explicit "no remotes" text counts.
    _rl=$(bd -C "$REPO_ROOT" dolt remote list 2>/dev/null) || _rl=""
    _no_remote=0; grep -qi 'no remotes' <<<"$_rl" && _no_remote=1
    if [ "$ALLOW_MIGRATE" = 1 ] && [ "$_no_remote" = 1 ]; then
        warn "pending migration, no remote, --allow-migrate set → backing up and migrating"
        bd -C "$REPO_ROOT" backup >/dev/null 2>&1 || warn "bd backup returned non-zero"
        bd -C "$REPO_ROOT" migrate >/dev/null 2>&1 || gate 13 "migration failed — inspect manually"
        ok "migrated"
    else
        gate 13 "pending schema migration. If no remote: rerun with --allow-migrate. If a remote exists: migrate deliberately as the single designated migrator, then 'bd dolt push', and 'bd bootstrap' other clones."
    fi
fi

# ---------------------------------------------------------------------------
# helpers for config editing (avoid buggy `bd config set` on nested YAML)
# ---------------------------------------------------------------------------
# Count how many representations of a dotted key exist (flat + nested-leaf).
config_count() {
    local key="$1" leaf="${1##*.}" ke; ke=$(printf '%s' "$key" | sed 's/\./\\./g')
    grep -cE "^${ke}:|^[[:space:]]+${leaf}:" "$CFG" 2>/dev/null || true
}

# Normalize a scalar key to a single flat dotted line "key: value".
ensure_config() {
    local key="$1" val="$2" leaf="${1##*.}" ns="${1%.*}" tmp
    [ -f "$CFG" ] || printf '' > "$CFG"
    tmp="$CFG.bdt.$$"
    # Drop every flat form and (only-under-the-right-parent) nested-leaf form,
    # then drop a now-empty ns header. keyre escapes regex metachars in the key
    # so the dot in e.g. "dolt.auto-push" is literal, and section tracking makes
    # the nested-leaf removal parent-aware (won't touch a same-named leaf under
    # a different block).
    local keyre; keyre=$(printf '%s' "$key" | sed 's/[][(){}.^$*+?|\\]/\\&/g')
    awk -v keyre="$keyre" -v leaf="$leaf" -v ns="$ns" '
        /^[^[:space:]#]/ {
            if ($0 ~ /^[A-Za-z0-9_.-]+:[[:space:]]*$/) { cur=$0; sub(/:.*/,"",cur) }
            else { cur="" }
        }
        $0 ~ "^" keyre ":"                          { next }
        ($0 ~ "^[[:space:]]+" leaf ":") && cur==ns  { next }
        { print }
    ' "$CFG" | awk -v ns="$ns" '
        { lines[NR]=$0 }
        END {
            for (n=1;n<=NR;n++) {
                l=lines[n]; h=l; sub(/:[[:space:]]*$/,"",h)
                if (l ~ /^[A-Za-z_]+:[[:space:]]*$/ && h==ns) {
                    nx=(n<NR)?lines[n+1]:""
                    if (nx !~ /^[[:space:]]/) continue   # childless header -> drop
                }
                print l
            }
        }
    ' > "$tmp"
    # ensure trailing newline, then append the single flat form
    [ -s "$tmp" ] && [ "$(tail -c1 "$tmp")" != "" ] && printf '\n' >> "$tmp"
    printf '%s: %s\n' "$key" "$val" >> "$tmp"
    mv -f "$tmp" "$CFG"
    # verify: bd agrees AND exactly one representation remains
    local got cnt; got=$(bd -C "$REPO_ROOT" config get "$key" 2>/dev/null || true)
    cnt=$(config_count "$key")
    if [ "$got" != "$val" ] || [ "${cnt:-0}" != 1 ]; then
        gate 20 "config key '$key' ambiguous after edit (get='$got', occurrences=$cnt) — review $CFG by hand"
    fi
    ok "$key = $val"
}

# ---------------------------------------------------------------------------
# 3. Durability first: ensure the Dolt remote + first push
# ---------------------------------------------------------------------------
head_ "Durability (remote + push)"
# "configured" = non-empty output that does not say "no remotes". Capture then
# test (a here-string, not a `grep -qv` pipe) to avoid the pipefail/SIGPIPE
# inversion that could misread a real remote as absent and re-add it.
_remotes=$(bd -C "$REPO_ROOT" dolt remote list 2>/dev/null) || _remotes=""
if [ -n "$_remotes" ] && ! grep -qi 'no remotes' <<<"$_remotes"; then
    ok "dolt remote already configured"
else
    ORIGIN=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)
    [ -n "$ORIGIN" ] || gate 15 "no dolt remote and no git 'origin' — cannot establish durability; leaving config untouched"
    bd -C "$REPO_ROOT" dolt remote add origin "$ORIGIN" >/dev/null 2>&1 || die "failed to add dolt remote"
    ok "added dolt remote origin -> $(printf '%s' "$ORIGIN" | sed -E 's#://[^/@]*@#://***@#')"
fi
bd -C "$REPO_ROOT" dolt commit -m "beads-config-audit: pre-push" >/dev/null 2>&1 || true
if ! bd -C "$REPO_ROOT" dolt push >/dev/null 2>&1; then
    gate 15 "'bd dolt push' failed — remote durability not established (is the git remote initialized?). Stopping before any JSONL removal."
fi
# Capture then test for non-empty (not `| grep -q .`, which can SIGPIPE-invert
# under pipefail and misreport a present ref as missing).
_ref=$(git -C "$REPO_ROOT" ls-remote origin refs/dolt/data 2>/dev/null) || _ref=""
[ -n "$_ref" ] || gate 15 "refs/dolt/data missing on remote after push"
ok "refs/dolt/data present on remote"

# ---------------------------------------------------------------------------
# 4. Apply preferred config
# ---------------------------------------------------------------------------
head_ "Config"
ensure_config export.auto false
ensure_config backup.git-push false
case "$MODE" in
    embedded) ensure_config dolt.auto-push true ;;
    server)   ensure_config dolt.auto-push false ;;
esac
AC=$(bd -C "$REPO_ROOT" config get dolt.auto-commit 2>/dev/null || echo '?')
ok "dolt.auto-commit = $AC (left at default)"

# JSONL hygiene -------------------------------------------------------------
head_ "JSONL hygiene"
gi="$BEADS_DIR/.gitignore"; [ -f "$gi" ] || gi="$REPO_ROOT/.gitignore"
add_ignore() { grep -qxF "$1" "$gi" 2>/dev/null || printf '%s\n' "$1" >> "$gi"; }

# issues.jsonl — remove entirely (regenerable), gitignore
if git -C "$REPO_ROOT" ls-files --error-unmatch .beads/issues.jsonl >/dev/null 2>&1; then
    git -C "$REPO_ROOT" rm -q .beads/issues.jsonl; ok "removed tracked issues.jsonl"
elif [ -f "$BEADS_DIR/issues.jsonl" ]; then
    rm -f "$BEADS_DIR/issues.jsonl"; ok "deleted untracked issues.jsonl"
fi
add_ignore "issues.jsonl"

# interactions.jsonl — keep the file, untrack it, gitignore
if git -C "$REPO_ROOT" ls-files --error-unmatch .beads/interactions.jsonl >/dev/null 2>&1; then
    git -C "$REPO_ROOT" rm -q --cached .beads/interactions.jsonl; ok "untracked interactions.jsonl (kept on disk)"
fi
add_ignore "interactions.jsonl"

# The Dolt DB dir, the machine credential key, and legacy *.db must NEVER be
# committed. Ensure they're ignored BEFORE the `git add -A` below, so a repair
# on a mis-configured project can't stage/commit (and then push) a secret.
data_base=$(basename "$DATA_DIR")
add_ignore "$data_base/"
add_ignore ".beads-credential-key"
add_ignore "*.db"
# If any are somehow already tracked, untrack them (keep on disk) so the commit
# removes them from the index rather than leaving a secret in history.
for p in ".beads/$data_base" ".beads/.beads-credential-key"; do
    if git -C "$REPO_ROOT" ls-files --error-unmatch "$p" >/dev/null 2>&1; then
        git -C "$REPO_ROOT" rm -q -r --cached "$p"; warn "untracked previously-committed $p"
    fi
done

# ---------------------------------------------------------------------------
# 5. Install git hooks (sync Dolt on push/pull) — mode-independent
# ---------------------------------------------------------------------------
head_ "Git hooks"
"$SELF_DIR/beads-hooks.sh" install "$BEADS_DIR" || warn "hook install reported an issue"

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------
head_ "Verify"
if bd -C "$REPO_ROOT" list >/dev/null 2>&1; then ok "bd list works"; else warn "bd list failed"; fi
if bd -C "$REPO_ROOT" vc status >/dev/null 2>&1; then ok "bd vc status works"; else warn "bd vc status failed"; fi
# gitignore assertions for the DB dir, credential, legacy db (ensured above)
for pat in "$data_base/" ".beads-credential-key" "*.db"; do
    if grep -qF "$pat" "$gi" 2>/dev/null; then ok "gitignored: $pat"; else warn "not gitignored: $pat (check $gi)"; fi
done
# capture-then-test avoids a pipefail/SIGPIPE inversion that could mis-report a
# tracked DB dir as untracked (grep -q exits early -> git dies -> pipeline fails)
if [ -n "$(git -C "$REPO_ROOT" ls-files "$DATA_DIR" 2>/dev/null | head -n1)" ]; then
    warn "DB dir is TRACKED — must not be committed"
else
    ok "DB dir not tracked"
fi

# ---------------------------------------------------------------------------
# 7. Commit the audit changes (no branch push)
# ---------------------------------------------------------------------------
if [ "$DO_COMMIT" = 1 ]; then
    # Stage only the paths we touched (so a pre-existing staged index isn't swept
    # in), and include root .gitignore ONLY if it exists — otherwise the pathspec
    # errors out and `|| true` would hide it, leaving the repair uncommitted.
    set -- .beads
    [ -f "$REPO_ROOT/.gitignore" ] && set -- "$@" .gitignore
    git -C "$REPO_ROOT" add -A -- "$@" 2>/dev/null || true
    if git -C "$REPO_ROOT" diff --cached --quiet -- "$@" 2>/dev/null; then
        ok "no changes to commit"
    else
        # Commit the staged index (NO pathspec). A pathspec commit
        # (`git commit -- <paths>`) rebuilds those paths from the WORKING TREE,
        # which silently drops the `git rm --cached` untrack of interactions.jsonl
        # (the file is deliberately kept on disk) — leaving it tracked forever and
        # making the next run abort on an empty `git commit`. The targeted staging
        # above already scoped the index to the paths we touched.
        git -C "$REPO_ROOT" commit -q -m "beads-config-audit: normalize config, hooks, and gitignore"
        ok "committed audit changes"
    fi
fi

head_ "Done"
printf 'OK: mode=%s, schema ok, remote current, hooks installed.\n' "$MODE"
