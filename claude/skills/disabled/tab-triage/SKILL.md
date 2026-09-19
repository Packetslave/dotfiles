---
name: tab-triage
description: Enumerate every open Chrome tab across all profiles on macOS, group them into themes, and recommend a disposition for each (keep / read-later / bookmark / actionable / close). Use whenever Brian wants help with an overgrown tab list, asks what's open, or wants a working set pruned. Read-only — it never closes a tab.
triggers:
  - help me with my tabs / my open tabs
  - what do I have open in chrome
  - triage my tabs / clean up my tabs
  - how many tabs do I have
  - what's in this chrome window
---

# Tab Triage

Reads every open Chrome tab, attributes each to its Chrome profile, and produces
a per-tab recommendation. **Brian closes the tabs; the skill never does.** That
split is deliberate — see "Why read-only" below.

**Script:** `Skills/tab-triage/scripts/chrome-tabs.py` (self-executable uv
script, stdlib-only — run directly by absolute path). No credentials, no
network egress; it talks to the local Chrome via JXA and reads files under
`~/Library/Application Support/Google/Chrome/`.

```
chrome-tabs.py                      # JSON: window_label, window_id, index, tab id, title, url, profile, domain
chrome-tabs.py --text               # readable, grouped by window
chrome-tabs.py --stats              # counts by window/profile/domain + duplicate URLs
chrome-tabs.py --windows            # just the window table: label, id, tab count, profile, source
chrome-tabs.py --profile "Brian"    # filter to one profile (display name)
chrome-tabs.py --set-profile 1759375689='610systems'   # pin a window by hand, permanently
```

Start with `--stats` to size the job, then `--text` to actually read the list.

## Window identity: labels are stable, indices are not

Chrome reorders its window list freely — between two dumps an hour apart on
2026-08-29 the 54-tab personal window moved from position 3 to position 2, with
no user action. So a window's **index is not a name for it**, and anything that
records `w3[19]` against an index goes silently wrong on the next dump: the
reference still resolves, just to a different tab.

Chrome's window **`id` is stable** for the window's lifetime (same four ids came
back reordered across those two dumps). The script keys everything on it:

- `~/.config/tab-triage/window-profiles.json` maps window id → `{label, profile,
  confidence, source}`.
- A **label** (`w1`, `w2`, …) is assigned on first sight and remembered, so `w2`
  means the same window tomorrow as today. `--text` and `--stats` print labels,
  not raw positions.
- The **profile** is resolved once and cached, so the heuristic below runs only
  for windows never seen before.
- Entries for windows that no longer exist are dropped on each run — a closed
  window's id never comes back.

**Whether ids survive a Chrome restart is untested.** They look timestamp-derived
(`1759375719` is a plausible epoch value), so session restore may well preserve
them — but that has not been checked, so do not rely on it either way. It does
not matter much: if ids persist, labels persist with them; if they do not, every
window is new, labels are reassigned from `w1`, and an old worksheet's references
are stale wholesale. Either way the cache self-heals on the next run, and a
re-dump is the fix. Delete the cache file to force re-derivation at any time.

**`--set-profile <window-id>=<profile name>` pins a window by hand** and sets
`source: manual`, which the heuristic then never overrides. Use it when a window
is genuinely ambiguous — a brand-new window with two generic tabs — rather than
letting a low-confidence guess stand. It validates the profile name against
Chrome's `Local State` and refuses an unknown window id.

## Profiles: how attribution works, and why it's a heuristic

Brian runs several Chrome profiles (as of 2026-08-29: `Default` = "Brian",
`Profile 1` = "packetslave.com", `Profile 2` = "610systems"). He uses Chrome's
**built-in profile switcher**, not separate `--user-data-dir` instances — so
every profile's windows live inside **one** Chrome process, and JXA sees all of
them at once. Nothing is hidden. Confirm with:

```
ps -axo command | grep -o -- "--user-data-dir=[^ ]*" | sort -u
```

If that ever shows more than the default path, he's switched to separate
instances and each one needs to be scripted separately — the current script
would only see whichever registered as "Google Chrome".

The gap is *attribution*: Chrome's scripting dictionary exposes no profile
attribute, and window titles don't carry the profile (a window titled with a
Gmail address just has Gmail focused). Two rejected approaches:

- **Accessibility API** (the profile chip in the toolbar): `osascript` is not
  granted assistive access, and granting it is a broad permission for a small
  gain. Fails with `-25211`.
- **Window title parsing:** unreliable, as above.

What the script does instead: extract URLs from each profile's newest two
`Sessions/Session_*` files and score each live window by URL overlap. Observed
88–92% overlap with an unambiguous winner per window. **Confidence is reported,
not hidden** — treat anything under ~60%, or a `?`, as unattributed rather than
trusting it. Expect that for incognito windows (no session file) and windows
whose URLs Chrome hasn't flushed yet.

## Why read-only

Closing tabs is unrecoverable in practice — Chrome's "reopen closed tab" is
shallow and a 90-tab sweep can't be undone. The value here is the *judgment*
(what's a duplicate, what's a stalled research cluster, what's a real to-do),
not the mechanical close. So the skill produces a recommendation list and Brian
acts on it. Do not add a `--close` flag without asking him first.

## Triage categories

Sort every tab into exactly one:

1. **Working set** — an active, coherent task in progress. Keep. Name the task
   so he can see the cluster (e.g. "gmail-duckdb OAuth setup", "SES + IAM").
2. **Duplicate** — same URL twice, or the same content from two sources (a
   paper on both arxiv and a publisher PDF). Keep one.
3. **Transient** — a Google search result page, a typo'd query, a `chrome://`
   AI-search URL. These are never worth keeping; call them out as trash.
4. **Read-later** — an article or paper he hasn't read. → Instapaper
   (`mcp__instapaper__add_bookmark`).
5. **Reference** — a tool/repo/doc he'll want to find again but isn't reading.
   → Pinboard (`mcp__pinboard__*`, or the **pinboard-write** skill).
6. **Actionable** — the tab is standing in for a task ("buy this", "set this
   up", a half-filled credential form). → a Linear issue (`linear.py create`), or OmniFocus for
   personal errands.
7. **Watch-later** — YouTube. Batch these; don't file them one at a time.
8. **Research cluster** — many tabs on one question (e.g. ten AI-memory
   projects). The tabs *are* the notes. Recommend one wiki page via
   `/claude-obsidian:save` capturing the comparison, then close all of them.
   This is where the biggest reduction comes from.

Report grouped by theme, not by window — the themes cross windows. Give counts
so he can see the shape before reading the detail.

## Gotchas

- **macOS only.** JXA/AppleScript. Brian doesn't run Chrome on Linux, so
  there's deliberately no CDP fallback.
- **Chrome must already be running.** The script refuses otherwise, because
  `Application("Google Chrome")` in JXA would silently *launch* it.
- **`ls` is aliased to `eza`** in this shell; `eza -t` takes an argument and
  will eat a following path. Use `/bin/ls` in any shell work here.
- **Tab counts and positions move under you** — 88 → 92 → 98 tabs across three
  dumps in one evening, with nothing closed. Window *labels* are stable (above),
  but a tab's `index` within its window is not, and neither is the tab list.
  Re-dump before acting on any reference. When persisting state about a tab
  (a checklist, a worksheet), key it on the **URL** or the tab `id`, never on
  `label[index]` — the worksheet's first version keyed checkboxes on the ref and
  every tick would have migrated to the wrong row at the first reorder.
