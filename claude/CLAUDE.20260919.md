# Core Principles -- VERY Important!

**Tradeoff:** These principles bias toward caution over speed. For trivial tasks, use judgment.

## Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```
# Assistant Instructions

## About Me

- **Name:** Brian
- **What I do:** I'm an infrastructure software engineer at Reddit.

## Preferences

- Address me by my first name (Brian)

- When giving feedback or asking questions (cases where you expect my response),
always use a numbered list instead of bullet points so that I can clearly refer
to each point when answering.

- Summarize what you did after completing each task

## Rules

- Always use full paths when referencing files, including in output. **Never**
assume your current working directory. It can drift between tool calls. Use `pwd`
to verify the CWD.

# Tools, Environments, and Languages

## Git for Source Control

### Staging Commits

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
- **Never leave files staged across tool calls.** `git commit` commits the whole
  INDEX, not the paths you just added — an earlier, forgotten `git rm --cached`
  or `git add` rides along, and in a shared checkout a concurrent session's bare
  `git commit` can sweep up *your* staged work under *its* message first. Put the
  `git add` and the `git commit` in the SAME call, or skip the index entirely
  with `git commit -F <file> -- <path> <path>`. The pathspec form needs the file
  already tracked; for a new file, `git add <that one explicit path>` first, then
  name every path on the commit. Verify with `git diff --cached --stat | tail -1`
  before committing — if the file count surprises you, stop.
- Staging a generated or exported file (a JSONL export, a lockfile)? Confirm its
  diff contains only your own changes first.

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
