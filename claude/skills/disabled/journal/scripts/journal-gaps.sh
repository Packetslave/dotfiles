#!/bin/bash
# Print work days (git commit dates) that have no Journal/ entry yet.
# Deterministic — used by the SessionStart hook and the journal skill's sweep.
# Silent when there are no gaps. Today is excluded (its entry is written at
# session close); dates before the repo's founding (2026-06-25) are ignored.
# Days are Brian's calendar days (America/Los_Angeles), the same clock the
# journal skill pins: mfa1 and seaside commit in UTC, so an evening's work
# carried its author's next-day date and was reported as a gap every morning.

REPO=${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
today=$(TZ=America/Los_Angeles date '+%Y-%m-%d')

covered=$(ls "$REPO"/Journal/*/ 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -u)
activity=$(TZ=America/Los_Angeles git -C "$REPO" log --format='%ad' --date=format-local:'%Y-%m-%d' 2>/dev/null | sort -u)

gaps=$(comm -23 <(echo "$activity") <(echo "$covered") | awk -v t="$today" '$0 < t && $0 >= "2026-06-25"')

if [ -n "$gaps" ]; then
  echo "Journal gaps — commit days with no Journal/ entry: $(echo "$gaps" | tr '\n' ' ')"
  echo "Backfill them via the journal skill's sweep procedure (Skills/journal/SKILL.md)."
fi
