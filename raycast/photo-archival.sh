#!/usr/bin/env -S LC_ALL=en_US.UTF-8 bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Photo & Memo Archival
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon 📂

# Documentation:
# @raycast.description Archive photos & voice memos into the Obsidian vault, then rebuild author/keyword pages.

# Resolve repo root from this script's location (raycast/ -> repo root).
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# Load config so the Python scripts inherit VAULT_PATH and friends.
source "$REPO/lib/config.sh"

bash "$REPO/obsidian/archival_process.sh"
python3 "$REPO/obsidian/reminders_backfill.py"
python3 "$REPO/obsidian/index_authors.py"
python3 "$REPO/obsidian/keyword_backfill.py"
