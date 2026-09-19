#!/usr/bin/env bash
# Headless morning run of the tldr-daily-summary skill.
# Installed as a cron job on mfa1 (runs as blanders, 0 7 * * 1-6 local time, from the
# dedicated clone ~/src/cowork-cron — never the interactive checkout, whose dirty
# tree and shared index would break the pull and the commit); logs to ~/logs/.
# Moved from seaside 2026-09-16 (seaside is not reachable off the tailnet).
# Requires: the Homebrew claude CLI, authenticated (run `claude` once
# interactively after provisioning a new machine).
#
# This script — not the model — owns the Healthchecks.io pings. The agent run is the
# thing being monitored, so it must not also be the thing reporting on itself: a run
# that is truncated, confused, or exits early would otherwise skip its own fail ping,
# or claim a success it never sent. See Skills/healthcheck-task-monitoring/SKILL.md.
set -euo pipefail

# The clone this script lives in, so the cron runs whichever checkout it was installed from.
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
CLAUDE="/home/linuxbrew/.linuxbrew/bin/claude"
HOST="$(hostname)"
LOG_DIR="$HOME/logs"
HC_URL="https://hc-ping.com/20176588-fb1c-4af7-baf1-62e4d9916838"

mkdir -p "$LOG_DIR"
exec >>"$LOG_DIR/tldr-cron-$(date -u +%Y-%m-%d).log" 2>&1
echo "=== $(date -u '+%Y-%m-%dT%H:%M:%SZ') starting"

# Monitoring must never be the reason the job fails, so ping errors are swallowed.
hc_ping() {
  curl -fsS -m 10 --retry 3 "${HC_URL}${1:-}" >/dev/null 2>&1 || \
    echo "warning: healthcheck ping '${1:-success}' failed"
}

# Any exit before the explicit success at the bottom is a failure worth paging on —
# non-zero exit from claude, a missing output file, a failed push, or a SIGTERM.
SUCCEEDED=0
on_exit() {
  if [[ "$SUCCEEDED" -eq 0 ]]; then
    echo "=== $(date -u '+%Y-%m-%dT%H:%M:%SZ') FAILED — sending fail ping"
    hc_ping /fail
  fi
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

hc_ping /start

cd "$REPO"
git pull --ff-only

"$CLAUDE" -p --dangerously-skip-permissions \
  "Run the tldr-daily-summary skill (Skills/tldr-daily-summary/SKILL.md) for today. This is a headless cron run on $HOST: skip the present_files call in Step 12 (that tool does not exist here). Do not send any Healthchecks.io pings — the wrapper script does that. Everything else applies as written, including moving processed threads from 051-Lists-1 to 800-Archives/801-Lists-1 and marking them read."

TODAY=$(TZ=America/Los_Angeles date +%Y-%m-%d)
OUT="output/md/tldr-daily-summary-$TODAY.md"
if [[ ! -f "$OUT" ]]; then
  echo "ERROR: expected output file $OUT not found"
  exit 1
fi

git add "$OUT"
git commit -m "tldr: daily summary $TODAY ($HOST cron)" || echo "nothing to commit"
# A push can lose the race with a concurrent session's push (2026-09-16: rejected
# non-fast-forward, digest stranded). The clone is clean and the digest is its only
# local commit, so one rebase-and-retry is safe.
git push || { git pull --rebase && git push; }

SUCCEEDED=1
hc_ping
echo "=== $(date -u '+%Y-%m-%dT%H:%M:%SZ') done"
