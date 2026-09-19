---
name: email-triage
description: >
  Sweep Brian's Gmail inbox, characterize what's actually in there, and surface
  a ranked list of what needs attention — then file it on his instruction.
  Encodes his label taxonomy, what counts as noise vs. signal, how to compute
  the *real* deadline behind a notice, how to sanity-check "verify your
  account" mail before raising an alarm, how to cross-reference the sweep
  against the journal and beads, and how findings get captured into
  OmniFocus and Google Calendar. This is the Gmail inbox; for the OmniFocus
  inbox see gtd-inbox-processing, for the Drafts app see drafts-inbox.
triggers:
  - sweep my inbox
  - triage my email
  - scan my gmail
  - scan my inbox
  - what's in my inbox
  - anything new in email
  - another sweep
  - process my email
---

# Email Triage

Brian's inbox runs ~900 threads and ~570 unread. It is not a to-do list and it
is never going to be at zero. The job is **not** to touch every message — it is
to answer "is there anything in here I actually need to act on," file what he
directs, and leave the rest alone.

**Default posture: propose, then wait.** Summarize, rank, and recommend. Do not
file, archive, label, or mark-as-read until Brian gives instructions. He
typically replies with a numbered list keyed to your ranked items.

**Capture is also confirm-first.** Never create an OmniFocus task or calendar
event off your own judgment. Propose the exact text, project, tag, and date;
write it only after he says go.

---

## 1. Sweep

Two queries, in parallel:

```
in:inbox newer_than:<N>d      # N = days since last sweep, default 2
in:inbox is:unread            # catches older unread that drifted down
```

Use `view: THREAD_VIEW_MINIMAL`, `pageSize: 50`.

**Two traps in `search_threads`:**

- Previews show only the **~5 oldest messages per thread**, with no truncation
  marker. Never answer "what's the latest here" from a preview of a
  multi-message thread — call `get_thread` first.
- `resultCountEstimate` saturates around 201. It is not a count. Get real
  volume from `list_labels` (`INBOX.threadsTotal` / `threadsUnread`).

Follow up with `get_thread` (`messageFormat: PLAIN_TEXT`) on anything you
intend to rank — you cannot compute a deadline from a snippet.

---

## 2. Noise vs. signal

**Noise — report as a characterized block, never itemized.** Give a count and a
sender roll-up ("eleven newsletters: Programmer Weekly, ByteByteGo, …"). Listing
these individually is the single fastest way to make a sweep useless.

- Newsletters: Substack, beehiiv, The Information, ByteByteGo, TLDR-likes
- GitHub notifications on `Packetslave/*` — auto-labeled `010-chassis-CI`, he
  tracks these in GitHub itself. Includes CI failure mail.
- Retail marketing, points statements, "welcome to our list"

**Signal — always surface, with the deadline computed:**

- Anything with a date attached: renewals, transfer windows, RSVP, expiry
- Financial anomalies — a charge or withdrawal he might not recognize.
  Routine scheduled autopay is *not* an anomaly.
- Security and account notices: OAuth deletion, payment verification, firmware
  patches, credential exposure
- Medical scheduling offers (these expire fast and are easy to miss)
- Travel logistics
- Domain/registrar mail — transfer notices, auth codes, expiry
- Subscription renewals, especially newly-started ones he'll forget by next year

---

## 3. Cross-reference against the memory systems

Before ranking, cross-reference the sweep against what the repo already knows. A
dated notice that closes a loop someone opened last week is not the same item as
one arriving cold — and an inbox-only view **systematically under-reports any
multi-item process**, because completed items get filed and drop out of
`in:inbox` while the process itself is still open.

Three greps, all scoped to the repo, all cheap:

```bash
# recent daily notes only -- 7 days is the window that pays
ls -1 Journal/$(date +%Y)/*.md | tail -7 | xargs grep -il '<term>'

Skills/linear-ops/scripts/linear.py search '<term>'   # is this thread the completion of tracked work?
rg -il '<term>' Memories/                             # durable operational facts, incl. known traps
```

Terms worth trying: the sender's brand, the project or domain name, any proper
noun in the subject. Reach for `wiki/` only when a proper noun does not decode.

**When a tracked process has an external checklist, reconcile against the
checklist — not the inbox.** Report what is *missing*, not what arrived. An open
bead's scope beats the email's, because each email only ever describes its own
item.

Seen 2026-08-31: an inbox sweep showed five domain-transfer completions and read
as finished. `cowork-uft` named **eight** domains; two more had completed on
Aug 30 but were already filed to `011-homelab` and so were invisible to
`in:inbox`; and `creepy.dating` had never been issued an auth code and had no
transfer activity at all. The journal had already flagged the migration as a
watch item and warned in as many words that the auth-code thread was not a
reliable checklist. "Five completed, no action" was wrong in both directions.

Call out every hit **inline on the ranked item** — what it connects to, and
whether the connection changes the deadline or the disposition. A thread that
matters only because of what it connects to still ranks on its own time pressure.

---

## 4. Compute the real deadline

The date printed in the email is usually **not** the date he needs to act. This
is the highest-value thing this skill does.

| Notice says | Real deadline |
|---|---|
| Babbel "renews 9/23" | **9/21** — Babbel requires cancellation ≥2 days prior |
| Substack annual renewal | The renewal date itself; charge lands same day, no grace |
| ICANN registrar transfer initiated | **+5 days** — auto-approves if not acted on |
| "OAuth clients deleted in 30 days" | 30 days from the notice date, then a 30-day restore window |
| Appointment offer | Effectively hours — the slot goes to someone else |

Always state the computed deadline, and say what made it earlier than the
printed one.

---

## 5. Sanity-check alarming mail before raising an alarm

"Verify your payment method," "Action Required," "Account Alert" — these are
both the shape of real notices and the shape of phishing. Check before you
either cry wolf or wave it through, and **say what you checked**:

- Where do the links actually resolve? Real AWS mail routes through
  `awstrack.me` (their SES click-tracker); Capital One through
  `click-notification.capitalone.com`. A brand-mismatched or lookalike domain
  is the tell.
- Does any link ask for credentials or card details? Legitimate notices link to
  a console or support case, never a form.
- Does the sending domain match the brand's real sending infrastructure?

Even when it verifies clean, tell him to navigate to the console directly
rather than clicking through. That habit should survive a wrong call.

Related: `Skills/security-audit/` for anything that turns out to be a real
exposure.

---

## 6. Output format

What works, in order:

1. **One line of volume** — "Twenty new threads. Three need you, one is on a
   clock." Not a table of counts.
2. **What's in there** — two to four short paragraphs of prose characterizing
   the shape. Noise gets described, not enumerated.
3. **Worth your attention, in order** — numbered. Each item: the concrete fact
   (amount, date, confirmation number), why it matters, and the computed
   deadline. Rank by *time pressure*, not importance.
4. **Routine** — a line or two for things that just need filing.
5. **Noise** — the roll-up.
6. **One concrete offer** — the obvious next action, phrased so "yes" is a
   complete reply.

Cite threads as `https://mail.google.com/mail/u/0/#inbox/<threadId>`.

---

## 7. Filing

Add the destination label **before** removing `INBOX`, so nothing is ever
briefly unfiled. Archive = remove `INBOX` only.

```
label_thread   {threadId, labelIds: ["Label_NN"]}
unlabel_thread {threadId, labelIds: ["INBOX"]}
```

**Leave pre-existing labels alone.** If a thread already carries a label his
filters applied, add the new one alongside — do not strip it. (The Amex
itinerary already had `700-Filed/Bills` from a filter; it got
`700-Filed/Travel` added, not swapped.)

**Do not mark anything read** as a side effect of filing. He did not ask.

### Label IDs

Verified 2026-08-31. The taxonomy is **tiered by number**, and the tier is the
first thing to read: `009-` actionable, `010-`/`011-` per-project, `500-Undecided/*`
a dead-letter tier, `700-Filed/*` terminal, `900-OLD/*` a frozen archive.

**Destinations — the only labels to propose:**

| Label | ID |
|---|---|
| `700-Filed/Bills` | `Label_17` |
| `700-Filed/Orders` | `Label_26` |
| `700-Filed/Travel` | `Label_30` |
| `700-Filed/Education` | `Label_46` |
| `700-Filed/Relationships` | `Label_32` |
| `700-Filed/Jobs` | `Label_559108891518029895` |
| `700-Filed/Voicemail` | `Label_31` |
| `700-Filed/Trinity` | `Label_52` |
| `011-homelab` | `Label_1661155129937722890` |
| `010-chassis` | `Label_7030143409341584019` |
| `010-chassis-Bills` | `Label_8435774412546471417` |
| `010-chassis-CI` | `Label_8728300087997996706` |
| `009-Inbox.@Action` | `Label_3074312546096595660` |

`700-Filed/Education` also has per-course sublabels (Earnable, Dream Job,
Instant Network, FinishersFormula); prefer the parent unless a thread clearly
belongs to one of them.

Observed routing: financial alerts and subscription renewals → `700-Filed/Bills`;
**all domain and registrar mail — auth codes, transfer notices, expiry,
completions → `011-homelab`**; shipping and order confirmations →
`700-Filed/Orders`; itineraries → `700-Filed/Travel`.

**`700-Filed/Domains` (`Label_23`) is superseded** for new mail — domains now
file to `011-homelab` alongside the rest of the infrastructure. The old label
still holds ~1,100 threads of history: leave them where they are, and leave the
label on any thread that already carries it.

**Never propose anything in the `500-Undecided/*` tier** (Sort, Reading List,
Notifications, GitHubSpam, Indirect, Forums, Bulk-Twitter, Daily Hope,
Inbox.bulk, Staff Plus stuff, Sent Messages). Threads you meet will carry those
labels — recognise them, never strip them, never route to them. Same for
`900-OLD/*`.

**Three labels this skill used to name no longer exist:** `+Lists`, `+Links`,
`++Inbox.@Read`. Do not try to apply them.

Every label was renamed in 2026-08 and **every ID survived unchanged** — the ID
is the stable identifier, the name is not. If a name here looks wrong, re-read it
from `list_labels` and trust the ID.

---

## 8. Capture — OmniFocus

**Confirm before writing.** Propose name, project, tag, due date, and note.

Tools: `mcp__remote-devices__omnifocus__*` in Cowork (requires the server
registered with Claude Desktop and proxied over the device bridge);
`mcp__omnifocus__*` in Claude Code via the repo `.mcp.json`. If neither is
present, fall back to the `of` CLI per `Skills/omnifocus-skill/SKILL.md`.

**Conventions:**

- Money decisions (renewals, cancellations, billing) → `Finances - General`
- Waiting-on-someone-else → `Waiting` tag (on hold, `allowsNextAction: false`,
  so it stays out of next-action lists)
- Actionable at a computer → `Computer - Personal`
- No travel or domains project exists. Fall back to `_Miscellaneous (Personal)`
  and offer to create a real project if the category recurs.
- **Flags are scarce** — around 13 active across ~500 tasks. Flag only genuine
  urgency; let due dates carry everything else. Diluting flags breaks his
  system.
- **Duplicate project names bite.** `create_task`/`update_task` match `project`
  by *name only* and silently pick the first match — `_Miscellaneous` exists in
  both the `Personal` and `Reddit` folders. Check `list_projects` first.
- Do not send literal HTML entities in `name` (`-&gt;`). Pass real characters.

**Note body should carry**, so the task survives without the email: source
sender and date, confirmation/receipt/order numbers, dollar amounts, and which
Gmail label it was filed under.

---

## 9. Capture — Google Calendar

Brian tracks **subscription renewals** on his calendar, not just in OmniFocus.

**Confirm before writing.** Conventions:

- Calendar: `brian@packetslave.com`
- All-day, `availability: AVAILABILITY_FREE` — it should not block the day
- Title: `<Service> renews — $<amount>/yr`
- Event sits **on** the renewal date; **reminders supply the runway**:
  `overrideReminders` at `10080` (7 days) and `1440` (1 day). A reminder that
  fires the morning of is too late to cancel anything.
- Description: amount, original subscription term, receipt number, and the
  concrete cancel path

Ask whether he wants an annual `RRULE` rather than a single event — for a
subscription he intends to keep, recurring means never revisiting it.

---

## Don'ts

- Don't itemize newsletters.
- Don't report `resultCountEstimate` as a real count.
- Don't file, archive, or mark read before he says so.
- Don't strip labels his filters applied.
- Don't create tasks or events without confirming placement.
- Don't rank by importance — rank by time pressure. The $75 renewal billing in
  two days outranks the $500 decision due next month.
- Don't route anything to the `500-Undecided/*` or `900-OLD/*` tiers.
- Don't call a tracked multi-item process complete from the inbox alone. The
  inbox shows what arrived, not what is outstanding.
