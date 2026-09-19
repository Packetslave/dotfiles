#!/usr/bin/env -S uv run --script
"""Fetch tweets, threads, and X articles as verbatim markdown captures.

Anti-scraper-safe fetch chain (worked out 2026-08-16, see SKILL.md):
  - cdn.syndication.twimg.com/tweet-result  — first-party, single tweet + parent
  - api.fxtwitter.com                       — full note-tweet text + article blocks

Usage:
  fetch-tweet.py <url-or-id>            # single tweet; walks parents to thread root;
                                        # auto-detects X articles and captures them
  fetch-tweet.py <id1> <id2> <id3> ...  # explicit thread (ordered tweet IDs)
  fetch-tweet.py <url-or-id> --out DIR  # override output root (default output/twitter)

The syndication endpoint cannot enumerate reply children — for a thread you only
have the hook of, collect the reply IDs in a browser first (see SKILL.md).
"""

import argparse
import json
import math
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# Repo root: this script lives at <repo>/Skills/twitter-ingest/scripts/
DEFAULT_OUT = str(Path(__file__).resolve().parents[3] / "output" / "twitter")
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
MAX_PARENT_WALK = 25


def syndication_token(tweet_id: int) -> str:
    """Port of X's embed token: ((id/1e15)*PI).toString(36).replace(/(0+|\\.)/g,'')."""
    x = (tweet_id / 1e15) * math.pi
    chars = "0123456789abcdefghijklmnopqrstuvwxyz"
    i, frac, out = int(x), x - int(x), ""
    while i:
        out = chars[i % 36] + out
        i //= 36
    out += "."
    for _ in range(12):
        frac *= 36
        d = int(frac)
        out += chars[d]
        frac -= d
    return re.sub(r"(0+|\.)", "", out)


def get_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_syndication(tweet_id: str) -> dict | None:
    url = (f"https://cdn.syndication.twimg.com/tweet-result"
           f"?id={tweet_id}&token={syndication_token(int(tweet_id))}&lang=en")
    try:
        data = get_json(url)
    except (urllib.error.URLError, json.JSONDecodeError) as e:
        print(f"  syndication fetch failed for {tweet_id}: {e}", file=sys.stderr)
        return None
    return data if data.get("__typename") == "Tweet" else None


def fetch_fxtwitter(tweet_id: str, screen_name: str = "i") -> dict | None:
    try:
        data = get_json(f"https://api.fxtwitter.com/{screen_name}/status/{tweet_id}")
    except (urllib.error.URLError, json.JSONDecodeError) as e:
        print(f"  fxtwitter fetch failed for {tweet_id}: {e}", file=sys.stderr)
        return None
    return data.get("tweet")


def tweet_record(tweet_id: str) -> dict:
    """One tweet with full text: syndication first, fxtwitter for truncated/failed."""
    syn = fetch_syndication(tweet_id)
    rec = {"id": tweet_id, "syn": syn, "fx": None}
    needs_fx = syn is None or "note_tweet" in syn or syn.get("article")
    if needs_fx:
        rec["fx"] = fetch_fxtwitter(
            tweet_id, (syn or {}).get("user", {}).get("screen_name", "i"))
    return rec


def full_text(rec: dict) -> str:
    if rec["fx"] and rec["fx"].get("text"):
        return rec["fx"]["text"]
    if rec["syn"]:
        return rec["syn"].get("text", "")
    return "(fetch failed)"


def article_from(rec: dict) -> dict | None:
    fx = rec["fx"] or {}
    return fx.get("article") if fx.get("article", {}).get("content") else None


def slugify(text: str, max_len: int = 40) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug[:max_len].rstrip("-") or "tweet"


def render_blocks(article: dict) -> list[str]:
    """Draft.js blocks -> markdown lines (headers, dividers, bold/italic, lists)."""
    entities = {e["key"]: e["value"] for e in article["content"].get("entityMap", [])}
    lines = []
    for b in article["content"]["blocks"]:
        text, btype = b["text"], b["type"]
        if btype == "atomic":
            kinds = {entities.get(str(er["key"]), {}).get("type")
                     for er in b.get("entityRanges", [])}
            lines.append("---" if kinds <= {"DIVIDER"} else f"*(unrendered: {kinds})*")
        elif btype == "header-one":
            lines.append(f"## {text}")
        elif btype == "header-two":
            lines.append(f"### {text}")
        elif btype == "unordered-list-item":
            lines.append(f"- {text}")
        elif btype == "ordered-list-item":
            lines.append(f"1. {text}")
        elif text.strip():
            lines.append(text)
    return lines


def meta_header(title, author_name, screen_name, url, created_at, capture_note):
    stats = ""
    return "\n".join([
        f"# {title}",
        "",
        f"- **Author:** {author_name} (@{screen_name})",
        f"- **Source:** {url}",
        f"- **Posted:** {created_at}",
        f"- **Captured:** {datetime.now(timezone.utc).strftime('%Y-%m-%d')} via {capture_note}. Text below is verbatim.",
    ])


def parse_ids(args: list[str]) -> list[str]:
    ids = []
    for a in args:
        m = re.search(r"/status/(\d+)", a) or re.fullmatch(r"(\d+)", a)
        if not m:
            sys.exit(f"not a tweet URL or ID: {a}")
        ids.append(m.group(1))
    return ids


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tweets", nargs="+", help="tweet URL(s) or ID(s), thread order")
    ap.add_argument("--out", default=DEFAULT_OUT, help="output root directory")
    args = ap.parse_args()
    ids = parse_ids(args.tweets)

    records = [tweet_record(i) for i in ids]
    if all(r["syn"] is None and r["fx"] is None for r in records):
        sys.exit("all fetches failed")

    # Single ID: walk parents up to the thread root so the capture starts at the hook.
    if len(records) == 1:
        walked = 0
        while walked < MAX_PARENT_WALK:
            first = records[0]["syn"]
            parent_id = (first or {}).get("in_reply_to_status_id_str")
            if not parent_id:
                break
            print(f"  walking up to parent {parent_id}", file=sys.stderr)
            records.insert(0, tweet_record(parent_id))
            walked += 1

    hook = records[0]
    hook_syn = hook["syn"] or {}
    hook_fx = hook["fx"] or {}
    user = hook_syn.get("user") or hook_fx.get("author") or {}
    screen_name = user.get("screen_name") or "unknown"
    author_name = user.get("name") or screen_name
    created = hook_syn.get("created_at") or hook_fx.get("created_at") or "unknown"
    url = f"https://x.com/{screen_name}/status/{hook['id']}"

    # Article: the linked tweet is just a pointer; capture the article body.
    article = next((a for a in (article_from(r) for r in records) if a), None)
    if article:
        title = article["title"]
        slug = f"{slugify(title)}-{hook['id']}"
        body = render_blocks(article)
        header = meta_header(
            title, author_name, screen_name, url, created,
            "the Twitter syndication endpoint + api.fxtwitter.com (full X-article blocks)")
        cover = (article.get("cover_media") or {}).get("media_info", {}).get("original_img_url")
        if cover:
            header += f"\n- **Cover image:** {cover}"
        content = header + "\n\n" + "\n\n".join(body) + "\n"
        filename = "article.md"
    else:
        title_src = full_text(hook).split("\n")[0]
        slug = f"{slugify(title_src)}-{hook['id']}"
        header = meta_header(
            f"Twitter thread by @{screen_name}" if len(records) > 1 else f"Tweet by @{screen_name}",
            author_name, screen_name, url, created,
            "the Twitter syndication endpoint (+ api.fxtwitter.com for note-tweets)")
        sections = []
        for n, r in enumerate(records):
            label = "Hook tweet" if (n == 0 and len(records) > 1) else f"Tweet {n + 1}" if len(records) > 1 else "Tweet"
            sections.append(f"## {label} ({r['id']})\n\n{full_text(r)}")
        content = header + "\n\n" + "\n\n".join(sections) + "\n"
        filename = "thread.md"

    out_dir = Path(args.out) / slug
    out_path = out_dir / filename
    if out_path.exists():
        sys.exit(f"refusing to overwrite existing capture: {out_path}")
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path.write_text(content)
    print(out_path)
    fx_rec = hook if hook["fx"] else records[-1]
    fx = fx_rec["fx"] or {}
    if fx:
        print(f"engagement ({fx_rec['id']}): {fx.get('views', '?')} views, "
              f"{fx.get('likes', '?')} likes, {fx.get('retweets', '?')} reposts",
              file=sys.stderr)
    if len(records) == 1 and filename == "thread.md":
        print("1 tweet captured, no parents: if this is a thread hook, enumerate the "
              "replies (SKILL.md step 2), delete this file, and rerun with all IDs",
              file=sys.stderr)


if __name__ == "__main__":
    main()
