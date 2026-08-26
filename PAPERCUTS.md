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
