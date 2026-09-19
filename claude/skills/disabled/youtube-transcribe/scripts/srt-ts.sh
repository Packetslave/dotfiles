#!/usr/bin/env bash
# srt-ts.sh — outline timestamps from a transcript.srt, without the two classic
# mistakes: grabbing the subtitle INDEX line instead of the arrow line (which a
# bare `grep -B2 | grep '^[0-9]'` does), and slicing HH:MM:SS to mm:ss, which
# silently drops the hour on a 60+ minute video (papercut 13ecfef7).
#
# usage: srt-ts.sh <transcript.srt> <phrase>...
#
# Output: one header line `last-timestamp HH:MM:SS <secs>` (compare <secs> to
# duration_seconds in metadata.json; near zero means the hour was lost), then
# per phrase every match (up to 5) as `HH:MM:SS <secs> <phrase>`, or a MISSING
# line. Matching is case-insensitive and literal. A phrase spanning a segment
# boundary will not match — shorten it to words inside one segment. Use the
# <secs> column for the outline's ?t= links.
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <transcript.srt> <phrase>..." >&2
  exit 2
fi
srt="$1"; shift
[ -f "$srt" ] || { echo "not a file: $srt" >&2; exit 2; }

to_secs() {  # HH:MM:SS -> total seconds
  local h m s
  IFS=: read -r h m s <<<"$1"
  echo $((10#$h*3600 + 10#$m*60 + 10#$s))
}

# The arrow line's start time is the segment's timestamp; keep all three fields.
arrow_starts() {  # stdin: srt excerpt -> stdout: HH:MM:SS per arrow line
  grep -E -- '-->' | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' || true
}

last=$(arrow_starts < "$srt" | tail -1)
printf 'last-timestamp %s %s\n' "$last" "$(to_secs "$last")"

for p in "$@"; do
  found=0
  while IFS= read -r ts; do
    [ -n "$ts" ] || continue
    printf '%s %-6s %s\n' "$ts" "$(to_secs "$ts")" "$p"
    found=$((found+1))
    [ "$found" -ge 5 ] && break
  done < <(grep -i -F -B2 -- "$p" "$srt" | arrow_starts)
  [ "$found" -eq 0 ] && printf 'MISSING  -      %s\n' "$p"
done
