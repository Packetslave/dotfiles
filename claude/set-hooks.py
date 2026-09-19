#!/usr/bin/env -S uv run --script
"""Merge dotfiles' claude/hooks.json into the "hooks" key of ~/.claude/settings.json.

settings.json is owned and rewritten by Claude Code (plugin toggles, GrowthBook
flags, etc.), so it must not be symlinked or templated -- see set-retention.py.
This merges one key from the dotfiles source of truth and leaves everything
else untouched, writing a .bak alongside on first change.

    ./set-hooks.py            # apply
    ./set-hooks.py --check    # report what WOULD happen, change nothing
    ./set-hooks.py --show     # report the current value

Output is prefixed with a stable token so config management can parse it:

    CHANGED:      the file was modified
    WOULD-CHANGE: --check, and applying would modify the file
    OK:           already at the requested value, nothing to do

Ansible note: `ansible.builtin.command` is SKIPPED under --check by default, which
would make a check run silently test nothing. The calling task must therefore set
`check_mode: false` and pass --check through itself, e.g.

    cmd: python3 ~/dotfiles/claude/set-hooks.py {{ '--check' if ansible_check_mode else '' }}
    check_mode: false
    changed_when: claude_hooks.stdout is match('(CHANGED|WOULD-CHANGE)')
"""

import json
import os
import shutil
import sys

KEY = "hooks"
SOURCE = os.path.expanduser("~/dotfiles/claude/hooks.json")
PATH = os.path.expanduser("~/.claude/settings.json")
HOST = os.uname().nodename


def main() -> int:
    args = [a for a in sys.argv[1:] if a]

    if not os.path.exists(PATH):
        print(f"OK: {HOST} has no {PATH} -- nothing to do")
        return 0

    with open(SOURCE) as fh:
        desired = json.load(fh)

    with open(PATH) as fh:
        settings = json.load(fh)

    current = settings.get(KEY)

    if args and args[0] == "--show":
        print(f"{HOST}: {KEY} = {json.dumps(current)}")
        return 0

    check_only = "--check" in args

    if current == desired:
        print(f"OK: {HOST} {KEY} already up to date")
        return 0

    if check_only:
        print(f"WOULD-CHANGE: {HOST} {KEY} would be updated from {SOURCE}")
        return 0

    shutil.copy2(PATH, PATH + ".bak")
    settings[KEY] = desired

    tmp = PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(settings, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, PATH)

    print(f"CHANGED: {HOST} {KEY} updated from {SOURCE} (backup at {PATH}.bak)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
