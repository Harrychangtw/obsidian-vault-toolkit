#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title NTU KB Sync
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 📓

# Documentation:
# @raycast.description Two-way sync of ~/Documents/03-ntu-kb with Drive so iPad PDF annotations come home.

# Deliberately no --resync entry point here: rebuilding the bisync baseline is
# the one operation that can lose an iPad edit, and it should not be a
# single keystroke away. Run `rclone/ntu_kb_sync.sh --resync` in a terminal.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
nohup bash "$REPO/rclone/ntu_kb_sync.sh" >/dev/null 2>&1 &
