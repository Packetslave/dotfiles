#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML>=6"]
# ///
"""Tests for journal-compile.py. Run as a close-out quality gate.

Every test drives the CLI in a temporary repo tree — nothing reaches into the
compiler's internals, so the tests constrain the contract rather than the
implementation. Silent-when-clean is the gaps script's contract, not this one:
a test runner that prints nothing on success is indistinguishable from one that
did not run, so success prints a single count line.
"""

import difflib
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

SCRIPT = Path(__file__).resolve().parent / "journal-compile.py"

UPS_FRAGMENT = """\
---
type: journal-fragment
date: 2026-08-29
time: "09:14"
host: lunchbox
summary: Landed the UPS health rules.
projects:
  - homelab
sources:
  - live
---

**[[homelab]]** — Four slow-burn rules landed as `83f9cf8`.
"""

# Both a single and a double quote in the summary, and a double quote in the
# prose: the exact shape that silently broke the hand-merged summary scalar.
TOOLING_FRAGMENT = """\
---
type: journal-fragment
date: 2026-08-29
time: "14:02"
host: mfa1
summary: Replaced the journal's "summary" scalar with compiled fragments.
projects:
  - assistant
  - homelab
sources:
  - live
  - git
---

**Tooling** — The old note used one `summary:` scalar that every session
hand-merged; an unescaped `"` hid a whole day from the index.
"""

EXPECTED_NOTE = """\
---
type: journal
title: '2026-08-29'
date: 2026-08-29
projects:
  - homelab
  - assistant
summary: Landed the UPS health rules. Replaced the journal's "summary" scalar with compiled fragments.
sources:
  - live
  - git
tags:
  - journal
generator: journal-compile
---

# 2026-08-29

## 09:14 · lunchbox — ups-alerts

**[[homelab]]** — Four slow-burn rules landed as `83f9cf8`.

## 14:02 · mfa1 — journal-fragments

**Tooling** — The old note used one `summary:` scalar that every session
hand-merged; an unescaped `"` hid a whole day from the index.
"""


def run(root: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(SCRIPT), *args, "--root", str(root)],
        capture_output=True,
        text=True,
        check=False,
    )


def write_fragment(root: Path, date: str, name: str, text: str) -> Path:
    day = root / "Journal" / date[:4] / date
    day.mkdir(parents=True, exist_ok=True)
    path = day / name
    path.write_text(text, encoding="utf-8")
    return path


def note(root: Path, date: str) -> Path:
    return root / "Journal" / date[:4] / f"{date}.md"


def standard_day(root: Path) -> None:
    write_fragment(root, "2026-08-29", "091400-lunchbox-ups-alerts.md", UPS_FRAGMENT)
    write_fragment(root, "2026-08-29", "140200-mfa1-journal-fragments.md", TOOLING_FRAGMENT)


# --- tests ------------------------------------------------------------------


def test_compiles_a_day_byte_exactly(root: Path) -> None:
    standard_day(root)
    result = run(root, "compile", "--date", "2026-08-29")
    assert result.returncode == 0, result.stderr
    actual = note(root, "2026-08-29").read_text(encoding="utf-8")
    diff = "".join(
        difflib.unified_diff(
            EXPECTED_NOTE.splitlines(keepends=True),
            actual.splitlines(keepends=True),
            "expected",
            "actual",
        )
    )
    assert actual == EXPECTED_NOTE, f"\n{diff}"


def test_compilation_is_idempotent(root: Path) -> None:
    standard_day(root)
    run(root, "compile", "--all")
    first = note(root, "2026-08-29").read_bytes()
    second_run = run(root, "compile", "--all")
    assert note(root, "2026-08-29").read_bytes() == first
    assert "unchanged" in second_run.stdout, second_run.stdout


def test_frontmatter_survives_quotes_in_prose(root: Path) -> None:
    standard_day(root)
    run(root, "compile", "--all")
    text = note(root, "2026-08-29").read_text(encoding="utf-8")
    meta = yaml.safe_load(text.split("---\n")[1])
    assert meta["type"] == "journal"
    assert meta["title"] == "2026-08-29"
    assert str(meta["date"]) == "2026-08-29"
    assert meta["tags"] == ["journal"]
    assert meta["summary"] == (
        "Landed the UPS health rules. "
        'Replaced the journal\'s "summary" scalar with compiled fragments.'
    )


def test_orders_chronologically_and_unions_metadata(root: Path) -> None:
    # Written out of order on disk; filename order is the chronological order.
    write_fragment(root, "2026-08-29", "140200-mfa1-journal-fragments.md", TOOLING_FRAGMENT)
    write_fragment(root, "2026-08-29", "091400-lunchbox-ups-alerts.md", UPS_FRAGMENT)
    run(root, "compile", "--all")
    text = note(root, "2026-08-29").read_text(encoding="utf-8")
    meta = yaml.safe_load(text.split("---\n")[1])

    assert meta["projects"] == ["homelab", "assistant"], meta["projects"]
    assert meta["sources"] == ["live", "git"], meta["sources"]
    assert meta["summary"].startswith("Landed the UPS health rules.")
    assert text.index("## 09:14 · lunchbox") < text.index("## 14:02 · mfa1")


def test_leaves_days_without_fragments_frozen(root: Path) -> None:
    stale = note(root, "2026-08-27")
    stale.parent.mkdir(parents=True, exist_ok=True)
    original = "---\ntype: journal\nsummary: \"an unbalanced quote\ndoes not matter here\n"
    stale.write_text(original, encoding="utf-8")
    standard_day(root)

    assert run(root, "compile", "--all").returncode == 0
    assert stale.read_text(encoding="utf-8") == original
    assert run(root, "check").stdout == ""


def test_refuses_to_overwrite_a_hand_written_note(root: Path) -> None:
    # The cutover day, and any day backfilled by hand: prose nothing else holds.
    hand_written = note(root, "2026-08-29")
    hand_written.parent.mkdir(parents=True, exist_ok=True)
    original = '---\ntype: journal\nsummary: "hand-merged"\ntags:\n  - journal\n---\n\nprose\n'
    hand_written.write_text(original, encoding="utf-8")
    standard_day(root)

    result = run(root, "compile", "--all")
    assert result.returncode == 1
    assert "refusing to overwrite" in result.stderr, result.stderr
    assert hand_written.read_text(encoding="utf-8") == original
    assert "hand-written note" in run(root, "check").stdout


def test_check_reports_an_uncompiled_day(root: Path) -> None:
    standard_day(root)
    result = run(root, "check")
    assert "2026-08-29 (no compiled note)" in result.stdout, result.stdout


def test_check_reports_a_note_behind_its_fragments(root: Path) -> None:
    standard_day(root)
    run(root, "compile", "--all")
    write_fragment(
        root,
        "2026-08-29",
        "170000-johnny5-late-session.md",
        UPS_FRAGMENT.replace('time: "09:14"', 'time: "17:00"').replace("host: lunchbox", "host: johnny5"),
    )
    result = run(root, "check")
    assert "2026-08-29 (out of date)" in result.stdout, result.stdout


def test_check_is_silent_when_clean(root: Path) -> None:
    standard_day(root)
    run(root, "compile", "--all")
    result = run(root, "check")
    assert result.stdout == "", result.stdout
    assert result.returncode == 0


def test_check_reports_a_malformed_fragment_without_crashing(root: Path) -> None:
    standard_day(root)
    write_fragment(root, "2026-08-29", "180000-mfa1-broken.md", "no frontmatter at all\n")
    result = run(root, "check")
    assert "malformed fragment" in result.stdout, result.stdout
    assert result.returncode == 0


def test_rejects_an_unquoted_time(root: Path) -> None:
    # Bare 14:32 is a YAML 1.1 sexagesimal integer, not a clock time.
    write_fragment(
        root,
        "2026-08-29",
        "143200-mfa1-sexagesimal.md",
        UPS_FRAGMENT.replace('time: "09:14"', "time: 14:32"),
    )
    result = run(root, "compile", "--all")
    assert result.returncode == 1
    assert "must be quoted" in result.stderr, result.stderr
    assert not note(root, "2026-08-29").exists()


def test_rejects_a_time_that_disagrees_with_the_filename(root: Path) -> None:
    # Fragments sort by filename but render their frontmatter time; a typo in
    # either would show the day's sessions out of the order they sorted in.
    write_fragment(
        root,
        "2026-08-29",
        "091400-lunchbox-ups-alerts.md",
        UPS_FRAGMENT.replace('time: "09:14"', 'time: "19:14"'),
    )
    result = run(root, "compile", "--all")
    assert result.returncode == 1
    assert "does not match the 091400 in the filename" in result.stderr, result.stderr


def test_rejects_a_fragment_filed_under_the_wrong_day(root: Path) -> None:
    write_fragment(root, "2026-08-30", "091400-lunchbox-ups-alerts.md", UPS_FRAGMENT)
    result = run(root, "compile", "--date", "2026-08-30")
    assert result.returncode == 1
    assert "does not match directory" in result.stderr, result.stderr


def test_errors_when_the_requested_day_has_no_fragments(root: Path) -> None:
    result = run(root, "compile", "--date", "2026-08-29")
    assert result.returncode == 1
    assert "no fragment directory" in result.stderr, result.stderr


# --- runner -----------------------------------------------------------------


def main() -> int:
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    failures = 0
    for test in tests:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Journal" / "2026").mkdir(parents=True)
            try:
                test(root)
            except AssertionError as exc:
                failures += 1
                print(f"FAIL {test.__name__}: {exc}", file=sys.stderr)
            except Exception as exc:  # noqa: BLE001 — a crash is a failure, not a stack trace
                failures += 1
                print(f"ERROR {test.__name__}: {exc!r}", file=sys.stderr)
    if failures:
        print(f"journal-compile: {failures} of {len(tests)} tests failed", file=sys.stderr)
        return 1
    print(f"journal-compile: {len(tests)} tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
