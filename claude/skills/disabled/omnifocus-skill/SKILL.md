---
name: omnifocus
description: >
  Manage OmniFocus tasks, projects, tags, and inbox using the OmniFocus CLI
  (`of`, installed via bun at ~/.bun/bin/of). Use this skill whenever the
  user wants to interact with OmniFocus — even casually. Triggers include:
  listing or searching tasks, creating or updating tasks or projects,
  flagging/completing tasks, checking the inbox, viewing tags, filtering by
  project or tag, running reports, or any mention of OmniFocus, "of tasks",
  "my tasks", "my projects", "to-do", "flagged items", or anything that sounds
  like personal task management. Always use this skill proactively rather than
  guessing about OmniFocus behavior.
---
``
# OmniFocus Skill

**Platform:** macOS only — OmniFocus is a Mac app and `of` drives it through JXA.
There is no Linux equivalent; in a Linux session, say so and stop.

Interact with OmniFocus via the `of` CLI (https://github.com/stephendolan/omnifocus-cli).

**Binary:** `/Users/blanders/.bun/bin/of` — always invoke with this full absolute path
(per the project's bash rules), never bare `of`, in case PATH doesn't include `~/.bun/bin`
in the sandbox shell.

Every command prints **JSON** to stdout. Pipe through `jq` to filter/shape output, and
add `--compact` for single-line JSON when the full record isn't needed.

This CLI only works on macOS with OmniFocus installed and Automation permission granted
(System Settings > Privacy & Security > Automation). It will not function inside the
Linux sandbox — run it via the host's native shell, not `mcp__workspace__bash`, unless
the sandbox has a working bridge to the host.

**Fork note (as of 2026-08-01, branch updated 2026-09-13):** `~/.bun/bin/of` is currently
symlinked to a local build of Brian's fork (`src/_external/omnifocus-cli`, branch
`feature/task-hierarchy`, which stacks on `feature/task-drop-support`), **not** the published
`@stephendolan/omnifocus-cli` npm package — added to get `task update --drop`/`--undrop`
(upstream PR: stephendolan/omnifocus-cli#44, not yet merged as of this writing) and the
parent/child task support documented below. Any future `bun install -g`/reinstall of the published
package will silently overwrite the symlink back to the stock build and drop/undrop
will stop working with no error — if that happens, re-run:
`ln -sf /Users/blanders/src/cowork/src/_external/omnifocus-cli/dist/cli.js ~/.bun/bin/of`
(rebuilding first with `bun run build` in that directory if the fork has since been
updated). As of 2026-08-15, dotfiles' `bin/mac-setup.sh` section 15 automates all of
this on a new machine (checks out the branch, builds, creates the symlink) — re-run
it as the recovery path too. Once PR #44 merges upstream and a new package version
is installed, this symlink workaround and this note can go away.

---

## Quick Reference

| Goal | Command |
|------|---------|
| List active tasks | `of task list` |
| List flagged tasks | `of task list --flagged` |
| Tasks in a project | `of task list --project "Name"` |
| Tasks with a tag | `of task list --tag "Name"` |
| Search tasks | `of search "query"` |
| View task details | `of task view <name\|id>` |
| Create a task | `of task create "Name" [options]` |
| Update/complete/flag a task | `of task update <name\|id> [options]` |
| Delete a task | `of task delete <name\|id>` |
| List inbox | `of inbox list` |
| Inbox count | `of inbox count` |
| Add to inbox | `of inbox add "Task name"` |
| List projects | `of project list` |
| View project details | `of project view <name\|id>` |
| Create a project | `of project create "Name" [options]` |
| Delete a project | `of project delete <name\|id>` |
| List tags | `of tag list` |
| View tag details | `of tag view <name\|path\|id>` |
| Create a tag | `of tag create "Name"` |
| Update a tag | `of tag update <name> [options]` |
| Delete a tag | `of tag delete <name>` |
| List folders | `of folder list` |
| View folder details | `of folder view "Name"` |
| List perspectives | `of perspective list` |
| Tasks in a perspective | `of perspective view "Name"` |
| Task statistics | `of task stats` |
| Project statistics | `of project stats` |
| Tag statistics | `of tag stats` |

All examples below omit the full binary path for readability — substitute
`/Users/blanders/.bun/bin/of` for `of` when actually running a command.

---

## Tasks

### Listing Tasks

```bash
of task list                        # All active tasks
of task list --flagged              # Flagged tasks only
of task list --project "Work"       # Filter by project
of task list --tag "urgent"         # Filter by tag
of task list --completed            # Include completed
of task list --parent "Work"        # Direct children of a task (action group)
```

Every task record carries `parentId`/`parent` (the action group it sits under, or `null`)
and `childCount`/`remainingChildCount` (how many direct children it has, and how many of
those are still open and active). A project's own root task is reported with `parent: null`
and a `childCount` equal to its top-level task count.

### Searching Tasks

```bash
of search "search term"             # Search task names and notes
```

### Viewing a Task

```bash
of task view "Task name or ID"      # Full task details
```

### Creating Tasks

```bash
of task create "Task name" \
  --project "Project Name" \        # optional
  --parent "Parent task" \          # optional, nest under an action group (not with --project)
  --tag tag1 tag2 \                 # optional
  --due 2025-07-15 \                # optional, ISO 8601 (YYYY-MM-DD or full datetime)
  --defer 2025-07-10 \              # optional, ISO 8601
  --flagged \                       # optional
  --estimate 30 \                   # optional, minutes
  --note "Additional context"       # optional
```

- `--due` and `--defer` use ISO 8601 format (`YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SS`)
- If the user says "next Friday" or "July 15th", convert to the correct ISO date first

### Updating Tasks

```bash
of task update "Task name" --complete             # Mark done
of task update "Task name" --flag                 # Flag it
of task update "Task name" --unflag                # Unflag
of task update "Task name" --name "New name"       # Rename
of task update "Task name" --due 2025-08-01        # Set due date
of task update "Task name" --project "Other"       # Move to project
of task update "Task name" --parent "Group"        # Move under an action group
of task update "Task name" --no-parent             # Un-nest to its project's top level or the inbox
of task update "Task name" --tag new-tag           # Replace tags
```

Tasks can be referenced by **name** or **ID**. A name that matches more than one task
(completed ones included) is an error listing each candidate's ID and location — use the ID.

### Deleting Tasks

```bash
of task delete "Task name"
of task delete "Group name" --force     # Required for an action group or a project root task
```

`task delete` refuses a task that has children, or a project's root task, because either
cascades to everything underneath. Only pass `--force` when Brian has explicitly said to
delete the whole group.

---

## Projects

```bash
of project list                             # All active projects
of project list --folder "Work"             # Filter by folder
of project list --status "on hold"          # Filter by status
of project list --dropped                   # Include dropped

of project view "Project Name"              # Project details

of project create "Project Name" \
  --folder "Folder Name" \                  # optional
  --tag tag1 \                              # optional
  --sequential \                            # optional — tasks must be done in order
  --note "Project notes"                    # optional

of project delete "Project Name"
```

**Note:** the CLI has no `project update` command. To change an existing project's
name, folder, status, or notes, use OmniFocus directly (or `of project delete` +
`of project create` if that's an acceptable substitute — confirm with the user first,
since that loses task history/IDs).

---

## Inbox

```bash
of inbox list                       # Top-level inbox items (action groups carry childCount)
of inbox list --all                 # Also include children of action groups, flat, with parentId
of inbox count                      # Count of top-level inbox items
of inbox add "Task name"            # Add a task straight to the inbox
of inbox add "Task name" --parent "Work"   # Add under an inbox action group
```

`of task create` without `--project` also lands in the inbox, but `of inbox add` is the
more direct quick-capture command.

Brian groups inbox items under parent tasks (e.g. `Work`, `Personal`). To work through one
group: `of inbox list` to find it and its `remainingChildCount`, then
`of task list --parent "Work"` for the children. Moving a child to a project with
`--project` takes it out of the group.

---

## Tags

```bash
of tag list                                      # All tags
of tag list --sort usage                         # Most used first
of tag list --sort activity                       # Most recently used first
of tag list --active-only                         # Only count active tasks
of tag list --unused-days 30                      # Unused for 30+ days

of tag view "TagName"                             # Tag details
of tag view "Parent/Child"                        # Nested tag (path syntax)

of tag create "TagName"
of tag create "Child" --parent "Parent"           # Nested tag

of tag update "OldName" --name "NewName"
of tag update "TagName" --inactive                # Deactivate

of tag delete "TagName"
```

---

## Folders & Perspectives

```bash
of folder list                                   # All folders
of folder list --dropped                         # Include dropped
of folder view "Folder Name"                     # Folder details

of perspective list                              # All available perspectives
of perspective view "Forecast"                   # Tasks in a perspective
of perspective view "Flagged"
```

**Note:** the CLI has no folder create/update/delete commands — folders can only be
listed and viewed.

---

## Statistics

```bash
of task stats          # Task counts and completion stats
of project stats        # Project-level stats
of tag stats             # Tag usage stats
```

---

## Workflow Patterns

### Morning Review

1. `of inbox count` — check for uncategorized items
2. `of task list --flagged` — priority tasks for today
3. `of perspective view "Forecast"` — what's due

### Past-Due Items

The CLI does not expose a dedicated overdue filter. To find past-due items:
1. `of task list` — fetch all active tasks
2. Filter client-side (e.g. via `jq`) for tasks where `due` is earlier than today's date
3. Present grouped by project or sorted by due date

### Capture & Triage

- Quick capture: `of inbox add "Thing to do"` → lands in inbox
- Full capture: `of task create "Name" --project "X" --tag Y --due YYYY-MM-DD`

### Bulk Status Check

```bash
of task stats                       # overall numbers
of project list                     # all active projects
of task list --flagged              # today's priorities
```

### Completing Tasks

When user says "mark X as done", "complete X", "finished X":
```bash
of task update "X" --complete
```

### Filtering with jq

Since every command returns JSON, chain `jq` for anything the CLI's own flags don't cover:

```bash
of task list | jq 'length'                          # Count tasks
of task list | jq '.[] | .name'                     # Task names only
of task list --flagged | jq '.[] | {name, due}'     # Specific fields
```

---

## Error Handling & Notes

- **Ambiguous names**: a task name shared by several tasks fails with "Multiple tasks
  found" and a list of IDs with locations — rerun with the ID. Project names still resolve
  to the first match, so confirm with `of project view` before moving tasks into a project
  whose name might not be unique.
- **Action groups**: `task delete` refuses a task with children or a project root task
  unless `--force`; `--parent` and `--project` can't be combined on create/update; a task
  can't be moved under itself or its own descendant.
- **IDs vs names**: All commands accept either. Prefer names for clarity; use IDs when
  the user supplies them or when names are ambiguous (IDs appear in JSON output, e.g. `"id": "kXu3B-LZfFH"`).
- **Date format**: Always ISO 8601 (`YYYY-MM-DD` or `YYYY-MM-DDTHH:MM:SS`). Convert
  natural language dates before passing to commands.
- **Tags replace, not append**: `--tag` on `task update` replaces the full tag list.
  Read existing tags first with `of task view` if you need to add without removing.
- **Nested tags**: Reference with path syntax `"Parent/Child"`.
- **No project update**: unlike tasks and tags, projects have no `update` subcommand —
  see the note under Projects above.
- **No folder mutation**: folders support only `list` and `view` — no create/update/delete.
- **Permission denied errors**: mean OmniFocus automation access hasn't been granted —
  ask the user to check System Settings > Privacy & Security > Automation.
- **Platform**: this is a macOS-only CLI driving OmniFocus via automation. It must run
  in a shell that actually has access to the user's Mac and OmniFocus install — not a
  sandboxed/remote environment without that access.
