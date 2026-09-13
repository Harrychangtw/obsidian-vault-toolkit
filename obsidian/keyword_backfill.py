#!/usr/bin/env python3
"""Build per-keyword Obsidian pages from [[wiki-links]] used in daily notes.

Scans the daily-notes folder, collects every `[[keyword]]` mention inside the
"things you've done" → "daily reflections" span of each note, and generates a
standalone page per keyword with its mention contexts. Re-runnable: existing
pages are only rewritten when new context is found.

Configuration is read from environment variables (see config.example.sh):
  VAULT_PATH, DAILY_NOTES_FOLDER, KEYWORDS_FOLDER
"""
import os
import re
from pathlib import Path
from collections import defaultdict

# --- CONFIGURATION (from environment, with sensible fallbacks) ---
VAULT_PATH = Path(os.environ.get("VAULT_PATH", str(Path.home() / "Obsidian" / "MyVault")))
DAILY_NOTES_FOLDER_NAME = os.environ.get("DAILY_NOTES_FOLDER", "daily-journal")
KEYWORDS_FOLDER_NAME = os.environ.get("KEYWORDS_FOLDER", "keywords")
# --- END OF CONFIGURATION ---

# Additional blocklist for common words that shouldn't become keyword pages
KEYWORD_BLOCKLIST = {
    'today', 'yesterday', 'tomorrow', 'morning', 'evening', 'afternoon', 'night',
    'daily', 'weekly', 'monthly', 'diary', 'reflection', 'moments', 'random stuff',
    'things', 'stuff', 'good', 'bad', 'great', 'nice', 'well', 'better', 'best',
    'finished', 'started', 'completed', 'did', 'went', 'got', 'had', 'made',
    'food', 'lunch', 'dinner', 'breakfast', 'ate', 'eating',
}

def extract_content_sections(content):
    """Extract only the relevant content sections from daily notes."""
    lines = content.split('\n')

    # Find start and end boundaries
    start_idx = None
    end_idx = None

    for i, line in enumerate(lines):
        line_clean = line.strip()

        # Look for start section
        if start_idx is None and re.match(r'^#+\s*✅.*things you.*done', line_clean, re.IGNORECASE):
            start_idx = i
            continue

        # Look for end section (after we found start)
        if start_idx is not None and re.match(r'^#+\s*🪞.*daily reflections', line_clean, re.IGNORECASE):
            # Find the end of this section (next # header or end of file)
            for j in range(i + 1, len(lines)):
                if lines[j].strip().startswith('#') and not lines[j].strip().startswith('###'):
                    end_idx = j
                    break
            if end_idx is None:
                end_idx = len(lines)
            break

    if start_idx is not None:
        if end_idx is not None:
            relevant_lines = lines[start_idx:end_idx]
        else:
            relevant_lines = lines[start_idx:]

        return '\n'.join(relevant_lines)

    return ""

def should_exclude_keyword(keyword):
    """Check if a keyword should be excluded from processing."""
    keyword_lower = keyword.lower().strip()

    # Check blocklist
    if keyword_lower in KEYWORD_BLOCKLIST:
        return True

    # Exclude very short or very long keywords
    if len(keyword.strip()) < 2 or len(keyword.strip()) > 50:
        return True

    # Exclude if it's just numbers
    if keyword.strip().isdigit():
        return True

    # Exclude date patterns
    if re.match(r'^\d{4}_\d{2}_\d{2}', keyword):
        return True

    # Exclude audio files (m4a) and other media file extensions
    if keyword_lower.endswith('.m4a') or '.m4a' in keyword_lower:
        return True

    # Exclude file paths that aren't keywords
    if '/' in keyword and any(folder in keyword for folder in ['voice_memo', 'authors', 'attachments', 'daily-journal']):
        return True

    return False

def extract_wiki_links(content):
    """Extract all [[keyword]] patterns from content and normalize them."""
    # Pattern to match [[link|display]] or [[link]] formats
    pattern = r'\[\[([^\]|]+)(?:\|([^\]]+))?\]\]'
    matches = re.findall(pattern, content)

    valid_keywords = []
    for match in matches:
        link_path = match[0].strip()  # The actual link path

        # Key the keyword off the link TARGET, never the display text —
        # [[500 Days of Summer|Summer]] must map to "500 Days of Summer",
        # otherwise a junk "Summer" page gets created.
        if link_path.startswith(f'{KEYWORDS_FOLDER_NAME}/'):
            # Remove the keywords/ prefix
            keyword = link_path[len(KEYWORDS_FOLDER_NAME) + 1:]
        elif '/' in link_path:
            # For other folder structures, take the last part
            keyword = link_path.split('/')[-1]
        else:
            # Simple link without folder
            keyword = link_path

        # Clean up the keyword
        keyword = keyword.strip()

        # Skip if should be excluded
        if keyword and not should_exclude_keyword(keyword):
            valid_keywords.append(keyword)

    return valid_keywords

def extract_context(content, keyword, context_chars=200):
    """Extract context around where a keyword appears in the content."""
    contexts = []

    # Create multiple patterns to catch different link formats for this keyword
    patterns = [
        # Direct link: [[keyword]]
        r'\[\[' + re.escape(keyword) + r'\]\]',
        # Link with display text: [[keyword|anything]]
        r'\[\[' + re.escape(keyword) + r'\|[^\]]+\]\]',
        # Link with display: [[anything|keyword]]
        r'\[\[[^\]|]+\|' + re.escape(keyword) + r'\]\]',
        # Keywords folder link: [[keywords/keyword]]
        r'\[\[' + re.escape(f'{KEYWORDS_FOLDER_NAME}/{keyword}') + r'\]\]',
        # Keywords folder with display: [[keywords/keyword|anything]]
        r'\[\[' + re.escape(f'{KEYWORDS_FOLDER_NAME}/{keyword}') + r'\|[^\]]+\]\]',
    ]

    for pattern in patterns:
        for match in re.finditer(pattern, content, re.IGNORECASE):
            start = max(0, match.start() - context_chars)
            end = min(len(content), match.end() + context_chars)

            context = content[start:end].strip()

            # Clean up context (remove excessive whitespace, markdown artifacts)
            context = re.sub(r'\n+', ' ', context)
            context = re.sub(r'\s+', ' ', context)

            if context and context not in contexts:
                contexts.append(context)

    return contexts

def scan_daily_notes(daily_notes_path):
    """Scan all daily notes and extract keywords with their contexts."""
    print(f"📖 Scanning daily notes in: {daily_notes_path}")

    keyword_data = defaultdict(lambda: {
        'contexts': [],
        'dates': [],
        'files': []
    })

    note_files = list(daily_notes_path.glob("*.md"))
    print(f"   Found {len(note_files)} note files to process")

    processed_files = 0
    for note_path in note_files:
        try:
            full_content = note_path.read_text(encoding='utf-8')

            # Extract only the relevant sections
            relevant_content = extract_content_sections(full_content)

            if not relevant_content.strip():
                continue  # Skip files without relevant sections

            keywords = extract_wiki_links(relevant_content)

            if not keywords:
                continue  # Skip files without keywords

            # Extract date from filename if possible
            date_match = re.search(r'(\d{4}_\d{2}_\d{2})', note_path.stem)
            note_date = date_match.group(1) if date_match else note_path.stem

            for keyword in keywords:
                contexts = extract_context(relevant_content, keyword)

                keyword_data[keyword]['contexts'].extend(contexts)
                keyword_data[keyword]['dates'].append(note_date)
                keyword_data[keyword]['files'].append(note_path.name)

            processed_files += 1

        except Exception as e:
            print(f"   ⚠️  Error processing {note_path.name}: {e}")

    print(f"   ✅ Processed {processed_files} files, found {len(keyword_data)} unique keywords")
    return keyword_data

def canonicalize_keywords(keyword_data, keywords_dir):
    """Merge case-variant keywords ([[arrival]] vs [[Arrival]]) into one entry.

    Canonical casing is the existing page's filename if one exists, otherwise
    the most-mentioned variant. Prevents duplicate pages differing only in case.
    """
    existing = {}
    if keywords_dir.exists():
        for page in keywords_dir.glob("*.md"):
            existing.setdefault(page.stem.lower(), page.stem)

    groups = defaultdict(list)
    for kw in keyword_data:
        groups[kw.lower()].append(kw)

    merged = {}
    for low, variants in groups.items():
        canonical = existing.get(low) or max(
            variants, key=lambda v: len(keyword_data[v]['contexts'])
        )
        entry = {'contexts': [], 'dates': [], 'files': []}
        for v in variants:
            entry['contexts'].extend(keyword_data[v]['contexts'])
            entry['dates'].extend(keyword_data[v]['dates'])
            entry['files'].extend(keyword_data[v]['files'])
        merged[canonical] = entry
    return merged

def extract_manual_sections(content):
    """Pull the manually-maintained sections out of an existing keyword page.

    Returns a dict with 'description', 'related', and 'tags' — each None when
    the section is absent or still the untouched placeholder.
    """
    sections = {}

    def section_body(header):
        m = re.search(r'^## ' + header + r'\n(.*?)(?=^## |\Z)', content, re.S | re.M)
        return m.group(1).strip() if m else None

    desc = section_body('Description')
    if desc and 'Add your description' not in desc:
        sections['description'] = desc

    related = section_body('Related')
    if related and re.sub(r'[-\s]', '', related):
        sections['related'] = related

    tags = section_body('Tags')
    if tags:
        sections['tags'] = tags

    return sections

def create_keyword_page_content(keyword, data, preserved=None):
    """Generate standardized content for a keyword page.

    `preserved` carries manual sections from an existing page (see
    extract_manual_sections) so a rebuild never wipes hand-written content.
    """
    preserved = preserved or {}

    # Header
    content = f"# {keyword}\n\n"

    # Basic info
    content += f"**Keyword**: `{keyword}`\n"
    content += f"**First mentioned**: {min(data['dates']) if data['dates'] else 'Unknown'}\n"
    content += f"**Total mentions**: {len(data['contexts'])}\n"
    content += f"**Appears in**: {len(set(data['files']))} notes\n\n"

    # Description section (preserved if already written by hand)
    content += "## Description\n\n"
    if preserved.get('description'):
        content += preserved['description'] + "\n\n"
    else:
        content += f"*Add your description of {keyword} here.*\n\n"

    # Context sections
    if data['contexts']:
        content += "## Context & Usage\n\n"

        # Group contexts by date/file
        date_file_contexts = defaultdict(list)
        for i, context in enumerate(data['contexts']):
            if i < len(data['dates']):
                date_key = data['dates'][i]
                date_file_contexts[date_key].append(context)

        for date in sorted(date_file_contexts.keys(), reverse=True):
            content += f"### {date}\n\n"
            for context in date_file_contexts[date][:3]:  # Limit to 3 contexts per date
                content += f"> {context}\n\n"

    # Related section (preserved if already filled by hand)
    content += "## Related\n\n"
    if preserved.get('related'):
        content += preserved['related'] + "\n"
    else:
        content += "- \n"  # Empty bullet point for manual filling

    # Tags (preserved if already customized)
    content += "\n## Tags\n\n"
    if preserved.get('tags'):
        content += preserved['tags'] + "\n"
    else:
        content += f"#keyword #{keyword.lower().replace(' ', '_').replace('/', '_')}\n"

    return content

def create_keyword_pages(keyword_data, keywords_dir):
    """Create individual pages for each keyword."""
    print(f"📝 Creating keyword pages in: {keywords_dir}")

    keywords_dir.mkdir(exist_ok=True)
    created_count = 0
    updated_count = 0

    for keyword, data in keyword_data.items():
        # Sanitize filename - remove any path prefixes and clean special characters
        safe_filename = re.sub(r'[<>:"/\\|?*]', '_', keyword).strip()
        if not safe_filename:
            continue

        keyword_file = keywords_dir / f"{safe_filename}.md"

        try:
            if keyword_file.exists():
                # Check if we should update (compare context count)
                existing_content = keyword_file.read_text(encoding='utf-8')

                # Simple heuristic: if new content has more contexts, update
                if len(data['contexts']) > existing_content.count('> '):
                    # Carry over hand-written sections so a rebuild never
                    # wipes Description/Related/Tags.
                    preserved = extract_manual_sections(existing_content)
                    new_content = create_keyword_page_content(keyword, data, preserved)
                    keyword_file.write_text(new_content, encoding='utf-8')
                    print(f"   📝 Updated: {keyword}")
                    updated_count += 1
                else:
                    print(f"   ⏭️  Skipped (no new content): {keyword}")
            else:
                new_content = create_keyword_page_content(keyword, data)
                keyword_file.write_text(new_content, encoding='utf-8')
                print(f"   ✨ Created: {keyword}")
                created_count += 1

        except Exception as e:
            print(f"   ❌ Error creating page for '{keyword}': {e}")

    print(f"   ✅ Created {created_count} new pages, updated {updated_count} pages")

def main():
    """Main function to orchestrate the keyword page creation."""
    daily_notes_path = VAULT_PATH / DAILY_NOTES_FOLDER_NAME
    keywords_dir = VAULT_PATH / KEYWORDS_FOLDER_NAME

    # Validate paths
    if not VAULT_PATH.exists():
        print(f"❌ Vault path not found: {VAULT_PATH}")
        return

    if not daily_notes_path.exists():
        print(f"❌ Daily notes folder not found: {daily_notes_path}")
        return

    print("🚀 Starting keyword page creation process...")
    print(f"   Vault: {VAULT_PATH}")
    print(f"   Daily notes: {daily_notes_path}")
    print(f"   Keywords output: {keywords_dir}")
    print("   📍 Processing only: '✅ Things you've done' → '🪞 Daily reflections' sections")

    # Step 1: Scan daily notes for keywords
    keyword_data = scan_daily_notes(daily_notes_path)

    if not keyword_data:
        print("❌ No keywords found in daily notes.")
        return

    # Collapse case-variant keywords into one canonical entry each
    keyword_data = canonicalize_keywords(keyword_data, keywords_dir)

    # Show sample of found keywords
    print("\n📋 Sample keywords found:")
    for i, keyword in enumerate(sorted(keyword_data.keys())[:15]):
        mention_count = len(keyword_data[keyword]['contexts'])
        print(f"   {i+1:2d}. {keyword} ({mention_count} mentions)")

    if len(keyword_data) > 15:
        print(f"   ... and {len(keyword_data) - 15} more")

    # Step 2: Create keyword pages
    create_keyword_pages(keyword_data, keywords_dir)

    print("\n🎉 Process completed successfully!")
    print(f"   Total keywords processed: {len(keyword_data)}")
    print(f"   Keyword pages location: {keywords_dir}")

if __name__ == "__main__":
    main()
