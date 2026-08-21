#!/bin/bash
#
# linux-setup.sh — bootstrap a new Linux machine (mac-setup.sh's sibling).
#
# Safe to re-run at any point: every step checks current state before acting.
#
# Deliberately minimal for now: install Homebrew, then use it to install
# ansible. The ansible playbook (ansible/bootstrap.yaml) does the rest —
# grow this script only with steps ansible can't do for itself.
#
# Usage:
#   ./linux-setup.sh

set -euo pipefail

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
# 2. Ansible
# ---------------------------------------------------------------------------
step "Installing ansible"
if brew list --formula ansible >/dev/null 2>&1; then
    info "ansible already installed."
else
    brew install ansible
fi

# ---------------------------------------------------------------------------
# 3. Cowork external checkouts (src/_external/)
# ---------------------------------------------------------------------------
# Mirrors mac-setup.sh §15. Third-party code under src/_external/ isn't part of
# the cowork clone (src/ is gitignored — each entry is its own repo), so every
# machine clones it itself. Four machines have been bitten by the missing
# checkouts: johnny5, impulse, lunchbox (2026-08-20), seaside (2026-08-21) —
# the last because §15 was macOS-only and Linux had no equivalent.
#
# On Linux the set is smaller than the Mac's: omnifocus-cli is deliberately
# skipped (OmniFocus is a Mac app driven over JXA).
step "Cowork external checkouts"
COWORK_DIR="${COWORK_DIR:-$HOME/src/cowork}"
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
    if [[ -f "$EXTERNAL_DIR/instapaper-mcp/build/index.js" ]]; then
        info "instapaper-mcp already built."
    elif command -v npm >/dev/null 2>&1; then
        (cd "$EXTERNAL_DIR/instapaper-mcp" && npm install && npm run build)
    else
        info "npm not found — skipping instapaper-mcp build (re-run after ansible installs node)."
    fi

    # omnifocus-cli is macOS-only (OmniFocus.app + JXA); nothing to do here.
    info "omnifocus-cli skipped (macOS only)."

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
info "Next: clone the dotfiles repo to ~/dotfiles and run"
info "  ansible-playbook ansible/bootstrap.yaml"
