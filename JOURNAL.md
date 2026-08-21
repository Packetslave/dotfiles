# Journal

## 2026-08-21 — Caddyfile made cross-platform via ansible template

- The installed Caddyfile hardcoded `root * /Users/blanders/src/cowork`,
  which breaks on Linux (`/home/blanders`). Converted the canonical copy
  in cowork to `configs/Caddyfile.j2` (`root * {{ cowork_root }}`) and
  switched the bootstrap.yaml install task from `copy` to `template`,
  passing `cowork_root: "{{ ansible_facts.env.HOME }}/src/cowork"`.
- `root` still must be a rendered literal, never `{$HOME}`: brew
  services runs caddy with HOME overridden (/opt/homebrew/var/lib on
  macOS), so the env placeholder resolves wrong at runtime.
- Verified by rendering the template with both a macOS and a Linux
  `cowork_root` through the same `caddy validate --adapter caddyfile`
  the real task uses; both passed.
- Updated cowork configs/README.md install section (old cp+sed
  instructions were superseded). Changes in cowork are uncommitted on
  main (Caddyfile deletion staged via git rm, .j2 untracked).

## 2026-08-21 — cross-platform bootstrap (Linux support)

- Split `ansible/bootstrap.yaml` into a cross-platform play (symlinks,
  oh-my-zsh, shared brew formulae, caddy) that imports `macos.yaml` or
  `linux.yaml` via `import_playbook` gated on `ansible_facts.system`.
  Both sub-playbooks are standalone-runnable (macos.yaml duplicates the
  /opt/reddit stat check for that reason).
- Cross-platform brew installs live in `homebrew_common_formulae` in
  bootstrap.yaml (beads, caddy, fzf, starship, zoxide so far); caddy
  paths are parametrized on `homebrew_prefix` (/opt/homebrew vs
  /home/linuxbrew/.linuxbrew).
- `bin/linux-setup.sh` is deliberately minimal (brew + ansible only);
  linux.yaml enables `loginctl enable-linger` so brew-services caddy
  survives logout. Polkit on some distros denies non-interactive
  enable-linger — fall back to `sudo loginctl enable-linger $USER`.
- **Pending**: linux-setup.sh has no cowork clone step — fine for
  seaside (already cloned), fix before the next Linux host setup.
- Cleaned up the stale `scripts/mac-setup.sh` in src/experiments
  (committed there, not pushed) after porting its one unique change —
  the /opt/reddit Claude-cask guard — into dotfiles' bin/mac-setup.sh.

## 2026-08-21 — F-keys as function keys via ansible

- Added `com.apple.keyboard.fnState` (NSGlobalDomain, bool true) to
  `ansible/bootstrap.yaml` so F1-F12 send plain function keys. Ordering
  matters: the task must come *before* the existing
  `activateSettings -u` task, or the setting only applies after
  logout/login. First placement (next to the other NSGlobalDomain task,
  after activateSettings) was wrong for this reason and was moved.
- Pushing to GitHub did not require Tailscale (it was stopped and the
  push succeeded), so it was left off.
- Noticed: AGENTS.md forbids AI-attribution trailers in commit
  messages, but recent commits (this session's and another session's)
  carry `Co-Authored-By: Claude` / `Claude-Session` trailers added by
  the Claude Code harness default. Flagged to Brian to resolve —
  either drop the rule or configure sessions to omit trailers.
