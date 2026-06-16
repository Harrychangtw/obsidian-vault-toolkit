#!/usr/bin/env bash
#
# Continuously mirror the current working directory to the cloud remote.
# Runs rclone sync in a loop with a fixed delay between passes. Handy on a
# home server / always-on machine. Ctrl-C to stop.
#
# Settings come from config.sh (see config.example.sh).
#   SYNC_INTERVAL_SECONDS - delay between passes (default 10)

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/config.sh"

INTERVAL="${SYNC_INTERVAL_SECONDS:-10}"
DEST="${RCLONE_REMOTE}:/00_archive/home-server$(pwd)"

while true; do
    echo "Waiting ${INTERVAL} seconds..."
    sleep "$INTERVAL"

    echo "Starting rclone sync of $(pwd) -> ${DEST}"
    rclone sync "$(pwd)" "$DEST" --copy-links --verbose --progress

    echo "Sync completed. Repeating..."
done
