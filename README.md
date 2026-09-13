# Obsidian Vault Toolkit

A small set of macOS automation scripts for running a journaling + backup
workflow on top of an [Obsidian](https://obsidian.md) vault. Three pieces fit
together and can be triggered from [Raycast](https://raycast.com):

1. **Obsidian archival workflow** — pull photos off an SD card and voice memos
   off macOS Voice Memos, file them by date, and weave them into daily-journal
   notes.
2. **Keyword & author backfill** — turn the `[[wiki-links]]` and quotes you
   write in your daily notes into a browsable web of keyword and author pages.
3. **Rclone backup pipeline** — mirror your local folders (and external
   volumes) to a cloud remote in parallel, with optional Discord notifications.

Everything is configured in one place (`config.sh`) so no paths or secrets are
hard-coded.

## Layout

```
config.example.sh      # copy to config.sh and edit
lib/config.sh          # shared loader sourced by every script
obsidian/
  archival_process.sh  # SD-card photos + voice memos -> dated folders + journals
  keyword_backfill.py  # [[keyword]] mentions -> per-keyword pages
  index_authors.py     # quotes in notes -> per-author pages
  quote_backfill.py    # add a "Quote of the day" to notes missing one
rclone/
  backup.sh            # parallel backup of local dirs + volumes -> remote
  restore.sh           # restore local dirs from the cloud mirror (destructive)
  sync_loop.sh         # continuously mirror the current dir (home-server use)
  ntu_kb_sync.sh       # two-way bisync of the NTU KB (for iPad annotation)
  ntu-kb.filter.example  # copy to ntu-kb.filter: what the bisync includes
raycast/
  photo-archival.sh    # Raycast: run archival, then author + keyword backfill
  system-backup.sh     # Raycast: kick off rclone backup
  system-restore.sh    # Raycast: kick off rclone restore
  ntu-kb-sync.sh       # Raycast: kick off the NTU KB two-way sync
```

## Setup

1. **Configure.** Copy the example config and edit it for your machine:
   ```bash
   cp config.example.sh config.sh
   $EDITOR config.sh
   ```
   At minimum set `VAULT_PATH`. For the rclone pipeline set `RCLONE_REMOTE` and
   `RCLONE_BASE_PATH`, and adjust `BACKUP_DIRS`. `config.sh` is git-ignored.

2. **Python deps** (for the backfill scripts):
   ```bash
   pip install -r requirements.txt
   ```

3. **External tools** used when available (all optional, graceful fallbacks):
   - [`rclone`](https://rclone.org) — required for the backup pipeline; run
     `rclone config` once to create your remote.
   - `tmux` — required for the parallel backup/restore panes.
   - `exiftool` — better photo date extraction (falls back to file mtime).
   - `ffprobe` (ffmpeg) — drops voice memos shorter than 10s.
   - `terminal-notifier` — macOS desktop notifications.

## The Obsidian workflow

`obsidian/archival_process.sh` runs in three stages:

- **Photos** — scans `/Volumes/*` for an SD card (FUJI/RICOH/LEICA `DCIM`
  folders) and copies images into `VAULT/photos/YYYY_MM_DD/`.
- **Voice memos** — moves new macOS Voice Memos into
  `VAULT/voice_memo/YYYY_MM_DD/`, discarding clips under 10 seconds.
- **Journals** — creates the daily note for each date from a template and
  embeds that day's photos ("Moments") and voice memos, preserving captions you
  already added.

Then the backfill scripts mine the notes you write:

- `index_authors.py` collects blockquotes ending in `> — [[authors/Name|Name]]`
  into per-author pages.
- `keyword_backfill.py` collects `[[keyword]]` links from the
  "Things you've done" → "Daily reflections" span of each note into per-keyword
  pages with their surrounding context.
- `quote_backfill.py` (optional) inserts a random "Quote of the day" into notes
  that don't have one, via a quote API (`QUOTE_API_URL`).

Run the whole chain by hand, or via the Raycast script:

```bash
bash obsidian/archival_process.sh
python3 obsidian/index_authors.py
python3 obsidian/keyword_backfill.py
```

> The journal template uses specific section headers (e.g. `# ✅ Things you've
> done`, `### 🗣️ Voice Memos`, `# 📷 Moments`). If you change the template,
> update the matching markers in the scripts.

## The rclone pipeline

`rclone/backup.sh` builds one job per entry in `BACKUP_DIRS` — an additive
`copy` to `<remote>:<base>/<name>` plus an exact `sync` mirror to
`<name>_sync` — adds any mounted external volumes, and runs them all in
parallel across tmux panes. `rclone/restore.sh` reverses the mirror.

```bash
bash rclone/backup.sh     # back up
bash rclone/restore.sh    # restore (overwrites local — read the warning)
```

Set `DISCORD_WEBHOOK_URL` in `config.sh` to get start/finish notifications;
leave it empty to disable them.

> ⚠️ `restore.sh` runs `rclone sync` **onto your local folders**, which deletes
> local files missing from the cloud mirror. Make sure that's what you want.

## The NTU KB two-way sync

`rclone/backup.sh` is a one-way push, so it can never bring an edit made on
another device back home. `rclone/ntu_kb_sync.sh` adds that missing direction
for one folder only — the knowledge base — using `rclone bisync`:

```
~/Documents/03-ntu-kb  <-->  <remote>:<base>/03-ntu-kb-live
```

The point is iPad annotation. Open that Drive folder in the Files app, mark up
a PDF with an editor that writes **in place** (Preview on iPadOS, PDF Expert,
Apple Markup), then run the sync and the annotated file replaces the one on the
Mac. Note that GoodNotes, Notability and Noteshelf import PDFs into their own
library instead of editing the file, so annotations made there never reach the
folder — that is an architectural difference, not a setting.

```bash
bash rclone/ntu_kb_sync.sh              # normal two-way sync
bash rclone/ntu_kb_sync.sh --dry-run    # show what would change, touch nothing
bash rclone/ntu_kb_sync.sh --resync     # rebuild the baseline (see below)
```

What it does and does not do:

- **Conflicts never lose bytes.** The newer file wins and the older one is kept
  beside it. Note that rclone appends the suffix *after* the extension, so the
  loser of a conflict on `paper.pdf` is `paper.pdf.conflict1` and will not open
  on a double-click until you rename it. The script lists any such file by name
  when it happens.
- **Deletions do propagate**, in both directions — that is what two-way sync
  means. A run that would delete more than `NTU_KB_MAX_DELETE` percent of one
  side aborts instead. Keep `backup.sh` running for actual backup.
- **It refuses rather than guesses.** If the stored baseline is missing or
  `ntu-kb.filter` changed, the run stops, notifies you, and tells you to
  `--resync`. Nothing is transferred in that state.
- **It won't sync over a half-finished commit.** Uncommitted changes to
  *tracked* files in `03-ntu-kb` or `02-coursework` abort the run; untracked
  files are ignored, since new PDFs arrive all the time. Override with
  `--ignore-dirty`.
- **`.git` is never synced.** Both directories are real repos and a
  conflict-renamed file inside `.git` would corrupt one.
- Only one instance runs at a time; logs land in
  `~/.local/state/obsidian-vault-toolkit/ntu-kb-sync/`.

`--resync` rebuilds the baseline from scratch and is the one operation that can
discard a device's edits, so it is intentionally **not** exposed as a Raycast
command. Run it from a terminal, after reading the log that told you to.

The include/exclude list lives in `rclone/ntu-kb.filter`, which is git-ignored
for the same reason as `config.sh` — an exclude list is a map of your folder
structure and of what you deliberately keep off the cloud. Copy
`rclone/ntu-kb.filter.example` and edit it. Comment each rule with *why*:
bulk you never open on a tablet, machine-written state that would only
manufacture conflicts, and above all anything holding third-party personal
data. Conversely, consider *including* large PDFs your `.gitignore` excludes
for size reasons — those are usually exactly what you want to annotate.
Editing the filter forces a `--resync` on the next run.

## Raycast integration

Symlink or add the `raycast/` scripts as
[Raycast Script Commands](https://github.com/raycast/script-commands). Each one
resolves the repo root relative to itself and sources `config.sh`, so they work
wherever you clone the repo.

## License

MIT — see [LICENSE](LICENSE).
