#!/bin/bash
# verify-card.sh: checks that every file on a camera card is also in a destination folder.
#
#   Usage: verify-card.sh <card-folder> <destination-folder>
#   e.g.   verify-card.sh /Volumes/Untitled "/Volumes/Photos/2026-11-17 shoot"
#
# How it decides: every file gets a SHA-256 fingerprint from Apple's built-in `shasum -a 256`.
# Files with the same fingerprint have the same contents, whatever their names or folders.
# A card file counts as copied if its fingerprint appears anywhere in the destination,
# in any subfolder, under any name.
#
# Skip rule (macOS housekeeping, never photos or videos), the same for both folders:
#   - files named ._* or .DS_Store
#   - the folders .Spotlight-V100, .Trashes and .fseventsd, with everything in them
# The number of skipped items is printed at the end.
#
# Read-only: this script never writes, moves or deletes anything.
# It doesn't use Camera Copy's code or its checksums file.

set -u
[ $# -eq 2 ] || { echo "Usage: verify-card.sh <card-folder> <destination-folder>"; exit 2; }
card="$1"; dest="$2"
[ -d "$card" ] && [ -d "$dest" ] || { echo "Both folders must exist."; exit 2; }

# The skip rule for `find`: leave out the junk folders whole, then leave out the junk files.
skip_dirs=( \( -name .Spotlight-V100 -o -name .Trashes -o -name .fseventsd \) -prune )
skip_files=( -name '._*' -o -name .DS_Store )

# Step 1: fingerprint every file in the destination. Keep just the fingerprints, one per line.
# (shasum puts a "\" in front of a line when the file name has odd characters; sed removes it.)
dest_prints=$(find "$dest" "${skip_dirs[@]}" -o -type f ! \( "${skip_files[@]}" \) -exec shasum -a 256 {} + \
              | sed 's/^\\//' | cut -c1-64)

# Step 2: go through the card one file at a time, fingerprint it, and look for it in the destination.
total=0; missing=0
while IFS= read -r -d '' file; do
  total=$((total + 1))
  print=$(shasum -a 256 < "$file" | cut -c1-64)
  if [ -z "$print" ]; then
    echo "UNREADABLE: $file"; missing=$((missing + 1))      # couldn't read it, so it can't be confirmed
  elif ! grep -qxF "$print" <<< "$dest_prints"; then
    echo "MISSING: $file"; missing=$((missing + 1))         # no file in the destination has these contents
  fi
done < <(find "$card" "${skip_dirs[@]}" -o -type f ! \( "${skip_files[@]}" \) -print0)

# Step 3: count what the skip rule left out on the card, so nothing is hidden.
skipped=$(find "$card" \( -name .Spotlight-V100 -o -name .Trashes -o -name .fseventsd \) -prune -print \
          -o -type f \( "${skip_files[@]}" \) -print | wc -l | tr -d ' ')
echo "Skipped $skipped macOS housekeeping item(s) on the card (._ files, .DS_Store, system folders)."

# Step 4: the verdict. Exit code 0: everything is there. 1: something is missing. 2: wrong usage.
if [ "$total" -eq 0 ]; then echo "NO FILES: nothing to check on the card."; exit 2; fi
if [ "$missing" -eq 0 ]; then echo "OK: all $total card files are in the destination"; exit 0; fi
echo "MISSING: $missing of $total"; exit 1
