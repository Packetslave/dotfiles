#!/usr/bin/env -S uv run --script
"""Set Claude Code's local session retention (cleanupPeriodDays) in ~/.claude/settings.json.

Claude Code prunes ~/.claude/projects/**/*.jsonl transcripts after cleanupPeriodDays
(default 30). Any archiving scheme that assumes transcripts persist on disk is wrong
past that window -- a machine offline longer than the period loses that history
permanently at its next launch.

settings.json is owned and rewritten by Claude Code, so it must not be symlinked or
templated. This merges one key and leaves everything else untouched, writing a .bak
alongside on first change.

    ./set-claude-retention.py 365            # apply
    ./set-claude-retention.py 365 --check    # report what WOULD happen, change nothing
    ./set-claude-retention.py --show         # report the current value

Output is prefixed with a stable token so config management can parse it:

    CHANGED:      the file was modified
    WOULD-CHANGE: --check, and applying would modify the file
    OK:           already at the requested value, nothing to do

Ansible note: `ansible.builtin.command` is SKIPPED under --check by default, which
would make a check run silently test nothing. The calling task must therefore set
`check_mode: false` and pass --check through itself, e.g.

    cmd: python3 ~/dotfiles/claude/set-retention.py 365 {{ '--check' if ansible_check_mode else '' }}
    check_mode: false
    changed_when: claude_retention.stdout is match('(CHANGED|WOULD-CHANGE)')
"""

import json
import os
import shutil
import sys

KEY = "cleanupPeriodDays"
PATH = os.path.expanduser("~/.claude/settings.json")
HOST = os.uname().nodename


def main() -> int:
    args = [a for a in sys.argv[1:] if a]
    if not args:
        print(__doc__)
        return 2

    if not os.path.exists(PATH):
        print(f"OK: {HOST} has no {PATH} -- nothing to do")
        return 0

    with open(PATH) as fh:
        settings = json.load(fh)

    current = settings.get(KEY)
    shown = current if current is not None else "ABSENT (default 30)"

    if args[0] == "--show":
        print(f"{HOST}: {KEY} = {shown}")
        return 0

    check_only = "--check" in args
    try:
        days = int(args[0])
    except ValueError:
        print(f"not an integer: {args[0]}")
        return 2

    if current == days:
        print(f"OK: {HOST} {KEY} already {days}")
        return 0

    if check_only:
        print(f"WOULD-CHANGE: {HOST} {KEY} {shown} -> {days}")
        return 0

    shutil.copy2(PATH, PATH + ".bak")
    settings[KEY] = days

    tmp = PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(settings, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, PATH)

    print(f"CHANGED: {HOST} {KEY} {shown} -> {days} (backup at {PATH}.bak)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
