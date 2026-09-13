#!/bin/bash
#
# Photo & Voice-Memo archival for an Obsidian daily-journal vault (macOS).
#
# Stage 1: copy new photos off any inserted SD card (FUJI/RICOH/LEICA folders),
#          filed into VAULT/photos/YYYY_MM_DD/.
# Stage 2: move new macOS Voice Memos into VAULT/voice_memo/YYYY_MM_DD/
#          (recordings shorter than 10s are discarded).
# Stage 3: create/update the matching daily-journal note for each date, embedding
#          the day's photos ("Moments") and voice memos, preserving any captions.
#
# Settings come from config.sh (see config.example.sh).

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/config.sh"

# Flush macOS Voice Memos to disk by launching then quitting the app.
APP_BUNDLE_ID="com.apple.VoiceMemos"
APP_NAME="Voice Memos"

echo "Opening Voice Memos..."
open -b "$APP_BUNDLE_ID" 2>/dev/null || true

for _ in {1..5}; do
    if pgrep -x "$APP_NAME" > /dev/null; then
        echo "Voice Memos is running."
        break
    fi
    sleep 0.5
done

echo "Quitting Voice Memos..."
osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" 2>/dev/null || true

# Derived paths
OBSIDIAN_VAULT="$VAULT_PATH"
PHOTOS_DIR="$OBSIDIAN_VAULT/$PHOTOS_FOLDER"
VOICE_MEMO_DIR="$OBSIDIAN_VAULT/$VOICE_MEMO_FOLDER"
JOURNAL_DIR="$OBSIDIAN_VAULT/$DAILY_NOTES_FOLDER"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Utility Functions ---
print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# --- Image Processing Functions ---
get_image_timestamp() {
    local file="$1"
    local timestamp=""
    if command -v exiftool >/dev/null 2>&1; then
        timestamp=$(exiftool -DateTimeOriginal -s3 "$file" 2>/dev/null)
        [ -z "$timestamp" ] && timestamp=$(exiftool -CreateDate -s3 "$file" 2>/dev/null)
        if [ -n "$timestamp" ]; then
            echo $(date -j -f "%Y:%m:%d %H:%M:%S" "$timestamp" "+%s" 2>/dev/null || echo "0")
            return
        fi
    fi
    [[ "$OSTYPE" == "darwin"* ]] && stat -f "%m" "$file" || stat -c "%Y" "$file"
}

get_image_date() {
    local file="$1"
    local date_taken=""
    if command -v exiftool >/dev/null; then
        date_taken=$(exiftool -DateTimeOriginal -s3 "$file" 2>/dev/null)
        [ -z "$date_taken" ] && date_taken=$(exiftool -CreateDate -s3 "$file" 2>/dev/null)
    fi
    if [ -z "$date_taken" ]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            date_taken=$(stat -f "%Sm" -t "%Y:%m:%d %H:%M:%S" "$file")
        else
            date_taken=$(stat -c "%y" "$file" | cut -d' ' -f1)
        fi
    fi
    echo "$date_taken" | sed 's/[: -]/_/g' | cut -d'_' -f1-3
}

# --- Voice Memo Processing Functions ---
get_voice_memo_date_folder() {
    local file_path="$1"
    local filename=$(basename "$file_path")
    local date_part=$(echo "$filename" | cut -d' ' -f1)
    # 1. Try filename (Relaxed regex to allow suffixes like .m4a or _1)
    if [[ "$date_part" =~ ^[0-9]{8} ]]; then
        local year=${date_part:0:4}
        local month=${date_part:4:2}
        local day=${date_part:6:2}

        # Validate date is not in the future
        local folder_date="${year}-${month}-${day}"
        local today=$(date "+%Y-%m-%d")
        if [[ "$folder_date" > "$today" ]]; then
            # Use file creation time instead
            if [[ "$OSTYPE" == "darwin"* ]]; then
                stat -f "%SB" -t "%Y_%m_%d" "$file_path" 2>/dev/null
                return
            fi
        fi
        echo "${year}_${month}_${day}"
        return
    fi

    # 2. Fallback to file creation time (stat)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # %SB = Birthtime/Creation, %Sm = Modification. Prefer Birthtime.
        stat -f "%SB" -t "%Y_%m_%d" "$file_path" 2>/dev/null
    else
        stat -c "%y" "$file_path" 2>/dev/null | cut -d' ' -f1 | sed 's/-/_/g'
    fi
}

get_voice_memo_timestamp() {
    local file="$1"
    # Try to get creation time from file system
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f "%B" "$file" 2>/dev/null || stat -f "%m" "$file"
    else
        stat -c "%Y" "$file"
    fi
}

# --- Journal Creation and Update Functions ---
create_daily_journal() {
    local date_str="$1"  # YYYY_MM_DD
    local day_abbr="$2"  # Mon, Tue, etc.
    local journal_file="$JOURNAL_DIR/${date_str}_${day_abbr}.md"
    if [ -f "$journal_file" ]; then return 0; fi
    print_status "Creating new daily journal: $journal_file"
    local year=$(echo "$date_str" | cut -d'_' -f1); local month=$(echo "$date_str" | cut -d'_' -f2); local day=$(echo "$date_str" | cut -d'_' -f3)
    local current_date="${year}-${month}-${day}"
    cat > "$journal_file" << EOF
---
tags:
date: ${current_date}
---

← [[$(date -j -v-1d -f "%Y-%m-%d" "$current_date" "+%Y_%m_%d_%a" 2>/dev/null || echo "")]]｜[[$(date -j -v+1d -f "%Y-%m-%d" "$current_date" "+%Y_%m_%d_%a" 2>/dev/null || echo "")]] →

📅 Three days ago: [[$(date -j -v-3d -f "%Y-%m-%d" "$current_date" "+%Y_%m_%d_%a" 2>/dev/null || echo "")]]
🗓️ One week ago: [[$(date -j -v-7d -f "%Y-%m-%d" "$current_date" "+%Y_%m_%d_%a" 2>/dev/null || echo "")]]
🌙 One month ago: [[$(date -j -v-30d -f "%Y-%m-%d" "$current_date" "+%Y_%m_%d_%a" 2>/dev/null || echo "")]]
⏳ One year ago: [[$(date -j -v-365d -f "%Y-%m-%d" "$current_date" "+%Y_%m_%d_%a" 2>/dev/null || echo "")]]

# ✅ Things you've done
---
- [ ]
---

# 📒 Diary
---
### 🌅 Morning Check-in
- What's my intention for today?
- How do I feel this morning?
### 🌇 Evening Reflection
- What went well today?
- What challenges did I face?
- What am I grateful for?
- How can I improve tomorrow?
### 🗣️ Voice Memos

### 🎲 Random Stuff
---

# 🪞Daily reflections
---
### 🔄 What went well?
-
### ⚠️ What could be improved?
-
### 🎯 What are some things I plan to do?
-
---

# 📷 Moments
---

EOF
    chmod u+rw "$journal_file"
}

# Get existing image lines, including captions
get_existing_moments_data() {
    local journal_file="$1"
    local in_moments_section=false
    if [ ! -f "$journal_file" ]; then return; fi

    while IFS= read -r line; do
        if [[ "$line" == "# 📷 Moments" ]]; then
            in_moments_section=true
        # Match lines that start with the image link format ![[...]]
        elif [[ "$in_moments_section" == true && "$line" =~ ^!\[\[(.+)\]\] ]]; then
            # Extract the image path from inside the brackets
            local img_path="${BASH_REMATCH[1]}"
            # Get just the filename
            local img_basename=$(basename "$img_path")
            # Output the filename and the original, full line, separated by a pipe
            echo "$img_basename|$line"
        # Stop parsing when the section ends
        elif [[ "$in_moments_section" == true && "$line" == "---" ]]; then
            break
        fi
    done < "$journal_file"
}

update_journal_moments() {
    local journal_file="$1"; local date_folder="$2"; local temp_file="${journal_file}.tmp"
    print_status "Checking moments section in: $journal_file"

    # Find all images in the filesystem and sort by timestamp
    local timestamp_file="/tmp/photo_timestamps_$$"
    for ext in jpg jpeg JPG JPEG png PNG; do
        while IFS= read -r -d '' file; do
            if [ -f "$file" ]; then
                echo "$(get_image_timestamp "$file")|$(basename "$file")" >> "$timestamp_file"
            fi
        done < <(find "$PHOTOS_DIR/$date_folder" -name "*.$ext" -print0 2>/dev/null)
    done
    if [ ! -f "$timestamp_file" ]; then print_warning "No images found for $date_folder"; return; fi
    local sorted_images=(); while IFS='|' read -r timestamp img_name; do sorted_images+=("$img_name"); done < <(sort -n "$timestamp_file"); rm -f "$timestamp_file"

    # Create a temporary file to store existing image lines with captions
    local existing_lines_file="/tmp/existing_lines_$$"
    get_existing_moments_data "$journal_file" > "$existing_lines_file"

    # Function to get existing line for an image
    get_existing_line() {
        local img_basename="$1"
        # Escape special characters in the filename for grep
        local escaped_basename=$(printf '%s\n' "$img_basename" | sed 's/[[\.*^$()+?{|]/\\&/g')
        grep "^${escaped_basename}|" "$existing_lines_file" 2>/dev/null | cut -d'|' -f2- | head -1
    }

    # Check if an update is needed - compare simple image lists
    local existing_images_str=$(cut -d'|' -f1 "$existing_lines_file" 2>/dev/null | sort)
    if [ "$(printf '%s\n' "${sorted_images[@]}" | sort)" == "$(echo "$existing_images_str")" ] && [ -n "$existing_images_str" ]; then
        print_status "Moments section is already up to date for $date_folder"
        rm -f "$existing_lines_file"
        return
    fi

    print_status "Updating moments section in: $journal_file"
    local moments_found=false; local skip_until_section_end=false
    while IFS= read -r line; do
        if [[ "$line" == "# 📷 Moments" ]]; then
            moments_found=true; echo "$line" >> "$temp_file"; echo "---" >> "$temp_file"; echo "" >> "$temp_file"

            # Use the lookup to write image links, preserving captions
            for img in "${sorted_images[@]}"; do
                local existing_line=$(get_existing_line "$img")
                if [ -n "$existing_line" ]; then
                    # If yes, use the entire preserved line
                    echo "$existing_line" >> "$temp_file"
                else
                    # If no, it's a new image. Add it without a caption.
                    echo "![[${date_folder}/${img}]]" >> "$temp_file"
                fi
                # Add a blank line after each image for clean formatting
                echo "" >> "$temp_file"
            done

            echo "---" >> "$temp_file"; skip_until_section_end=true
        elif [[ "$skip_until_section_end" == true ]]; then
            if [[ "$line" =~ ^#[[:space:]] || "$line" == "EOF" ]]; then skip_until_section_end=false; echo "$line" >> "$temp_file"; fi
        else echo "$line" >> "$temp_file"; fi
    done < "$journal_file"

    # If no moments section was found, add it at the end
    if [ "$moments_found" == false ]; then
        echo "" >> "$temp_file"; echo "# 📷 Moments" >> "$temp_file"; echo "---" >> "$temp_file"; echo "" >> "$temp_file"
        for img in "${sorted_images[@]}"; do echo "![[${date_folder}/${img}]]" >> "$temp_file"; echo "" >> "$temp_file"; done; echo "---" >> "$temp_file"
    fi

    # Clean up temporary file
    rm -f "$existing_lines_file"

    mv "$temp_file" "$journal_file"; print_status "Updated moments section with ${#sorted_images[@]} images."
    chmod u+rw "$journal_file"
}

get_existing_voice_memos() {
    local journal_file="$1"; local existing_memos=(); local in_voice_memos_section=false
    if [ ! -f "$journal_file" ]; then echo ""; return; fi
    while IFS= read -r line; do
        if [[ "$line" == "### 🗣️ Voice Memos" ]]; then in_voice_memos_section=true
        elif [[ "$in_voice_memos_section" == true && "$line" =~ ^!\[\[voice_memo/.*\.m4a\]\]$ ]]; then
            local memo_path=$(echo "$line" | sed 's/!\[\[\(.*\)\]\]/\1/')
            existing_memos+=("$(basename "$memo_path")")
        elif [[ "$in_voice_memos_section" == true && ("$line" =~ ^### || "$line" == "---") ]]; then break
        fi
    done < "$journal_file"
    printf '%s\n' "${existing_memos[@]}" | sort | uniq
}

update_journal_voice_memos() {
    local journal_file="$1"
    local date_folder="$2"
    local memo_date_folder_path="$VOICE_MEMO_DIR/$date_folder"
    local temp_file="${journal_file}.tmp"

    if [ ! -d "$memo_date_folder_path" ]; then
        return
    fi

    print_status "Checking voice memos section in: $journal_file"

    # Get all voice memos with timestamps and sort by creation time
    local timestamp_file="/tmp/voice_memo_timestamps_$$"
    find "$memo_date_folder_path" -name "*.m4a" -print0 | while IFS= read -r -d '' file; do
        if [ -f "$file" ]; then
            echo "$(get_voice_memo_timestamp "$file")|$(basename "$file")" >> "$timestamp_file"
        fi
    done

    if [ ! -f "$timestamp_file" ]; then
        print_warning "No voice memos found for $date_folder"
        return
    fi

    # Sort by timestamp and extract filenames
    local sorted_memos=()
    while IFS='|' read -r timestamp memo_name; do
        sorted_memos+=("$memo_name")
    done < <(sort -n "$timestamp_file")
    rm -f "$timestamp_file"

    if [ ${#sorted_memos[@]} -eq 0 ]; then
        return
    fi

    # Get existing voice memos from journal
    local existing_memos_str=$(get_existing_voice_memos "$journal_file")
    local existing_memos_array=()
    if [ -n "$existing_memos_str" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && existing_memos_array+=("$line")
        done <<< "$existing_memos_str"
    fi

    # Check if the sorted memos match existing ones (same content, same order)
    local current_memos_sorted=$(printf '%s\n' "${sorted_memos[@]}")
    local existing_memos_sorted=$(printf '%s\n' "${existing_memos_array[@]}" | sort)

    if [ "$current_memos_sorted" == "$existing_memos_sorted" ] && [ -n "$existing_memos_str" ]; then
        print_status "Voice Memos section is already up to date for $date_folder"
        return
    fi

    print_status "Updating voice memos section in: $journal_file"

    # Update the journal file
    local memos_section_found=false
    local skip_until_section_end=false

    while IFS= read -r line; do
        if [[ "$line" == "### 🗣️ Voice Memos" ]]; then
            memos_section_found=true
            echo "$line" >> "$temp_file"
            echo "" >> "$temp_file"

            # Add all voice memos sorted by creation time
            for memo in "${sorted_memos[@]}"; do
                echo "![[voice_memo/${date_folder}/${memo}]]" >> "$temp_file"
                echo "" >> "$temp_file"
            done

            skip_until_section_end=true
        elif [[ "$skip_until_section_end" == true ]]; then
            # Skip existing voice memo entries until we hit the next section
            if [[ "$line" =~ ^### || "$line" == "---" ]]; then
                skip_until_section_end=false
                echo "$line" >> "$temp_file"
            fi
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$journal_file"

    if [ "$memos_section_found" == false ]; then
        print_status "Adding missing '### 🗣️ Voice Memos' section to $journal_file"
        # Insert before ### 🎲 Random Stuff if it exists, or at the end
        rm -f "$temp_file"

        # Try to insert the section in the right place
        local inserted=false
        while IFS= read -r line; do
            if [[ "$line" == "### 🎲 Random Stuff" && "$inserted" == false ]]; then
                echo "### 🗣️ Voice Memos" >> "$temp_file"
                echo "" >> "$temp_file"
                for memo in "${sorted_memos[@]}"; do
                    echo "![[voice_memo/${date_folder}/${memo}]]" >> "$temp_file"
                    echo "" >> "$temp_file"
                done
                inserted=true
            fi
            echo "$line" >> "$temp_file"
        done < "$journal_file"

        if [ "$inserted" == false ]; then
            # Append at end if marker not found
            echo "" >> "$temp_file"
            echo "### 🗣️ Voice Memos" >> "$temp_file"
            echo "" >> "$temp_file"
            for memo in "${sorted_memos[@]}"; do
                echo "![[voice_memo/${date_folder}/${memo}]]" >> "$temp_file"
                echo "" >> "$temp_file"
            done
        fi

        mv "$temp_file" "$journal_file"
        print_status "Added voice memos section with ${#sorted_memos[@]} memos."
        chmod u+rw "$journal_file"
        return
    fi

    mv "$temp_file" "$journal_file"
    print_status "Updated voice memos section with ${#sorted_memos[@]} memos (sorted by creation time)."
    chmod u+rw "$journal_file"
}

# --- Main Processing Stages ---
process_sd_cards() {
    local sd_cards=(); local processed_count=0; print_status "Scanning for SD cards..."
    for volume in /Volumes/*; do [ -d "$volume/DCIM" ] && sd_cards+=("$volume"); done
    if [ ${#sd_cards[@]} -eq 0 ]; then print_warning "No SD cards with DCIM folder found"; return 1; fi
    print_status "Found ${#sd_cards[@]} SD card(s)"
    for sd_card in "${sd_cards[@]}"; do
        print_status "Processing SD card: $(basename "$sd_card")"
        local camera_folders=()
        # Find FUJI folders (ending with _FUJI)
        while IFS= read -r -d '' dir; do
            camera_folders+=("$dir")
        done < <(find "$sd_card/DCIM/" -type d -name "*_FUJI" -print0 2>/dev/null)
        # Find RICOH folders (case-insensitive, containing RICOH)
        while IFS= read -r -d '' dir; do
            camera_folders+=("$dir")
        done < <(find "$sd_card/DCIM/" -type d \( -iname "*RICOH*" \) -print0 2>/dev/null)
        # Find LEICA folders (case-insensitive, containing LEICA)
        while IFS= read -r -d '' dir; do
            camera_folders+=("$dir")
        done < <(find "$sd_card/DCIM/" -type d \( -iname "*LEICA*" \) -print0 2>/dev/null)
        if [ ${#camera_folders[@]} -eq 0 ]; then
            print_warning "No FUJI, RICOH, or LEICA folders found in $(basename "$sd_card")"
            continue
        fi
        print_status "Found camera folders: ${camera_folders[*]}"
        for camera_folder in "${camera_folders[@]}"; do
            print_status "Processing folder: $(basename "$camera_folder")"
            find "$camera_folder" -type f -print0 | while IFS= read -r -d '' image_file; do
                local date_folder=$(get_image_date "$image_file")
                if [ -z "$date_folder" ] || [ "$date_folder" == "__" ]; then print_error "Could not determine date for: $image_file"; continue; fi
                local dest_folder="$PHOTOS_DIR/$date_folder"; mkdir -p "$dest_folder"
                local filename=$(basename "$image_file"); local dest_file="$dest_folder/$filename"
                if [ -f "$dest_file" ]; then
                    print_warning "File already exists, skipping: $filename"
                else
                    print_status "Copying: $filename -> $date_folder/"; cp "$image_file" "$dest_file"; ((processed_count++))
                fi
            done
        done
    done
    print_status "Processed $processed_count files from SD cards"
    return 0
}

process_voice_memos() {
    local processed_count=0
    print_status "Stage 1: Moving new voice memos to organized folders"
    print_status "Scanning for voice memos in: $VOICE_MEMO_SOURCE_DIR"

    if [ ! -d "$VOICE_MEMO_SOURCE_DIR" ]; then
        print_warning "Voice memo source directory not found. Skipping."
        return 1
    fi

    local files_to_process=()
    while IFS= read -r -d '' file; do
        files_to_process+=("$file")
    done < <(find "$VOICE_MEMO_SOURCE_DIR" -name "*.m4a" -print0 | sort -z)

    if [ ${#files_to_process[@]} -eq 0 ]; then
        print_warning "No new voice memos (.m4a files) found."
        return 1
    fi

    print_status "Found ${#files_to_process[@]} voice memos to process."

    for memo_file in "${files_to_process[@]}"; do
        local filename=$(basename "$memo_file")

        # --- Check duration and skip/delete if < 10 seconds ---
        local duration=0
        if command -v ffprobe >/dev/null 2>&1; then
            duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$memo_file" 2>/dev/null | awk '{printf("%d\n",$1)}')
        fi
        if [ -z "$duration" ] || [ "$duration" -lt 10 ]; then
            print_warning "Voice memo too short (<10s), deleting: $filename"
            rm -f "$memo_file"
            continue
        fi
        # ------------------------------------------------------

        local date_folder=$(get_voice_memo_date_folder "$memo_file")

        if [ -z "$date_folder" ]; then
            print_error "Could not determine date for voice memo: $filename"
            continue
        fi

        local dest_folder="$VOICE_MEMO_DIR/$date_folder"
        mkdir -p "$dest_folder"
        local dest_file="$dest_folder/$filename"

        if [ -f "$dest_file" ]; then
            print_warning "Voice memo already exists in vault: $filename. Deleting original."
            rm "$memo_file"
        else
            print_status "Moving: $filename -> voice_memo/$date_folder/"
            mv "$memo_file" "$dest_file"
            if [ $? -eq 0 ]; then
                ((processed_count++))
            else
                print_error "Failed to move $filename"
            fi
        fi
    done

    print_status "Stage 1 Complete: Moved $processed_count new voice memos."
    return 0
}

update_all_journals() {
    print_status "Stage 2: Updating daily journals with photos and voice memos..."

    # Only include photo folders if SD cards were detected
    local all_date_folders
    if [ "$SKIP_PHOTO_JOURNAL_UPDATE" = "1" ]; then
        # Only use voice memo folders
        all_date_folders=$(find "$VOICE_MEMO_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort -u)
    else
        # Use both photo and voice memo folders
        all_date_folders=$(
            (find "$PHOTOS_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; ;
             find "$VOICE_MEMO_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;) | sort -u
        )
    fi
    local today=$(date "+%Y_%m_%d")
    # Always ensure today's note exists, even on days with no photos/voice memos,
    # so the reminders step has a note to write into.
    all_date_folders=$(printf '%s\n%s\n' "$all_date_folders" "$today" | sort -u)

    for folder_name in $all_date_folders; do
        if ! [[ "$folder_name" =~ ^[0-9]{4}_[0-9]{2}_[0-9]{2}$ ]]; then
            continue
        fi
        # Skip folders with dates in the future
        if [[ "$folder_name" > "$today" ]]; then
            print_warning "Skipping future date folder: $folder_name"
            continue
        fi
        local year=$(echo "$folder_name" | cut -d'_' -f1)
        local month=$(echo "$folder_name" | cut -d'_' -f2)
        local day=$(echo "$folder_name" | cut -d'_' -f3)
        local day_abbr=$(date -j -f "%Y-%m-%d" "${year}-${month}-${day}" "+%a" 2>/dev/null || echo "")

        if [ -z "$day_abbr" ]; then
            print_error "Could not get day for $folder_name"
            continue
        fi

        local journal_file="$JOURNAL_DIR/${folder_name}_${day_abbr}.md"

        # Create journal if it doesn't exist
        [ ! -f "$journal_file" ] && create_daily_journal "$folder_name" "$day_abbr"

        # Only update photos section if not skipping photo journal update
        if [ "$SKIP_PHOTO_JOURNAL_UPDATE" != "1" ]; then
            update_journal_moments "$journal_file" "$folder_name"
        fi

        # Always update voice memos section
        update_journal_voice_memos "$journal_file" "$folder_name"
    done

    print_status "Stage 2 Complete: All journals updated with sorted voice memos."
}

# --- Main Execution ---
main() {
    print_status "Starting Photo & Memo Archival Process"
    echo "======================================="

    if [ ! -d "$OBSIDIAN_VAULT" ]; then
        print_error "Obsidian vault not found: $OBSIDIAN_VAULT"
        exit 1
    fi

    mkdir -p "$PHOTOS_DIR" "$JOURNAL_DIR" "$VOICE_MEMO_DIR"

    # Detect SD cards first
    local sd_cards=()
    for volume in /Volumes/*; do
        [ -d "$volume/DCIM" ] && sd_cards+=("$volume")
    done

    # Set flag to skip photo archival and photo journal update if no SD card
    if [ ${#sd_cards[@]} -eq 0 ]; then
        print_warning "No SD cards detected. Skipping photo archival process and photo-to-markdown update."
        SKIP_PHOTO_JOURNAL_UPDATE=1
    else
        SKIP_PHOTO_JOURNAL_UPDATE=0
        echo -e "\n${BLUE}Stage 1: Processing SD Cards${NC}"
        echo "-------------------------------"
        process_sd_cards
    fi

    # Always process voice memos, regardless of SD card presence
    echo -e "\n${BLUE}Stage 2: Processing Voice Memos${NC}"
    echo "-------------------------------"
    process_voice_memos

    echo -e "\n${BLUE}Stage 3: Updating Daily Journals${NC}"
    echo "-------------------------------"
    update_all_journals

    echo -e "\n======================================="
    print_status "Archival Process Complete!"
}

# Run the main function
main
