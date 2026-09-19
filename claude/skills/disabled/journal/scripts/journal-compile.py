#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["PyYAML>=6"]
# ///
"""journal-compile.py — assemble per-session journal fragments into daily notes.

The daily note at Journal/<year>/<YYYY-MM-DD>.md is a *generated artifact*. The
authored records are per-session fragments at
Journal/<year>/<YYYY-MM-DD>/<HHMMSS>-<host>-<slug>.md, each written once by
exactly one session and never touched again. Two sessions can never write the
same path, so the concurrent-clobbering that a single shared daily note invites
cannot happen. This script is the only writer of the daily note.

    journal-compile.py compile                # today (America/Los_Angeles)
    journal-compile.py compile --date <day>   # one day
    journal-compile.py compile --all          # every fragment-bearing day
    journal-compile.py check                  # report days out of date; silent when clean

Compilation is deterministic and idempotent: the same fragments always produce
byte-identical output, and a note already matching its fragments is left alone
(not even its mtime moves). Frontmatter is emitted by PyYAML rather than
assembled from strings, so a quotation mark in anyone's prose can no longer
break the day's YAML and drop it out of the journal.base index.

History is frozen by construction, not by special-case code: the compiler only
ever visits days that have a fragment directory, so every pre-cutover daily note
is inert. A second guard backs that up — a compiled note is stamped
`generator: journal-compile`, and the compiler refuses to overwrite a note
without that stamp. So a fragment dropped into a day whose note was written by
hand (the cutover day, or any backfilled day) stops with an error instead of
destroying prose nothing else holds a copy of.

`check` compares the note's bytes against what its fragments compile to, rather
than comparing mtimes. Git does not preserve mtimes, so after any clone or pull
an mtime test reports noise; the content test is deterministic, and it also
catches a daily note that someone hand-edited (which is never correct — edit the
fragment and recompile).

Cowork sandbox sessions write fragments but must NOT compile: the FUSE mount's
stale-read quirks could commit a mangled note. The day self-heals at the next
native close-out, and `check` makes the staleness visible in the meantime.
"""

import argparse
import datetime
import re
import sys
from pathlib import Path
from zoneinfo import ZoneInfo

import yaml

TZ = ZoneInfo("America/Los_Angeles")
GENERATOR = "journal-compile"
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
FRAGMENT_RE = re.compile(r"^(\d{6})-(.+)$")
FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n?", re.DOTALL)


class FragmentError(Exception):
    """A fragment that cannot be compiled. Blast radius is its own day."""


class _Dumper(yaml.SafeDumper):
    """SafeDumper that indents list items under their key, matching the vault's style."""

    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


def repo_root(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    return Path(__file__).resolve().parents[3]


def today() -> str:
    return datetime.datetime.now(TZ).strftime("%Y-%m-%d")


def fragment_days(root: Path) -> list[tuple[str, Path]]:
    """Every day that has a fragment directory, oldest first."""
    journal = root / "Journal"
    days = [
        (day.name, day)
        for year in sorted(journal.glob("*"))
        if year.is_dir()
        for day in sorted(year.iterdir())
        if day.is_dir() and DATE_RE.match(day.name)
    ]
    return sorted(days, key=lambda d: d[0])


def note_path(day_dir: Path, date: str) -> Path:
    return day_dir.parent / f"{date}.md"


def read_fragment(path: Path, date: str) -> dict:
    text = path.read_text(encoding="utf-8")
    match = FRONTMATTER_RE.match(text)
    if not match:
        raise FragmentError(f"{path.name}: no YAML frontmatter")
    try:
        meta = yaml.safe_load(match.group(1)) or {}
    except yaml.YAMLError as exc:
        raise FragmentError(f"{path.name}: unparseable frontmatter: {exc}") from exc
    if not isinstance(meta, dict):
        raise FragmentError(f"{path.name}: frontmatter is not a mapping")

    if meta.get("type") != "journal-fragment":
        raise FragmentError(f"{path.name}: type must be 'journal-fragment'")
    for field in ("time", "host", "summary"):
        if not meta.get(field):
            raise FragmentError(f"{path.name}: missing required field '{field}'")
    if not isinstance(meta["time"], str):
        # Bare 14:32 parses as a YAML 1.1 sexagesimal integer, not a clock time.
        raise FragmentError(f'{path.name}: time must be quoted, e.g. time: "14:32"')
    if meta.get("date") and str(meta["date"]) != date:
        raise FragmentError(f"{path.name}: date {meta['date']} does not match directory {date}")
    stamp, slug = parse_name(path, str(meta["host"]))
    # Fragments sort by filename but render their frontmatter time; if the two
    # disagree the note displays its sessions out of the order it sorted them in.
    if meta["time"] != f"{stamp[:2]}:{stamp[2:4]}":
        raise FragmentError(
            f"{path.name}: time {meta['time']!r} does not match the {stamp} in the filename"
        )

    return {
        "time": meta["time"],
        "host": str(meta["host"]),
        "slug": slug,
        "summary": str(meta["summary"]).strip(),
        "projects": [str(p) for p in meta.get("projects") or []],
        "sources": [str(s) for s in meta.get("sources") or []],
        "body": text[match.end() :].strip("\n"),
    }


def parse_name(path: Path, host: str) -> tuple[str, str]:
    """The HHMMSS stamp and trailing kebab-case tag of <HHMMSS>-<host>-<slug>.md."""
    match = FRAGMENT_RE.match(path.stem)
    if not match:
        raise FragmentError(f"{path.name}: name must be <HHMMSS>-<host>-<slug>.md")
    stamp, rest = match.groups()
    prefix = f"{host}-"
    slug = rest[len(prefix) :] if rest.startswith(prefix) else rest.partition("-")[2]
    if not slug:
        raise FragmentError(f"{path.name}: name must be <HHMMSS>-<host>-<slug>.md")
    return stamp, slug


def note_state(note: Path, text: str) -> str:
    """How an existing daily note stands against what its fragments compile to.

    The one place that decision is made — `compile` and `check` are two reports
    of the same answer, and must never drift apart on what "current" means.

      missing     — no note yet
      current     — the note is exactly what the fragments compile to
      handwritten — a note this compiler did not write; never overwrite it
      stale       — a compiled note now behind its fragments
    """
    if not note.exists():
        return "missing"
    existing = note.read_text(encoding="utf-8")
    if existing == text:
        return "current"
    # Anything unparseable counts as hand-written — a note broken by a stray
    # quote is exactly the prose worth not destroying.
    match = FRONTMATTER_RE.match(existing)
    if not match:
        return "handwritten"
    try:
        meta = yaml.safe_load(match.group(1))
    except yaml.YAMLError:
        return "handwritten"
    if isinstance(meta, dict) and meta.get("generator") == GENERATOR:
        return "stale"
    return "handwritten"


def ordered_union(lists) -> list[str]:
    """Union preserving first-appearance order across chronological fragments."""
    seen: dict[str, None] = {}
    for items in lists:
        for item in items:
            seen.setdefault(item, None)
    return list(seen)


def compile_day(day_dir: Path, date: str) -> str | None:
    """The full text of the day's compiled note, or None if it has no fragments."""
    paths = sorted(p for p in day_dir.iterdir() if p.is_file() and p.suffix == ".md")
    if not paths:
        return None
    fragments = [read_fragment(p, date) for p in paths]

    frontmatter = {
        "type": "journal",
        "title": date,
        "date": datetime.date.fromisoformat(date),
        "projects": ordered_union(f["projects"] for f in fragments),
        "summary": " ".join(f["summary"] for f in fragments if f["summary"]),
        "sources": ordered_union(f["sources"] for f in fragments),
        "tags": ["journal"],
        "generator": GENERATOR,
    }
    emitted = yaml.dump(
        frontmatter,
        Dumper=_Dumper,
        sort_keys=False,
        allow_unicode=True,
        default_flow_style=False,
        width=1 << 30,
    ).rstrip("\n")

    parts = ["---", emitted, "---", "", f"# {date}", ""]
    for fragment in fragments:
        parts += [f"## {fragment['time']} · {fragment['host']} — {fragment['slug']}", ""]
        if fragment["body"]:
            parts += [fragment["body"], ""]
    return "\n".join(parts).rstrip("\n") + "\n"


def cmd_compile(args) -> int:
    root = repo_root(args.root)
    if args.all:
        days = fragment_days(root)
        if not days:
            print("No fragment directories under Journal/ — nothing to compile.")
            return 0
    else:
        date = args.date or today()
        if not DATE_RE.match(date):
            print(f"error: --date must be YYYY-MM-DD, got {date!r}", file=sys.stderr)
            return 2
        day_dir = root / "Journal" / date[:4] / date
        if not day_dir.is_dir():
            print(f"error: no fragment directory at {day_dir}", file=sys.stderr)
            return 1
        days = [(date, day_dir)]

    failed = False
    for date, day_dir in days:
        try:
            text = compile_day(day_dir, date)
        except FragmentError as exc:
            print(f"error: {date}: {exc}", file=sys.stderr)
            failed = True
            continue
        if text is None:
            print(f"error: {date}: fragment directory is empty", file=sys.stderr)
            failed = True
            continue
        note = note_path(day_dir, date)
        state = note_state(note, text)
        if state == "current":
            print(f"unchanged {note.relative_to(root)}")
        elif state == "handwritten":
            if "<<<<<<< " in note.read_text(encoding="utf-8", errors="replace"):
                # A rebase conflict on the generated note, not a hand edit: the
                # markers make it unparseable. Clear them and recompile.
                print(
                    f"error: {date}: {note.relative_to(root)} contains git conflict markers — "
                    "refusing to overwrite it. During a rebase take the upstream side "
                    f"(`git checkout --ours -- {note.relative_to(root)}`), then compile again; "
                    "do not move its content into a fragment.",
                    file=sys.stderr,
                )
            else:
                print(
                    f"error: {date}: {note.relative_to(root)} was written by hand, not compiled — "
                    "refusing to overwrite it. Move its content into a fragment in "
                    f"{day_dir.relative_to(root)}/ first, then compile.",
                    file=sys.stderr,
                )
            failed = True
        else:
            note.write_text(text, encoding="utf-8")
            print(f"wrote     {note.relative_to(root)}")
    return 1 if failed else 0


def cmd_check(args) -> int:
    root = repo_root(args.root)
    problems = []
    for date, day_dir in fragment_days(root):
        note = note_path(day_dir, date)
        try:
            text = compile_day(day_dir, date)
        except FragmentError as exc:
            problems.append(f"{date} (malformed fragment: {exc})")
            continue
        if text is None:
            continue
        state = note_state(note, text)
        if state == "missing":
            problems.append(f"{date} (no compiled note)")
        elif state == "handwritten":
            problems.append(f"{date} (hand-written note — move it into a fragment before compiling)")
        elif state == "stale":
            problems.append(f"{date} (out of date)")

    if problems:
        print(f"Journal days needing compilation: {', '.join(problems)}")
        print(
            'Run "$(git rev-parse --show-toplevel)"/Skills/journal/scripts/journal-compile.py compile --all '
            "(native sessions only — Cowork sandbox sessions leave this to the next native close-out)."
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subparsers = parser.add_subparsers(dest="command", required=True)

    compile_parser = subparsers.add_parser("compile", help="regenerate a day's note from its fragments")
    which = compile_parser.add_mutually_exclusive_group()
    which.add_argument("--date", help="day to compile (default: today, America/Los_Angeles)")
    which.add_argument("--all", action="store_true", help="compile every fragment-bearing day")
    compile_parser.add_argument("--root", help="repo root (default: inferred from this script's path)")
    compile_parser.set_defaults(func=cmd_compile)

    check_parser = subparsers.add_parser("check", help="report days out of date; silent when clean")
    check_parser.add_argument("--root", help="repo root (default: inferred from this script's path)")
    check_parser.set_defaults(func=cmd_check)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
