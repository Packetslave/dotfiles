#!/usr/bin/env -S uv run --script
"""Dump every open Chrome tab as JSON (or readable text), attributed to its profile.

Read-only against Chrome: never launches it, never closes or navigates anything.

Chrome's built-in profile switcher runs every profile inside one process, so JXA
sees all profiles' windows at once -- but the scripting dictionary exposes no
profile attribute, and Chrome reorders its window list freely, so a window's
INDEX is not a stable name for it.

Chrome's window `id` IS stable for the window's lifetime (verified 2026-08-29:
the same four ids came back reordered across two dumps an hour apart). So this
script keys everything on that id:

  * a stable label (w1, w2, ...) assigned on first sight and remembered, so
    "w2" means the same window in tomorrow's dump as in today's;
  * the profile, resolved once by URL-overlap against the per-profile session
    files and then cached, or set by hand with --set-profile.

Cache lives at ~/.config/tab-triage/window-profiles.json. Delete it to re-derive.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
from collections import Counter
from urllib.parse import urlsplit

CHROME_DIR = pathlib.Path.home() / "Library/Application Support/Google/Chrome"
CACHE = pathlib.Path.home() / ".config/tab-triage/window-profiles.json"
URL_RE = re.compile(rb"https?://[\x20-\x7e]{5,200}")

JXA = r"""
function run() {
  const chrome = Application("Google Chrome");
  const out = [];
  const wins = chrome.windows;
  for (let w = 0; w < wins.length; w++) {
    const win = wins[w];
    const wid = String(win.id());
    const tabs = win.tabs;
    for (let t = 0; t < tabs.length; t++) {
      const tab = tabs[t];
      out.push({
        window: w + 1,
        window_id: wid,
        index: t + 1,
        id: tab.id(),
        title: tab.title(),
        url: tab.url(),
        loading: tab.loading(),
      });
    }
  }
  return JSON.stringify(out);
}
"""


def chrome_is_running() -> bool:
    return subprocess.run(
        ["/usr/bin/pgrep", "-x", "Google Chrome"], capture_output=True
    ).returncode == 0


def fetch_tabs() -> list[dict]:
    proc = subprocess.run(
        ["/usr/bin/osascript", "-l", "JavaScript", "-e", JXA],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"osascript failed: {proc.stderr.strip()}")
    return json.loads(proc.stdout)


def norm(url: str) -> str:
    return url.rstrip("/").split("#")[0]


def known_profiles() -> dict[str, str]:
    """Profile display name -> profile directory, from Chrome's Local State."""
    ls = CHROME_DIR / "Local State"
    if not ls.exists():
        return {}
    cache = json.loads(ls.read_text()).get("profile", {}).get("info_cache", {})
    return {meta.get("name", d): d for d, meta in cache.items()}


def profile_url_sets() -> dict[str, set[str]]:
    """Profile display name -> normalized URLs from its two newest session files."""
    sets = {}
    for name, dirname in known_profiles().items():
        sessions = CHROME_DIR / dirname / "Sessions"
        if not sessions.is_dir():
            continue
        files = sorted(sessions.glob("Session_*"), key=lambda p: p.stat().st_mtime, reverse=True)
        urls = set()
        for f in files[:2]:  # session files rotate; the newest two cover live state
            try:
                blob = f.read_bytes()
            except OSError:
                continue
            for m in URL_RE.finditer(blob):
                urls.add(norm(m.group().decode("ascii", "ignore").split("\x00")[0]))
        if urls:
            sets[name] = urls
    return sets


def load_cache() -> dict:
    if not CACHE.exists():
        return {}
    try:
        return json.loads(CACHE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def save_cache(cache: dict) -> None:
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps(cache, indent=2, sort_keys=True) + "\n")


def resolve_windows(tabs: list[dict]) -> dict[str, dict]:
    """window_id -> {label, profile, confidence, source}. Reads and updates the cache.

    A manual entry is never overwritten. A window already cached keeps its label,
    so references stay stable across dumps. Entries for windows that no longer
    exist are dropped -- a closed window's id never comes back.
    """
    cache = load_cache()
    live_ids = []
    for t in tabs:  # preserve first-seen order without a set
        if t["window_id"] not in live_ids:
            live_ids.append(t["window_id"])

    cache = {k: v for k, v in cache.items() if k in live_ids}
    sets = profile_url_sets()
    used = {v["label"] for v in cache.values()}

    for wid in live_ids:
        entry = cache.get(wid)
        if entry and entry.get("source") == "manual":
            continue
        urls = {norm(t["url"]) for t in tabs
                if t["window_id"] == wid and t["url"].startswith("http")}
        profile, conf = "?", 0.0
        if urls and sets:
            scores = {n: len(urls & s) for n, s in sets.items()}
            best = max(scores, key=scores.get)
            if scores[best]:
                profile, conf = best, scores[best] / len(urls)
        if entry:
            # Keep the cached answer; only refresh confidence.
            entry["confidence"] = round(conf, 2)
            if entry["profile"] == "?" and profile != "?":
                entry["profile"], entry["source"] = profile, "heuristic"
            continue
        n = 1
        while f"w{n}" in used:
            n += 1
        used.add(f"w{n}")
        cache[wid] = {"label": f"w{n}", "profile": profile,
                      "confidence": round(conf, 2), "source": "heuristic"}

    save_cache(cache)
    return cache


def domain(url: str) -> str:
    parts = urlsplit(url)
    if parts.scheme in ("chrome", "chrome-extension", "file", "about"):
        return parts.scheme
    return parts.netloc.removeprefix("www.") or parts.scheme or "?"


def set_profile(spec: str) -> None:
    if "=" not in spec:
        sys.exit("--set-profile takes <window-id>=<profile name>, e.g. 1759375719='610systems'")
    wid, name = spec.split("=", 1)
    wid, name = wid.strip(), name.strip()
    names = known_profiles()
    if name not in names:
        sys.exit(f"unknown profile {name!r}; known: {sorted(names)}")
    cache = load_cache()
    entry = cache.get(wid)
    if not entry:
        sys.exit(f"window id {wid!r} is not in the cache; run the script once first "
                 f"(known: {sorted(cache)})")
    entry.update(profile=name, source="manual")
    save_cache(cache)
    print(f"{entry['label']} ({wid}) pinned to {name!r} — the heuristic will not override it")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--text", action="store_true", help="human-readable instead of JSON")
    ap.add_argument("--stats", action="store_true", help="counts by window/profile/domain")
    ap.add_argument("--profile", help="only tabs from this profile (display name)")
    ap.add_argument("--set-profile", metavar="ID=NAME",
                    help="pin a window id to a profile by hand; survives re-runs")
    ap.add_argument("--windows", action="store_true",
                    help="just the window table (labels, ids, profiles)")
    args = ap.parse_args()

    if args.set_profile:
        set_profile(args.set_profile)
        return

    if not chrome_is_running():
        sys.exit("Google Chrome is not running (refusing to launch it).")

    tabs = fetch_tabs()
    wins = resolve_windows(tabs)
    for t in tabs:
        w = wins[t["window_id"]]
        t["window_label"] = w["label"]
        t["profile"] = w["profile"]
        t["profile_source"] = w["source"]
        t["profile_confidence"] = w["confidence"]
        t["domain"] = domain(t["url"])

    order = sorted({t["window_label"] for t in tabs}, key=lambda l: int(l[1:]))

    if args.windows:
        print(f"cache: {CACHE}\n")
        print(f"{'label':6} {'window id':12} {'tabs':>5}  {'source':10} {'conf':>5}  profile")
        for lab in order:
            wt = [t for t in tabs if t["window_label"] == lab]
            t0 = wt[0]
            print(f"{lab:6} {t0['window_id']:12} {len(wt):5}  {t0['profile_source']:10} "
                  f"{t0['profile_confidence']:5.0%}  {t0['profile']}")
        return

    if args.profile:
        tabs = [t for t in tabs if t["profile"] == args.profile]
        if not tabs:
            sys.exit(f"no tabs for profile {args.profile!r}; "
                     f"known: {sorted({w['profile'] for w in wins.values()})}")
        order = sorted({t["window_label"] for t in tabs}, key=lambda l: int(l[1:]))

    if args.stats:
        print(f"{len(tabs)} tabs across {len(order)} windows\n")
        for lab in order:
            wt = [t for t in tabs if t["window_label"] == lab]
            t0 = wt[0]
            note = "pinned by hand" if t0["profile_source"] == "manual" \
                else f"{t0['profile_confidence']:.0%} confidence"
            print(f"  {lab}: {len(wt):3d} tabs   profile={t0['profile']} ({note})")
        dupes = {u: n for u, n in Counter(t["url"] for t in tabs).items() if n > 1}
        by_domain = Counter(t["domain"] for t in tabs)
        print(f"\n{len(by_domain)} distinct domains, {len(dupes)} duplicated URLs\n")
        for dom, n in by_domain.most_common(25):
            print(f"{n:4d}  {dom}")
        if dupes:
            print("\nduplicated URLs:")
            for url, n in sorted(dupes.items(), key=lambda kv: -kv[1]):
                print(f"{n:4d}  {url}")
    elif args.text:
        for lab in order:
            wt = [t for t in tabs if t["window_label"] == lab]
            t0 = wt[0]
            src = t0["profile_source"]
            note = "pinned" if src == "manual" else f"{t0['profile_confidence']:.0%}"
            print(f"\n=== {lab} — {t0['profile']} ({note}) — {len(wt)} tabs ===")
            for t in wt:
                print(f"  [{t['index']:3d}] {t['title']}\n        {t['url']}")
    else:
        json.dump(tabs, sys.stdout, indent=2)
        print()


if __name__ == "__main__":
    main()
