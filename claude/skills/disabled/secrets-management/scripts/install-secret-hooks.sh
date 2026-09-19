#!/usr/bin/env bash
# Install the TruffleHog pre-commit secret guard into every repo we author.
#
# Idempotent: re-run after editing trufflehog-pre-commit.sh to push the update
# everywhere. Safe alongside other hook owners -- cowork's pre-commit is a
# plain `#!/usr/bin/env sh` script, chassis has a sops guard on
# core.hooksPath, and this only ever rewrites its own marker block.
#
# Refuses to run without trufflehog installed. That is deliberate: the guard
# fails closed, so installing it on a machine that cannot run it would block
# every commit there -- including seaside's headless TLDR digest cron.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SRC="$SRC_DIR/trufflehog-pre-commit.sh"
BEGIN="# --- BEGIN TRUFFLEHOG SECRET GUARD v1 ---"
END="# --- END TRUFFLEHOG SECRET GUARD v1 ---"

REPOS=(
  "$HOME/src/cowork"
  "$HOME/src/cowork/src/homelab"
  "$HOME/src/cowork/src/matrix"
  "$HOME/src/cowork/src/chassis"
  "$HOME/src/cowork/src/papercuts-mcp"
  "$HOME/src/cowork/src/experiments"
  "$HOME/dotfiles"
)

if ! command -v trufflehog >/dev/null 2>&1; then
  echo "refusing to install: trufflehog is not on PATH." >&2
  echo "The guard fails closed, so installing it here would block every commit." >&2
  echo "Install it first:  brew install trufflehog" >&2
  exit 1
fi
[ -f "$GUARD_SRC" ] || { echo "missing $GUARD_SRC" >&2; exit 1; }

for repo in "${REPOS[@]}"; do
  if [ ! -d "$repo/.git" ] && ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    printf '  %-42s SKIP (not a git repo here)\n' "${repo/#$HOME/~}"
    continue
  fi

  # Honour core.hooksPath when a repo sets one (chassis does), otherwise .git/hooks.
  hp=$(git -C "$repo" config --get core.hooksPath || true)
  if [ -n "$hp" ]; then
    case "$hp" in /*) hookdir="$hp" ;; *) hookdir="$repo/$hp" ;; esac
  else
    hookdir="$(git -C "$repo" rev-parse --absolute-git-dir)/hooks"
  fi
  mkdir -p "$hookdir"

  /bin/cp -f "$GUARD_SRC" "$hookdir/trufflehog-guard.sh"
  chmod +x "$hookdir/trufflehog-guard.sh"

  hook="$hookdir/pre-commit"
  if [ ! -f "$hook" ]; then
    printf '#!/usr/bin/env sh\n' > "$hook"
  fi

  # The shim is POSIX sh on purpose: cowork's pre-commit is
  # `#!/usr/bin/env sh`, and on Linux that is dash, which has neither
  # process substitution nor `read -d` nor pipefail. The guard itself is bash
  # and runs as its own process.
  block=$(cat <<SHIM
$BEGIN
# Managed by install-secret-hooks.sh -- do not edit this block by hand.
# Resolve alongside this hook, not under .git/hooks: a repo may set
# core.hooksPath elsewhere (chassis points at scripts/hooks).
_th_guard="\$(dirname "\$0")/trufflehog-guard.sh"
if [ ! -x "\$_th_guard" ]; then
  echo >&2 "pre-commit: trufflehog-guard.sh missing -- run install-secret-hooks.sh"
  exit 1
fi
"\$_th_guard" || exit \$?
$END
SHIM
)

  if grep -qF "$BEGIN" "$hook"; then
    python3 - "$hook" "$BEGIN" "$END" "$block" <<'PY'
import sys
path, begin, end, block = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(path).read().split("\n")
out, skip = [], False
for ln in lines:
    if ln.strip() == begin.strip():
        skip = True
        out.append(block)
        continue
    if ln.strip() == end.strip():
        skip = False
        continue
    if not skip:
        out.append(ln)
open(path, "w").write("\n".join(out))
PY
    status="updated"
  else
    # PREPEND (right after the shebang), never append. An existing hook may
    # `exec` or exit early and would then skip the guard entirely -- chassis's
    # sops guard `exec`s whenever a commit touches secrets/, which is exactly
    # the case the guard most needs to see.
    python3 - "$hook" "$block" <<'PYPREPEND'
import sys
path, block = sys.argv[1], sys.argv[2]
lines = open(path).read().split(chr(10))
at = 1 if lines and lines[0].startswith("#!") else 0
lines[at:at] = ["", block]
open(path, 'w').write(chr(10).join(lines))
PYPREPEND
    status="installed"
  fi
  chmod +x "$hook"
  printf '  %-42s %-10s (%s)\n' "${repo/#$HOME/~}" "$status" "${hookdir/#$HOME/~}"
done

echo
echo "Done. Verify one with:  cd <repo> && git commit --allow-empty -m test"
