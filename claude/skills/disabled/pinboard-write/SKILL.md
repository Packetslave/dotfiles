---
name: pinboard-write
description: >
  Write (mutate) Pinboard.in bookmarks and tags — add or delete a bookmark,
  rename or delete a tag. The pinboard MCP connector (mcp__pinboard__*) is
  read-only, so use this skill for any mutation. Triggers: "bookmark this to
  pinboard," "save this to pinboard," "add a pinboard bookmark," "delete this
  pinboard bookmark," "rename this pinboard tag," "delete this pinboard tag."
---

# Pinboard Write

Direct wrapper around the write side of the [Pinboard API v1](https://pinboard.in/api/)
(`posts/add`, `posts/delete`, `tags/rename`, `tags/delete`). The `pinboard` MCP server
(`mcp__pinboard__*`) only exposes read tools (`search_bookmarks`, `list_tags`, etc.) —
this skill is the write counterpart, using the same credential.

**Script:** `Skills/pinboard-write/scripts/pinboard-write.py` (self-executable uv
script — run directly by absolute path, not via `uv run`).

## Usage

Credentials come from `secrets/pinboard.enc.env` (same file the MCP server uses — see
[[secrets-management]]). Always run via `sops exec-env` so the token never lands in
plaintext in your shell:

```bash
export REPO="$(git rev-parse --show-toplevel)"
sops exec-env "$REPO/secrets/pinboard.enc.env" \
  '"$REPO"/Skills/pinboard-write/scripts/pinboard-write.py add \
    --url https://example.com --title "Example" --tags python,api'
```

Commands:
- `add --url URL --title TITLE [--notes TEXT] [--tags a,b,c] [--private] [--toread] [--no-replace] [--dt ISO8601]`
- `delete --url URL`
- `tag-rename --old OLD --new NEW`
- `tag-delete --tag TAG`

Run `pinboard-write.py <command> --help` for full flag details.

## Notes

- **Rate limit:** Pinboard's guideline is one write call per user every 3 seconds.
  Each script invocation makes exactly one call, so normal single-shot use is fine —
  don't script tight loops of calls without adding a delay.
- **`add` defaults** match Pinboard's own API defaults: shared (not private), not
  marked to-read, and replaces any existing bookmark at the same URL.
- **`tag-rename`/`tag-delete` are global** — they act across every bookmark with that
  tag, not just one. Confirm with Brian before running either if the tag is widely
  used.
- Exits non-zero and prints the raw API response if Pinboard returns anything other
  than `result_code: done`.

## Related

- [[secrets-management]] — the sops+age pattern the token uses
- Pinboard MCP connector (`mcp__pinboard__*`) — the read counterpart, registered in
  `.mcp.json`
