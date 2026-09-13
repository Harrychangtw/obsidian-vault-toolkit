# shellcheck shell=bash
#
# Sourced by every script in the toolkit. It loads the user's `config.sh`
# (copied from `config.example.sh`) and validates the essentials.

# --- Locale normalisation -------------------------------------------------
# macOS GUI launchers (Raycast, LaunchAgents, Shortcuts) hand child processes a
# BCP-47/ICU locale id built from the Region setting, e.g.
#   LC_ALL=en-TW-u-ca-gregory-co-standard-cu-twd-fw-sun-hc-h23-ms-metric-tz-twtpe
# libc cannot parse that, so every `bash`, `date`, `sort`, `python3` we spawn
# prints "setlocale: LC_ALL: cannot change locale (...): Invalid argument".
# A *valid* localised locale is no better here: `date +%a` under zh_TW returns
# a localised day abbreviation instead of "Sun", which would corrupt journal
# filenames. Pin a known English UTF-8 locale for the whole toolkit.
if locale -a 2>/dev/null | grep -qx 'en_US.UTF-8'; then
  _TOOLKIT_LOCALE="en_US.UTF-8"
elif locale -a 2>/dev/null | grep -qx 'C.UTF-8'; then
  _TOOLKIT_LOCALE="C.UTF-8"
else
  _TOOLKIT_LOCALE="C"
fi
unset LC_COLLATE LC_CTYPE LC_MESSAGES LC_MONETARY LC_NUMERIC LC_TIME
export LANG="$_TOOLKIT_LOCALE"
export LC_ALL="$_TOOLKIT_LOCALE"
unset _TOOLKIT_LOCALE

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
