#!/bin/bash
#
# mac-setup.sh — bootstrap a brand-new Mac from scratch.
#
# Safe to re-run at any point: every step checks current state before acting,
# so if the script stops (reboot for an OS update, network hiccup, ctrl-C)
# just run it again and it picks up where it left off.
#
# Interactive by design — expect GUI prompts (Xcode CLI tools), sudo password
# prompts, and a browser round-trip for GitHub auth.
#
# Usage:
#   ./mac-setup.sh
#
# Override any of the defaults below via environment variables, e.g.:
#   DOTFILES_REPO=Packetslave/dotfiles PLAYBOOK=ansible/bootstrap.yaml ./mac-setup.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GITHUB_USER="${GITHUB_USER:-Packetslave}"
DOTFILES_REPO="${DOTFILES_REPO:-${GITHUB_USER}/dotfiles}"   # owner/name on GitHub
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
PLAYBOOK="${PLAYBOOK:-ansible/bootstrap.yaml}"               # path relative to DOTFILES_DIR
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
STUDIO_HOST="${STUDIO_HOST:-studio}"                         # tailnet host with the cowork repo
COWORK_REPO="${COWORK_REPO:-${STUDIO_HOST}:git/cowork.git}"
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

[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS."

# Keep sudo warm so the user isn't re-prompted mid-run.
step "Priming sudo (you may be asked for your password)"
sudo -v
# Refresh the sudo timestamp in the background for the life of the script.
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# 1. macOS software updates
# ---------------------------------------------------------------------------
step "Checking for macOS software updates"
update_list=$(softwareupdate --list 2>&1 || true)
if echo "$update_list" | grep -q "No new software available"; then
    info "macOS is up to date."
else
    info "Installing all available updates (this can take a while)..."
    sudo softwareupdate --install --all --verbose || true
    if echo "$update_list" | grep -qi "restart"; then
        printf '\n'
        info "One or more updates require a RESTART."
        info "Reboot when the installer asks, then re-run this script —"
        info "it will skip everything already done and continue."
        read -r -p "    Press Enter to continue for now, or ctrl-C to stop and reboot... "
    fi
fi

# ---------------------------------------------------------------------------
# 2. Xcode Command Line Tools
# ---------------------------------------------------------------------------
step "Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
    info "Already installed at $(xcode-select -p)"
else
    info "Triggering install — click 'Install' in the GUI dialog."
    xcode-select --install
    until xcode-select -p >/dev/null 2>&1; do
        sleep 5
    done
    info "Installed."
fi

# ---------------------------------------------------------------------------
# 3. Homebrew
# ---------------------------------------------------------------------------
step "Homebrew"
# Apple Silicon installs to /opt/homebrew, Intel to /usr/local.
if [[ -x /opt/homebrew/bin/brew ]]; then
    BREW=/opt/homebrew/bin/brew
elif [[ -x /usr/local/bin/brew ]]; then
    BREW=/usr/local/bin/brew
else
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x /opt/homebrew/bin/brew ]]; then
        BREW=/opt/homebrew/bin/brew
    else
        BREW=/usr/local/bin/brew
    fi
fi
eval "$("$BREW" shellenv)"
info "Using $(command -v brew)"

# Make brew available in future login shells (idempotent append).
zprofile="$HOME/.zprofile"
shellenv_line="eval \"\$($BREW shellenv)\""
if ! grep -qsF "$shellenv_line" "$zprofile"; then
    printf '\n%s\n' "$shellenv_line" >> "$zprofile"
    info "Added brew shellenv to $zprofile"
fi

# ---------------------------------------------------------------------------
# 4. Ansible + GitHub CLI
# ---------------------------------------------------------------------------
step "Installing ansible, gh, and mas"
for pkg in ansible gh mas; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
        info "$pkg already installed."
    else
        brew install "$pkg"
    fi
done

# ---------------------------------------------------------------------------
# 5. GUI apps (casks)
# ---------------------------------------------------------------------------
step "Installing casks: 1Password, Chrome, Claude Code, Tailscale"
for cask in 1password google-chrome claude-code tailscale-app; do
    if brew list --cask "$cask" >/dev/null 2>&1; then
        info "$cask already installed."
    else
        brew install --cask "$cask"
    fi
done

# ---------------------------------------------------------------------------
# 6. 1Password sign-in gate
# ---------------------------------------------------------------------------
# The GitHub login later in this script needs the passkey stored in
# 1Password, so don't continue until it's signed in and unlocked.
step "1Password setup"
info "Sign in to 1Password and unlock your vault before continuing."
open -a "1Password"
read -r -p "    Press Enter once 1Password is signed in and unlocked... "

# 1Password for Safari (Mac App Store app) — this is what surfaces the
# GitHub passkey prompt during the login later.
SAFARI_1P_ID=1569813296
if mas list | grep -q "^${SAFARI_1P_ID} "; then
    info "1Password for Safari already installed."
else
    info "Installing 1Password for Safari from the App Store..."
    until mas install "$SAFARI_1P_ID"; do
        info "Install failed — this usually means you're not signed in to the App Store."
        open -a "App Store"
        read -r -p "    Sign in via the App Store window, then press Enter to retry... "
    done
fi

# Enabling the extension is GUI-only — Apple doesn't allow scripting it.
info "In the Safari window that opens: Settings (cmd-,) -> Extensions ->"
info "enable '1Password for Safari' and allow it on every website."
info "Also recommended: System Settings -> General -> AutoFill & Passwords ->"
info "turn on 1Password, so Safari's passkey sheet can offer it."
open -a Safari
read -r -p "    Press Enter once the Safari extension is enabled and unlocked... "

# ---------------------------------------------------------------------------
# 7. Tailscale: sign in and join the tailnet
# ---------------------------------------------------------------------------
# Studio — where the cowork repo lives — is only reachable over the tailnet,
# so this machine has to be signed in before the SSH access step below.
step "Tailscale setup"
TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
if "$TAILSCALE" status >/dev/null 2>&1; then
    info "Already signed in to the tailnet."
else
    open -a Tailscale
    info "In the Tailscale menu-bar app: sign in and connect this machine to"
    info "your tailnet (approve the VPN system extension when macOS asks)."
    read -r -p "    Press Enter once you're signed in and connected... "
    until "$TAILSCALE" status >/dev/null 2>&1; do
        info "Not connected yet — finish sign-in in the app; retrying in 5s..."
        sleep 5
    done
    info "Connected to the tailnet."
fi

# ---------------------------------------------------------------------------
# 8. SSH key
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

# ssh config: load keys into the agent and store passphrases in the keychain.
ssh_config="$HOME/.ssh/config"
if ! grep -qsF "UseKeychain yes" "$ssh_config"; then
    cat >> "$ssh_config" <<EOF

Host *
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile $SSH_KEY
EOF
    chmod 600 "$ssh_config"
    info "Added keychain settings to $ssh_config"
fi
ssh-add --apple-use-keychain "$SSH_KEY" 2>/dev/null || ssh-add "$SSH_KEY"

# ---------------------------------------------------------------------------
# 9. GitHub: authenticate and upload the key
# ---------------------------------------------------------------------------
step "GitHub authentication"
if gh auth status >/dev/null 2>&1; then
    info "Already logged in to GitHub."
else
    info "Logging in — follow the prompts (browser flow is easiest)."
    info "The login opens Safari, where 1Password can offer your GitHub passkey."
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

# Pre-trust github.com so the clone below doesn't stop to ask.
if ! grep -qs "github.com" "$HOME/.ssh/known_hosts"; then
    ssh-keyscan github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# 10. Studio SSH access + cowork clone (over the tailnet)
# ---------------------------------------------------------------------------
step "SSH access to studio"
if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "$STUDIO_HOST" true 2>/dev/null; then
    info "Key-based SSH to $STUDIO_HOST already works."
else
    info "Copying the SSH key to $STUDIO_HOST — you'll be asked for your"
    info "password on $STUDIO_HOST."
    ssh-copy-id -i "${SSH_KEY}.pub" "$STUDIO_HOST"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$STUDIO_HOST" true \
        || die "Key-based SSH to $STUDIO_HOST still fails after ssh-copy-id."
    info "Key installed and verified."
    # ssh-copy-id appends directly to ~/.ssh/authorized_keys on studio; if an
    # ansible run manages that file, it may prune the key again — add it to
    # studio's ansible config as well to make it permanent.
    info "NOTE: if $STUDIO_HOST's authorized_keys is ansible-managed, also add"
    info "this key to that ansible config so the next run doesn't remove it."
fi

step "Cowork repo ($COWORK_REPO -> $COWORK_DIR)"
if [[ -d "$COWORK_DIR/.git" ]]; then
    info "Already cloned."
else
    # Prompted because the repo is large — skip it on a slow connection and
    # clone later instead.
    read -r -p "    Clone the cowork repo now? It's big. [Y/n] " reply
    if [[ "$reply" =~ ^[Nn] ]]; then
        info "Skipping — clone later with: git clone $COWORK_REPO $COWORK_DIR"
    else
        mkdir -p "$(dirname "$COWORK_DIR")"
        git clone "$COWORK_REPO" "$COWORK_DIR"
    fi
fi

# ---------------------------------------------------------------------------
# 11. Dotfiles
# ---------------------------------------------------------------------------
step "Dotfiles ($DOTFILES_REPO -> $DOTFILES_DIR)"
if [[ -d "$DOTFILES_DIR/.git" ]]; then
    info "Repo already cloned; pulling latest."
    git -C "$DOTFILES_DIR" pull --ff-only
else
    git clone "git@github.com:${DOTFILES_REPO}.git" "$DOTFILES_DIR"
fi

# ---------------------------------------------------------------------------
# 12. Ansible bootstrap playbook
# ---------------------------------------------------------------------------
step "Ansible bootstrap playbook: $PLAYBOOK"
cd "$DOTFILES_DIR"
[[ -f "$PLAYBOOK" ]] || die "Playbook '$PLAYBOOK' not found in $DOTFILES_DIR. Set PLAYBOOK=<path> and re-run."

# The playbook reads the sudo password from the login keychain (service
# 'ansible-sudo') for become tasks and cask installs — seed it once here.
if security find-generic-password -s ansible-sudo -w >/dev/null 2>&1; then
    info "Keychain entry 'ansible-sudo' already present."
else
    info "Storing your account password in the login keychain as 'ansible-sudo'"
    info "(the playbook uses it for sudo — delete later with:"
    info " security delete-generic-password -s ansible-sudo)"
    security add-generic-password -s ansible-sudo -a "$USER" -w
fi

read -r -p "    Run the bootstrap playbook now? [Y/n] " reply
if [[ "$reply" =~ ^[Nn] ]]; then
    info "Skipping the playbook — re-run this script when you're ready."
else
    # Install any role/collection requirements first (no-op if already present).
    if [[ -f requirements.yml ]]; then
        ansible-galaxy install -r requirements.yml
    fi
    # OBJC_DISABLE_INITIALIZE_FORK_SAFETY / OS_ACTIVITY_MODE work around the
    # macOS Objective-C fork-safety abort in Ansible's forked workers.
    OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES OS_ACTIVITY_MODE=disable \
        ansible-playbook -i "localhost," -c local "$PLAYBOOK"
fi

# ---------------------------------------------------------------------------
# 13. SOPS/age identity (Secure Enclave) — cowork secrets access
# ---------------------------------------------------------------------------
# Each machine has its own non-exportable Secure Enclave age identity; cowork
# secrets are encrypted to every machine's public recipient. Enrollment is
# finished from an ALREADY-enrolled machine (see cowork's
# Skills/secrets-management/SKILL.md) — until then this machine can't decrypt.
step "SOPS/age identity"
AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
# Normally installed by the playbook; cover the case where it was skipped.
for pkg in age age-plugin-se sops; do
    brew list --formula "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done
if [[ -f "$AGE_KEY_FILE" ]]; then
    info "Identity already exists at $AGE_KEY_FILE"
else
    mkdir -p "$(dirname "$AGE_KEY_FILE")"
    chmod 700 "$HOME/.config/sops" "$(dirname "$AGE_KEY_FILE")"
    age-plugin-se keygen --access-control=any-biometry-or-passcode -o "$AGE_KEY_FILE"
fi
recipient=$(grep -o 'age1se1[0-9a-z]*' "$AGE_KEY_FILE" | head -1)
info "This machine's public recipient: $recipient"
info "To finish enrollment, from an already-enrolled machine (e.g. lunchbox):"
info "  1. add the recipient above to .sops.yaml in the cowork repo"
info "  2. sops updatekeys -y secrets/*.enc.env"
info "  3. commit + push, then 'git pull' in $COWORK_DIR on this machine"

# ---------------------------------------------------------------------------
# 14. Claude Code plugins
# ---------------------------------------------------------------------------
# The cowork repo's wiki workflow needs the claude-obsidian plugin
# (/claude-obsidian:* skills); mattpocock-skills is the general engineering
# skill set. Marketplace names come from each repo's .claude-plugin manifest:
# Packetslave/claude-obsidian -> "agricidaniel-claude-obsidian" (fork keeps
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
add_claude_plugin Packetslave/claude-obsidian agricidaniel-claude-obsidian claude-obsidian
add_claude_plugin mattpocock/skills mattpocock mattpocock-skills
add_claude_plugin anthropics/claude-plugins-official claude-plugins-official frontend-design
add_claude_plugin anthropics/claude-plugins-official claude-plugins-official playwright
add_claude_plugin anthropics/claude-plugins-official claude-plugins-official github
add_claude_plugin sweetrb/apple-notes-mcp apple-notes-mcp apple-notes
add_claude_plugin ChromeDevTools/chrome-devtools-mcp chrome-devtools-plugins chrome-devtools-mcp

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

# ---------------------------------------------------------------------------
# 15. Cowork external checkouts (src/_external/)
# ---------------------------------------------------------------------------
# Third-party code under src/_external/ isn't part of the cowork clone, so
# each machine clones + builds it itself. A missing instapaper-mcp build
# surfaces as /mcp reconnect error -32000 (bit johnny5's setup, then impulse).
step "Cowork external checkouts"
if [[ -d "$COWORK_DIR/.git" ]]; then
    EXTERNAL_DIR="$COWORK_DIR/src/_external"
    mkdir -p "$EXTERNAL_DIR"
    if [[ -d "$EXTERNAL_DIR/claude-obsidian" ]]; then
        info "claude-obsidian checkout already present."
    else
        git clone https://github.com/Packetslave/claude-obsidian "$EXTERNAL_DIR/claude-obsidian"
    fi
    if [[ ! -d "$EXTERNAL_DIR/instapaper-mcp" ]]; then
        git clone https://github.com/hendronf/Instapaper-MCP "$EXTERNAL_DIR/instapaper-mcp"
    fi
    if [[ -f "$EXTERNAL_DIR/instapaper-mcp/build/index.js" ]]; then
        info "instapaper-mcp already built."
    else
        (cd "$EXTERNAL_DIR/instapaper-mcp" && npm install && npm run build)
    fi
    if [[ ! -d "$EXTERNAL_DIR/omnifocus-cli" ]]; then
        git clone git@github.com:Packetslave/omnifocus-cli.git "$EXTERNAL_DIR/omnifocus-cli"
    fi
    # Drop/undrop support (upstream PR #44) lives on this branch; a main-branch
    # build silently lacks --drop (bit impulse, 2026-08-15).
    OF_BRANCH="feature/task-drop-support"
    if [[ "$(git -C "$EXTERNAL_DIR/omnifocus-cli" rev-parse --abbrev-ref HEAD)" != "$OF_BRANCH" ]]; then
        git -C "$EXTERNAL_DIR/omnifocus-cli" fetch origin "$OF_BRANCH"
        git -C "$EXTERNAL_DIR/omnifocus-cli" checkout "$OF_BRANCH"
        rm -f "$EXTERNAL_DIR/omnifocus-cli/dist/cli.js"  # force rebuild after branch switch
    fi
    if [[ -f "$EXTERNAL_DIR/omnifocus-cli/dist/cli.js" ]]; then
        info "omnifocus-cli already built."
    else
        (cd "$EXTERNAL_DIR/omnifocus-cli" && bun install && bun run build)
    fi
    # The omnifocus skill invokes ~/.bun/bin/of by absolute path; point it at
    # the fork build. (A bun/npm install of the stock package would silently
    # clobber this symlink — re-run this section if drop/undrop stops working.)
    mkdir -p "$HOME/.bun/bin"
    ln -sf "$EXTERNAL_DIR/omnifocus-cli/dist/cli.js" "$HOME/.bun/bin/of"

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

# ---------------------------------------------------------------------------
# 16. 1Password extension for Chrome (optional — Safari covers the bootstrap)
# ---------------------------------------------------------------------------
step "1Password extension for Chrome"
ONEPASSWORD_EXT_ID="aeblfdkhhhdcdjpifhhbdiojplfjncoa"
if find "$HOME/Library/Application Support/Google/Chrome" -maxdepth 3 -type d \
        -name "$ONEPASSWORD_EXT_ID" 2>/dev/null | grep -q .; then
    info "1Password Chrome extension already installed."
else
    info "Opening the Chrome Web Store — click 'Add to Chrome' to install"
    info "the 1Password extension, then make sure it's linked to the app."
    open -a "Google Chrome" "https://chromewebstore.google.com/detail/${ONEPASSWORD_EXT_ID}"
    read -r -p "    Press Enter once the extension is installed (or to skip)... "
fi

step "Done"
info "Mac bootstrap complete. Open a new terminal to pick up shell changes."
