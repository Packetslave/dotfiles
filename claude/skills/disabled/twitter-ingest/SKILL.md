---
name: twitter-ingest
description: Fetch a tweet, thread, or X (long-form) article as a verbatim markdown capture without fighting Twitter's anti-scraper, then optionally push it to Instapaper/Pinboard and ingest it into the wiki. Use whenever Brian gives an x.com or twitter.com URL and wants it grabbed, saved, summarized, bookmarked, or filed — even if he doesn't say "ingest".
triggers:
  - grab this tweet / thread / article
  - add this twitter thread to the wiki
  - save this x.com link to instapaper / pinboard
  - ingest this tweet
---

# Twitter / X Ingest

Turns an x.com URL into a verbatim capture in `output/twitter/<slug>-<hookid>/`
(`thread.md` for tweets/threads, `article.md` for X long-form articles), then
feeds the usual downstream steps (Instapaper, Pinboard, wiki ingest).

**Script:** `Skills/twitter-ingest/scripts/fetch-tweet.py` (self-executable uv
script, stdlib-only — run directly by absolute path). No credentials needed;
its only egress is `cdn.syndication.twimg.com` (X's own embed endpoint) and
`api.fxtwitter.com` (third-party; only tweet IDs/handles are sent).

**Slash command:** `/twitter-ingest <url> [scope notes]` — a thin pointer at
this file in `.claude/commands/twitter-ingest.md`, so it works in native
Claude Code on every machine (the `/cowork:twitter-ingest` form is the
Cowork desktop plugin's, and is only present where that plugin is installed).

## How the fetch chain works (and why)

- **Syndication endpoint** (first-party, curl-able): returns one tweet + its
  immediate parent. Token math is ported into the script. Two limits: it
  cannot enumerate reply children, and it truncates note-tweets (>280 chars).
- **fxtwitter** fills both gaps the script cares about: full note-tweet text,
  and the complete block content of X articles (title, headers, dividers —
  the script renders these to markdown).
- **Parent-walking:** given any tweet ID, the script walks `in_reply_to` up to
  the thread root. So the **last** tweet of a self-reply thread reconstructs
  the *entire* thread with no browser (verified on a 7-tweet thread,
  2026-08-16).
- Dead ends — don't rediscover these: `syndication.twitter.com/srv/
  timeline-profile` (429s, then an empty timeline), nitter.net, xcancel,
  threadreaderapp, sotwe (all bot-walled or dead as of 2026-08).
- **Blocked network?** The fetch chain is fine — diagnose which network is
  the problem, because the fix differs:
  - The browser tab lands on `chrome-error://chromewebdata/` with the body
    "Access to x.com was denied … HTTP ERROR 403" while the *script* worked
    fine (seen 2026-09-05 on mfa1): that is x.com rejecting the **headless
    Chrome user agent**, not a network block — the same URL returns 200 to
    `curl` with a desktop UA. Fix is the UA override in step 2; no VPN or
    allowlist change is involved.
  - `Tunnel connection failed: 403` from a proxy, in a Cowork session, from
    the local VM *and* the cloud container alike (seen 2026-08-29): that's
    the session's egress allowlist, and no VPN will help. Durable fix: add
    `cdn.syndication.twimg.com` and `api.fxtwitter.com` to the session's
    network allowlist (both are stable and only ever receive tweet IDs);
    until then, run the skill from native Claude Code on the Mac instead.
  - Cert-name mismatches, DNS weirdness, or a captive portal in a *native*
    session: that's aggressive WiFi (coffee-shop content filters) — ask
    Brian to turn on Tailscale exit-node routing and retry.
  - Last resort either way: read the tweet from the rendered x.com page in a
    browser session and write the capture by hand, verbatim, noting the
    method in the capture header.

## Workflow

0. **Check the ingest log first — before fetching anything.**

   ```
   /home/blanders/src/cowork/Skills/wiki-ops/scripts/ingest-log.py check "<url>"
   ```

   Exit 3 means this tweet or thread is already in `Skills/_ingest-log.txt`
   (the line is printed). **STOP.** Show Brian the line and ask whether he
   wants it re-ingested; do nothing else until he says so. Exit 0 means
   proceed — but threads are logged by their **hook's** status id, so a
   reply or tail URL of a logged thread passes this check. After step 1's
   capture, if the hook id in `thread.md` differs from the URL Brian gave,
   run `check` again with the hook URL before going further. Every run ends
   by appending to the log (step 7).

1. **Classify the URL** by running the script on it:

   ```
   "$(git rev-parse --show-toplevel)"/Skills/twitter-ingest/scripts/fetch-tweet.py "<url>"
   ```

   - **X article** (tweet links `x.com/i/article/…`): detected automatically;
     full body captured as `article.md`. Done.
   - **Single tweet / reply chain:** captured as `thread.md`, parents walked
     to the root automatically. Done.
   - **Thread where Brian gave the hook:** the capture will contain only the
     hook (no children) — go to step 2.

2. **Enumerate thread children when needed** (hook-only case) with the
   chrome-devtools MCP. **Set a desktop user agent first** — x.com serves
   headless Chrome a 403 error page and nothing else:

   1. `new_page` on any URL (or reuse a page), then `emulate` on that page
      with `userAgent` set to a current desktop Chrome string, e.g.
      `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36
      (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36`. The override
      persists across navigations on that page.
   2. `navigate_page` to the x.com thread URL. Threads render logged-out;
      long tweets show a truncated body + "Show more" — that's fine, only
      the IDs matter here.
   3. Collect the author's `/status/<id>` links in page order. An
      `evaluate_script` over `a[href*="/status/"]`, deduplicated and
      filtered to `/<handle>/status/<digits>`, is more reliable than reading
      a snapshot; replies from other accounts appear after the author's and
      are dropped by the handle filter.

   **Count mismatch?** If the hook promises N items and you found fewer
   author replies, do not accept either number silently: scroll the thread
   page and look for "Show more replies" / "probable spam" buttons, then
   `curl -s https://api.fxtwitter.com/<handle>/status/<last-id>` and read
   `tweet.replies` — `0` means the thread really ends there (hooks
   overstate their count; the 2026-09-05 "8 prompts" thread had seven).
   Record the mismatch on the wiki page.

   Then **delete the hook-only `thread.md`** (the script refuses to
   overwrite; the capture directory name is unchanged) and rerun with all
   IDs in page order:

   ```
   fetch-tweet.py <hook-id> <id2> <id3> ...
   ```

   The one case that skips the browser entirely: Brian linked the *tail*
   tweet rather than the hook. Then a single run on that ID reconstructs the
   thread by parent-walking. If you only have the hook, you have to
   enumerate — the tail is not identifiable without doing so.

3. **Sanity-check the capture**: every tweet section has full text (no
   mid-sentence cutoffs — a cutoff means a note-tweet fell back incorrectly).
   The script prints only the capture path; for engagement figures (the
   page's Provenance section wants views, likes, reposts) read
   `https://api.fxtwitter.com/<handle>/status/<hook-id>` — `tweet.views`,
   `tweet.likes`, `tweet.retweets`. When the hook promises an outcome
   rather than a count, there is no count to reconcile; note the
   overpromise on the page instead.

4. **Push to Instapaper** (best-effort, via the `instapaper` MCP):
   - **Articles:** `add_bookmark` with the tweet URL — Instapaper's server-side
     parser extracts x.com articles cleanly (verified 2026-08-16), so a plain
     URL bookmark gets the full text.
   - **Threads:** Instapaper can't parse a thread page; convert the capture
     to HTML in the scratchpad (`cmark-gfm -e autolink thread.md > …/thread.html`
     — Homebrew's on macOS, on `PATH` on mfa1) and call `add_private_bookmark`
     with `content_file` pointing at it (the server reads the file, so the
     HTML never passes through the conversation), `source_label` =
     `twitter-ingest`, and **title** = `<short title you compose from the
     hook> — @<handle> thread` (threads carry no title field; write one).
     Do not rely on `description` — it is a silent no-op on private
     bookmarks (papercut `82ea9099`); the title is the only list-view
     metadata that survives, and the source URL is in the body header.

5. **Bookmark to Pinboard** (best-effort, via the `pinboard-write` skill —
   `Skills/pinboard-write/SKILL.md`): original tweet URL, title = article
   title or a short thread description, `--private`, `--notes` = one-line
   summary, tags = `twitter` + 2-4 existing topic tags (check
   `mcp__pinboard__list_tags`). That skill's example uses `$REPO`; use
   absolute paths instead, exactly like this (one Bash call, `sops` needs
   the quoted inner command):

   ```
   sops exec-env /home/blanders/src/cowork/secrets/pinboard.enc.env \
     '/home/blanders/src/cowork/Skills/pinboard-write/scripts/pinboard-write.py add \
      --url <tweet-url> --title "<title>" --private --tags twitter,<t2>,<t3> \
      --notes "<one line, no backticks or $>"'
   ```

   (`/Users/blanders/src/cowork/…` on a Mac.)

6. **Draft the wiki pages and queue the ingest** — under `wiki/library/`
   (imported third-party material; `Decisions/decision-wiki-library-split-2026-09-18.md`). Same default as
   youtube-transcribe: ingest unless Brian says otherwise (standing
   instruction 2026-08-03) — but honor per-request scoping ("don't put it in
   the wiki yet").

   *Which skill:* `/claude-obsidian:wiki-ingest` owns the process rules
   (provenance, claims, what a source may and may not do to canonical
   pages) — load it once if you have not this session.

   *Mechanics — queue by default (since 2026-09-06).* Draft everything a
   direct ingest would write, then hand it to the capture queue instead of
   taking the vault lock yourself: the drain files every waiting ingest as
   one transaction. Concretely:

   1. Read `wiki/hot.md`, `wiki/index.md`, the hub and the speaker page (if
      one exists), and one recent framework page as the model.
   2. Draft the framework page into the session scratchpad with a quoted
      heredoc, and the speaker page too if it is new.
   3. Write a JSON manifest (shape in `Skills/wiki-ops/SKILL.md`, "Ingests
      ride the queue too") with: `title`; `log_entry` — the one paragraph
      you would have written to `wiki/log.md`; `hot_line` — the one bullet
      for `wiki/hot.md`; `source` — `{"locator": "output/twitter/<dir>/
      thread.md", "title": "<hook> (@handle X thread, <date>) — verbatim
      capture", "content_kind": "document", "authority": …}`; and `writes`
      — the create(s) by `content_file`, plus anchored `edits` for the
      existing speaker page (`updated:`, `summary:`, `related:`, "Ingested
      material", Related), the hub (`related:`, Speakers, Frameworks) and
      `wiki/index.md` (the alphabetical neighbour's line). No log or hot
      writes — the drain owns those.
   4. `Skills/wiki-ops/scripts/wiki-queue.py add-ingest --manifest <file>`.
      It inlines the drafts, anchor-checks every edit against the live
      vault and refuses on any problem — fix and rerun. The capture already
      lives inside the vault, so there is no `.raw/` copy.

   Report the record name to Brian and say the page lands at the next
   `/drain`. **Ingest directly** (the `wiki-ops` "Standard operation flow":
   `check-anchors` → `lock` → `build-bundle` → `inspect` → `apply` →
   `lint` → `release`, with the same manifest minus `log_entry`/`hot_line`
   and plus the log and hot edits) only when Brian asks for the page now.

   *Where it files:* productivity, self-improvement, career, and AI-tips
   listicles go into the personal-development corpus by speaker and
   framework — see that hub page's convention (AnderSon's late-reply
   listicle and the 2026-09-05 prompt-pack thread are the precedents for
   the growth-account end of that range). Content that is not that — tech,
   infra, news, politics — gets a topical page under the hub it belongs to,
   or ask Brian when no hub fits. Twitter ingests do **not** add a line to
   `wiki/index.md`'s `## Sources` section; the ledger is the record.

   *Naming:* slug the speaker page by name when the account is an
   identifiable person (`daniel-pink`); by **handle** when it is anonymous
   or the display name is borrowed (`tedcruz1072676`, display name "Ted
   Cruz" — not the senator, and a name-slug would alias him). Title it
   `Display Name (@handle)`, alias only the handle, and disambiguate in the
   first line.

   *Ledger authority follows the account, not the platform:* an
   identifiable author posting their own material is `primary` (Daniel
   Pink, 2026-09-05); an anonymous engagement account is `community` with
   an explicit caveat on the speaker page (AnderSon, 2026-08-16). Research
   the author cites is second-hand either way — say so on the framework
   page rather than upgrading it.

   *Anchors that exist* (for `edits`-form writes): `wiki/index.md` and the
   hub — the alphabetical neighbour's line; a speaker page — its
   `updated:` line and the last "Ingested material" bullet. For a direct
   ingest only: `wiki/log.md` — `"# Wiki Log\n\n"` (new entry goes directly
   under it, newest first); `wiki/hot.md` — `"## Recent Changes\n\n"`
   (prepend a bullet, prune one).

7. **Append to the ingest log** — always, even when steps 4-6 were scoped
   out, so the next run is refused rather than repeated. With a queued
   ingest this is also the only duplicate guard until the drain writes the
   ledger:

   ```
   /home/blanders/src/cowork/Skills/wiki-ops/scripts/ingest-log.py add "<hook-url>" "<short title from the hook>"
   ```

   Commit `Skills/_ingest-log.txt` with the rest of the run — the capture
   directory, the log line and the `wiki-queue/` record, by explicit path —
   and push (cowork policy: straight to `main`; this skill's standing
   approval covers the commit, so the Beads block's "no commit unless asked"
   does not apply). Close the chrome-devtools page you opened in step 2. If
   Brian explicitly approved a re-ingest at step 0, pass `--force` here.

Steps 4-6 run when Brian asked for them or asked for a full ingest; skip any
he scoped out.

## Rules

- Captures are verbatim — never paraphrase tweet text in the capture file
  (synthesis belongs in wiki pages).
- The script refuses to overwrite an existing capture directory file; delete
  manually if a re-fetch is genuinely wanted.
- Quote-tweets, embedded media, and polls aren't rendered (only noted) — if
  one matters, capture it deliberately and say so in the capture.
