#!/usr/bin/env python3
"""Aggregate quotes from daily notes into per-author Obsidian pages.

Looks for blockquotes that end with an author wiki-link, e.g.

    > The quote content is here.
    > — [[authors/Author Name|Author Name]]

and appends each unique quote to that author's page (creating it if needed).

Configuration is read from environment variables (see config.example.sh):
  VAULT_PATH, DAILY_NOTES_FOLDER, AUTHORS_FOLDER
"""
import os
import re
from collections import defaultdict
from pathlib import Path

# --- CONFIGURATION (from environment, with sensible fallbacks) ---
VAULT_PATH = Path(os.environ.get("VAULT_PATH", str(Path.home() / "Obsidian" / "MyVault")))
DIRECTORIES_TO_SCAN = [os.environ.get("DAILY_NOTES_FOLDER", "daily-journal")]
AUTHORS_FOLDER_NAME = os.environ.get("AUTHORS_FOLDER", "authors")
# --- End Configuration ---

def sanitize_filename(name: str) -> str:
    """Removes characters that are invalid in file names."""
    return re.sub(r'[<>:"/\\|?*]', '', name)

def find_quotes_in_vault(vault_base_path: Path, scan_dirs: list[str]) -> defaultdict:
    """
    Scans specified directories in the vault for quotes and returns a dictionary
    mapping authors to a set of their quotes.
    """
    print("🔍 Starting scan for quotes...")

    # Regex to find quotes formatted as:
    # > The quote content is here.
    # > — [[authors/Author Name|Author Name]]
    quote_pattern = re.compile(
        r'> (.*?)\n> — \[\[.*?\|(.*?)\]\]',
        re.MULTILINE | re.DOTALL
    )

    authors_quotes = defaultdict(set)
    total_notes_scanned = 0

    for directory in scan_dirs:
        scan_path = vault_base_path / directory
        if not scan_path.exists():
            print(f"⚠️  Warning: Directory not found, skipping: {scan_path}")
            continue

        print(f"   Scanning directory: {directory}...")
        for md_file in scan_path.rglob("*.md"):
            total_notes_scanned += 1
            try:
                content = md_file.read_text(encoding="utf-8")
                matches = quote_pattern.findall(content)
                for quote, author in matches:
                    # Clean up quote content by removing leading/trailing whitespace
                    # and replacing blockquote markers from multiline quotes.
                    cleaned_quote = quote.strip().replace('\n> ', '\n')
                    authors_quotes[author.strip()].add(cleaned_quote)
            except Exception as e:
                print(f"⚠️  Could not read file {md_file}: {e}")

    print(f"✅ Scan complete. Scanned {total_notes_scanned} notes.")
    print(f"   Found {sum(len(q) for q in authors_quotes.values())} quotes from {len(authors_quotes)} authors.\n")
    return authors_quotes

def update_author_pages(vault_base_path: Path, authors_folder: str, all_quotes: defaultdict):
    """
    Creates or updates author pages with the quotes found.
    """
    print("✍️  Starting to update author pages...")
    author_dir_path = vault_base_path / authors_folder

    # Ensure the authors directory exists
    author_dir_path.mkdir(exist_ok=True)

    if not all_quotes:
        print("   No authors found to update.")
        return

    for author, quotes in sorted(all_quotes.items()):
        sanitized_name = sanitize_filename(author)
        author_note_path = author_dir_path / f"{sanitized_name}.md"

        quotes_added_count = 0

        try:
            # Create the author note if it doesn't exist
            if not author_note_path.exists():
                print(f"   📄 Creating new page for: {author}")
                initial_content = f"# {author}\n\nTags: #author\n\n## Quotes\n\n"
                author_note_path.write_text(initial_content, encoding="utf-8")
                existing_content = initial_content
            else:
                existing_content = author_note_path.read_text(encoding="utf-8")

            # Append new quotes
            content_to_append = ""
            for quote in sorted(list(quotes)):
                # Check if the exact quote is already in the note to avoid duplicates
                if f"> {quote}" not in existing_content:
                    content_to_append += f"> {quote}\n\n"
                    quotes_added_count += 1

            if content_to_append:
                with author_note_path.open("a", encoding="utf-8") as f:
                    f.write(content_to_append)
                print(f"   ➕ Added {quotes_added_count} new quote(s) to {author}'s page.")
            else:
                print(f"   👍 Page for {author} is already up-to-date.")

        except Exception as e:
            print(f"❌ Error updating page for {author}: {e}")

    print("\n✅ All author pages updated successfully!")

def main():
    """Main function to run the script."""
    if not VAULT_PATH.exists() or not VAULT_PATH.is_dir():
        print("❌ FATAL ERROR: The specified vault path does not exist or is not a directory.")
        print("   Please set the 'VAULT_PATH' environment variable (see config.example.sh).")
        print(f"   Current path: {VAULT_PATH}")
        return

    all_found_quotes = find_quotes_in_vault(VAULT_PATH, DIRECTORIES_TO_SCAN)
    update_author_pages(VAULT_PATH, AUTHORS_FOLDER_NAME, all_found_quotes)

if __name__ == "__main__":
    main()
