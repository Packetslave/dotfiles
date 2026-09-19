---
name: secrets-management
description: >
  Playbook for sops + age secrets in cowork and src/homelab, which share four
  per-device recipients. Use whenever Brian wants to set up sops/age on a machine,
  add or edit an encrypted secret, run a script that needs credentials, add or
  remove a machine's access (recipient), or rotate/revoke a key. Read it FIRST to
  check which model applies: src/chassis uses sops too but with one shared key, so
  its rules differ and this skill routes there rather than restating them. Also
  answers which operations need a Mac (creating a file, not editing one). Decision
  rationale lives in Decisions/decision-secrets-management-2026-06-26.md.
---

# Secrets Management (sops + age)

Encrypt project secrets with **[sops](https://github.com/getsops/sops)** + **[age](https://github.com/FiloSottile/age)**,
**per-device keys (multi-recipient)**. Encrypted blobs (`secrets/*.enc.env`) live in git and sync
via the `studio` remote; the *decryption* keys are per-machine and **never** synced or stored in
plaintext at rest. Rationale and rejected alternatives:
`Decisions/decision-secrets-management-2026-06-26.md`.

> **Run on the host, not the sandbox.** Key generation, `sops`, and git all run natively on
> macOS/Linux. The Cowork sandbox has no enrolled key — see "Sandbox" at the end.

---

## First: which tree are you in?

**Three repos use sops, in two incompatible ways.** Applying one model's rules
to the other is the mistake this section exists to prevent.

| | **cowork** + **src/homelab** | **src/chassis** |
|---|---|---|
| Model | per-device, **multi-recipient** | **one shared key** |
| Recipients | 5 — `age1ck4nr0…` (Linux) + lunchbox, johnny5, impulse, studio (Secure Enclave) | 1 — `age1l7dx7uq…`, a plain age key |
| Private key | never leaves its machine | **deliberately copied** to `~/.config/chassis/age.key`, and a `SOPS_AGE_KEY` Actions secret |
| Creating an encrypted file | **needs a Mac** (see below) | any machine holding the key |
| Path rules | cowork `secrets/*.enc.env`; homelab `ansible/vars/*.enc.yaml` **and** `secrets/*.enc.env` | `secrets/*.env` |
| Everyday tooling | raw `sops` | `make secrets-{decrypt,edit,encrypt,merge,check}` |

**This skill covers cowork and homelab.** For chassis, stop here and read its
own docs, which sit next to the Makefile that implements them:

- `src/chassis/secrets/README.md` — the file layout, and why infra and app
  secrets are split (nothing in `prod.sops.env` may land on a box).
- `src/chassis/docs/runbooks/secrets-rotation.md` — onboard a machine, rotate
  the key, change a value, add a recipient.

Do not copy chassis's procedures here. A second copy drifts from its Makefile,
and the whole point of the routing table above is that its answers differ.

**cowork and homelab share the same four recipients, in two separate
`.sops.yaml` files that are kept in step by hand.** Enrolling a machine means
editing both. `studio` is listed but commented out — it is not enrolled.

---

## What needs a Mac (and what does not)

The macOS-only step is **wrapping a data key**, which `age-plugin-se` does for
the three Secure-Enclave recipients. Wrapping happens when a file is
**created**. A file that already exists carries its data key, so changing a
value wraps nothing.

| Operation | Linux (mfa1) | Why |
|---|---|---|
| `sops -d` / `exec-env` | works | any **one** recipient key unwraps |
| `sops set` on an existing file | works | reuses the file's existing data key |
| `sops <file>` editor flow | works | same |
| `sops updatekeys`, recipient list unchanged | works | nothing new to wrap |
| `sops -e` on a **new** file | **Mac only** | new data key, wrapped for all four |
| enrolling a **new** Secure-Enclave recipient | **Mac only** | must wrap for the new one |

**Rule of thumb: if the `.enc` file already exists, edit it wherever you are.**
Reach for a Mac only to create one, or to add a recipient.

This was stated as a blanket "writing needs a Mac" until 2026-08-28, in eleven
places, and it sent a session hunting for a Mac to add two values to a file
already on the local disk. Verified on mfa1 against a copy of
`src/homelab/ansible/vars/monitoring.enc.yaml`; all four recipients survived
each operation that succeeded.

### The trap that makes this hard to test

`sops set` reads the **target file's own metadata**, so it works even on a copy
outside the `.sops.yaml` paths. `sops -e` and the editor flow instead consult
`creation_rules`, which sops matches against the **input path** — so on a file
staged anywhere else they fail with:

```
error loading config: no matching creation rules found
```

That looks exactly like the plugin constraint and is not it. **Test inside a
path the rules match**, or you will conclude the wrong thing — which is
precisely what happened on the first attempt to map this.

---

## Mental model

- **One age identity per machine.** Macs use a Secure-Enclave identity (`age-plugin-se`, Touch-ID
  gated, non-exportable). Linux uses a plain age key file (`chmod 600`).
- **Every secret is encrypted to *all* machines** as recipients, listed in `.sops.yaml`. Any one
  machine decrypts with its own local identity.
- **Membership changes = re-encrypt.** Adding/removing a machine, or rotating a key, means editing
  the recipient list and re-running sops over the secrets. This is also how you **revoke** a lost
  machine.

---

## Prerequisites (per machine, one-time)

Install via Homebrew (macOS) or your Linux package manager:

```bash
# macOS
brew install sops age
brew install age-plugin-se        # Macs only — Secure Enclave plugin

# Linux (example: Homebrew on Linux, or use apt/dnf)
brew install sops age
```

---

## 1. Enroll a machine (generate its key, add it as a recipient)

**On a Mac (Secure Enclave):**
```bash
mkdir -p ~/.config/sops/age
age-plugin-se keygen -o ~/.config/sops/age/keys.txt --access-control=any-biometry-or-passcode
# prints the PUBLIC recipient, e.g.  age1se1q?...    <-- copy this
```

**On Linux (plain key):**
```bash
mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt        # prints "Public key: age1..." <-- copy this
chmod 600 ~/.config/sops/age/keys.txt
```

Then on every machine, point sops at its local identity (add to your shell profile):
```bash
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
```

Finally, **add the public recipient to `.sops.yaml`** at the repo root (one line per machine) and
**re-encrypt existing secrets** (see step 4). Until a machine's recipient is in `.sops.yaml` and
the secrets are re-encrypted, that machine cannot decrypt.

`.sops.yaml` shape:
```yaml
creation_rules:
  - path_regex: secrets/.*\.enc\.env$
    key_groups:
      - age:
          - age1...        # studio (Secure Enclave)
          - age1...        # macbook-air (Secure Enclave)
          - age1...        # linux-pc
          # add one line per enrolled machine
```

---

## 2. Create a new secret

Write the plaintext `KEY=value` pairs, encrypt in place, then **delete the plaintext**:
```bash
cat > secrets/unifi.enc.env <<'EOF'
UNIFI_HOST=192.168.192.1
UNIFI_USER=ro-account
UNIFI_PASS=...redacted...
EOF
sops --encrypt --in-place secrets/unifi.enc.env     # values become ciphertext; keys stay readable
# ^ MAC ONLY in cowork/homelab: a new file wraps a fresh data key for all four
#   recipients, three of which are Secure Enclave. See "What needs a Mac".
git add secrets/unifi.enc.env .sops.yaml            # commit on the HOST (never the sandbox)
```
The file is safe to commit: only values are encrypted, so diffs stay sane.

---

## 3. Read / edit a secret

```bash
sops secrets/unifi.enc.env            # opens decrypted in $EDITOR; re-encrypts on save
sops --decrypt secrets/unifi.enc.env  # print decrypted to stdout (avoid; prefer exec-env)
```

**Non-interactively — the path to prefer in a script or an agent session.**
`sops set` needs no `$EDITOR`, and `--value-stdin` keeps the secret out of the
process list, which a value passed as an argument would not be:

```bash
printf '"%s"' "$TOKEN" | sops set --value-stdin secrets/unifi.enc.env '["UNIFI_PASS"]'
```

Two things bite here. The value must be **JSON-encoded**, so a bare string
needs its surrounding quotes — otherwise sops rejects it with `Value for --set
is not valid JSON`. And the index is a JSON path in single quotes,
`'["KEY"]'`. Read it back to prove the round trip before trusting it:

```bash
sops -d --extract '["UNIFI_PASS"]' secrets/unifi.enc.env
```

This works on any machine that can decrypt the file — see "What needs a Mac".

---

## 4. Re-encrypt after changing recipients (add/remove a machine, rotate)

```bash
sops updatekeys secrets/unifi.enc.env   # re-encrypts to the current .sops.yaml recipient set
# repeat for each secrets/*.enc.env, then commit on the host
```

**ADDING a Secure-Enclave recipient is Mac only** — the data key has to be
wrapped for the new one. `updatekeys` with the recipient list *unchanged* is a
no-op that succeeds anywhere. **Removing** a recipient re-wraps only for those
that remain, so a revocation can be done from any machine still on the list.

Remember homelab has **two** `creation_rules` paths, and cowork's recipient
list must be kept in step with homelab's by hand:

```bash
sops updatekeys ansible/vars/*.enc.yaml secrets/*.enc.env   # in src/homelab
```
To **revoke** a machine: remove its `age1...` line from `.sops.yaml`, run `updatekeys`, commit.
The retired key can no longer decrypt future versions.

---

## 5. Consume a secret in a script (the important part)

`sops exec-env` decrypts into environment variables for a single child process — nothing hits
disk. Scripts just read normal env vars, so **no script changes are needed**:

```bash
sops exec-env secrets/unifi.enc.env \
  'uv run Skills/home-network-debugging/scripts/unifi-client-port.py truenas'
```

This populates `UNIFI_HOST` / `UNIFI_USER` / `UNIFI_PASS`, which the helper already reads. The
old manual `export …; read -rs …` flow still works for ad-hoc use; `exec-env` is the durable path.

---

## 6. The pre-commit secret guard (TruffleHog)

Every repo we author blocks a commit whose **staged content** contains a credential
TruffleHog can confirm is live. Added 2026-08-24 after a Grafana Cloud token was found
committed in plaintext, seven times, in `src/homelab` — see bead `cowork-8lm`.

```bash
# Install or update the guard everywhere (idempotent — re-run after editing the guard):
./Skills/secrets-management/scripts/install-secret-hooks.sh
```

Covers cowork, `src/{homelab,matrix,chassis,papercuts-mcp,experiments}` and `~/dotfiles`.
Deliberately **not** the `src/_external/` checkouts, which are upstream clones.

- **Fails closed.** No TruffleHog on PATH, no commit. A guard that silently no-ops when
  its scanner is missing gives false assurance. The installer therefore refuses to run
  unless TruffleHog is present, so a machine can never be left unable to commit.
- **`trufflehog` is in `homebrew_common_formulae`** (dotfiles `ansible/bootstrap.yaml`),
  so every machine picks it up on its next bootstrap run.
- **Only staged content is scanned**, exported to a scratch directory first. Scanning the
  working tree would also walk `.git/objects` and re-report every secret ever committed —
  which would block *all* future commits in cowork and homelab, both of which have one in
  their history.
- **`--results=verified,unknown`.** A finding must be confirmed live (or unverifiable) to
  block. That keeps false positives near zero, at the cost of an outbound call to the
  issuing provider to test the candidate. It is what catches the case that actually
  matters — the Grafana token was detected as `VERIFIED LIVE`. The trade-off is that a
  real-but-already-revoked credential can slip through as merely `unverified`.
- **Accepted risk: verification makes outbound requests to hosts taken from the scanned
  content.** TruffleHog confirms a credential by trying it, and self-hosted detectors take
  the endpoint from the match itself — a staged a staged Postgres connection string causes a
  connection attempt to `host`. That is an outbound request built from a user-controlled
  URL with no allow-list, and no flag constrains it short of `--no-verification`. Accepted
  because verification is the capability that makes this worth having: it separates a live
  credential from a high-entropy string, and it is what caught the Grafana token. A noisy
  gate gets bypassed reflexively, which is the worse outcome. Locally, the scanned content
  is what you just staged in your own tree; in CI, the repos are private with no external
  contributors. **Revisit if any of those repos starts taking PRs from untrusted
  contributors** — CI should then use `--no-verification` even while the local hook keeps
  verifying. Raised by Macroscope's security review on chassis PR #13, 2026-08-24.
- **Example credentials in documentation will block a commit.** An `unknown` result —
  verification attempted and errored, which is what a fake host produces — blocks just as
  a verified one does. Writing this very section tripped the guard, because it contained a
  literal Postgres connection string. Describe the shape in prose rather than pasting a
  parseable example, or bypass that one commit.
- **Bypass** a deliberate commit with `git commit --no-verify`.
- **Two hook owners existed and were respected**: beads managed cowork's `pre-commit`
  between its own markers until it was retired on 2026-09-17, and chassis points `core.hooksPath` at `scripts/hooks` for its
  sops guard. The installer only ever rewrites its own marker block, and the shim it adds
  is POSIX `sh` (resolving the bash guard relative to itself) because beads wrote that
  hook with a `#!/usr/bin/env sh` shebang — which is `dash` on Linux.

**Not a substitute for rotation.** The guard stops a *new* leak; it does nothing about a
credential already in history. If one lands, rotate it.

## Sandbox

The Cowork Linux sandbox has no enrolled age key, so `sops` can't decrypt there. Run any
secret-consuming command **on the host** (the established pattern for the UniFi helper). Do not
copy a private key into the sandbox except as a deliberate, short-lived exception.

## Guardrails

- **Never commit plaintext secrets or private keys.** `.gitignore` blocks common patterns;
  `secrets/*.enc.env` (encrypted) is the only thing that belongs in git.
- **Commit on the host, not the sandbox** (the FUSE mount breaks git's lockfile cleanup).
- The age **private** key (`~/.config/sops/age/keys.txt`) lives outside the repo and is never
  synced to cloud storage — that is the whole point of the per-device design.
