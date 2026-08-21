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
