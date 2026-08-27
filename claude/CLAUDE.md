# Global instructions

Applies to every Claude Code session on this machine, in any repository.
Project-level `CLAUDE.md` files add to this; where they genuinely conflict, the
project file wins.

## Staging commits

**Never `git add -A`, `git add .`, or `git commit -a`.** Stage explicit paths,
in every repository, every time.

The reason is not tidiness. Several Claude Code sessions can be running against
one checkout at once, and unrelated work is routinely sitting in the tree beside
yours — another session's in-flight edits, a hook's regenerated file, a build
artifact. A blanket stage sweeps all of it into your commit, under your message,
and the mistake is invisible in the commit you just made: nothing errors, and
the diff looks like something you wrote. It has happened (2026-08-27, cowork —
a parallel session's uncommitted skill edit, caught only because the diffstat
was read before committing).

- **`git status` is not a list of *your* changes.** Diff each path before you
  stage it.
- **Re-check `git status` between commits** — the tree moves under you.
- If a file you did not touch is dirty, leave it alone and say so in the report.
- Staging a generated or exported file (a JSONL export, a lockfile)? Confirm its
  diff contains only your own changes first.

`git add -p` is fine, as is `git add <path>` for a file or directory you
genuinely own in full.

## Searching the filesystem

**Never run a full recursive scan of the filesystem root or the home
directory.** No `find /`, `find ~`, `rg` / `grep -r` over `/` or `$HOME`, `ls -R
~`, or equivalent. They are slow, bury the useful result in permission errors
and cache noise, and wander into mounted volumes, backups and other people's
data.

**Scope every search to a known root** — the repository you are working in, a
specific config directory, a Homebrew prefix, a single collection path.

**Better: ask the tool that already knows.** A broad scan is almost always a
lazy substitute for a precise query that exists:

| Instead of scanning for… | Ask |
|---|---|
| an ansible module's file or options | `ansible-doc <collection>.<module>` |
| where a collection is installed | `ansible-galaxy collection list` |
| a formula's install prefix | `brew --prefix <formula>` |
| a Python module's path | `python3 -c "import x; print(x.__file__)"` |
| an executable's location | `command -v <name>` |
| a library's flags | `pkg-config --cflags --libs <lib>` |
| files tracked by a repo | `git ls-files` / `git grep` |

If a wide search really is the right tool, say what root you are scoping it to
and why the targeted query does not work.
