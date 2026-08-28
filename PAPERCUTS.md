# Papercuts

Small frictions hit while working in this repo. Log in the moment; one or
two sentences each (guess at cause/fix is a bonus).

- 2026-08-21: caddy on seaside reported healthy (`brew services` running,
  clean start) while `root` pointed at a nonexistent macOS path — nothing
  validates that the root directory exists, so the breakage only shows as
  404s. `caddy validate` checks syntax, not paths; a curl-based smoke test
  after install (like the Verify section in cowork configs/README.md) is
  the only real check.
- 2026-08-21: non-interactive `ssh seaside <cmd>` doesn't get linuxbrew in
  PATH (profile not sourced), so `ansible-playbook` isn't found — needed an
  explicit `export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH` prefix.
- 2026-08-26: the system `python3` has no PyYAML, so the obvious
  `python3 -c "import yaml; yaml.safe_load(...)"` check on a playbook edit
  just fails with ImportError. `ansible-playbook --syntax-check <playbook>`
  is the right validator anyway — it's already installed, and it parses the
  playbook the way ansible will. It prints two "no inventory"/"hosts list is
  empty" WARNINGs on a localhost playbook that are noise, not failure.
- 2026-08-26: `yazi --debug`, which every yazi doc and issue thread names for
  showing resolved config paths, is deprecated and prints only a one-line
  pointer to `ya env` — and `ya env` doesn't report the config directory at
  all. `ya pkg list` was the workable check that the config dir resolved
  through a symlink, since it reads package.toml and prints the pinned rev.
- 2026-08-27: `ls -t <dir>` fails in this shell — `ls` is aliased to eza, whose
  `-t` means `--time <FIELD>`, so it errors with "invalid value for --time"
  instead of sorting by mtime. Bit me listing `~/.local/share/wezterm`. Use
  `command ls -t` (or eza's `-s modified`) when a script wants real `ls`
  semantics; worth remembering that any snippet copied from the web with
  `ls -t` in it will misfire here.
- 2026-08-27: no way to see which clipboard strategy Claude Code picked
  without watching its UI text — it prints "copied N chars to clipboard" vs
  "to tmux buffer" vs "sent N via OSC 52", and those strings are the only
  signal. There is a `clipboard: setClipboard mux= ssh= native= predicted=
  emit= bytes=` debug line in the binary, but nothing surfaced it in normal
  use. Made the SSH+tmux clipboard bug look unfixed when the copy had in fact
  worked (the hook fires after the buffer is set, so the message is stale).
- 2026-08-27: `karabiner_cli --lint-complex-modifications` will not read
  karabiner.json — it wants a standalone `{title, rules}` file, so validating a
  rule edit means extracting `profiles[0].complex_modifications.rules` to a
  temp file first. Karabiner also logs nothing when it reloads the config, so
  ~/.local/share/karabiner/log can't tell you whether an edit took effect;
  press the key instead.
