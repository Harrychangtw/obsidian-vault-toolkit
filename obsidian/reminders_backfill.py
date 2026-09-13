#!/usr/bin/env python3
"""Inject the day's completed Apple Reminders into that day's daily note.

Replaces the old "Quote of the day" backfill. Queries Apple Reminders for items
completed on the target date (default: today) and inserts them as the first
entries of the "# ✅ Things you've done" section of the matching daily-journal
note. Idempotent — re-running never duplicates lines.

Meant to run in the end-of-day archival flow (raycast/photo-archival.sh), after
archival_process.sh has ensured today's note exists.

Config from environment (see config.example.sh): VAULT_PATH, DAILY_NOTES_FOLDER.

Usage:
    python3 reminders_backfill.py            # today
    python3 reminders_backfill.py 2026_06_16 # a specific day
"""
import os
import subprocess
import sys
from datetime import date
from pathlib import Path

VAULT_PATH = Path(os.environ.get("VAULT_PATH", str(Path.home() / "Obsidian" / "MyVault")))
DAILY_NOTES_SUBDIR = os.environ.get("DAILY_NOTES_FOLDER", "daily-journal")

HEADER = "# ✅ Things you've done"

# Narrow 1-day window keeps the Reminders query fast (unbounded queries are slow).
APPLESCRIPT = '''
on run argv
	set targetDay to (current date)
	set time of targetDay to 0
	if (count of argv) > 0 then
		set d to item 1 of argv
		set y to (text 1 thru 4 of d) as integer
		set mo to (text 6 thru 7 of d) as integer
		set da to (text 9 thru 10 of d) as integer
		set day of targetDay to 1
		set year of targetDay to y
		set month of targetDay to mo
		set day of targetDay to da
	end if
	set nextDay to targetDay + (1 * days)
	set out to {}
	tell application "Reminders"
		set doneReminders to (reminders whose completed is true and completion date is greater than or equal to targetDay and completion date is less than nextDay)
		repeat with r in doneReminders
			set end of out to "- [x] " & (name of r)
		end repeat
	end tell
	if (count of out) is 0 then return ""
	set AppleScript's text item delimiters to linefeed
	return (out as text)
end run
'''


def completed_reminders(date_us: str) -> list[str]:
    """Return ['- [x] name', ...] for reminders completed on date_us (YYYY_MM_DD)."""
    result = subprocess.run(
        ["osascript", "-", date_us],
        input=APPLESCRIPT, capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"  [ERROR] osascript failed: {result.stderr.strip()}")
        return []
    return [ln for ln in result.stdout.splitlines() if ln.strip()]


def inject(lines: list[str], new_lines: list[str]) -> tuple[list[str], int]:
    """Insert new_lines after the divider following HEADER, skipping any already
    present in that section. Returns (updated_lines, count_added)."""
    try:
        h = next(i for i, ln in enumerate(lines) if ln.strip() == HEADER)
    except StopIteration:
        return lines, 0
    div = next((i for i in range(h + 1, len(lines)) if lines[i].strip() == "---"), None)
    if div is None:
        return lines, 0
    end = next((i for i in range(div + 1, len(lines)) if lines[i].strip() == "---"), len(lines))
    present = {lines[i].strip() for i in range(div + 1, end)}
    to_add = [ln for ln in new_lines if ln.strip() not in present]
    if not to_add:
        return lines, 0
    return lines[:div + 1] + to_add + lines[div + 1:], len(to_add)


def main() -> None:
    date_us = sys.argv[1] if len(sys.argv) > 1 else date.today().strftime("%Y_%m_%d")

    daily_dir = VAULT_PATH / DAILY_NOTES_SUBDIR
    matches = sorted(daily_dir.glob(f"{date_us}_*.md"))
    if not matches:
        print(f"[WARN] No daily note found for {date_us} in {daily_dir}")
        return
    note = matches[0]

    rem = completed_reminders(date_us)
    if not rem:
        print(f"[INFO] No completed reminders for {date_us}; nothing to add.")
        return

    lines = note.read_text(encoding="utf-8").split("\n")
    updated, added = inject(lines, rem)
    if not added:
        print(f"[SKIP] Completed reminders already present in {note.name}")
        return
    note.write_text("\n".join(updated), encoding="utf-8")
    print(f"[UPDATE] Added {added} completed reminder(s) to {note.name}")


if __name__ == "__main__":
    main()
