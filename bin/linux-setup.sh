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

step "Done"
info "Next: clone the dotfiles repo to ~/dotfiles and run"
info "  ansible-playbook ansible/bootstrap.yaml"
