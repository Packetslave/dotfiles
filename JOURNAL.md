# Journal

## 2026-08-25 — the Linux side stops being a second-class citizen

Provisioning mfa1 (Ubuntu 24.04 mini) as a full Claude Code box exposed
how thin the Linux path was. Three fixes, one theme: things that looked
macOS-only because nobody had checked.

- **claude-code is not a macOS-only cask.** It lives in `homebrew_casks`,
  which reads as Mac-only, but Homebrew 6 installs casks on Linux, the
  cask resolves per platform (`linux-x64` vs `darwin-arm64`), and
  `community.general.homebrew_cask` runs there — all three verified on
  seaside. It moved to a new `homebrew_common_casks`, gated on the same
  `/opt/reddit` stat that filters `claude_casks`. Do not copy
  `install_options: adopt` across; that adopts an app already in
  /Applications and means nothing off macOS.
- **Twenty-three formulae were stranded in macos.yaml** — node, jq, git,
  gh, sops, age, ripgrep among them. bootstrap.yaml was already
  symlinking ~/.p10k.zsh, ~/.config/atuin and ~/.config/eza on every
  platform while their binaries were Mac-only, and claude/statusline.sh
  parses JSON with a jq Linux never installed. Promoted, and the
  duplicated `uv` entry collapsed.
- **zshrc's claude() wrapper was the expensive one.** Three hardcoded
  /opt/homebrew paths plus /Users/blanders meant that on Linux it
  shadowed the real binary with a function pointing at nothing. Now
  derives the prefix from `brew shellenv` (which exports
  HOMEBREW_PREFIX), resolves binaries with `whence -p` — `command -v`
  finds the function itself from inside the function — and degrades to
  launching claude with a warning when there is no sops identity yet,
  instead of making claude unlaunchable on every unenrolled machine.
- **linux-setup.sh reached mac-setup.sh parity**: ssh key, GitHub auth
  and upload, cowork clone, age identity, plugins, and it now runs the
  playbook itself. Ordering matters — gh before the playbook, the cowork
  clone before it (Caddy tasks skip silently without
  configs/Caddyfile.j2), plugins and checkouts after it (they need
  claude, node and jq). That last one retired the old "re-run after
  ansible installs node" dead end, which could never come true while
  nothing on Linux installed node.
- Checked, not assumed: `--check --diff` on impulse went ok=30 to ok=31
  with changed and failed unmoved. The one `changed` is oh-my-zsh
  pulling; the one `failed` is caddy's service-info task being skipped
  in check mode so `from_json` gets an empty string. Both pre-existing.

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
  instructions were superseded). Committed and pushed in both repos
  (dotfiles a55de5f, cowork b2dd630).
- Rolled out to seaside: its installed Caddyfile still had the macOS
  root (caddy was silently serving a nonexistent path). Cause: the
  seaside ~/src/cowork clone was behind — installed configs never
  self-update, and a stale *source* clone is a second way to be stale.
  `git pull` in cowork + `ansible-playbook ansible/bootstrap.yaml`
  fixed it; verified the md-viewer rewrite and ?raw=1 over :2015.
- Confirmed the HOME-override gotcha exists on Linux too: brew's
  generated systemd unit runs caddy with
  HOME=/home/linuxbrew/.linuxbrew/var/lib, so `root` must stay a
  rendered literal on both platforms. macOS machines (lunchbox,
  impulse, johnny5, studio) pick up the template on their next
  bootstrap run.

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
- ~~**Pending**: linux-setup.sh has no cowork clone step~~ — done
  2026-08-25, see below.
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
