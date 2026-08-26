# Global instructions

Applies to every Claude Code session on this machine, in any repository.
Project-level `CLAUDE.md` files add to this; where they genuinely conflict, the
project file wins.

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
