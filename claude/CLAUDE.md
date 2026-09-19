# Tools, Environments, and Languages

## General

- never assume or guess the current date/time. When doing something time-related,
  always confirm with `date

## Shell

- I use zsh on all my machines, not bash.

- when running `rm`, `mv`, `cp`, `ls` always run them as `command <name> <args>`
  to avoid issues with shell aliasing (`rm` is frequently aliased to `rm -i`, for
  example).

## Claude Code settings

- `~/.claude/settings.local.json` is never read. `settings.local.json` only
  exists as a project-level concept (`<project>/.claude/settings.local.json`,
  a gitignored personal override next to that project's `settings.json`) —
  there is no user/home-level equivalent. Global config belongs in
  `~/.claude/settings.json` only.

- `~/.claude/settings.json` must never be symlinked or templated wholesale.
  Claude Code owns and rewrites it at runtime (plugin toggles, GrowthBook
  flags, session state), so a symlink into dotfiles turns those runtime
  writes into git-tracked changes and leaks machine-specific state (enabled
  plugins, theme) across every machine sharing the repo. To manage one key
  from dotfiles, merge it in with a small script that reads the live file,
  sets just that key, and writes back atomically (see `claude/set-retention.py`
  and `claude/set-hooks.py` for the pattern) — don't add more keys to that
  approach speculatively; only ones actually causing pain.

- To debug whether a hook is actually loading/firing, don't just eyeball the
  JSON — run `claude --debug hooks -p "test"` and check the "Watching for
  changes in setting files" line (confirms the file path is even a candidate)
  and the "Hook UserPromptSubmit ... success" lines (confirms it executed and
  what it returned). A hook can have perfectly valid JSON and still never run
  because it lives at a path nothing reads.
