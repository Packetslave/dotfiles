---
name: omnifocus-triage
description: >
  Evidence-based sweep of the OmniFocus inbox that does the research before
  asking: cross-checks every item against the journal, beads, Gmail, public
  repos, and RDAP to find tasks that are likely already done, detects
  duplicate captures, and identifies tasks Claude can execute directly with
  the session's connectors — then presents the groups as numbered lists with
  receipts and acts only on Brian's bulk approval. The batch/research
  counterpart to gtd-inbox-processing's item-by-item clarify loop: triage
  shrinks and enriches the inbox, clarify empties it.
triggers:
  - triage my omnifocus inbox
  - what in my inbox is already done
  - which of my tasks can you do for me
  - find stale tasks
  - what can you knock out from my inbox
---

# OmniFocus Triage

Research-first triage of the OmniFocus inbox. Where **gtd-inbox-processing**
walks Brian through every item and asks, this skill *investigates* first and
asks once, in bulk. First run (2026-08-29, Cowork) cleared 8 of ~90 inbox
items as already-done/duplicates and executed 5 more directly.

**Tool access:** the OmniFocus MCP connector — `mcp__omnifocus__*` in native
Claude Code, `mcp__remote-devices__omnifocus__*` in Cowork. `list_inbox` on a
large inbox (~90 items ≈ 68KB) exceeds the tool-result cap and lands in a
saved file — read **all** of it before classifying; the newest items are at
the end.

## The sweep

1. Pull the full inbox and classify every item into four buckets:
   **likely already done** (with evidence), **duplicate capture**,
   **Claude-doable now**, and **leave alone**.
2. Verify the first bucket against real sources (below) — never from vibes.
3. Present the actionable buckets as numbered lists, one line of evidence
   each, so Brian can rule on them by number ("all 7 are done", "do 2, 6,
   and 7"). Summarize the leave-alone bucket in a sentence; never enumerate
   90 items back at him.
4. Act only after his call. Batch completions via
   `update_task {completed: true}`.

## Evidence sources for "likely done" (strongest first)

- **Journal** (`Journal/{year}/*.md`) — grep the task's distinctive nouns
  across entries dated **on or after** the capture date; the receipts
  (commits, bead IDs, PR links) make the case. A task captured at night is
  often done the next day (the packetslave-DNS-under-OpenTofu task was
  captured 8/26 evening, shipped 8/27).
- **Linear** (`PAC-*`; old `cowork-*` ids resolve via `linear.py resolve`) — a
  still-open issue means NOT done; a Done one is a receipt. `SameBrain-*` beads live on the work side and are unverifiable
  from a personal session — say so rather than guessing, and skip work-repo
  tasks (snooguts GHE, BigQuery, go/ links, expenses) entirely.
- **Gmail** — confirmation email patterns: "Welcome / your account is ready"
  (account-creation tasks), receipts, shipping/transfer notices. The
  *absence* of an expected confirmation is evidence the other way.
- **Public GitHub** — `raw.githubusercontent.com/Packetslave/...` settles
  "add X to bootstrap/dotfiles" tasks without needing the repo mounted.
- **RDAP** for domain-state tasks: `rdap.verisign.com/{com,net}/v1/domain/<d>`,
  `rdap.publicinterestregistry.org/rdap/domain/<d>`. The `.art` registry
  (CentralNic) blocks RDAP — infer from sibling domains in the same order,
  or from registrar emails.

Negative results are findings too: report what was checked and found NOT
done (with the check that failed to confirm), so Brian knows it was looked
at and the next sweep doesn't redo it.

## Judgment rules

- **"Verify X" ≠ "I asked about X."** Sending the outbound email does not
  complete a verify task — it converts it to a waiting-for (tag it, note the
  date, keep it open until the confirmation arrives).
- **Same-name duplicates** hide in a big inbox (two "charge front door cam
  battery" captures five weeks apart). Complete the older/unflagged one;
  keep the one with more context or the flag.
- **Indirect evidence gets flagged as such** — homelab alerts routing to
  Pushover *implies* the Pushover-app task is done, but say "weaker
  evidence" and let Brian confirm.
- A task whose residue is already tracked elsewhere (a follow-up bead) is
  done as an inbox item — the bead carries the remainder.

## What Claude can typically do (and not)

Doable from a Cowork session: Gmail drafts (`create_draft` — never send),
RDAP/web status checks, researching a captured link and writing the
what-it-is/why-care summary **into the task's note** (prefix
`Researched YYYY-MM-DD (Claude):`, keep the original note above it — triage
must survive outside the chat), edits in the mounted cowork repo,
twitter-ingest captures, filing/tagging/due-dating, and follow-up re-checks
via `send_later` (never in-process cron). Not doable: Reddit-internal
anything, machines not linked to the session, portals behind Brian's
logins/2FA (TTP, Waiver Watch), and physical-world tasks.

## Filing conventions (when Brian says where things go)

- **Waiting-for:** reuse the existing on-hold **Waiting** tag (2014-vintage
  — never create a parallel one). Brian's convention: **defer date = the day
  the waiting started** (a machine-sortable "waiting since"), **due date =
  when to follow up**. When a follow-up re-ups the wait, move the due date
  forward but never the defer — it preserves the true age of the wait.
  Append a dated status line to the note on every check.
- **Projects:** naming is `Area - Subarea` (`Travel - General`,
  `Tech - Startup - chassis`); folders are `Personal` (sub `Classes`) and
  `Reddit` (sub `Cloudflare`). Creating an `X - General` under Personal is
  fine when no project fits and Brian asked for filing.
- **Due dates:** Brian's convention encodes "due <day>" as midnight Pacific
  = `<day>T07:00:00Z` (T08:00:00Z during PST).
- **Duplicate project names:** `update_task`'s `project` field matches by
  name only — see the warning in `Skills/gtd-inbox-processing/SKILL.md` before
  filing into a possibly-ambiguous name.
