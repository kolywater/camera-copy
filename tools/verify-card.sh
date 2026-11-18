#!/bin/bash
# verify-card.sh: checks that every file on a camera card is also in a destination folder.
#
#   Usage: verify-card.sh <card-folder> <destination-folder>
#   e.g.   verify-card.sh /Volumes/Untitled "/Volumes/Photos/2026-11-17 shoot"
#
# Give the card first, then this import's folder (not a whole photo library: every file in the
# destination is fingerprinted, so a big library makes the check much slower).
#
# How it decides: every file gets a SHA-256 fingerprint from Apple's built-in `shasum -a 256`.
# Files with the same fingerprint have the same contents, whatever their names or folders.
# A card file counts as copied if its fingerprint appears anywhere in the destination,
# in any subfolder, under any name. (So an empty card file matches any empty file there.)
#
# Skip rule (macOS housekeeping, never photos or videos), the same for both folders:
#   - files named ._* or .DS_Store
#   - the folders .Spotlight-V100, .Trashes and .fseventsd, with everything in them
# The number of skipped items is printed at the end. Symlinks are ignored (cameras don't make them).
#
# What a miss means: a card file with no match in the destination is MISSING, and the check
# fails, unless it is one of Sony's known extra files below. Camera Copy copies only photos and
# videos, so those extras are listed as "not copied, not a photo/video" and counted, but don't
# fail the check. Any other file type (e.g. .CR3, .NEF, .WAV) counts as MISSING, so a new kind of
# file can never pass quietly.
#
# Progress: while fingerprinting, it prints a line at most every 2 seconds (and once at the end), e.g.
#   Destination: 1,240 of 3,100 files (41.2 GB of 98.0 GB)
# Camera Copy shows these as a progress bar. They never change the result.
#
# Read-only: it never writes, moves or deletes anything on the card or in the destination.
# It keeps its two working lists in a temporary folder and deletes that folder when it ends.
# It doesn't use Camera Copy's code or its checksums file.

# Sony's known extra files (not photos or videos). Letter case doesn't matter.
#   xml          clip sidecars (C0001M01.XML) and MEDIAPRO.XML
#   bin          STATUS.BIN and similar camera status files
#   ind          SONYCARD.IND, the card's index
#   bdm cpi mpl  AVCHD index files that Sony cameras create even if you never shoot AVCHD
#   PRIVATE/M4ROOT/THMBNL/*.JPG   Sony's small clip previews: only JPGs, only directly in that folder
#                                 (anything else in a THMBNL folder still counts as MISSING)
#   AVF_INFO/*.INT *.BNP *.INP    Sony's card database, only directly in AVF_INFO at the card root
#                                 (the same types anywhere else still count as MISSING)
known_extra_types="xml bin ind bdm cpi mpl"

set -u
[ $# -eq 2 ] || { echo "Usage: verify-card.sh <card-folder> <destination-folder>"; exit 2; }

# Turn both folders into full, real paths (this also follows a folder given as a symlink).
card=$(cd -- "$1" 2>/dev/null && pwd -P) || { echo "Can't open the card folder: $1"; exit 2; }
dest=$(cd -- "$2" 2>/dev/null && pwd -P) || { echo "Can't open the destination folder: $2"; exit 2; }

# Refuse a mix-up: if one folder is inside the other, the check would pass without proving anything.
# Compared in lowercase, because Mac disks usually treat "Card" and "card" as the same folder.
card_lc=$(printf '%s' "$card" | tr '[:upper:]' '[:lower:]'); dest_lc=$(printf '%s' "$dest" | tr '[:upper:]' '[:lower:]')
[ "$card_lc" != "$dest_lc" ] || { echo "The card and the destination are the same folder."; exit 2; }
case "$dest_lc/" in "$card_lc/"*) echo "The destination is inside the card folder. Check the order: card first."; exit 2;; esac
case "$card_lc/" in "$dest_lc/"*) echo "The card folder is inside the destination. Check the order: card first."; exit 2;; esac
[ -d "$card/DCIM" ] || [ -d "$card/PRIVATE" ] || [ "${card##*/}" = DCIM ] || echo "Note: $card has no DCIM or PRIVATE folder. Is it the card?"

# Is this card file one of Sony's known extras? (Checks the clip previews, then the type, ignoring case.)
is_known_extra() {
  path=$(printf '%s' "/${1#"$card"/}" | tr '[:upper:]' '[:lower:]')    # its place on the card, in lowercase
  case "$path" in
    /private/m4root/thmbnl/*/*) ;;                     # inside a subfolder of THMBNL: not a preview
    /private/m4root/thmbnl/*.jpg) return 0 ;;          # Sony's clip previews: JPGs directly in that folder
    /avf_info/*/*) ;;                                  # inside a subfolder of AVF_INFO: not Sony's database
    /avf_info/*.int|/avf_info/*.bnp|/avf_info/*.inp) return 0 ;;   # Sony's card database at the card root
  esac
  name=${path##*/}
  case "$name" in *.*) ;; *) return 1 ;; esac            # no type at all: not a known extra
  case " $known_extra_types " in *" ${name##*.} "*) return 0 ;; esac
  return 1
}

# Progress helpers. The total size of the files in a list, the number of files in it, sizes in words,
# and the progress line itself (at most every 2 seconds, plus the last one).
total_bytes() { xargs -0 stat -f %z < "$1" | awk '{ s += $1 } END { print s + 0 }'; }   # for the progress line only
file_count() { tr -cd '\0' < "$1" | wc -c | tr -d ' '; }
in_words() { awk -v b="$1" 'BEGIN { if (b >= 1e9) printf "%.1f GB", b / 1e9; else if (b >= 1e6) printf "%.1f MB", b / 1e6; else printf "%.0f KB", b / 1e3 }'; }
show_progress() {   # label, files done, files in all, bytes done, bytes in all
  [ "$2" -lt "$3" ] && [ "$SECONDS" -lt $((last_shown + 2)) ] && return
  last_shown=$SECONDS
  printf "%s: %'d of %'d files (%s of %s)\n" "$1" "$2" "$3" "$(in_words "$4")" "$(in_words "$5")"
}

# A temporary folder for the working lists, deleted when the script ends.
work=$(mktemp -d) || exit 2
trap 'rm -rf "$work"' EXIT

# The skip rule for `find`: leave out the junk folders whole, then leave out the junk files.
skip_dirs=( \( -name .Spotlight-V100 -o -name .Trashes -o -name .fseventsd \) -prune )
skip_files=( -name '._*' -o -name .DS_Store )

# Step 1: list every file on the card. If any card folder can't be read, stop: we can't vouch for it.
if ! find "$card" "${skip_dirs[@]}" -o -type f ! \( "${skip_files[@]}" \) -print0 > "$work/card-files"; then
  echo "NOT OK: couldn't read every folder on the card ($card)."; exit 1
fi

# Step 2: fingerprint every file in the destination, one at a time, keeping just the fingerprints.
# A destination file that can't be read simply has no fingerprint, so a card file can't match it.
echo "Fingerprinting the destination (this can take a while)…"
find "$dest" "${skip_dirs[@]}" -o -type f ! \( "${skip_files[@]}" \) -print0 > "$work/dest-files"
all=$(file_count "$work/dest-files"); all_bytes=$(total_bytes "$work/dest-files"); counted=0; done_bytes=0
last_shown=-99; show_progress Destination 0 "$all" 0 "$all_bytes"
: > "$work/dest-prints"
while IFS= read -r -d '' file; do
  print=$(shasum -a 256 2>/dev/null < "$file" | cut -c1-64)
  [ -z "$print" ] || echo "$print" >> "$work/dest-prints"
  size=$(stat -f %z "$file" 2>/dev/null) || size=0           # only for the progress line
  counted=$((counted + 1)); done_bytes=$((done_bytes + size))
  show_progress Destination "$counted" "$all" "$done_bytes" "$all_bytes"
done < "$work/dest-files"
sort -u -o "$work/dest-prints" "$work/dest-prints"

# Step 3: go through the card one file at a time, fingerprint it, and look for it in the destination.
echo "Checking the card…"
total=0; missing=0; extras=0
missing_list=(); extras_list=()
all=$(file_count "$work/card-files"); all_bytes=$(total_bytes "$work/card-files"); done_bytes=0
last_shown=-99; show_progress Card 0 "$all" 0 "$all_bytes"
while IFS= read -r -d '' file; do
  total=$((total + 1))
  size=$(stat -f %z "$file" 2>/dev/null) || size=0           # only for the progress line
  done_bytes=$((done_bytes + size))
  print=$(shasum -a 256 2>/dev/null < "$file" | cut -c1-64)
  if [ -z "$print" ]; then
    missing_list+=("UNREADABLE: $file"); missing=$((missing + 1))   # couldn't read it, so it can't be confirmed
  elif grep -qxF -- "$print" "$work/dest-prints"; then
    :                                                       # found in the destination: all good
  elif is_known_extra "$file"; then
    extras_list+=("  $file"); extras=$((extras + 1))      # listed, but doesn't fail
  else
    missing_list+=("MISSING: $file"); missing=$((missing + 1))   # no file in the destination has these contents
  fi
  show_progress Card "$total" "$all" "$done_bytes" "$all_bytes"
done < "$work/card-files"

# Every card file on the list must have been checked; otherwise the result can't be trusted.
[ "$total" -eq "$all" ] || { echo "NOT OK: only $total of $all card files could be checked."; exit 1; }

# Step 4: count what the skip rule left out on the card, so nothing is hidden.
skipped=$(find "$card" "${skip_dirs[@]}" -print -o -type f \( "${skip_files[@]}" \) -print | wc -l | tr -d ' ')
echo "Skipped $skipped macOS housekeeping item(s) on the card (._ files, .DS_Store; a system folder counts as one)."

# Step 5: the two lists. Sony's extras first (they don't fail), then anything missing (it fails).
if [ "$extras" -gt 0 ]; then
  echo "Not copied, not a photo/video ($extras Sony extra file(s); these don't fail the check):"
  printf '%s\n' "${extras_list[@]}"
fi
[ "$missing" -eq 0 ] || printf '%s\n' "${missing_list[@]}"

# Step 6: the verdict, naming both folders so a mix-up shows.
# Exit code 0: everything is there. 1: something is missing or unreadable. 2: wrong usage or nothing to check.
if [ "$total" -eq 0 ]; then echo "NO FILES: nothing to check on $card."; exit 2; fi
if [ "$missing" -eq 0 ] && [ "$extras" -eq 0 ]; then echo "OK: all $total files on $card are in $dest"; exit 0; fi
if [ "$missing" -eq 0 ]; then echo "OK: all $((total - extras)) files on $card are in $dest, apart from the $extras Sony extras above"; exit 0; fi
echo "MISSING: $missing of $total files on $card are not in $dest"; exit 1
