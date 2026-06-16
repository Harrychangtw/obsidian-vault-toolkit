#!/usr/bin/env python3
"""Insert a "Quote of the day" section into daily notes that don't have one.

For each daily note it fetches a random quote from a quote API, creates an
author page + wiki-link if needed, and inserts the quote block after a known
anchor line in the note template. Already-processed notes are skipped.

Configuration is read from environment variables (see config.example.sh):
  VAULT_PATH, DAILY_NOTES_FOLDER, AUTHORS_FOLDER, QUOTE_API_URL
"""
import os
import re
from pathlib import Path

import requests

# --- CONFIGURATION (from environment, with sensible fallbacks) ---
VAULT_PATH = Path(os.environ.get("VAULT_PATH", str(Path.home() / "Obsidian" / "MyVault")))
DAILY_NOTES_SUBDIR = os.environ.get("DAILY_NOTES_FOLDER", "daily-journal")
AUTHORS_SUBDIR = os.environ.get("AUTHORS_FOLDER", "authors")
# Any API that returns JSON with "content" and "author" fields.
QUOTE_API_URL = os.environ.get("QUOTE_API_URL", "https://api.quotable.io/random")
# --- END OF CONFIGURATION ---

# String to check if the note already has a quote
QUOTE_HEADER = "# 💭 Quote of the day"

# The anchor line in your template after which the quote section will be inserted
INSERTION_ANCHOR = "⏳ One year ago:"


def sanitize_filename(name: str) -> str:
    """Removes characters that are invalid for filenames."""
    return re.sub(r'[<>:"/\\|?*]', '', name)

def get_random_quote():
    """Fetches a random quote from the configured quote API."""
    try:
        response = requests.get(QUOTE_API_URL, timeout=10)
        # Raises an exception for bad status codes (e.g., 404, 500)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f"  [ERROR] API request failed: {e}")
        return None

def main():
    """Main function to run the backfill process."""
    daily_notes_dir = VAULT_PATH / DAILY_NOTES_SUBDIR
    authors_dir = VAULT_PATH / AUTHORS_SUBDIR

    if not daily_notes_dir.is_dir():
        print(f"ERROR: Daily notes directory not found at: {daily_notes_dir}")
        return

    # Ensure the authors directory exists, create it if it doesn't
    authors_dir.mkdir(exist_ok=True)

    print(f"Starting backfill process for daily notes in: {daily_notes_dir}")
    print("---")

    note_files = list(daily_notes_dir.glob("*.md"))

    for note_file in note_files:
        try:
            content = note_file.read_text(encoding='utf-8')

            if QUOTE_HEADER in content:
                print(f"[SKIP] Quote section already in: {note_file.name}")
                continue

            if INSERTION_ANCHOR not in content:
                print(f"[WARN] Anchor '{INSERTION_ANCHOR}' not found in: {note_file.name}. Skipping.")
                continue

            print(f"[UPDATE] Processing: {note_file.name}")

            # 1. Fetch quote data
            quote_data = get_random_quote()
            if not quote_data:
                continue  # Skip this file if the API call fails

            quote_content = quote_data['content']
            author_name = quote_data['author']

            # 2. Prepare author note and create wikilink
            sanitized_author = sanitize_filename(author_name)
            author_note_path = authors_dir / f"{sanitized_author}.md"

            if not author_note_path.exists():
                author_note_content = f"# {author_name}\n\nTags: #author\n\n## Quotes\n\n"
                author_note_path.write_text(author_note_content, encoding='utf-8')
                print(f"  -> Created author note for: {author_name}")

            linked_author = f"[[{AUTHORS_SUBDIR}/{sanitized_author}|{author_name}]]"

            # 3. Format the new section with correct markdown and newlines
            quote_section = (
                f"\n\n{QUOTE_HEADER}\n"
                f"---\n\n"
                f"> {quote_content}\n"
                f"> — {linked_author}\n\n"
                f"---"
            )

            # 4. Insert the new section into the file's content
            lines = content.splitlines()
            new_lines = []
            for line in lines:
                new_lines.append(line)
                if INSERTION_ANCHOR in line:
                    # Append the fully formatted quote section after the anchor line
                    new_lines.append(quote_section)

            new_content = "\n".join(new_lines)

            # 5. Write the new content back to the file
            note_file.write_text(new_content, encoding='utf-8')
            print(f"  -> Successfully added quote by {author_name}.")

        except Exception as e:
            print(f"  [ERROR] Failed to process {note_file.name}: {e}")

    print("---")
    print("✅ Backfill process completed!")


if __name__ == "__main__":
    main()
