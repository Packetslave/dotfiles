---
name: tldr-daily-summary
description: >
  Use this skill whenever the user asks for a TLDR daily summary, TLDR digest,
  TLDR newsletter roundup, or says anything like "give me today's TLDR" or "summarize
  my TLDR newsletters." This skill finds all TLDR newsletter emails received today
  that have been labeled "051-Lists-1" in Gmail, extracts every news item from each
  newsletter, strips sponsored content and cross-newsletter duplicates, organizes items
  by topic, and writes a clean markdown file with every headline hyperlinked to its
  source article. Use this skill any time TLDR newsletters are involved, even if the
  user phrases the request casually (e.g., "what's in my TLDR today?").
---

# TLDR Daily Summary Skill

You are producing a daily digest of TLDR newsletters from the user's Gmail inbox.
The output is a dated markdown file, organized by topic with every headline
linked to its source article, sponsored content removed, and cross-newsletter
duplicates collapsed into one entry. **Every item carries a 1–2 sentence
summary** drawn from the newsletter's own blurb — the digest is a detailed
briefing, not a bare link list. The exact output format is specified in Step 9
and is mandatory.

---

## Step 0 — Task monitoring: nothing to do here

**Do not send Healthchecks.io pings from this skill.** The cron wrapper
(`Skills/tldr-daily-summary/scripts/run-headless.sh`) owns the start/success/fail
pings for check `20176588-fb1c-4af7-baf1-62e4d9916838`, and derives them from this
run's exit status rather than from anything the model reports. Pinging from here as
well would double-ping and could mark a healthy run failed.

On an unrecoverable error (label not found, zero threads, file-write failure, etc.),
just stop and say why — exiting non-zero is what signals the failure. See
`Skills/healthcheck-task-monitoring/SKILL.md`.

---

## Step 1 — Get today's date in America/Los_Angeles

TLDR emails are sent in the user's local timezone. Always use the LA timezone to
get the correct date, even if the UTC date has already rolled over.

```bash
TZ="America/Los_Angeles" date +"%Y-%m-%d"    # e.g. 2026-05-26  (for filename and title)
TZ="America/Los_Angeles" date +"%Y/%m/%d"    # e.g. 2026/05/26  (for Gmail query)
```

---

## Step 2 — Find the Gmail label IDs for "051-Lists-1" and "800-Archives/801-Lists-1"

The Gmail MCP requires label *IDs* (not display names). Call `list_labels` once
and note two entries:

| Role | Label name | Known ID (confirm if it changes) |
|---|---|---|
| Source — new, unprocessed newsletters | `051-Lists-1` | `Label_8900298282806820351` |
| Destination — processed newsletters | `800-Archives/801-Lists-1` | `Label_8039708668405788356` |

The source ID gates which threads are processed (Step 3); the destination ID is
where processed threads are moved (Step 10). The destination is nested under
`800-Archives` in Gmail, so its `name` in `list_labels` is the full
`800-Archives/801-Lists-1`, not the bare `801-Lists-1`.

If either label doesn't exist, tell the user and stop gracefully.

---

## Step 3 — Search for today's newsletter threads

This skill processes multiple newsletter sources. Search for all of them, then
filter by the `051-Lists-1` label before processing.

### Newsletter sources to search

| Newsletter | Search query (sender) | Label required |
|---|---|---|
| TLDR (all editions) | `from:tldrnewsletter.com` | `Label_8900298282806820351` (`051-Lists-1`) |
| The Information AM | `from:hello@theinformation.com` | `Label_8900298282806820351` (`051-Lists-1`) |
| 1440 Daily Digest | `from:dailydigest@email.join1440.com` | `Label_8900298282806820351` (`051-Lists-1`) |
| Pointer | `from:suraj@pointer.io` | `Label_8900298282806820351` (`051-Lists-1`) |
| tl;dr sec | `from:clint@tldrsec.com` | `Label_8900298282806820351` (`051-Lists-1`) |
| Unsupervised Learning | `from:unsupervised-learning@mail.beehiiv.com` | `Label_8900298282806820351` (`051-Lists-1`) |
| Last Week in AWS | `from:corey@lastweekinaws.com` | `Label_8900298282806820351` (`051-Lists-1`) |
| The Pragmatic Engineer: The Pulse | `from:pragmaticengineer+the-pulse@substack.com` | `Label_8900298282806820351` (`051-Lists-1`) |

Run one `search_threads` call per sender, each with the same date range:

### Search query format

Call `search_threads` once per sender with a query like:

```
from:tldrnewsletter.com after:YYYY/MM/DD before:YYYY/MM/DD
from:hello@theinformation.com after:YYYY/MM/DD before:YYYY/MM/DD
from:dailydigest@email.join1440.com after:YYYY/MM/DD before:YYYY/MM/DD
from:suraj@pointer.io after:YYYY/MM/DD before:YYYY/MM/DD
from:clint@tldrsec.com after:YYYY/MM/DD before:YYYY/MM/DD
from:unsupervised-learning@mail.beehiiv.com after:YYYY/MM/DD before:YYYY/MM/DD
from:corey@lastweekinaws.com after:YYYY/MM/DD before:YYYY/MM/DD
from:pragmaticengineer+the-pulse@substack.com after:YYYY/MM/DD before:YYYY/MM/DD
```

**Important:** Do NOT include a `label:` filter in the query string — it causes
empty results even when matching emails exist. Instead, search by sender and date
only, then verify the label in the returned `labelIds` fields.

After getting results, confirm each thread has `Label_8900298282806820351` in its
`labelIds`. If a thread is missing the label, skip it.

If no threads are returned for today's date, fall back to `newer_than:3d` and
filter to threads from the correct date using the message `date` field.

Collect every qualifying thread ID.

---

## Step 4 — Fetch each thread

Call `get_thread` for **every** thread ID found. Do them all in parallel — one
`get_thread` call per thread in the same turn — to minimize latency.

The response objects can be very large. When the tool system saves a response to
a file (you'll see a file path in the result), use the **Read tool** to access it
directly. These files are single-line JSON, so `limit: 1` is sufficient.

**If the Read tool fails** with a token-limit error (file too large for a single
line), fall back to the Grep-based extraction described in Step 5B below — do NOT
skip the thread.

---

## Step 5 — Extract articles and links from each newsletter

Each source has a different format. Parse each thread according to the rules
below (5A–5H), identified by sender.

---

### 5A — TLDR newsletters (`from:tldrnewsletter.com`)

Each TLDR email has an HTML part and a **plaintext part**. The plaintext part is
the reliable one to parse.

### Plaintext structure

```
ARTICLE TITLE (N MINUTE READ)

Article summary paragraph.

ANOTHER ARTICLE (N MINUTE READ)

Summary paragraph.

...

Links:
1. https://actual-article-url.com/...
2. https://another-url.com/...
3. https://links.tldrnewsletter.com/XXXXX   ← TLDR tracking URL, use as-is
```

The numbered `Links:` section at the bottom maps positionally to in-text `[1]`,
`[2]`, etc. references. Article entries appear in the order they appear in the
email, and each links to the URL at the matching index in the `Links:` section.

### Extraction algorithm

1. Split the plaintext on `\n\nLinks:\n` to separate article content from the
   link list.
2. Parse the `Links:` block into a numbered map: `{1: url, 2: url, ...}`.
3. Walk the article content. An article block looks like:
   ```
   TITLE IN ALL CAPS OR TITLE CASE (N MINUTE READ)
   
   One or more paragraphs of summary.
   ```
   The `(N MINUTE READ)` or `(X MINUTE VIDEO)` suffix marks the end of the title.
4. The URL for each article is the link whose index matches the first `[N]`
   reference in that article block. If there's no `[N]`, the URL is the next
   unused link in sequence.
5. Use the URL exactly as found — TLDR tracking links (`links.tldrnewsletter.com`,
   `tracking.tldrnewsletter.com`) are fine to use verbatim when no direct URL exists.
6. **Keep the summary paragraph with each extracted item.** The digest requires a
   1–2 sentence summary per item (see Step 9), and the newsletter's own blurb is
   the source for it — do not discard it during extraction and emit title+URL only.

### Newsletter name mapping

Identify which TLDR edition each email is from using the subject line or the
`<title>` in the HTML body:

- `TLDR` (no suffix) → **TLDR Main**
- `TLDR IT` → **TLDR IT**
- `TLDR Dev` → **TLDR Dev**
- Other suffixes follow the same pattern.

---

### 5B — The Information AM (`from:hello@theinformation.com`)

The Information AM uses a **plaintext body** with numbered stories.

**Identify The Information AM emails:** Multiple newsletters arrive from
`hello@theinformation.com`. Only process the one that is specifically "The
Information AM." Identify it by looking for the text `The Information AM` in the
plaintext body — it appears as a header block near the top:

```
******************
The Information AM
******************
```

Skip any thread from `hello@theinformation.com` that does NOT contain this exact
header. Do not rely on the subject line alone, as other Information newsletters
share the same sender address.

**Plaintext structure:**

```
******************
The Information AM
******************

1.

HEADLINE TEXT

By AUTHOR NAME

Source:

SOURCE NAME ( https://actual-article-url.com/... )

Full article text follows...

2.

NEXT HEADLINE

...
```

**Extraction algorithm:**

1. Split on the numbered story markers (`\n1.\n`, `\n2.\n`, etc.).
2. For each story block:
   - The **headline** is the first non-empty line after the number.
   - The **URL** is inside the parentheses on the `Source:` line — the URL
     directly follows the source name: `SOURCE NAME ( URL )`. Extract the URL
     from the parentheses.
3. **Output format:** headline only + link to the full story. Do NOT include
   article body text or author names in the digest.
4. **Source attribution:** `*(The Information AM)*`

**Sponsored content signals:** Skip any story where the source is a brand/company
clearly paying for placement (e.g., a byline that reads "Presented by BRAND").

#### 5B-fallback — Large file handling for The Information AM

If the Read tool fails on a saved `get_thread` file (token-limit error), use the
**Grep tool** instead. These files are single-line JSON, so all extraction happens
via pattern matching on the raw JSON string.

**Step 1 — Confirm it's the AM newsletter:**

```
pattern: The Information AM
output_mode: content
-o: true
```

If `The Information AM` appears in the file, proceed. Otherwise skip the thread.

**Step 2 — Extract story slugs (headlines):**

The Information AM links each story to a `/briefings/` or `/articles/` URL on
theinformation.com. The slug encodes the headline in human-readable form.

```
pattern: briefings/[a-z0-9-]+
output_mode: content
-o: true
head_limit: 50
```

Also run:

```
pattern: articles/[a-z0-9-]+
output_mode: content
-o: true
head_limit: 50
```

Each story appears **twice** in the results (two links per story). Deduplicate by
keeping unique slugs in order. Convert slug to title by replacing hyphens with
spaces and capitalizing words.

The full theinformation.com URL is:
`https://www.theinformation.com/<slug>`

**Step 3 — Extract external source URLs:**

```
pattern: \( https://[^\) ]+
output_mode: content
-o: true
head_limit: 100
```

This returns all `( URL` strings. Strip the leading `( ` to get bare URLs.
Exclude URLs pointing to `theinformation.com` — those are the internal links
already captured in Step 2. The remaining external URLs are the source links
for each story (one per story, in order).

**Step 4 — Pair stories with sources:**

Match deduplicated slugs (from Step 2) with external source URLs (from Step 3)
positionally. The Nth unique slug pairs with the Nth external source URL.

Use the theinformation.com briefings URL as the article link in the digest, and
note the external source name in the summary if useful.

---

### 5C — 1440 Daily Digest (`from:dailydigest@email.join1440.com`)

The 1440 Daily Digest is **HTML-only** — there is no plaintext body. Parse the
HTML directly.

**HTML structure:**

The email has two tiers of content:

**Tier 1 — Full stories** (Need To Know section):
These are multi-paragraph stories with a large Georgia-font title:
```html
<div style="font-family:Georgia...font-size:23px...">
  <p style="padding:0;margin:0;">Story Title Here</p>
</div>
```
The body follows in a Roboto-font div. The **first `<a href>` link** in the body
is the primary source link. Use `link.join1440.com` tracking URLs as-is.

**Tier 2 — Bullet items** (Sports, Science & Technology, Business & Markets,
Politics & World Affairs, In-Depth sections):
These appear as inline `>` bullet items in Roboto 15px font:
```html
<span style="color:#7edcf2;">&gt;&nbsp;</span><strong>Bold Lead</strong>&nbsp;brief summary (<a href="...">More</a>)
```
Each `>` item is one story. The bold lead text is the headline; use the `More`
link as the article URL.

**Extraction algorithm:**

1. Split HTML on the `font-family:Georgia[^>]+font-size:23px` pattern. Each
   chunk starting with a 23px Georgia title is either a section header or a
   full story.
2. Identify **section headers** by `background-color:#ffef5f` (yellow
   highlight). Note the current section name but do not emit it as a story.
3. Full story titles (no yellow background): extract title text + first
   `link.join1440.com` href in the following Roboto body div.
4. For **bullet items** within each section, find all `color:#7edcf2` spans
   (the `>` marker), then extract the bold lead text + the `More` link href
   that follows.

**Sponsored content signals:** Skip any story or bullet item where the link
leads to `invest.modemobile.com`, `refer.` subdomains, or other promotional
domains not associated with news sources. Also skip items that read like
investment pitches ("Could Make This Company Soar", "Shark Tank Investor", etc.).

**Source attribution:** `*(1440 Daily Digest)*`

#### 5C-fallback — Large file handling for 1440 Daily Digest

If the Read tool fails on the saved `get_thread` file (token-limit error), use
the **Grep tool** to extract URLs, then decode them with Python in bash.

**Step 1 — Extract all base64-encoded story URLs:**

All 1440 story links follow the format:
`link.join1440.com/click/CAMPAIGN_ID/BASE64_URL/USER_TOKEN`

Run:
```
pattern: click/\d+\.\d+/[A-Za-z0-9+/]+=*
output_mode: content
-o: true
head_limit: 100
```

**Step 2 — Decode the base64 URLs using Python in bash:**

Write the extracted base64 strings (the third path component between the second
and third slash after `click/`) to a file in the workspace, then run:

```python
import base64

b64_urls = [...]  # list of base64 strings extracted by Grep

for b64 in b64_urls:
    padded = b64 + '=' * (-len(b64) % 4)
    try:
        url = base64.b64decode(padded).decode('utf-8', errors='replace')
        print(url.split('?')[0])  # strip tracking params
    except Exception:
        pass
```

**Step 3 — Filter and classify:**

Exclude decoded URLs pointing to:
- `join1440.com` (homepage/subscription links)
- `readtangle.com` or other sponsor domains
- `r.ppntrk.com` or similar ad-tracking domains
- `youtube.com/watch` without additional path context

The remaining URLs are the actual story links. Infer headline from the URL slug.
For stories with two URLs (the 1440 briefings page + external source), prefer
the external source as the link and use the 1440 link's slug for the title.

**Step 4 — Skip sponsored items:**

Skip any story where the decoded URL leads to investment pitches
(`invest.modemobile.com`) or promotional domains clearly not news sources.

---

### 5D — Pointer (`from:suraj@pointer.io`)

Pointer is a Beehiiv-hosted newsletter. Subject lines are just `Issue #NNN` with no
other identifying text — identify it by sender address alone.

**Plaintext structure:**

The body is organized into `# Section Title` blocks, each followed by a long
em-dash rule, in this order:

```
[sponsor blurb — no header, appears first]

# Most Popular From Last Issue

———————————————————————————

**[Title](url)**** **-** **Author Name

———————————————————————————

# Notable Links

———————————————————————————

**[Title](url)**: One-sentence description.

**[Title](url)**: One-sentence description.

...

———————————————————————————

# Null Pointer

[comic image + caption — no article link]
```

**Main-body items.** Between the opening sponsor blurb and `# Null Pointer`,
the issue's principal content is a run of standalone article items, each its
own `# [Title](url)` header followed by an optional `— Author Name` line, a
`**tl;dr**:` summary (often a pull quote), and a topic-tag line:

```
# [Yes You Can Measure Engineering](https://www.rubick.com/valuesum-metric/)

— Jade Rubick

**tl;dr**: "I'd like to share my favorite way of measuring the value delivery
of engineering organizations. …"

###### _Management Metrics_
```

These are real articles and belong in the digest — do NOT skip them. Sponsored
items use the identical shape but carry a `_Promoted by NAME_` line before the
tag line; skip those (they also tend to be repeated verbatim from the top-of-
issue sponsor blurb).

**Extraction algorithm:**

1. Walk the body header to header (`# ...`). For each `# [TITLE](URL)` header
   that is not `# Null Pointer`, `# Most Popular From Last Issue`, or
   `# Notable Links`, take `TITLE`, `URL`, the `— Author` line if present, and
   the `**tl;dr**:` text as the summary. Skip any item whose block contains
   `_Promoted by`.
2. Locate the `# Notable Links` section: everything between the `# Notable Links`
   header and the next `# ` header (or end of body). Within that span, each item
   matches `**[TITLE](URL)**: DESCRIPTION.` — extract `TITLE`, `URL`, and
   `DESCRIPTION`.
3. Ignore: the sponsor blurb before the first header,
   `# Most Popular From Last Issue` (recycled from the prior issue), and
   `# Null Pointer` (a comic, not an article).
4. **Output format:** title + URL + the description as given. Notable Links
   descriptions are one-liners and can be used verbatim; main-body `tl;dr`
   quotes are often long — condense to 1–2 sentences.
5. **Source attribution:** `*(Pointer)*`

**Large file handling:** Pointer emails are typically too large for a direct
`Read` of the saved `get_thread` file — treat Grep as the normal extraction path
here, not just a fallback:

```
pattern: \*\*\[[^\]]+\]\([^)]+\)\*\*: [^\\]+
output_mode: content
-o: true
head_limit: 50
```

This returns each `**[Title](url)**: description` item as a single match. Discard
any match that falls in the sponsor blurb or `# Most Popular From Last Issue`
section — locate the `# Notable Links` and following `# ` header positions
separately (e.g. `pattern: # [A-Z][^\\]{0,40}`) to establish the span boundaries.

---

### 5E — tl;dr sec (`from:clint@tldrsec.com`)

Identify by sender address. Subject lines look like `[tl;dr sec] #339 - Hugging
Face's Incident Report, Context Bombs, AI does Cryptanalysis`.

**Plaintext structure:**

The body opens with a personal greeting/intro (skip), then breaks into
`## SectionName` blocks, each followed by a long em-dash rule:

```
## AppSec

———————————————————————————

[Title](url)
[Author Name](author-url) description sentence(s).

[Title](url)
[Author Name](author-url) description sentence(s).

## Cloud Security

———————————————————————————

...

## Misc

———————————————————————————

* Author - [Title](url) - optional description

## ✉️ Wrapping Up

———————————————————————————

[closing remarks — skip]
```

Sponsor callouts appear as their own `## ` block whose header contains a `👉`
emoji, e.g. `## **👉 **[**Download the Playbook**](sponsor-url)` — skip these
entirely.

**Section topics:** `AppSec`, `Cloud Security`, `Blue Team`, `Red Team`,
`AI + Security`, and `Misc` are the recurring topical sections (the exact set can
vary issue to issue). `Misc` contains off-topic/fun links (YouTube videos, jokes)
rather than security news — include these too, grouped into the digest's "Quick
Takes" section rather than "Security".

**Extraction algorithm:**

1. Walk the body header to header (`## ...`). Skip any header containing `👉`
   (sponsor) and the final `## ✉️ Wrapping Up` section (closing remarks, no
   content).
2. Within each remaining topical section (`AppSec`, `Cloud Security`, `Blue Team`,
   `Red Team`, `AI + Security`), items follow:
   ```
   [TITLE](URL)
   [AUTHOR](AUTHOR_URL) DESCRIPTION
   ```
   Extract `TITLE`, `URL`, and `DESCRIPTION`.
3. Items in `## Misc` follow a bullet pattern instead:
   `* AUTHOR - [TITLE](URL) - DESCRIPTION` (the trailing `- DESCRIPTION` is
   optional).
4. **Output format:** title + URL + description sentence.
5. **Source attribution:** `*(tl;dr sec)*`

**Large file handling:** tl;dr sec emails are typically too large for a direct
`Read` of the saved `get_thread` file — treat Grep as the normal extraction path:

```
pattern: \[[^\]]+\]\([^)]+\)\\n\[[^\]]+\]\([^)]+\) [^\\]+
output_mode: content
-o: true
head_limit: 50
```

This captures `[Title](url)\n[Author](url) description` pairs for the topical
sections. For `## Misc`, run a second pass:

```
pattern: \* [^-]+- \[[^\]]+\]\([^)]+\)[^\\]*
output_mode: content
-o: true
head_limit: 30
```

Cross-reference matches against the section-header positions (as in 5D) to
exclude anything captured from a `👉` sponsor block or `## ✉️ Wrapping Up`.

---

### 5F — Unsupervised Learning (`from:unsupervised-learning@mail.beehiiv.com`)

Unsupervised Learning (Daniel Miessler) is a Beehiiv-hosted plaintext newsletter
organized into `## SECTION` blocks: `UPDATES`, `CYBERSECURITY`,
`NATIONAL SECURITY`, `AI`, `TECHNOLOGY`, `HUMANS`, `IDEAS`, `DISCOVERY`,
`RECOMMENDATION OF THE WEEK`, `APHORISM OF THE WEEK` (the exact set varies
issue to issue).

**Plaintext structure:**

```
## CYBERSECURITY

**Mugging Face: 17,600 attacker actions crossed Hugging Face's trust boundaries**
Really good analysis here of what happened... [HUGGING FACE BLOG](url)

* bullet sub-point
* bullet sub-point

**The hotel Wi-Fi gateways hijacking Microsoft 365 accounts** Attackers are
poisoning hotel Wi-Fi gateways... [COMPUTERWORLD ARTICLE](url)

## AI

...
```

**Extraction algorithm:**

1. Walk the body header to header (`## SECTION NAME`).
2. Skip `## UPDATES` (personal notes/announcements, not news items) and any
   `Sponsor` block (marked with a `Sponsor` line before the pitch). Skip
   `## RECOMMENDATION OF THE WEEK` and `## APHORISM OF THE WEEK` — no links.
3. Within each remaining section, each item matches
   `**Bold Headline** description sentence(s) [LINK LABEL](url)` — extract the
   bold text as the title, the sentence(s) before the bracketed link as the
   description, and the URL from the link. Ignore `* bullet` sub-points under
   an item — they elaborate on the item already captured.
4. **Output format:** title + URL + description sentence.
5. **Source attribution:** `*(Unsupervised Learning)*`

**Large file handling:** if the Read tool fails on the saved `get_thread`
file, use Grep as the normal extraction path:

```
pattern: \*\*[^*]+\*\*[^\[]*\[[^\]]+\]\([^)]+\)
output_mode: content
-o: true
head_limit: 60
```

Cross-reference matches against `## ` header positions (pattern `## [A-Z][^\n]*`)
to exclude anything from `## UPDATES`, a `Sponsor` block,
`## RECOMMENDATION OF THE WEEK`, or `## APHORISM OF THE WEEK`.

---

### 5G — Last Week in AWS (`from:corey@lastweekinaws.com`)

Corey Quinn's newsletter is plaintext with two link-bearing sections, each
bounded above and below by a line of `*` characters:

```
******************************
Things I Found on the Internet
******************************

[paragraph with an inline ( url ) link]

[paragraph with an inline ( url ) link]

*****************************
What AWS Has For Us This Time
*****************************

[paragraph with an inline ( url ) link]

...
```

Unlike the other sources, links aren't wrapped in markdown — each paragraph is
a sentence or two with the URL inline as a bare `( https://... )` parenthetical,
usually right after the feature/tool name, followed by Corey's commentary.

**Extraction algorithm:**

1. Skip the intro paragraph before the first `*`-bordered header (personal
   riffing on the week, not a discrete item).
2. Locate the two sections: "Things I Found on the Internet" and "What AWS Has
   For Us This Time" (bounded by the asterisk-rule lines above and below each
   header).
3. Within each section, split into paragraphs (blank-line separated). Each
   paragraph is one item.
4. For each paragraph, take the text before the first `( url )` as the
   headline (the tool/feature name), and use the sentence(s) after it as the
   summary — condense Corey's commentary to one sentence.
5. Stop processing once you reach the sign-off line ("...and that's what
   happened Last Week in AWS") — everything after that (bio, referral link,
   swag, subscribe footer) is not content.
6. **Output format:** headline + URL + one-sentence summary.
7. **Source attribution:** `*(Last Week in AWS)*`

**Large file handling:** if the Read tool fails on the saved `get_thread`
file, use Grep to pull every inline link and cross-reference by position:

```
pattern: \([^)]*https?://[^\)]+\)
output_mode: content
-o: true
head_limit: 60
```

---

### 5H — The Pragmatic Engineer: The Pulse (`from:pragmaticengineer+the-pulse@substack.com`)

**Identify precisely by this full sender address.** The Pragmatic Engineer
sends other editions from related-but-different addresses (the main weekday
edition at `pragmaticengineer@substack.com`, Deepdives at
`pragmaticengineer+deepdives@substack.com`) — only process `+the-pulse@`.
Those other editions are out of scope for now even if they carry the label.

The Pulse is a long-form essay issue, not a link roundup — there's one post
URL for the whole issue, and the items are the topics listed in its intro.

**Plaintext structure:**

```
View this post on the web at https://newsletter.pragmaticengineer.com/p/the-pulse-...

The Pulse is a series covering events, insights, and trends within Big Tech
and startups. ...
Today, we cover:
Moving my video podcast off Spotify due to constant reliability issues.
Spotify's podcast platform has become chronically unreliable...
Will Kimi K3 trigger US push for closed-source AI models? Moonshot AI's...
AWS laughs off "heart attack" billing error. AWS customers were billed...
Industry pulse. OpenAI's unreleased model tried to hack HuggingFace...
1. Moving my video podcast off Spotify due to constant reliability issues
[long essay section]
2. Will Kimi K3 trigger US push for closed-source AI models?
[long essay section]
...
```

**Extraction algorithm:**

1. Find the post URL on the `View this post on the web at URL` line near the
   top — this is the link used for every item pulled from this issue.
2. Locate the `Today, we cover:` block: the paragraphs immediately following
   it, up to (not including) the first numbered section header (`1. ...`).
3. Each paragraph in that block is one digest item: the first sentence is the
   headline, the rest of the paragraph is the summary. Do not pull content
   from the numbered essay sections themselves — they're the same topics
   expanded at length, and the intro summary is enough for a digest.
4. **Output format:** headline + link to the post URL (same URL for every item
   from this issue) + the summary sentence(s) from the intro paragraph.
5. **Source attribution:** `*(The Pragmatic Engineer: The Pulse)*`

**Large file handling:** if the Read tool fails on the saved `get_thread`
file, Grep for the post URL (`pattern: View this post on the web at (\S+)`)
and for the `Today, we cover:` block (`pattern: Today, we cover:[\s\S]*?\n1\.`,
with `multiline: true`) to pull just the summary paragraphs without loading
the full essay.

---

## Step 6 — Filter sponsored content

Skip any article block that contains any of these signals:

- The word "sponsor", "sponsored", or "presented by" (case-insensitive) anywhere
  in the title or the first line of the summary
- A parenthetical like `(Sponsor)` or `(Ad)` in the title
- The article is one of the TLDR-internal CTAs: "Advertise with TLDR",
  "TLDR is hiring", "Join TLDR", job board listings, or newsletter promotion blurbs

When in doubt, err on the side of including rather than excluding.

---

## Step 7 — Deduplicate across newsletters

Track article titles and URLs you've already added. When the same story appears
in multiple newsletters (same URL or very similar title):

- Keep the first occurrence you process.
- In the source attribution at the end of that item, list *all* newsletters it
  appeared in, e.g. `*(TLDR Main, TLDR DevOps)*`.

---

## Step 8 — Organize by topic

Group items into sections based on subject matter. Use your judgment — the goal
is a digest that's easy to scan. Suggested sections (adjust as content warrants):

- **AI & Large Language Models** — AI products, research, industry dynamics
- **Security** — vulnerabilities, attacks, privacy, compliance
- **Development & Tools** — languages, frameworks, libraries, developer tooling
- **Infrastructure & Enterprise** — cloud, containers, MDM, SaaS platforms, CI/CD
- **Data Engineering** — pipelines, warehouses, streaming, analytics
- **Fintech** — payments, banking, financial services, crypto
- **Science & Space** — research, physics, biology, astronomy
- **Hardware & Chips** — CPUs, GPUs, semiconductors, robotics
- **World News & Sports** — geopolitics, elections, sports (primarily from 1440)
- **Quick Takes** — short items that don't fit neatly elsewhere

Not every section needs to appear — skip empty ones.

---

## Step 9 — Write the markdown output file

Save to:
```
output/md/tldr-daily-summary-YYYY-MM-DD.md
```
(inside the workspace folder, e.g. `_Cowork/output/md/`)

Create the directory if it doesn't exist:
```bash
mkdir -p /path/to/workspace/output/md
```

### Document structure

```markdown
# TLDR Daily Summary — [Human-readable date, e.g. Tuesday, August 4, 2026]

*Compiled from [list newsletters found, e.g. TLDR Main, TLDR Dev, TLDR Data, The Information AM, 1440 Daily Digest]. Sponsored content and duplicate items removed.*

---

## [Section Name]

**[Article Title](https://source-url)** — One- to two-sentence summary of the article. *(Newsletter Name)*

...more items...

---

## [Next Section]

...
```

### Item format — MANDATORY, do not improvise

Past runs drifted into terse link lists; the user explicitly prefers the
detailed format. These rules are binding:

```markdown
**[Title](URL)** — Summary sentence(s). *(Source newsletter)*
```

- **Every item is its own paragraph** starting with the bold linked title.
  Do NOT format items as `- ` bullet list entries.
- **Every item gets a 1–2 sentence summary** after an em-dash. Use the
  newsletter's own blurb (condensed if long); if the source genuinely
  provides none, write one sentence yourself from the title/context.
  A bare `**[Title](URL)** *(Source)*` with no summary is not acceptable —
  if you find yourself emitting one, go back to the source email and pull
  the blurb.
- **Section headers are plain text** — `## Security`, not `## 🔒 Security`.
  No emoji anywhere in headers.
- The source attribution in italics at the end names the newsletter(s);
  for duplicates, list all of them: `*(TLDR Main, TLDR DevOps)*`.

**Correct:**

```markdown
**[Massively Parallel Postgres Backups](https://planetscale.com/blog/massively-parallel-postgres-backups)** — PlanetScale's approach to dramatically faster Postgres backup throughput by sharding the backup stream across workers. *(TLDR Dev)*
```

**Wrong (terse bullet, no summary, emoji header — do not do this):**

```markdown
## 🔧 Developer Tools

- [Massively Parallel Postgres Backups](https://planetscale.com/blog/...) *(TLDR Dev)*
```

---

## Step 10 — Move processed newsletters to the archive label and mark them read

For every thread that contributed at least one item to the digest (status ✅
or ⚠️ in the processing notes you're about to write in Step 11), move it from
the source label to the destination label and mark it read. Two calls per
thread, add first so the thread is never momentarily unlabelled:

```
label_thread(threadId: "<thread id>", labelIds: ["Label_8039708668405788356"])
unlabel_thread(threadId: "<thread id>", labelIds: ["UNREAD", "Label_8900298282806820351"])
```

Do this for every processed thread ID, across all sources — the original
five as well as Unsupervised Learning, Last Week in AWS, and The Pragmatic
Engineer: The Pulse. Afterwards a processed thread carries
`800-Archives/801-Lists-1` and neither `051-Lists-1` nor `UNREAD`.

Leave threads where they are (unread, still in `051-Lists-1`) if they were
intentionally excluded: wrong newsletter variant, missing the `051-Lists-1`
label, or a fetch/extraction failure (status ⏭️ or ❌) — those should stay
visible so they don't get silently lost. Calling `unlabel_thread` for a label
the thread doesn't have is harmless — fine to call regardless.

If a thread has multiple messages (e.g. a follow-up in the same conversation),
`unlabel_thread` clears `UNREAD` across the whole thread, which is what we
want here.

---

## Step 11 — Append processing notes

At the very end of the markdown file, after all content sections, always add a
`---` divider followed by a `## Processing Notes` section.

Track the following throughout the run and record it here:

- **Sources searched**: every sender queried in Step 3.
- **Threads found**: each thread ID returned, with newsletter name and date.
- **Threads processed successfully**: threads where full content was extracted
  (either via Read or a Grep fallback).
- **Threads skipped or partially processed**: any thread where:
  - The file was too large and the Grep fallback was used but content was
    incomplete or stories were not added to the digest.
  - The thread was skipped because it lacked the required label.
  - The thread was the wrong newsletter variant (e.g. "AI Agenda" instead of
    "The Information AM") and intentionally excluded.
  - Any other reason stories were not included.
- **Sources searched but no threads found**: senders that returned zero results.

### Format

```markdown
---

## Processing Notes

| Source | Status | Notes |
|--------|--------|-------|
| TLDR Main | ✅ Processed | 8 items |
| TLDR Fintech | ✅ Processed | 10 items |
| TLDR IT | ✅ Processed | 8 items |
| TLDR Dev | ✅ Processed | 9 items |
| TLDR DevOps | ✅ Processed | 9 items |
| TLDR Data | ✅ Processed | 13 items |
| The Information AM | ⚠️ Partial | File too large for Read; Grep fallback used. 7 story slugs identified but not included in digest. |
| The Information AI Agenda | ⏭️ Skipped | Not The Information AM — different newsletter variant. |
| 1440 Daily Digest | ✅ Processed | 15 items via base64 decode fallback. |
| Pointer | ✅ Processed | 6 items from Notable Links via Grep extraction. |
| tl;dr sec | ✅ Processed | 12 items (incl. Misc) via Grep extraction. |
| Unsupervised Learning | ✅ Processed | 9 items across CYBERSECURITY, AI, and other sections. |
| Last Week in AWS | ✅ Processed | 8 items from both link sections. |
| The Pragmatic Engineer: The Pulse | ✅ Processed | 4 items from the "Today, we cover" summary. |
```

Use these status icons:
- ✅ **Processed** — full content extracted, stories included in digest.
- ⚠️ **Partial** — fallback used; some stories may be missing.
- ⏭️ **Skipped** — intentionally excluded (wrong variant, no label, etc.).
- ❌ **Failed** — could not be read by any method; stories not included.
- 🔍 **No results** — sender queried but no threads found for today's date.

---

## Step 12 — Present the file

No success ping here — the wrapper sends it once this run exits cleanly (see Step 0).

Present the markdown output file with `mcp__cowork__present_files` and
briefly note how many newsletters were processed and how many items are in the
digest.
