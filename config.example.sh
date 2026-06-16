# shellcheck shell=bash
#
# Copy this file to `config.sh` and edit the values for your machine.
# `config.sh` is git-ignored so your personal paths and secrets never get
# committed. Every shell and Python script in this toolkit reads its settings
# from here (the Python scripts pick them up as environment variables).

# Absolute path to your Obsidian vault (where daily notes, photos and voice
# memos live). On macOS this is often an external volume.
export VAULT_PATH="${VAULT_PATH:-$HOME/Obsidian/MyVault}"

# Sub-folders inside the vault. Defaults match the bundled journal template.
export DAILY_NOTES_FOLDER="${DAILY_NOTES_FOLDER:-daily-journal}"
export KEYWORDS_FOLDER="${KEYWORDS_FOLDER:-keywords}"
export AUTHORS_FOLDER="${AUTHORS_FOLDER:-authors}"
export PHOTOS_FOLDER="${PHOTOS_FOLDER:-photos}"
export VOICE_MEMO_FOLDER="${VOICE_MEMO_FOLDER:-voice_memo}"

# macOS Voice Memos recordings source directory. Leave as-is on a stock Mac.
export VOICE_MEMO_SOURCE_DIR="${VOICE_MEMO_SOURCE_DIR:-$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings}"

# --- rclone pipeline ---------------------------------------------------------

# The rclone remote to back up to / restore from (run `rclone listremotes`).
export RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"

# Base path on the remote where backups are stored.
export RCLONE_BASE_PATH="${RCLONE_BASE_PATH:-/00_archive/macbook-pro}"

# Local directories to back up. Edit to taste.
export BACKUP_DIRS=(
  "$HOME/Documents"
  "$HOME/Desktop"
  "$HOME/Downloads"
)

# Optional Discord webhook for sync notifications. Leave empty to disable.
export DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
