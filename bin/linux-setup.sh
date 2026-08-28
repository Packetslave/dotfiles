#!/bin/bash
#
# linux-setup.sh — bootstrap a new Linux machine (mac-setup.sh's sibling).
#
# Safe to re-run at any point: every step checks current state before acting.
#
# Ansible does as much as it can (ansible/bootstrap.yaml -> linux.yaml); this
# script covers what ansible cannot do for itself — installing brew and ansible,
# creating credentials, cloning repos, and the post-install steps that need the
# binaries ansible just put on disk.
#
# NOT handled here, by design:
#   * Tailscale, the zsh package, the login shell, sudoers and authorized_keys.
#     Those are system-level and belong to the homelab repo, which applies them
#     over SSH:  ansible-playbook -i hosts.ini workstations.yaml --limit <host>
#   * Docker, likewise homelab — it rewrites the host's iptables FORWARD policy,
#     so it is scoped to an explicit inventory group that no k3s node is in.
#
# Usage:
#   ./linux-setup.sh
#
# Override any default below via the environment, e.g.:
#   COWORK_DIR=/srv/cowork ./linux-setup.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (mirrors mac-setup.sh)
# ---------------------------------------------------------------------------
GITHUB_USER="${GITHUB_USER:-Packetslave}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
PLAYBOOK="${PLAYBOOK:-ansible/bootstrap.yaml}"               # relative to DOTFILES_DIR
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
ORIGIN_HOST="${ORIGIN_HOST:-seaside}"                        # tailnet host with the cowork repo
ORIGIN_USER="${ORIGIN_USER:-blanders}"                       # login on that host
COWORK_REPO="${COWORK_REPO:-${ORIGIN_USER}@${ORIGIN_HOST}:git/cowork.git}"
COWORK_DIR="${COWORK_DIR:-$HOME/src/cowork}"
SSH_KEY_EMAIL="${SSH_KEY_EMAIL:-brian.landers@gmail.com}"
SSH_KEY_TITLE="${SSH_KEY_TITLE:-$(hostname -s) ($(date +%Y-%m-%d))}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
bold=$(tput bold 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)

step()  { printf '\n%s==> %s%s\n' "$bold" "$*" "$reset"; }
info()  { printf '    %s\n' "$*"; }
die()   { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "This script is for Linux."

# ---------------------------------------------------------------------------
# 1. Homebrew
# ---------------------------------------------------------------------------
step "Homebrew"
# Homebrew on Linux installs to /home/linuxbrew/.linuxbrew.
BREW=/home/linuxbrew/.linuxbrew/bin/brew
if [[ -x "$BREW" ]]; then
    info "Already installed at $BREW"
else
    info "Installing Homebrew (you may be asked for your sudo password)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    [[ -x "$BREW" ]] || die "Homebrew install finished but $BREW is missing."
fi
eval "$("$BREW" shellenv)"
info "Using $(command -v brew)"

# Make brew available in future login shells (idempotent append). ~/.profile
# covers bash logins before the dotfiles zsh setup is in place, ~/.zprofile
# covers zsh afterwards.
shellenv_line="eval \"\$($BREW shellenv)\""
for profile in "$HOME/.profile" "$HOME/.zprofile"; do
    if ! grep -qsF "$shellenv_line" "$profile"; then
        printf '\n%s\n' "$shellenv_line" >> "$profile"
        info "Added brew shellenv to $profile"
    fi
done

# ---------------------------------------------------------------------------
# 2. Ansible + GitHub CLI
# ---------------------------------------------------------------------------
# gh is needed in step 4, before the playbook runs; ansible is needed in step 6.
# Both are in the playbook's package lists too, so this is just the bootstrap.
step "Installing ansible and gh"
for pkg in ansible gh; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
        info "$pkg already installed."
    else
        brew install "$pkg"
    fi
done

# ---------------------------------------------------------------------------
# 3. SSH key
# ---------------------------------------------------------------------------
step "SSH key"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [[ -f "$SSH_KEY" ]]; then
    info "Key already exists at $SSH_KEY"
else
    info "Generating new ed25519 key at $SSH_KEY"
    ssh-keygen -t ed25519 -C "$SSH_KEY_EMAIL" -f "$SSH_KEY"
fi

# No UseKeychain on Linux (that is a macOS ssh extension); AddKeysToAgent is
# enough, and the agent may not be running at all in a headless session.
ssh_config="$HOME/.ssh/config"
if ! grep -qsF "IdentityFile $SSH_KEY" "$ssh_config"; then
    cat >> "$ssh_config" <<EOF

Host *
  AddKeysToAgent yes
  IdentityFile $SSH_KEY
EOF
    chmod 600 "$ssh_config"
    info "Added agent settings to $ssh_config"
fi
if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
    ssh-add "$SSH_KEY" 2>/dev/null || info "Could not add the key to the agent (passphrase?)."
else
    info "No ssh-agent in this session — skipping ssh-add."
fi

# ---------------------------------------------------------------------------
# 4. GitHub: authenticate and upload the key
# ---------------------------------------------------------------------------
step "GitHub authentication"
if gh auth status >/dev/null 2>&1; then
    info "Already logged in to GitHub."
else
    info "Logging in — follow the prompts. On a headless box choose the"
    info "device-code flow and paste the code into a browser elsewhere."
    gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key
fi

# gh's default token can't manage SSH keys; grab the scope if we lack it.
if ! gh auth status 2>&1 | grep -q "admin:public_key"; then
    info "Adding admin:public_key scope to the gh token..."
    gh auth refresh --hostname github.com --scopes admin:public_key
fi

step "Uploading SSH key to GitHub"
pub_key_material=$(awk '{print $2}' "${SSH_KEY}.pub")
if gh ssh-key list 2>/dev/null | grep -qF "$pub_key_material"; then
    info "Key is already on your GitHub account."
else
    gh ssh-key add "${SSH_KEY}.pub" --title "$SSH_KEY_TITLE"
    info "Key added as '$SSH_KEY_TITLE'."
fi

# Pre-trust github.com so the clones below don't stop to ask.
if ! grep -qs "github.com" "$HOME/.ssh/known_hosts"; then
    ssh-keyscan github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# 5. Origin SSH access + cowork clone (over the tailnet)
# ---------------------------------------------------------------------------
# $ORIGIN_HOST's authorized_keys is ansible-managed from
# https://github.com/<user>.keys by the homelab repo, so installing this
# machine's key is a playbook run from an ALREADY-provisioned machine. Step 4
# pushed the key to GitHub; warn and carry on rather than dying, since every
# later step except the checkouts works without the clone.
#
# This host also has to be ON the tailnet first — that is homelab's
# workstations.yaml plus a manual `sudo tailscale up`.
step "SSH access to $ORIGIN_HOST"
cowork_reachable=true
if ! command -v tailscale >/dev/null 2>&1; then
    info "tailscale is not installed — $ORIGIN_HOST is only reachable on the tailnet."
    info "Run homelab's workstations.yaml against this host, then 'sudo tailscale up'."
fi
if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "${ORIGIN_USER}@${ORIGIN_HOST}" true 2>/dev/null; then
    info "Key-based SSH to $ORIGIN_HOST already works."
else
    cowork_reachable=false
    info "No key-based SSH to $ORIGIN_HOST yet, and it takes publickey only."
    info "From a machine that already has access, run (in the homelab repo,"
    info "typically ~/src/cowork/src/homelab):"
    info "    cd <homelab>/ansible && ansible-playbook -i hosts.ini \\"
    info "        webserver.yaml --limit ${ORIGIN_HOST}"
    info "That installs every key on https://github.com/${GITHUB_USER}.keys,"
    info "which now includes this machine's. Then re-run this script."
fi

step "Cowork repo ($COWORK_REPO -> $COWORK_DIR)"
if [[ -d "$COWORK_DIR/.git" ]]; then
    info "Already cloned."
elif [[ "$cowork_reachable" != true ]]; then
    info "Skipping — no SSH access to $ORIGIN_HOST yet (see above)."
else
    mkdir -p "$(dirname "$COWORK_DIR")"
    git clone "$COWORK_REPO" "$COWORK_DIR"
fi

# ---------------------------------------------------------------------------
# 6. Ansible bootstrap playbook
# ---------------------------------------------------------------------------
# Runs after the cowork clone on purpose: bootstrap.yaml's Caddy tasks are
# silently skipped unless configs/Caddyfile.j2 is already on disk.
step "Ansible bootstrap playbook: $PLAYBOOK"
if [[ -d "$DOTFILES_DIR" ]]; then
    cd "$DOTFILES_DIR"
    [[ -f "$PLAYBOOK" ]] || die "Playbook '$PLAYBOOK' not found in $DOTFILES_DIR."
    if [[ -f requirements.yml ]]; then
        ansible-galaxy install -r requirements.yml
    fi
    # No OBJC_DISABLE_INITIALIZE_FORK_SAFETY needed here — that is a macOS
    # fork-safety workaround.
    ansible-playbook -i "localhost," -c local "$PLAYBOOK"
else
    info "$DOTFILES_DIR not found — skipping the playbook."
fi

# ---------------------------------------------------------------------------
# 7. SOPS/age identity — cowork secrets access
# ---------------------------------------------------------------------------
# No Secure Enclave on Linux, so this is a plain age identity file protected by
# permissions alone (see cowork's decision-secrets-management-2026-06-26.md).
# Enrollment is finished from an ALREADY-enrolled machine; until then this host
# cannot decrypt, and the zshrc claude wrapper will say so and carry on.
step "SOPS/age identity"
AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
for pkg in age sops; do
    brew list --formula "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done
if [[ -f "$AGE_KEY_FILE" ]]; then
    info "Identity already exists at $AGE_KEY_FILE"
else
    mkdir -p "$(dirname "$AGE_KEY_FILE")"
    chmod 700 "$HOME/.config/sops" "$(dirname "$AGE_KEY_FILE")"
    age-keygen -o "$AGE_KEY_FILE"
    chmod 600 "$AGE_KEY_FILE"
fi
recipient=$(grep -o 'age1[0-9a-z]*' "$AGE_KEY_FILE" | tail -1)
info "This machine's public recipient: $recipient"
info "To finish enrollment, from an already-enrolled machine (e.g. impulse):"
info "  1. add the recipient above to .sops.yaml in the cowork repo"
info "  2. sops updatekeys -y secrets/*.enc.env"
info "  3. commit + push, then 'git pull' in $COWORK_DIR on this machine"

# ---------------------------------------------------------------------------
# 8. Claude Code plugins
# ---------------------------------------------------------------------------
# Mirrors mac-setup.sh, minus apple-notes (the MCP server drives Notes.app over
# JXA). Marketplace names come from each repo's .claude-plugin manifest:
# Packetslave/claude-obsidian -> "agricidaniel-claude-obsidian" (the fork keeps
# upstream's name), mattpocock/skills -> "mattpocock".
step "Claude Code plugins"
add_claude_plugin() {
    local repo="$1" marketplace="$2" plugin="$3"
    if ! claude plugin marketplace list 2>/dev/null | grep -q "$marketplace"; then
        claude plugin marketplace add "$repo"
    fi
    if claude plugin list 2>/dev/null | grep -q "${plugin}@${marketplace}"; then
        info "$plugin already installed."
    else
        claude plugin install "${plugin}@${marketplace}"
    fi
}
if command -v claude >/dev/null 2>&1; then
    add_claude_plugin Packetslave/claude-obsidian agricidaniel-claude-obsidian claude-obsidian
    add_claude_plugin mattpocock/skills mattpocock mattpocock-skills
    add_claude_plugin anthropics/claude-plugins-official claude-plugins-official frontend-design
    add_claude_plugin anthropics/claude-plugins-official claude-plugins-official playwright
    add_claude_plugin anthropics/claude-plugins-official claude-plugins-official github
    add_claude_plugin ChromeDevTools/chrome-devtools-mcp chrome-devtools-plugins chrome-devtools-mcp
    info "apple-notes skipped (macOS only)."

    # settings.json: seed defaults on a fresh machine (existing values win — the
    # left side of jq's + loses to what's already in the file), then point
    # statusLine at the dotfiles-owned script (symlinked into ~/.claude by ansible)
    mkdir -p "$HOME/.claude"
    CLAUDE_SETTINGS="$HOME/.claude/settings.json"
    [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
    jq --arg cmd "$HOME/.claude/statusline.sh" \
        '{model: "claude-fable-5[1m]", theme: "dark", tui: "fullscreen"} + .
         + {statusLine: {type: "command", command: $cmd}}' \
        "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" && mv -f "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
else
    info "claude not found — skipping (re-run after the playbook installs it)."
fi

# ---------------------------------------------------------------------------
# 9. Cowork external checkouts (src/_external/)
# ---------------------------------------------------------------------------
# Mirrors mac-setup.sh. Third-party code under src/_external/ isn't part of the
# cowork clone (src/ is gitignored — each entry is its own repo), so every
# machine clones it itself. Five machines have been bitten by the missing
# checkouts: johnny5, impulse, lunchbox (2026-08-20), seaside (2026-08-21) —
# the last because §15 was macOS-only and Linux had no equivalent.
#
# On Linux the set is smaller: omnifocus-cli and ContainerTools are macOS-only.
# papercuts-mcp used to be skipped here too — it lived on Reddit's GHE, which a
# personal box cannot reach — but it now has a bare repo on the tailnet origin,
# so both platforms clone it (see below).
step "Cowork external checkouts"
if [[ -d "$COWORK_DIR/.git" ]]; then
    EXTERNAL_DIR="$COWORK_DIR/src/_external"
    mkdir -p "$EXTERNAL_DIR"

    # claude-obsidian — required by Skills/wiki-ops/scripts/wiki-tx.py, which
    # imports claude_obsidian.ledgers. Without it /claude-obsidian:save and
    # wiki-ingest die with an ImportError.
    if [[ -d "$EXTERNAL_DIR/claude-obsidian" ]]; then
        info "claude-obsidian checkout already present."
    else
        git clone https://github.com/Packetslave/claude-obsidian "$EXTERNAL_DIR/claude-obsidian"
    fi

    # instapaper-mcp — upstream, not a fork. Needs node/npm to build; a missing
    # build surfaces as /mcp reconnect error -32000.
    if [[ ! -d "$EXTERNAL_DIR/instapaper-mcp" ]]; then
        git clone https://github.com/hendronf/Instapaper-MCP "$EXTERNAL_DIR/instapaper-mcp"
    fi
    # Guard on node_modules, not on the compiled entrypoint: instapaper-mcp
    # commits build/ upstream, so build/index.js exists the moment you clone and
    # the old check skipped the install every time on a fresh machine. node_modules
    # is gitignored, so it actually reports whether this checkout was installed.
    # A missing install surfaces as MCP error -32000, by way of
    # ERR_MODULE_NOT_FOUND on @modelcontextprotocol/sdk (bit mfa1, 2026-08-25).
    if [[ -d "$EXTERNAL_DIR/instapaper-mcp/node_modules" ]]; then
        info "instapaper-mcp already installed."
    elif command -v npm >/dev/null 2>&1; then
        (cd "$EXTERNAL_DIR/instapaper-mcp" && npm install && npm run build)
    else
        info "npm not found — skipping instapaper-mcp install."
    fi

    # private-journal-mcp: Claude's own private notebook, with local semantic
    # search (Xenova/all-MiniLM-L6-v2, ~90MB fetched into ~/.cache/huggingface
    # on first use). npm >=11 blocks sharp's install script — that is expected
    # and harmless; text feature-extraction does not need sharp.
    if [[ ! -d "$EXTERNAL_DIR/private-journal-mcp" ]]; then
        git clone https://github.com/obra/private-journal-mcp.git "$EXTERNAL_DIR/private-journal-mcp"
    fi
    # dist/ is gitignored here, unlike instapaper-mcp's build/ — but guard on
    # node_modules anyway, for the same reason and so the two read alike.
    if [[ -d "$EXTERNAL_DIR/private-journal-mcp/node_modules" ]]; then
        info "private-journal-mcp already installed."
    elif command -v npm >/dev/null 2>&1; then
        (cd "$EXTERNAL_DIR/private-journal-mcp" && npm install && npm run build)
    else
        info "npm not found — skipping private-journal-mcp install."
    fi
    # Registered user-scoped in ~/.claude.json (not cowork's .mcp.json) so every
    # project on this machine shares one journal, with PRIVATE_JOURNAL_PATH
    # pinned inside the cowork repo — entries are committed and therefore sync
    # across machines via seaside. Without this step the checkout above is inert.
    if [[ -f "$EXTERNAL_DIR/private-journal-mcp/dist/index.js" ]] && command -v jq >/dev/null 2>&1; then
        CLAUDE_JSON="$HOME/.claude.json"
        [[ -f "$CLAUDE_JSON" ]] || echo '{}' > "$CLAUDE_JSON"
        jq --arg node "$(command -v node)" \
           --arg entry "$EXTERNAL_DIR/private-journal-mcp/dist/index.js" \
           --arg jpath "$COWORK_DIR/.private-journal" \
           --arg path "$(brew --prefix)/bin:/usr/local/bin:/usr/bin:/bin" \
           '.mcpServers["private-journal"] = {
                type: "stdio",
                command: $node,
                args: [$entry],
                env: {
                    PRIVATE_JOURNAL_PATH: $jpath,
                    PATH: $path
                }
            }' "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv -f "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
        info "private-journal registered in $CLAUDE_JSON"
    fi


    # papercuts-mcp: the workflow-friction tracker over .papercuts/. It is OUR
    # code, so it lives at src/papercuts-mcp rather than under _external/ —
    # which is exactly where cowork's committed .mcp.json points. Origin is
    # the tailnet origin over the tailnet: it used to live on Reddit's GHE, unreachable
    # from a personal box, so no personal machine ever had it and the server
    # was one laptop away from being lost outright (cowork-vey, 2026-08-25).
    PAPERCUTS_DIR="$COWORK_DIR/src/papercuts-mcp"
    if [[ ! -d "$PAPERCUTS_DIR" ]]; then
        git clone "${ORIGIN_USER}@${ORIGIN_HOST}:git/papercuts-mcp.git" "$PAPERCUTS_DIR"
    fi
    # node_modules, not dist/, for the same reason as the checkouts above: it is
    # gitignored, so it actually reports whether THIS checkout was installed.
    if [[ -d "$PAPERCUTS_DIR/node_modules" ]]; then
        info "papercuts-mcp already installed."
    elif command -v npm >/dev/null 2>&1; then
        (cd "$PAPERCUTS_DIR" && npm ci && npm run build)
    else
        info "npm not found — skipping papercuts-mcp install."
    fi
    # No ~/.claude.json step, unlike private-journal: cowork's .mcp.json already
    # registers papercuts project-scoped at dist/src/index.js, so a built
    # checkout is all it needs.

    # gmail-duckdb: OUR code, so src/gmail-duckdb rather than _external/. Its own
    # repo because cowork gitignores src/ outright — the 2026-08-28 design pass
    # nearly filed it inside the cowork repo before that was noticed. No build
    # step: it is a uv-managed Python project. Only mfa1 actually runs it (the
    # archive and the hourly timer live there), but every machine clones it so
    # the code is never one disk away from being lost.
    GMAIL_DUCKDB_DIR="$COWORK_DIR/src/gmail-duckdb"
    if [[ ! -d "$GMAIL_DUCKDB_DIR" ]]; then
        git clone "${ORIGIN_USER}@${ORIGIN_HOST}:git/gmail-duckdb.git" "$GMAIL_DUCKDB_DIR"
    else
        info "gmail-duckdb checkout already present."
    fi

    # omnifocus-cli is macOS-only (OmniFocus.app + JXA); nothing to do here.
    info "omnifocus-cli skipped (macOS only)."
    # ContainerTools drives Apple's `container`, which does not exist off macOS.
    info "ContainerTools skipped (macOS only)."
    # papercuts-mcp lives on github.snooguts.net (Reddit GHE) — unreachable from
    # a personal machine, so the papercuts MCP stays dark here.
    info "papercuts-mcp skipped (Reddit GHE)."

    # Own nested repos under src/ (independent git repos, gitignored by cowork)
    for repo in experiments matrix; do
        if [[ -d "$COWORK_DIR/src/$repo" ]]; then
            info "src/$repo already cloned."
        else
            git clone "git@github.com:Packetslave/${repo}.git" "$COWORK_DIR/src/$repo"
        fi
    done
else
    info "cowork clone missing — skipping src/_external checkouts."
fi

step "Done"
info "Remaining manual steps:"
info "  * finish sops enrollment (step 7 printed the recipient)"
info "  * run 'claude' once to authenticate interactively"
info "  * 'bd bootstrap' to seed the beads DB — never 'bd import' the JSONL"
info "  * install the TruffleHog pre-commit guard:"
info "      $COWORK_DIR/Skills/secrets-management/scripts/install-secret-hooks.sh"
