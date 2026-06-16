#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title System Backup
# @raycast.mode silent

# Optional parameters:
# @raycast.icon ☁️

# Documentation:
# @raycast.description Back up local folders to the cloud remote with rclone.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
nohup bash "$REPO/rclone/backup.sh" >/dev/null 2>&1 &
