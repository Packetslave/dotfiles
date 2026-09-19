---
name: journal
description: Write this session's contribution to the per-day work journal in Journal/ as a fragment, compile the day's note, or sweep git history for un-journaled days. Use at session close, and on "journal this," "log today's work," "update the journal," "journal sweep."
---

# Journal

The running record of what Brian and Claude accomplished together. Two kinds of
file, and the distinction is the whole design:

- **Fragments** — `Journal/<year>/<YYYY-MM-DD>/<HHMMSS>-<host>-<slug>.md`. One
  per session, **authored**, created once and never rewritten by anyone else.
- **The daily note** — `Journal/<year>/<YYYY-MM-DD>.md`. **Generated** from that
  day's fragments by `scripts/journal-compile.py`. Nobody edits it by hand —
  not you, not Brian, not even to fix an obvious typo.

Several sessions close on the same day, from several machines. Because each
writes a filename no other session can produce, they cannot clobber each other:
the conflict class is gone structurally rather than by everyone being careful.

`Journal/journal.base` is the browsable index (it lists `type: journal`, so
fragments never appear in it); `Journal/_index.md` explains the system. The
journal records *what happened when*; durable facts belong in the wiki
(CLAUDE.md § Memory) and a journal entry never edits `wiki/` files.

## Writing an entry (session close)

**1. Resolve the day, the time and the host — explicitly.**

```bash
TZ=America/Los_Angeles date '+%Y-%m-%d %H%M%S %H:%M'
hostname -s
```

Pin the timezone. mfa1 and seaside run UTC, so bare `date` names *tomorrow* for
about seven hours every evening, and the entry lands on the wrong calendar day.

**2. Write one fragment.** Create
`Journal/<year>/<date>/<HHMMSS>-<host>-<slug>.md`, where `<slug>` is a short
kebab-case tag for this session's work (`ups-alerts`, `journal-fragments`).
Create the day directory if it does not exist; never write to a fragment path
that already exists.

```markdown
---
type: journal-fragment
date: 2026-08-29
time: "14:02"
host: mfa1
summary: One line covering THIS session — it becomes part of the day's summary.
projects:
  - homelab
sources:
  - live
---

**[[homelab]]** — What was accomplished, in complete sentences with outcomes and
numbers. Receipts inline: [[homelab]], commit `83f9cf8`, issue PAC-611.

**Tooling** — Next work thread, same shape.
```

- `time:` **must be quoted.** Bare `14:02` is a YAML 1.1 sexagesimal integer,
  not a clock time; the compiler rejects it rather than printing `862`.
- `summary:` covers *this session only*. The day's summary is every fragment's
  one-liner joined in time order — there is no shared scalar to hand-merge, and
  quoting is the compiler's problem, not yours.
- One bolded project paragraph per work thread; prose, not bullet fragments.
  Include what was decided and what failed, not just what landed.
- `projects:` uses kebab-case names matching wiki pages where they exist
  (`env8oy`, `rock-camp`, `matrix`); `tooling` for environment/skill/infra work,
  `assistant` for work on the assistant system itself. The day's `projects:` and
  `sources:` are the union across fragments.
- `sources: [live]` for a fragment written the same day; a backfilled one lists
  what it was reconstructed from (`git`, `wiki-log`, `transcripts`).
- Wikilinks are for vault pages. A repo artifact gets a plain path in backticks,
  or `wiki-lint` reports a dead link.

**3. Compile the day.**

```bash
"$(git rev-parse --show-toplevel)"/Skills/journal/scripts/journal-compile.py compile
```

With no arguments it compiles today (America/Los_Angeles). It is idempotent —
running it again on unchanged fragments rewrites nothing. Commit the fragment
and the regenerated note together.

**In a Cowork sandbox session, write the fragment and stop.** Do not compile:
the FUSE mount's stale-read quirks could commit a mangled note. The day goes
stale, `check` says so, and the next native close-out heals it.

**Done when** every accomplishment of the session — implemented, fixed, built,
decided — has a paragraph in the fragment carrying its receipts, and (native
sessions) the compiled note is current.

## Correcting a day

Edit the **fragment**, then recompile. A correction applied to the daily note is
erased by the next compile, and until then the note and its fragments disagree
with nothing to say which is right.

```bash
"$(git rev-parse --show-toplevel)"/Skills/journal/scripts/journal-compile.py compile --date 2026-08-29
```

Brian can add a note to any day the same way: drop a fragment into the day's
directory and recompile. There is no special case for a human entry.

## Rebase conflict on the compiled note

When a rebase across another session's journal commit conflicts on
`Journal/<year>/<date>.md` (add/add or content), **do not merge the prose and
do not move anything into a fragment**. The note is generated; the conflict
markers are the only problem. During a rebase `--ours` is the UPSTREAM side —
the note already compiled from the other sessions' fragments — so take it,
recompile (your fragment is already in the day's directory), stage, continue:

```bash
git checkout --ours -- Journal/<year>/<date>.md
"$(git rev-parse --show-toplevel)"/Skills/journal/scripts/journal-compile.py compile --date <date>
git add Journal/<year>/<date>.md
GIT_EDITOR=true git rebase --continue
```

If you run `compile` before clearing the markers it refuses with a message that
names conflict markers; that is the guard reading an unparseable note, not a
hand edit. Bit twice (2026-09-01, 2026-09-13), hence this section.

## Checking

```bash
"$(git rev-parse --show-toplevel)"/Skills/journal/scripts/journal-compile.py check
```

Reports days whose fragments have no compiled note, whose note does not match
what its fragments compile to (a Cowork session's fragment, or a hand-edit), or
whose fragment is malformed. Silent when clean, and always exits 0. The
SessionStart hook runs it, so staleness surfaces at session start.

It compares bytes, not mtimes — git does not preserve mtimes, so an mtime test
would report noise after every clone or pull.

## Sweep (catch missed days)

1. Run `"$(git rev-parse --show-toplevel)"/Skills/journal/scripts/journal-gaps.sh` —
   it prints commit days with no journal coverage (silent when there are none).
   The SessionStart hook runs it too.
2. For each such date, reconstruct the day from `git log --stat --since/--until`
   for that date, plus `wiki/log.md` entries when they cover it. Write it as a
   fragment — `<HHMMSS>-<host>-backfill.md`, `sources: [git]` (add `wiki-log` if
   used) — and compile the day. Backfill heals through the same pipeline as a
   live day.
3. Done when every commit date has a journal note.

## Testing the compiler

```bash
"$(git rev-parse --show-toplevel)"/Skills/journal/scripts/journal-compile-test.py
```

Fixture-driven, CLI-seam only. Prints one line on success; run it after any
change to the compiler.

## History before the fragment era

Daily notes from before the cutover were hand-merged and have no fragment
directory. The compiler only ever visits days that have one, so those notes are
frozen by construction — nothing regenerates them, and they are not migrated.

A second guard backs that up. A compiled note carries `generator: journal-compile`
in its frontmatter, and the compiler **refuses to overwrite a note without that
stamp** (anything it cannot parse counts as hand-written, which is exactly the
note a stray quote broke). So dropping a fragment into a hand-written day — the
cutover day itself, or a day someone backfilled by hand — stops with an error
naming the file, instead of destroying prose nothing else holds a copy of. If
you genuinely want such a day compiled, move its body into a fragment first.
