#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title System Restore
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🤖

# Documentation:
# @raycast.description Restore local folders from the cloud remote with rclone (destructive on local).

REPO="$(cd "$(dirname "$0")/.." && pwd)"
nohup bash "$REPO/rclone/restore.sh" >/dev/null 2>&1 &
