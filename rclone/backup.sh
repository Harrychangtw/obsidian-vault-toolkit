#!/usr/bin/env bash
#
# Parallel rclone backup of local directories (plus mounted external volumes)
# to a cloud remote, orchestrated across tmux panes so every location syncs
# concurrently. Sends an optional Discord summary when finished.
#
# For each configured directory two passes run:
#   copy  -> <remote>:<base>/<name>        (additive archive, never deletes)
#   sync  -> <remote>:<base>/<name>_sync   (exact mirror, prunes deletions)
#
# Settings come from config.sh (see config.example.sh).

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/config.sh"

SESSION="sync_session"
TMUX="tmux -f /dev/null"
START_TIME=$(date +%s)

REMOTE_BASE="${RCLONE_REMOTE}:${RCLONE_BASE_PATH}"

# Shared excludes applied to every transfer.
# The patterns must stay quoted in the command text we send into the tmux
# panes: those panes run zsh, whose `nomatch` aborts a whole line when an
# unquoted glob (e.g. *.pyc) matches nothing. Literal quotes prevent globbing.
EXCLUDE_PATTERNS=(
  ".git/**"
  "node_modules/**"
  ".next/**"
  ".vercel/**"
  "dist/**"
  "build/**"
  ".venv/**"
  "__pycache__/**"
  "*.pyc"
  ".pytest_cache/**"
  ".mypy_cache/**"
  "*.egg-info/**"
  ".DS_Store"
  ".cache/**"
)
EXCLUDE_STR=""
for _pat in "${EXCLUDE_PATTERNS[@]}"; do
  EXCLUDE_STR+=" --exclude '${_pat}'"
done

# Function to send discord notifications (no-op if webhook unset)
send_discord_notification() {
  [ -z "${DISCORD_WEBHOOK_URL:-}" ] && return 0
  local payload="$1"
  curl -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 &
}

notify() {
  local message="$1"
  command -v terminal-notifier >/dev/null 2>&1 && \
    terminal-notifier -message "$message" -title "Rclone Sync" -group "rclone-sync"
  send_discord_notification "$(printf '{"content": "%s"}' "$message")"
}

# Check if the session already exists
if $TMUX has-session -t "$SESSION" 2>/dev/null; then
  echo "Session $SESSION already exists. Killing it."
  $TMUX kill-session -t "$SESSION"
  notify "⛔ Previous sync session terminated."
  sleep 2
  command -v terminal-notifier >/dev/null 2>&1 && terminal-notifier -remove "rclone-sync" >/dev/null 2>&1
  exit 0
fi

# Preflight: rclone must be installed, its config readable by the current user,
# and the configured remote present. Without this the failure only shows up as
# N tmux panes that each die instantly with
#   CRITICAL: Failed to load config file "...": permission denied
# which is easy to miss behind the pane layout. The usual cause is an earlier
# `sudo rclone config`, which leaves rclone.conf owned by root.
preflight() {
  if ! command -v rclone >/dev/null 2>&1; then
    echo "[preflight] rclone is not installed or not on PATH." >&2
    exit 1
  fi

  local conf remotes
  conf="$(rclone config file 2>/dev/null | tail -n 1)"

  if ! remotes="$(rclone listremotes 2>&1)"; then
    echo "[preflight] rclone cannot read its config:" >&2
    printf '%s\n' "$remotes" | sed 's/^/    /' >&2
    if [ -n "$conf" ] && [ -e "$conf" ] && [ ! -r "$conf" ]; then
      echo "[preflight] $conf is not readable by $(whoami). Fix with:" >&2
      echo "    sudo chown \"$(whoami)\" \"$conf\" && chmod 600 \"$conf\"" >&2
    fi
    exit 1
  fi

  if ! printf '%s\n' "$remotes" | grep -qx "${RCLONE_REMOTE}:"; then
    echo "[preflight] Remote '${RCLONE_REMOTE}:' is not in $conf. Configured remotes:" >&2
    printf '%s\n' "$remotes" | sed 's/^/    /' >&2
    exit 1
  fi
}
preflight

# Build the command list from BACKUP_DIRS: a copy pass and a sync pass each.
cmds=()
for dir in "${BACKUP_DIRS[@]}"; do
  [ -d "$dir" ] || { echo "--> Skipping missing dir: $dir"; continue; }
  name=$(basename "$dir")
  cmds+=("rclone copy \"$dir\" \"${REMOTE_BASE}/${name}\" --copy-links --verbose --progress --transfers=8 ${EXCLUDE_STR}")
  cmds+=("rclone sync \"$dir\" \"${REMOTE_BASE}/${name}_sync\" --copy-links --verbose --progress --transfers=8 ${EXCLUDE_STR}")
done

# Add mounted external volumes (archive-only copy).
echo "Scanning for external volumes in /Volumes..."
for volume_path in /Volumes/*; do
    [ -d "${volume_path}" ] || continue
    volume_name=$(basename "${volume_path}")
    if [[ "${volume_name}" == "Macintosh HD" || "${volume_name}" == *TimeMachine* ]]; then
        echo "--> Skipping volume: ${volume_name}"
        continue
    fi
    echo "--> Adding volume to sync: ${volume_name}"
    cmds+=("rclone copy \"${volume_path}\" \"${RCLONE_REMOTE}:/00_archive/volumes/${volume_name}\" --copy-links --verbose --progress --transfers=8")
done

if [ ${#cmds[@]} -eq 0 ]; then
  echo "Nothing to back up. Check BACKUP_DIRS in config.sh."
  exit 1
fi

# Create a new session and the required number of panes
$TMUX new-session -d -s "$SESSION"

num_cmds=${#cmds[@]}
echo "Initializing tmux with ${num_cmds} panes across multiple windows."

# Create panes across multiple windows and capture pane IDs
panes_per_window=6
pane_ids=()

# First window's first pane ID
pane_ids+=("$($TMUX list-panes -t "$SESSION:0" -F "#{pane_id}")")

# Create splits/windows and capture pane IDs
for ((i=1; i<num_cmds; i++)); do
    win=$(( i / panes_per_window ))
    pos=$(( i % panes_per_window ))

    if (( pos == 0 )); then
        $TMUX new-window -t "$SESSION" -n "sync-$win"
        pane_ids+=("$($TMUX list-panes -t "$SESSION:$win" -F "#{pane_id}")")
    else
        new_pid="$($TMUX split-window -h -t "$SESSION:$win" -P -F "#{pane_id}")"
        pane_ids+=("$new_pid")
    fi
done

# Ensure all panes exist and apply layout
total_windows=$(( (num_cmds + panes_per_window - 1) / panes_per_window ))
for ((w=0; w<total_windows; w++)); do
    expected=$(( w == total_windows-1 ? (num_cmds - w*panes_per_window) : panes_per_window ))
    while :; do
        count="$($TMUX list-panes -t "$SESSION:$w" | wc -l | tr -d ' ')"
        [[ "$count" -ge "$expected" ]] && break
        sleep 0.1
    done
    $TMUX select-layout -t "$SESSION:$w" tiled
done

notify "🔄 Sync in progress for ${num_cmds} location(s)..."
sleep 2
command -v terminal-notifier >/dev/null 2>&1 && terminal-notifier -remove "rclone-sync" >/dev/null 2>&1

# Create a completion tracking dir
TRACKING_DIR="/tmp/rclone_sync_$$"
mkdir -p "$TRACKING_DIR"

# Send each command into its respective pane using pane IDs and literal mode
for i in ${!cmds[@]}; do
  pid="${pane_ids[$i]}"
  echo "Sending command to pane ${pid}..."
  $TMUX send-keys -t "$pid" "reset" C-m
  sleep 0.1
  cmd="${cmds[$i]} && touch '$TRACKING_DIR/pane${i}_done' || touch '$TRACKING_DIR/pane${i}_failed'"
  $TMUX send-keys -t "$pid" -l -- "$cmd"
  $TMUX send-keys -t "$pid" C-m
done

# Export variables for the background process
export START_TIME num_cmds DISCORD_WEBHOOK_URL TRACKING_DIR
export cmds_str="$(declare -p cmds)"

# Wait for all commands to complete then send notifications
(
  eval "$cmds_str"

  echo "Waiting for all panes to complete..."
  while true; do
    completed=0
    failed=0
    for i in ${!cmds[@]}; do
      if [[ -f "$TRACKING_DIR/pane${i}_done" ]]; then
        ((completed++))
      elif [[ -f "$TRACKING_DIR/pane${i}_failed" ]]; then
        ((failed++))
      fi
    done

    total_finished=$((completed + failed))
    if [[ $total_finished -eq $num_cmds ]]; then
      break
    fi
    sleep 2
  done

  end_time=$(date +%s)
  duration=$((end_time - START_TIME))
  last_sync_time=$(date "+%Y-%m-%d %H:%M:%S")

  if [[ $failed -gt 0 ]]; then
    status_emoji="⚠️"
    status_text="Completed with ${failed} error(s)"
    color=16744192
  else
    status_emoji="✅"
    status_text="Success"
    color=3066993
  fi

  command -v terminal-notifier >/dev/null 2>&1 && \
    terminal-notifier -message "${status_emoji} Sync of ${num_cmds} location(s) completed at ${last_sync_time}" -title "Rclone Sync" -group "rclone-sync"

  if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    report_title="${status_emoji} Sync Completed"
    report_description="Sync of **${num_cmds}** location(s) finished."
    fields="[{\"name\": \"Status\", \"value\": \"${status_text}\", \"inline\": true}, {\"name\": \"Completed At\", \"value\": \"${last_sync_time}\", \"inline\": true}, {\"name\": \"Duration\", \"value\": \"${duration}s\", \"inline\": true}]"

    tasks_list=""
    for cmd in "${cmds[@]}"; do
      src=$(echo "$cmd" | awk '{print $3}')
      dest=$(echo "$cmd" | awk '{print $4}')
      tasks_list+="• \`$src\` → \`$dest\`\\n"
    done
    fields="$fields, {\"name\": \"Synced Locations\", \"value\": \"${tasks_list}\"}"

    discord_payload=$(cat <<EOF
{
  "embeds": [{
    "title": "${report_title}",
    "description": "${report_description}",
    "color": ${color},
    "fields": [${fields}],
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"
  }]
}
EOF
)
    send_discord_notification "$discord_payload"
  fi

  rm -rf "$TRACKING_DIR"
  sleep 1
  $TMUX kill-session -t "$SESSION" 2>/dev/null || true
) &

echo "All sync commands sent. Waiting for completion in the background."
