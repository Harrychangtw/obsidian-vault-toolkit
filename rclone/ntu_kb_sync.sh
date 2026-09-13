#!/usr/bin/env bash
#
# Two-way sync of the NTU knowledge base between this Mac and Google Drive, so
# PDFs can be annotated on an iPad (Preview / PDF Expert, editing in place via
# the Files app) and the marked-up files come back home.
#
#   ~/Documents/03-ntu-kb  <-->  gdrive:/00_archive/macbook-pro/03-ntu-kb-live
#
# This is deliberately NOT part of backup.sh. That script stays a one-way push
# of Documents/Desktop/Downloads and is left untouched; it keeps mirroring
# 03-ntu-kb into .../Documents and .../Documents_sync as before. Those two
# remote copies are pushed from the Mac only, so they never fight with the
# bisync path used here -- but they will drift from reality whenever an iPad
# edit lands, so treat 03-ntu-kb-live as the live copy and the others as
# point-in-time backup.
#
# Unlike `rclone sync`, `rclone bisync` keeps a state snapshot between runs so
# it can tell "changed here" from "deleted there". It is an advanced command:
# when it cannot reconcile the two sides it refuses to run rather than guess,
# and this script surfaces that instead of papering over it.
#
# Usage:
#   ntu_kb_sync.sh                 normal two-way sync
#   ntu_kb_sync.sh --dry-run       show what would change, touch nothing
#   ntu_kb_sync.sh --resync        rebuild the baseline (see notes below)
#   ntu_kb_sync.sh --ignore-dirty  sync even with uncommitted git changes
#
# Settings come from config.sh (see config.example.sh).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$REPO_ROOT/lib/config.sh"

# --- Settings ----------------------------------------------------------------

LOCAL_DIR="${NTU_KB_LOCAL:-$HOME/Documents/03-ntu-kb}"
REMOTE_SUBPATH="${NTU_KB_REMOTE_SUBPATH:-03-ntu-kb-live}"
REMOTE="${RCLONE_REMOTE}:${RCLONE_BASE_PATH}/${REMOTE_SUBPATH}"
FILTER_FILE="${NTU_KB_FILTER:-$REPO_ROOT/rclone/ntu-kb.filter}"

# Abort the run rather than propagate a mass deletion. This is a percentage of
# the files on a side; a stray "delete the whole folder" on the iPad trips it.
MAX_DELETE="${NTU_KB_MAX_DELETE:-10}"

# Git repos to check for uncommitted work, relative to LOCAL_DIR. Both are real
# repos with separate histories; 02-coursework is nested but not a submodule.
GIT_REPOS=("." "02-coursework")

LOG_DIR="${NTU_KB_LOG_DIR:-$HOME/.local/state/obsidian-vault-toolkit/ntu-kb-sync}"
LOCK_DIR="${TMPDIR:-/tmp}/ntu-kb-sync.lock"
KEEP_LOGS=20

# --- Argument parsing --------------------------------------------------------

DRY_RUN=0
RESYNC=0
IGNORE_DIRTY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1 ;;
    --resync)       RESYNC=1 ;;
    --ignore-dirty) IGNORE_DIRTY=1 ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^#\{0,1\} \{0,1\}//'
      exit 0 ;;
    *)
      echo "[ntu-kb] Unknown argument: $1 (try --help)" >&2
      exit 2 ;;
  esac
  shift
done

# --- Notifications -----------------------------------------------------------

send_discord() {
  [ -z "${DISCORD_WEBHOOK_URL:-}" ] && return 0
  curl -H "Content-Type: application/json" -X POST -d "$1" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 &
}

notify() {
  local message="$1"
  command -v terminal-notifier >/dev/null 2>&1 && \
    terminal-notifier -message "$message" -title "NTU KB Sync" -group "ntu-kb-sync" >/dev/null 2>&1
  echo "[ntu-kb] $message"
}

# Fail loudly on every path: Raycast runs this detached, so an error that only
# reaches stderr is an error nobody sees.
fail() {
  local message="$1"
  notify "❌ $message"
  send_discord "$(printf '{"embeds":[{"title":"❌ NTU KB Sync failed","description":%s,"color":15158332}]}' \
    "$(json_string "$message")")"
  exit 1
}

# Minimal JSON string escaper for the Discord payloads.
json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))' <<< "$1"
}

# --- Single-instance lock ----------------------------------------------------
# mkdir is atomic, which `[ -e ]` plus `touch` is not.

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -f "$LOCK_DIR/pid" ] && kill -0 "$(cat "$LOCK_DIR/pid")" 2>/dev/null; then
    notify "⏳ A sync is already running (pid $(cat "$LOCK_DIR/pid")). Nothing to do."
    exit 0
  fi
  echo "[ntu-kb] Clearing a stale lock at $LOCK_DIR"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" || fail "Could not acquire the lock at $LOCK_DIR"
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# --- Preflight ---------------------------------------------------------------

preflight() {
  command -v rclone >/dev/null 2>&1 || fail "rclone is not installed or not on PATH."

  local conf remotes
  conf="$(rclone config file 2>/dev/null | tail -n 1 || true)"
  if ! remotes="$(rclone listremotes 2>&1)"; then
    echo "[ntu-kb] rclone cannot read its config:" >&2
    printf '%s\n' "$remotes" | sed 's/^/    /' >&2
    if [ -n "$conf" ] && [ -e "$conf" ] && [ ! -r "$conf" ]; then
      echo "[ntu-kb] Fix with: sudo chown \"$(whoami)\" \"$conf\" && chmod 600 \"$conf\"" >&2
    fi
    fail "rclone config is unreadable."
  fi
  printf '%s\n' "$remotes" | grep -qx "${RCLONE_REMOTE}:" \
    || fail "Remote '${RCLONE_REMOTE}:' is not configured in $conf."

  [ -d "$LOCAL_DIR" ] || fail "Local KB not found at $LOCAL_DIR"
  [ -f "$FILTER_FILE" ] || fail "Filter file not found at $FILTER_FILE"

  # bisync refuses to create Path2, so make sure it exists on a first run.
  if ! rclone lsjson "$REMOTE" --stat >/dev/null 2>&1; then
    if [ "$RESYNC" -eq 1 ]; then
      echo "[ntu-kb] Remote path does not exist yet, creating $REMOTE"
      [ "$DRY_RUN" -eq 1 ] || rclone mkdir "$REMOTE" || fail "Could not create $REMOTE"
    else
      fail "$REMOTE does not exist. Run once with --resync to establish it."
    fi
  fi
}

# Uncommitted work in either repo means a sync could interleave iPad edits with
# a half-finished commit. Only TRACKED changes count: untracked files are the
# normal state here (new PDFs arrive all the time) and blocking on them would
# make the script refuse to run almost every time.
check_git_clean() {
  [ "$IGNORE_DIRTY" -eq 1 ] && return 0
  local rel repo dirty=()
  for rel in "${GIT_REPOS[@]}"; do
    repo="$LOCAL_DIR/$rel"
    [ -d "$repo/.git" ] || continue
    if ! git -C "$repo" diff --quiet HEAD 2>/dev/null; then
      dirty+=("$rel")
    fi
  done
  if [ ${#dirty[@]} -gt 0 ]; then
    echo "[ntu-kb] Uncommitted changes to tracked files in: ${dirty[*]}" >&2
    for rel in "${dirty[@]}"; do
      echo "--- $rel ---" >&2
      git -C "$LOCAL_DIR/$rel" status --short --untracked-files=no >&2
    done
    echo "[ntu-kb] Commit or stash first, or re-run with --ignore-dirty." >&2
    fail "Aborted: uncommitted git changes in ${dirty[*]}. Nothing was synced."
  fi
}

preflight
check_git_clean

# --- Run bisync --------------------------------------------------------------

mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
# Build the suffix with plain ifs. Do NOT inline `$([ x ] && echo y)` here: under
# `set -e` an assignment inherits the status of its last command substitution, so
# a false test would abort the script with no output and no log at all.
LOG_SUFFIX=""
if [ "$DRY_RUN" -eq 1 ]; then LOG_SUFFIX="${LOG_SUFFIX}-dryrun"; fi
if [ "$RESYNC" -eq 1 ]; then LOG_SUFFIX="${LOG_SUFFIX}-resync"; fi
LOG_FILE="$LOG_DIR/${STAMP}${LOG_SUFFIX}.log"
START_TIME=$(date +%s)

BISYNC_ARGS=(
  "$LOCAL_DIR" "$REMOTE"
  --filters-file "$FILTER_FILE"
  # Newer file wins; the older one is kept as `name.conflict1.ext` rather than
  # being thrown away, so a genuine both-sides edit never loses bytes.
  --conflict-resolve newer
  --conflict-loser num
  --conflict-suffix conflict
  --max-delete "$MAX_DELETE"
  --create-empty-src-dirs
  # Recover from an interrupted run without demanding a full --resync.
  --resilient
  --recover
  # Google Docs/Sheets have no real file to download and only produce errors.
  --drive-skip-gdocs
  --transfers 8
  --checkers 16
  --verbose
  --log-file "$LOG_FILE"
)

[ "$DRY_RUN" -eq 1 ] && BISYNC_ARGS+=(--dry-run)
if [ "$RESYNC" -eq 1 ]; then
  # On a baseline rebuild, the Mac is authoritative for content, but nothing on
  # the remote is deleted -- a remote-only file is pulled down instead.
  BISYNC_ARGS+=(--resync --resync-mode newer)
fi

[ "$DRY_RUN" -eq 1 ] || notify "🔄 Syncing NTU KB with Drive…"

set +e
rclone bisync "${BISYNC_ARGS[@]}"
EXIT_CODE=$?
set -e

DURATION=$(( $(date +%s) - START_TIME ))

# --- Report ------------------------------------------------------------------

# bisync logs one line per queued operation, e.g.
#   INFO : - Path1  Queue copy to Path2  - <path>
# Path1 is the Mac, Path2 is Drive.
count_matches() {
  grep -cE "$1" "$LOG_FILE" 2>/dev/null || true
}

UPLOADED=$(count_matches 'Queue copy to Path2')
DOWNLOADED=$(count_matches 'Queue copy to Path1')
DELETED=$(count_matches 'Queue delete')
# Exactly one of these NOTICE lines per real conflict. Do NOT grep for the bare
# word "conflict": it also appears in the rename lines, the winner/loser lines
# and the copy of the renamed file, which inflates the count several times over.
CONFLICTS=$(count_matches 'New or changed in both paths')

# A --resync does not plan queues, it just transfers, so it logs `Copied (new)`
# with no direction. Count those instead of reporting a misleading 0 in / 0 out.
TRANSFERRED=$(count_matches ': (Copied|Updated|Deleted)')

# Name the conflicted files: knowing *which* ones need a look is the whole value.
CONFLICT_FILES="$(grep -E 'New or changed in both paths' "$LOG_FILE" 2>/dev/null \
  | sed -E 's/.*New or changed in both paths[[:space:]]+-[[:space:]]*//' | head -15 || true)"

# Name the files that came down from the iPad -- the whole point of the run.
PULLED_FILES="$(grep -E 'Queue copy to Path1' "$LOG_FILE" 2>/dev/null \
  | sed -E 's/.*Queue copy to Path1[[:space:]]+-[[:space:]]*//' \
  | sed "s|^$LOCAL_DIR/||" | head -15 || true)"

if [ "$EXIT_CODE" -eq 0 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "[ntu-kb] DRY RUN — nothing was changed. Would have:"
    echo "         ${DOWNLOADED} file(s) Drive → Mac, ${UPLOADED} file(s) Mac → Drive, ${DELETED} deletion(s)."
    if [ -n "$PULLED_FILES" ]; then
      echo "         Incoming:"
      printf '%s\n' "$PULLED_FILES" | sed 's/^/           /'
    fi
    echo "[ntu-kb] Full log: $LOG_FILE"
    exit 0
  fi

  if [ "$RESYNC" -eq 1 ]; then
    SUMMARY="baseline rebuilt, ${TRANSFERRED} file(s) transferred"
  else
    SUMMARY="⬇ ${DOWNLOADED} in, ⬆ ${UPLOADED} out"
  fi
  [ "$DELETED" -gt 0 ]   && SUMMARY="$SUMMARY, ${DELETED} deleted"
  [ "$CONFLICTS" -gt 0 ] && SUMMARY="$SUMMARY, ⚠️ ${CONFLICTS} conflict(s) kept as .conflictN"
  notify "✅ NTU KB synced — ${SUMMARY} (${DURATION}s)"

  if [ -n "$PULLED_FILES" ]; then
    echo "[ntu-kb] Came down from Drive:"
    printf '%s\n' "$PULLED_FILES" | sed 's/^/           /'
  fi

  if [ -n "$CONFLICT_FILES" ]; then
    echo "[ntu-kb] Changed on BOTH sides. The newer copy kept the name; the older"
    echo "         one is beside it with .conflictN appended (after the extension,"
    echo "         so it will not open by double-click until you rename it):"
    printf '%s\n' "$CONFLICT_FILES" | sed 's/^/           /'
  fi

  if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    pulled_field=""
    if [ -n "$PULLED_FILES" ]; then
      list="$(printf '%s' "$PULLED_FILES" | sed 's/^/• `/; s/$/`/' | paste -sd '\n' -)"
      pulled_field=", {\"name\": \"Pulled from Drive\", \"value\": $(json_string "$list")}"
    fi
    if [ -n "$CONFLICT_FILES" ]; then
      clist="$(printf '%s' "$CONFLICT_FILES" | sed 's/^/• `/; s/$/`/')"
      pulled_field="${pulled_field}, {\"name\": \"Changed on both sides\", \"value\": $(json_string "$clist")}"
    fi
    color=$([ "$CONFLICTS" -gt 0 ] && echo 16744192 || echo 3066993)
    send_discord "$(cat <<EOF
{
  "embeds": [{
    "title": "$([ "$CONFLICTS" -gt 0 ] && echo '⚠️' || echo '✅') NTU KB Sync",
    "description": "Two-way sync of \`03-ntu-kb\` finished.",
    "color": ${color},
    "fields": [
      {"name": "Drive → Mac", "value": "${DOWNLOADED}", "inline": true},
      {"name": "Mac → Drive", "value": "${UPLOADED}", "inline": true},
      {"name": "Conflicts", "value": "${CONFLICTS}", "inline": true},
      {"name": "Deletions", "value": "${DELETED}", "inline": true},
      {"name": "Duration", "value": "${DURATION}s", "inline": true}
      ${pulled_field}
    ],
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
  }]
}
EOF
)"
  fi
else
  # bisync stops instead of guessing. The two cases worth distinguishing are a
  # missing/stale baseline (needs --resync) and a refused mass deletion.
  if grep -qiE 'must run --resync|cannot find prior|filters.*chang|prior listing.*(missing|not found)' "$LOG_FILE" 2>/dev/null; then
    REASON="baseline is missing or the filter file changed"
    ADVICE="Review the log, then rebuild the baseline with: $0 --resync"
  elif grep -qiE 'max-delete|too many deletes|deletes exceed' "$LOG_FILE" 2>/dev/null; then
    REASON="it would delete more than ${MAX_DELETE}% of the files on one side"
    ADVICE="Check which side lost files before doing anything. Nothing was deleted."
  else
    REASON="rclone bisync exited $EXIT_CODE"
    ADVICE="See the log for the failing operation."
  fi

  echo >&2
  echo "[ntu-kb] Sync aborted: $REASON" >&2
  echo "[ntu-kb] $ADVICE" >&2
  echo "[ntu-kb] Log: $LOG_FILE" >&2
  tail -20 "$LOG_FILE" >&2 2>/dev/null || true

  notify "🛑 NTU KB sync stopped — $REASON"
  send_discord "$(cat <<EOF
{
  "embeds": [{
    "title": "🛑 NTU KB Sync stopped",
    "description": "bisync refused to run rather than guess. **Nothing was changed.**",
    "color": 15158332,
    "fields": [
      {"name": "Reason", "value": $(json_string "$REASON")},
      {"name": "What to do", "value": $(json_string "$ADVICE")},
      {"name": "Log", "value": "\`${LOG_FILE}\`"}
    ],
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
  }]
}
EOF
)"
fi

# Trim old logs.
ls -1t "$LOG_DIR"/*.log 2>/dev/null | tail -n +$((KEEP_LOGS + 1)) | xargs -I{} rm -f {} 2>/dev/null || true

echo "[ntu-kb] Log: $LOG_FILE"
exit "$EXIT_CODE"
