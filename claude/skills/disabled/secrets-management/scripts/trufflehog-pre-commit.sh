#!/usr/bin/env bash
# --- BEGIN TRUFFLEHOG SECRET GUARD v1 ---
# Blocks a commit whose staged content contains a credential TruffleHog can
# confirm is live. Installed and updated by install-secret-hooks.sh -- edit the
# canonical copy and re-run the installer rather than editing a deployed copy.
#
# Only STAGED CONTENT is scanned, exported to a scratch directory first. Scanning
# the working tree instead would also walk .git/objects and re-report every secret
# ever committed, which would block every future commit in any repo that has one
# in its history (cowork and homelab both do).
#
# Fails closed: no TruffleHog, no commit. That is deliberate -- a guard that
# silently no-ops when its scanner is missing provides false assurance.
# Install it with `brew install trufflehog`.
#
#
# ACCEPTED RISK -- verification makes outbound requests to hosts taken from the
# content being scanned. TruffleHog confirms a credential by trying it, and for
# self-hosted detectors the endpoint comes from the match itself: a staged
# a staged Postgres connection string causes a connection attempt to `host`. That is
# an outbound request built from a user-controlled URL with no allow-list, and
# there is no TruffleHog flag to constrain it short of disabling verification.
#
# Accepted deliberately, because verification is the whole point here: it is what
# distinguishes a live credential from a high-entropy string, and it is what
# caught the Grafana Cloud token that prompted this guard. `--no-verification`
# would flood the hook with unverified matches, and a guard that cries wolf gets
# bypassed reflexively -- a worse security outcome than this risk.
#
# Threat model: the content scanned here is what the developer just staged in
# their own working tree. Someone able to stage a crafted DSN can already run
# arbitrary commands on the machine. Revisit if that stops being true.
#
# Bypass for a deliberate commit:  git commit --no-verify
set -uo pipefail

if ! command -v trufflehog >/dev/null 2>&1; then
  echo >&2 ""
  echo >&2 "  ✖ COMMIT BLOCKED: trufflehog is not installed."
  echo >&2 ""
  echo >&2 "    This repo's pre-commit secret guard fails closed by design."
  echo >&2 "    Install it:   brew install trufflehog"
  echo >&2 "    Or converge:  ansible-playbook -i localhost, ~/dotfiles/ansible/bootstrap.yaml"
  echo >&2 "    Bypass once:  git commit --no-verify"
  echo >&2 ""
  exit 1
fi

_th_tmp=$(mktemp -d "${TMPDIR:-/tmp}/trufflehog-precommit.XXXXXX") || exit 1
trap 'rm -rf "$_th_tmp"' EXIT

# The scan root is a CHILD of the scratch dir and the report lives OUTSIDE it.
# With both in one directory TruffleHog scanned its own JSON output, and a staged
# file named like the report would have been truncated by the redirection before
# it was ever scanned -- a silent bypass.
_th_root="$_th_tmp/scan"
_th_out="$_th_tmp/report.json"
_th_list="$_th_tmp/staged.nul"
mkdir -p "$_th_root" || exit 1

# ONE authoritative listing, NUL-delimited, with its exit status checked. Two
# separate `git diff` calls could disagree, and a failing `git diff` whose output
# is captured by `$(...)` or hidden behind a process substitution reads as
# "nothing staged" -- fail-open in a guard whose whole premise is failing closed.
#
# --diff-filter=d excludes deletions and keeps everything else. The earlier ACMR
# silently dropped type-changes (T), so replacing a symlink with a real file
# containing a credential was never scanned.
if ! git diff --cached --name-only --diff-filter=d -z > "$_th_list"; then
  echo >&2 "  ✖ COMMIT BLOCKED: could not list staged files (git diff failed)."
  exit 1
fi
[ -s "$_th_list" ] || exit 0

# Export the INDEX version of each staged path, preserving directory structure,
# so what gets scanned is exactly what is about to be committed.
#
# `:./path` not `:path` -- a staged name beginning with `0:` would otherwise parse
# as git's `:<stage>:<path>` selector and export the wrong blob. `./` on the
# dirname operand for the same class of reason: a leading `-` parses as an option.
# A failed export aborts rather than skipping the file, so nothing slips through
# unscanned.
while IFS= read -r -d '' _th_f; do
  mkdir -p "$_th_root/$(dirname "./$_th_f")" || exit 1
  if ! git show ":./$_th_f" > "$_th_root/$_th_f"; then
    echo >&2 "  ✖ COMMIT BLOCKED: could not export staged file for scanning: $_th_f"
    exit 1
  fi
done < "$_th_list"

trufflehog filesystem "$_th_root" \
  --results=verified,unknown \
  --no-update \
  --fail \
  --json > "$_th_out" 2>/dev/null
_th_rc=$?

# 183 = findings. 0 = clean. Anything else is a scanner failure, and failing
# closed means treating that as a block too rather than waving the commit through.
if [ "$_th_rc" -eq 0 ]; then
  exit 0
fi

echo >&2 ""
if [ "$_th_rc" -eq 183 ]; then
  echo >&2 "  ✖ COMMIT BLOCKED: live credential(s) found in staged content."
else
  echo >&2 "  ✖ COMMIT BLOCKED: trufflehog exited $_th_rc (scan error, not a clean result)."
fi
echo >&2 ""

python3 - "$_th_out" "$_th_tmp" "$_th_root" >&2 <<'PYEOF'
import json, sys
report, tmp, root = sys.argv[1], sys.argv[2], sys.argv[3]
seen = set()
try:
    lines = open(report, encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    lines = []
for line in lines:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue
    f = d.get("SourceMetadata", {}).get("Data", {}).get("Filesystem", {})
    path = (f.get("file") or "?")
    # Strip the scratch prefix so the path shown is the one the user staged.
    # Cannot compare against `root` directly: on macOS mktemp yields /var/... while
    # TruffleHog reports the resolved /private/var/..., so match on the unique
    # scratch-directory component instead.
    marker = "/" + tmp.rstrip("/").rsplit("/", 1)[-1] + "/scan/"
    if marker in path:
        path = path.split(marker, 1)[1]
    key = (d.get("DetectorName"), path, f.get("line"))
    if key in seen:
        continue
    seen.add(key)
    # Only two states reach here: Verified, or `unknown` (verification was
    # attempted and errored). Both block. Do not print "unverified" -- that is a
    # third TruffleHog state which is filtered out and never gets this far.
    state = "VERIFIED LIVE" if d.get("Verified") else "UNCONFIRMED (verification failed)"
    line_no = f.get("line")
    where = f"{path}:{line_no}" if line_no else path
    print(f"    {d.get('DetectorName')} [{state}]  {where}")
PYEOF

echo >&2 ""
echo >&2 "    Remove the credential and rotate it -- committing then amending does"
echo >&2 "    not help, the value still reaches the object store."
echo >&2 "    Deliberate commit anyway:  git commit --no-verify"
echo >&2 ""
exit 1
# --- END TRUFFLEHOG SECRET GUARD v1 ---
