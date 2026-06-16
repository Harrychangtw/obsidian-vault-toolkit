#!/usr/bin/env bash
#
# Restore local directories from their cloud mirrors, the reverse of backup.sh.
# For each configured directory it runs:
#   sync  <remote>:<base>/<name>_sync  ->  <local dir>
# across parallel tmux panes, with an optional Discord summary at the end.
#
# WARNING: `rclone sync` is destructive on the destination (local). It will
# delete local files that no longer exist in the cloud mirror. Make sure you
# really want to overwrite local state before running this.
#
# Settings come from config.sh (see config.example.sh).

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/config.sh"

SESSION="restore_session"
TMUX="tmux -f /dev/null"
START_TIME=$(date +%s)

REMOTE_BASE="${RCLONE_REMOTE}:${RCLONE_BASE_PATH}"

EXCLUDES=(
  --exclude ".git/**"
  --exclude "node_modules/**"
  --exclude ".next/**"
  --exclude "dist/**"
  --exclude "build/**"
  --exclude ".venv/**"
  --exclude "__pycache__/**"
  --exclude "*.pyc"
  --exclude ".pytest_cache/**"
  --exclude ".mypy_cache/**"
  --exclude "*.egg-info/**"
  --exclude ".DS_Store"
  --exclude ".cache/**"
)
EXCLUDE_STR="${EXCLUDES[*]}"

send_discord_notification() {
  [ -z "${DISCORD_WEBHOOK_URL:-}" ] && return 0
  local payload="$1"
  curl -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 &
}

notify() {
  local message="$1"
  command -v terminal-notifier >/dev/null 2>&1 && \
    terminal-notifier -message "$message" -title "Rclone Restore" -group "rclone-restore"
  send_discord_notification "$(printf '{"content": "%s"}' "$message")"
}

# Check if the session already exists
if $TMUX has-session -t "$SESSION" 2>/dev/null; then
  echo "Session $SESSION already exists. Killing it."
  $TMUX kill-session -t "$SESSION"
  notify "⛔ Previous restore session terminated."
  sleep 2
  command -v terminal-notifier >/dev/null 2>&1 && terminal-notifier -remove "rclone-restore" >/dev/null 2>&1
  exit 0
fi

# Build restore commands from BACKUP_DIRS.
cmds=()
for dir in "${BACKUP_DIRS[@]}"; do
  name=$(basename "$dir")
  cmds+=("rclone sync \"${REMOTE_BASE}/${name}_sync\" \"$dir\" --copy-links --verbose --progress --transfers=8 ${EXCLUDE_STR}")
done

if [ ${#cmds[@]} -eq 0 ]; then
  echo "Nothing to restore. Check BACKUP_DIRS in config.sh."
  exit 1
fi

# Create a new session and the required number of panes
$TMUX new-session -d -s "$SESSION"

num_cmds=${#cmds[@]}
echo "Initializing tmux with ${num_cmds} panes for restore."

if (( num_cmds > 1 )); then
    for ((i=1; i<num_cmds; i++)); do
        $TMUX split-window -h -t "$SESSION:0"
    done
fi
$TMUX select-layout -t "$SESSION" even-vertical

notify "🔄 Restore in progress for ${num_cmds} location(s)..."
sleep 2
command -v terminal-notifier >/dev/null 2>&1 && terminal-notifier -remove "rclone-restore" >/dev/null 2>&1

# Give shells time to be ready in the panes
sleep 5

TRACKING_DIR="/tmp/rclone_restore_$$"
mkdir -p "$TRACKING_DIR"

for i in ${!cmds[@]}; do
  echo "Sending command to pane ${i}..."
  $TMUX send-keys -t "$SESSION":0.$i "reset" C-m
  sleep 0.1
  $TMUX send-keys -t "$SESSION":0.$i "${cmds[$i]} && touch '$TRACKING_DIR/pane${i}_done' || touch '$TRACKING_DIR/pane${i}_failed'" C-m
done

export START_TIME num_cmds DISCORD_WEBHOOK_URL TRACKING_DIR
export cmds_str="$(declare -p cmds)"

(
  eval "$cmds_str"

  echo "Waiting for all restore panes to complete..."
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
    terminal-notifier -message "${status_emoji} Restore of ${num_cmds} location(s) completed at ${last_sync_time}" -title "Rclone Restore" -group "rclone-restore"

  if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
    report_title="${status_emoji} Restore Completed"
    report_description="Restore of **${num_cmds}** location(s) from cloud finished."
    fields="[{\"name\": \"Status\", \"value\": \"${status_text}\", \"inline\": true}, {\"name\": \"Completed At\", \"value\": \"${last_sync_time}\", \"inline\": true}, {\"name\": \"Duration\", \"value\": \"${duration}s\", \"inline\": true}]"

    tasks_list=""
    for cmd in "${cmds[@]}"; do
      src=$(echo "$cmd" | awk '{print $3}')
      dest=$(echo "$cmd" | awk '{print $4}')
      tasks_list+="• \`$src\` → \`$dest\`\\n"
    done
    fields="$fields, {\"name\": \"Restored Locations\", \"value\": \"${tasks_list}\"}"

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

echo "All restore commands sent. Waiting for completion in the background."
