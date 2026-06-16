# shellcheck shell=bash
#
# Sourced by every script in the toolkit. It loads the user's `config.sh`
# (copied from `config.example.sh`) and validates the essentials.

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_LIB_DIR/.." && pwd)"

if [ -f "$_REPO_ROOT/config.sh" ]; then
  # shellcheck source=/dev/null
  source "$_REPO_ROOT/config.sh"
elif [ -f "$_REPO_ROOT/config.example.sh" ]; then
  echo "[config] config.sh not found, falling back to defaults from config.example.sh" >&2
  # shellcheck source=/dev/null
  source "$_REPO_ROOT/config.example.sh"
else
  echo "[config] No config file found. Copy config.example.sh to config.sh." >&2
  exit 1
fi

if [ -z "${VAULT_PATH:-}" ]; then
  echo "[config] VAULT_PATH is not set. Edit config.sh." >&2
  exit 1
fi
