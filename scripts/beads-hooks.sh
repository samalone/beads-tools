#!/usr/bin/env bash
#
# beads-hooks.sh — install/verify the beads-tools git-hook sync sections.
#
#   beads-hooks.sh install [beads-dir]   ensure beads hooks + our sync sections
#   beads-hooks.sh check   [beads-dir]   verify they are in place (exit 0 = ok)
#
# What it manages, on top of `bd hooks install --beads`:
#   * pre-push  -> `bd dolt commit && bd dolt push` when pushing to origin
#   * post-merge -> `bd dolt pull` after a git pull/merge
# Both are mode-INDEPENDENT (the primary durability path in server mode, a cheap
# guaranteed sync point in embedded mode), non-blocking (never fail a git op),
# and timeout-guarded. Our lines live OUTSIDE beads' own integration markers, so
# `bd hooks install` preserves them across bd upgrades.
#
set -euo pipefail

PROG=beads-hooks
BEGIN_MARK='# --- BEGIN BEADS-TOOLS SYNC (managed by beads-tools; edits here are overwritten) ---'
END_MARK='# --- END BEADS-TOOLS SYNC ---'

die()  { printf '%s: error: %s\n'   "$PROG" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }

# ---- payloads --------------------------------------------------------------
pre_push_body() {
    cat <<'EOF'
# Sync Beads Dolt data to the remote whenever code is pushed to origin.
# Non-blocking by policy: this section never fails a git push.
if command -v bd >/dev/null 2>&1; then
  case "${1:-origin}" in
    origin|"")
      _bdt_to=${BEADS_HOOK_TIMEOUT:-120}
      # Bound every Dolt call so a stalled remote can never hang git. Falls back
      # to perl's alarm; if no timeout mechanism exists at all, skip (return 124)
      # rather than run unbounded.
      _bdt() {
        if command -v timeout >/dev/null 2>&1; then timeout "$_bdt_to" "$@"
        elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$_bdt_to" "$@"
        elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$_bdt_to" "$@"
        else echo "beads-tools: no timeout helper; skipping Dolt sync" >&2; return 124; fi
      }
      _bdt bd dolt commit -m "beads-tools: pre-push sync" >/dev/null 2>&1 || true
      if _bdt bd dolt push >/dev/null 2>&1; then
        echo "beads-tools: pushed Dolt issue data (refs/dolt/data)" >&2
      else
        echo "beads-tools: 'bd dolt push' skipped/failed — continuing with git push" >&2
      fi
      ;;
  esac
fi
EOF
}

post_merge_body() {
    cat <<'EOF'
# Refresh Beads Dolt data from the remote after a git pull/merge. Non-blocking.
if command -v bd >/dev/null 2>&1; then
  _bdt_to=${BEADS_HOOK_TIMEOUT:-120}
  # Bound the pull so a stalled remote can never hang git; skip if no timeout
  # mechanism exists rather than run unbounded.
  _bdt() {
    if command -v timeout >/dev/null 2>&1; then timeout "$_bdt_to" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$_bdt_to" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$_bdt_to" "$@"
    else echo "beads-tools: no timeout helper; skipping Dolt sync" >&2; return 124; fi
  }
  if _bdt bd dolt pull >/dev/null 2>&1; then
    echo "beads-tools: pulled Dolt issue data (refs/dolt/data)" >&2
  else
    echo "beads-tools: 'bd dolt pull' skipped/failed — continuing" >&2
  fi
fi
EOF
}

# ---- helpers ---------------------------------------------------------------

# Strip any existing beads-tools block (inclusive of markers) from a file.
strip_block() {
    awk '
        /^# --- BEGIN BEADS-TOOLS SYNC/ { skip=1 }
        skip==0 { print }
        /^# --- END BEADS-TOOLS SYNC/   { skip=0 }
    ' "$1"
}

# ensure_block <hook-file> <body-fn>: (re)write our marked section at end of file.
ensure_block() {
    local file="$1" body_fn="$2" tmp
    if [ ! -f "$file" ]; then
        printf '#!/usr/bin/env sh\n' > "$file"
        chmod +x "$file"
    fi
    # Refuse to rewrite a file with unbalanced markers — stripping a lone BEGIN
    # would delete everything after it and silently truncate the hook.
    local nb ne
    nb=$(grep -c '^# --- BEGIN BEADS-TOOLS SYNC' "$file" 2>/dev/null || true)
    ne=$(grep -c '^# --- END BEADS-TOOLS SYNC'   "$file" 2>/dev/null || true)
    [ "${nb:-0}" = "${ne:-0}" ] || die "unbalanced beads-tools markers in $file (begin=$nb end=$ne) — fix by hand"
    tmp="$file.bdt.$$"
    # strip our old block, then trim trailing blank lines so reinstalls are
    # byte-idempotent (otherwise a blank line accumulates before the block each run)
    strip_block "$file" | awk '
        { buf[NR]=$0 }
        END { last=NR; while (last>0 && buf[last] ~ /^[[:space:]]*$/) last--;
              for (i=1;i<=last;i++) print buf[i] }
    ' > "$tmp"
    # single blank separator line before our block (only if the file is non-empty).
    # Computed BEFORE the append redirect below so we never read "$tmp" inside the
    # same command that writes it (avoids SC2094 read/write-in-pipeline).
    local sep=''
    [ -s "$tmp" ] && sep=$'\n'
    {
        printf '%s' "$sep"
        printf '%s\n' "$BEGIN_MARK"
        "$body_fn"
        printf '%s\n' "$END_MARK"
    } >> "$tmp"
    mv -f "$tmp" "$file"
    chmod +x "$file"
}

hooks_dir_for() {   # echo the active hooks dir; prefer core.hooksPath, else .beads/hooks
    local beadsdir="$1" hp
    hp=$(git -C "$beadsdir/.." config --get core.hooksPath 2>/dev/null || true)
    if [ -n "$hp" ]; then
        case "$hp" in /*) printf '%s' "$hp" ;; *) printf '%s/%s' "$(git -C "$beadsdir/.." rev-parse --show-toplevel)" "$hp" ;; esac
    else
        printf '%s/hooks' "$beadsdir"
    fi
}

# ---- commands --------------------------------------------------------------
cmd_install() {
    local beadsdir="$1"
    # 1. Ensure beads' own hooks + core.hooksPath (idempotent; preserves our block).
    bd -C "$beadsdir/.." hooks install --beads >/dev/null 2>&1 \
        || warn "'bd hooks install --beads' returned non-zero (continuing)"
    local hd; hd=$(hooks_dir_for "$beadsdir")
    [ -d "$hd" ] || die "hooks dir not found: $hd (is bd hooks install working?)"
    ensure_block "$hd/pre-push"   pre_push_body
    ensure_block "$hd/post-merge" post_merge_body
    printf '%s: installed sync sections in %s/{pre-push,post-merge}\n' "$PROG" "$hd"
}

cmd_check() {
    local beadsdir="$1" hd rc=0
    hd=$(hooks_dir_for "$beadsdir")
    for h in pre-push post-merge; do
        if [ ! -f "$hd/$h" ] || ! grep -q 'BEADS-TOOLS SYNC' "$hd/$h"; then
            warn "missing beads-tools sync section in $hd/$h"
            rc=1
        fi
    done
    [ "$rc" = 0 ] && printf '%s: sync hooks present in %s\n' "$PROG" "$hd"
    return "$rc"
}

# ---- main ------------------------------------------------------------------
cmd="${1:-}"; beadsdir="${2:-$PWD/.beads}"
[ -d "$beadsdir" ] || die "no .beads directory at: $beadsdir"
case "$cmd" in
    install) cmd_install "$beadsdir" ;;
    check)   cmd_check   "$beadsdir" ;;
    *)       printf 'usage: %s {install|check} [beads-dir]\n' "$PROG" >&2; exit 2 ;;
esac
