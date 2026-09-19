---
name: gtd-inbox-processing
description: >
  Collaborative, item-by-item GTD (Getting Things Done) clarify workflow for
  the OmniFocus inbox. Walks Brian through each inbox item one at a time using
  David Allen's clarify decision tree, gets his call on each one, and executes
  the resulting OmniFocus change immediately via the OmniFocus MCP connector
  (`mcp__omnifocus__*`) before moving to the next item. Auto-detects bare-URL
  "read later" captures and offers a shortened fast-path menu for those
  instead of the full decision tree. This is the process/judgment layer; the
  underlying `of` CLI (same tool, now exposed as an MCP server) is documented
  in omnifocus-skill for any flow still using it directly.
triggers:
  - process my inbox
  - process my omnifocus inbox
  - clarify my inbox
  - GTD my inbox
  - empty my inbox
  - work through my inbox
---

# GTD Inbox Processing

Runs David Allen's "clarify" step of GTD against the live OmniFocus inbox,
one item at a time, with Brian making every disposition call. This skill is
the workflow/judgment layer on top of the **OmniFocus MCP connector**
(`mcp__omnifocus__*` tools) — see `Skills/omnifocus-skill/SKILL.md` for the
underlying `of` CLI these tools wrap; this skill only adds the GTD decision
tree and the collaborative loop around it.

**Tool access:** all OmniFocus operations below use `mcp__omnifocus__*`
tools directly — no shell commands, no host-shell/sandbox platform
distinction to worry about. If those tools aren't showing up, the MCP
server needs reconnecting (`/mcp` in the CLI) — it still requires OmniFocus
running on Brian's Mac with Automation permission granted, since the MCP
server is the same `of` binary under the hood.

**Duplicate project names:** `update_task`'s `project` field matches by
**name only** and silently resolves to whichever same-named project it
finds first if more than one exists (e.g. Brian had a `_Miscellaneous` in
both the `Personal` and `Reddit` folders) — it does **not** accept a
project ID there, unlike `update_project`'s `idOrName`, which does. Before
filing into a project whose name might not be unique, check `list_projects`
for duplicates; if one exists, ask Brian whether to rename them apart
(`update_project {"idOrName": "<id>", "name": "<Name> (<Folder>)"}` — IDs
work fine here) rather than guess which one a name-only move landed in.

---

## Scope

This is the **clarify** step only — deciding what each inbox item is and
where it belongs. It is not:
- A weekly review (reviewing existing projects/next actions/waiting-for
  list) — that's a separate concern, not covered here.
- A "do the work" session, except for the 2-minute-rule exception below.

Goal at the end of a run: **inbox count is 0**, and everything that was in
it now lives somewhere deliberate (done, deleted, filed as reference,
someday/maybe, delegated, or turned into a next action/project).

---

## Step 0 — Check the existing GTD structure (first run, or if unsure)

Brian's tag/context setup is partial — don't assume standard GTD contexts
exist. Before processing items, check what's actually there:

```
mcp__omnifocus__list_tags {"sortBy": "usage"}
mcp__omnifocus__list_folders {}
mcp__omnifocus__list_projects {}
mcp__omnifocus__list_projects {"status": "on hold"}   # candidate home for Someday/Maybe
```

Look specifically for:
1. **Contexts** (e.g. `@calls`, `@errands`, `@computer`, `@home`) — tags
   representing where/how a next action gets done.
2. **Waiting For** — a tag or project marking delegated items.
3. **Someday/Maybe** — a tag or on-hold project for non-committed ideas.
4. **Reference** — GTD reference material doesn't belong in a task manager
   at all. Confirm with Brian where reference items should actually go
   (a note, a project doc in this repo, elsewhere) — don't invent an
   OmniFocus "Reference" project as a default without asking.
5. **Links to Review** — the dedicated project for URL-dump inbox items
   (see "URL-dump fast path" in Step 2), plus the `NoAction` tag used to
   mark its contents as non-actionable. Already decided with Brian
   (2026-08-01) — check whether the `Links to Review` project and
   `NoAction` tag exist (via `list_projects`/`list_tags`, or query directly
   with `get_project {"idOrName": "Links to Review"}` /
   `get_tag {"idOrName": "NoAction"}`), and create them if missing:
   `mcp__omnifocus__create_project {"name": "Links to Review"}` /
   `mcp__omnifocus__create_tag {"name": "NoAction"}`.
   This one doesn't need to go back through the ask-Brian loop below; the
   other three (contexts, Waiting For, Someday/Maybe) still do.

Report what exists vs. what's missing, and ask Brian (numbered options)
whether to:
1. Use what's already there as-is.
2. Create the missing pieces now (e.g. a `Waiting For` tag, a
   `Someday/Maybe` on-hold project) before processing starts.
3. Skip structure for now and just process items, deferring anything that
   doesn't have a clean home to a decision made per-item.

Don't create tags/projects without Brian picking option 2 — this is exactly
the kind of existing-setup change the project's "ask before changes" rule
covers.

---

## Step 1 — Pull the inbox

```
mcp__omnifocus__list_inbox {}
mcp__omnifocus__get_inbox_count {}
```

`list_inbox` returns **top-level** items only. Each carries `childCount` and
`remainingChildCount`; an item with `childCount > 0` is an action group
(Brian groups captures under parents like `Work` and `Personal`). Report
the count of top-level items and, for each group, how many open children
it holds. If everything is 0, stop here — nothing to process.

### Action groups

When you reach a group, ask Brian whether to process its children now
(e.g. "`Work` has 57 open children — work through them?"). On yes:

```
mcp__omnifocus__list_tasks {"parent": "<group name or id>"}
```

and run each child through the normal per-item flow below, exactly as if
it were a top-level inbox item. A child filed into a project via
`update_task {"project": ...}` leaves the group automatically. When the
group's `remainingChildCount` reaches 0 (re-check with `get_task`), offer
to delete the now-empty group — `delete_task` will still refuse if any
children remain (see the cascade note in Step 2c), and completed children
count. Only pass `"force": true` after Brian explicitly says to delete the
group and everything in it.

To nest a new task under a group, `create_task {"name": ..., "parent":
"<group>"}`; to pull a child out to the inbox top level,
`update_task {"idOrName": ..., "parent": null}`.

---

## Step 2 — Process one item at a time

For **each** inbox item, in order:

### URL-dump fast path (check this first, before the normal flow)

Brian has a habit of capturing bare links to review later, and these don't
fit the normal task-shaped disposition menu — check for this before
presenting the item normally.

**Detection (auto):** treat an item as a URL dump if its name is — or is
essentially just — a URL (starts with `http://`/`https://`, or is a bare
domain/link) with no verb or task framing in the name or note ("call,"
"reply to," "buy," "renew," etc.). If it's ambiguous, fall back to the
normal flow below — asking the full menu for a link only costs one extra
question, but fast-pathing an item that was actually a real task loses its
real disposition.

If it **is** a URL dump, ask this shortened menu instead of the full one:

```
0. Skip — leave it in the inbox, move to the next item
1. Read/Review — file it to review later
2. Read now — quick enough to skim right now
3. Someday/Maybe — not now, might be later
4. Trash — not worth reading
5. Actually a task — this isn't just a link, use the full menu
```

| Disposition | Action |
|---|---|
| **0. Skip** | No OmniFocus call — leave the item untouched and move on |
| **1. Read/Review** | `mcp__omnifocus__update_task {"idOrName": "<item>", "project": "Links to Review", "tags": ["NoAction"]}` |
| **2. Read now** | Skim it together right then, then `mcp__omnifocus__update_task {"idOrName": "<item>", "completed": true}` |
| **3. Someday/Maybe** | Same as the main flow — tag/move per the Step 0 structure |
| **4. Trash** | `mcp__omnifocus__delete_task {"idOrName": "<item>"}` |
| **5. Actually a task** | Drop into the normal flow below, starting at "a. Present the item" |

`Links to Review` and `NoAction` should already exist per Step 0 — if
either is missing, create it before running the Read/Review disposition.

If it's **not** a URL dump, go straight to the normal flow:

### a. Present the item

Show the item's name and note (`mcp__omnifocus__get_task {"idOrName": "<item>"}`
if the note isn't already visible from `list_inbox`). Don't
summarize/paraphrase — show what Brian actually wrote so he's clarifying
his own capture, not my interpretation of it.

**`dictated: ` prefix:** Siri/dictation captures land in the inbox
prefixed with `dictated: ` (e.g. `dictated: cancel Medium membership
before August 4`). Always strip this prefix when the item is kept as an
active task — include the `"name"` field (with the prefix removed) in
whatever `update_task`/`create_task` call executes the disposition. No
need to ask; just do it. Doesn't apply to items that get deleted (Trash)
or filed as Reference, since the name doesn't persist in OmniFocus either
way.

### b. Ask for the disposition (numbered, per Brian's standing preference)

Ask exactly one question per item, framed as GTD's clarify flowchart:

```
0. Skip — not deciding right now, leave it in the inbox
1. Next action (auto) — actionable, single step; I'll suggest the project
   and context tag
2. Next action (ask) — actionable, single step; you tell me where it goes
3. Mark complete — already done, just needs to be marked off
4. Reference — not actionable, but worth keeping — needs to be filed
   somewhere other than OmniFocus
5. Someday/Maybe — not actionable right now, but might be later
6. Do it now — actionable, takes under 2 minutes, just knock it out
7. New project — actionable, but it's a multi-step outcome
8. Trash — not actionable, doesn't matter, delete it
```

Wait for Brian's answer before touching OmniFocus.

### c. Execute immediately

Call the corresponding `mcp__omnifocus__*` tool right after Brian
answers — don't batch. See `Skills/omnifocus-skill/SKILL.md` for the
underlying `of` CLI these tools wrap, if you need more background.

| Disposition | Action |
|---|---|
| **0. Skip** | No OmniFocus call — leave the item untouched and move on |
| **1. Next action (auto)** | Infer the best-fit project and context tag from the item's name/note and the existing project/tag structure (Step 0), then call `mcp__omnifocus__update_task {"idOrName": "<item>", "project": "<inferred>", "tags": ["<inferred>"]}` immediately — state what you filed it under as part of confirming the action, not as a blocking question. If nothing reasonable can be inferred, say so and fall through to option 2 instead of guessing badly. |
| **2. Next action (ask)** | Ask which project (or none — stand-alone action) and which context tag, then `mcp__omnifocus__update_task {"idOrName": "<item>", "project": "<Project>", "tags": ["<context>"]}` |
| **3. Mark complete** | `mcp__omnifocus__update_task {"idOrName": "<item>", "completed": true}` — no doing-it-together step, just marks it done |
| **4. Reference** | Confirm where it's being filed (per Step 0.4), then once filed: `mcp__omnifocus__delete_task {"idOrName": "<item>"}` |
| **5. Someday/Maybe** | Tag/move per the Step 0 structure, e.g. `mcp__omnifocus__update_task {"idOrName": "<item>", "tags": ["Someday/Maybe"]}` (or move into the on-hold project via `"project"` if that's the chosen home) |
| **6. Do it now** | Do the 2-minute thing together right then (e.g. draft the reply, send the message), then `mcp__omnifocus__update_task {"idOrName": "<item>", "completed": true}` |
| **7. New project** | Ask for the project name and the very next physical action. Create the project (`mcp__omnifocus__create_project {"name": "<Name>"}`), then either rename this inbox item into that first next action and move it in (`update_task` with `"name"` + `"project"`), or create a fresh next-action task in the new project (`mcp__omnifocus__create_task`) and delete the original inbox item (`delete_task`) — whichever keeps a single next action live, not the whole project outcome sitting as a task |
| **8. Trash** | `mcp__omnifocus__delete_task {"idOrName": "<item>"}` |

**Trash cascade guard:** deleting a parent/action group deletes every
sub-item under it, and there is no undo from the API. Since 2026-09-13
the tools expose this: every task carries `childCount`, and `delete_task`
**refuses** a task with children (or a project's root task, below) unless
`"force": true` is passed. Never pass `force` on Brian's behalf — if a
Trash disposition is refused, tell him what the group contains
(`list_tasks {"parent": ...}`) and ask whether he really wants the whole
group gone. (Background: this bit live on 2026-08-01, when trashing an
item named "drums" silently took four nested sub-items with it.) If a
cascade-delete does happen anyway: tell Brian immediately and have him
try `Cmd+Z` in OmniFocus right away (same-session undo can recover it) —
don't just keep processing.

**Project root-task trap (confirmed 2026-08-02):** every OmniFocus project
has an underlying root task object with the **same name and same ID** as
the project itself. When processing a *project's* tasks (not the real
inbox) via `mcp__omnifocus__list_tasks {"project": "<Name>"}`, that root
task shows up in the results looking like an ordinary top-level item —
`"project": "<Name>"`, `"parent": null`, and a `childCount` equal to the
project's top-level task count. **`delete_task` on it would delete the
entire project**; the guard above now refuses it unless forced (it
happened live when a task literally named "Today", matching the "Today"
project it lived in, got trashed as a stray placeholder). Rule: if an
item's name exactly matches the project name it's filed under, it is the
project's container object — leave it alone/skip it, and never force it.
Recovery is the same as above (`Cmd+Z` immediately), and note the same
undo also reverts any project/task creations made after the bad delete
in that same undo step.

`tags` on `update_task` **replaces** the full tag list, same as the
underlying CLI — read the task first (`get_task`) if you need to add a tag
without dropping existing ones.

**Don't ask about due/defer dates by default** — Brian will call one out
explicitly if an item needs one. Only set `due`/`defer` when he volunteers
a date unprompted; convert any natural-language date he gives ("next
Friday") to ISO 8601 before passing it to any tool call.

### d. Move to the next item

Repeat a–c until the inbox is empty.

---

## Step 3 — Verify

```
mcp__omnifocus__get_inbox_count {}
```

Confirm it's 0. If any items remain (e.g. Brian explicitly deferred a
decision), state which ones and why, rather than silently leaving them.

---

## Step 4 — Summary

Give Brian a short tally of what happened this run, grouped by
disposition (e.g. "3 trashed, 2 filed as reference, 1 someday/maybe, 4
done now, 5 became next actions, 1 became a new project, 2 skipped").
Don't re-list every item — the counts plus anything unusual (e.g. a new
project or a new tag created) is enough.
