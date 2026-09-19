#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["requests"]
# ///
"""Write operations for Pinboard.in bookmarks — add/delete bookmarks, rename/delete tags.

The pinboard-bookmarks-mcp-server MCP connector is read-only; this script covers the
write side of the same Pinboard API v1 (https://pinboard.in/api/) it reads from.

Credentials come from the environment so nothing secret lands in the file:
  PINBOARD_TOKEN   username:token, from https://pinboard.in/settings/password

Usage (run via sops so the token never lands in shell history/env):
  sops exec-env secrets/pinboard.enc.env \
    'uv run Skills/pinboard-write/scripts/pinboard-write.py add --url https://example.com --title "Example" --tags foo,bar'

Commands:
  add --url URL --title TITLE [--notes TEXT] [--tags a,b,c] [--private] [--toread] [--no-replace] [--dt 2026-01-01T12:00:00Z]
  delete --url URL
  tag-rename --old OLD --new NEW
  tag-delete --tag TAG

Notes:
  - Pinboard's guideline is one write call per user every 3 seconds; each run of
    this script makes a single call, so that's naturally respected.
  - `add` defaults match Pinboard's own API defaults: shared, not marked to-read,
    and replaces any existing bookmark at the same URL.
"""
import argparse
import os
import sys

import requests

API_BASE = "https://api.pinboard.in/v1"


def _token() -> str:
    token = os.environ.get("PINBOARD_TOKEN")
    if not token:
        sys.exit("error: PINBOARD_TOKEN environment variable is required (see script header)")
    return token


def _call(path: str, params: dict) -> dict:
    params = {**params, "auth_token": _token(), "format": "json"}
    resp = requests.get(f"{API_BASE}{path}", params=params, timeout=15)
    resp.raise_for_status()
    return resp.json()


def _finish(result: dict) -> None:
    print(result)
    # Pinboard reports success under a different key depending on the endpoint:
    # posts/add and posts/delete return {"result_code": "done"}, while
    # tags/rename and tags/delete return {"result": "done"}. Checking only
    # result_code made both tag commands exit 1 on success (seen 2026-08-27 —
    # a tag-delete that had actually worked reported failure).
    status = result.get("result_code", result.get("result"))
    if status != "done":
        sys.exit(1)


def cmd_add(args: argparse.Namespace) -> None:
    params = {
        "url": args.url,
        "description": args.title,
        "shared": "no" if args.private else "yes",
        "toread": "yes" if args.toread else "no",
        "replace": "no" if args.no_replace else "yes",
    }
    if args.notes:
        params["extended"] = args.notes
    if args.tags:
        params["tags"] = " ".join(t.strip() for t in args.tags.split(",") if t.strip())
    if args.dt:
        params["dt"] = args.dt
    _finish(_call("/posts/add", params))


def cmd_delete(args: argparse.Namespace) -> None:
    _finish(_call("/posts/delete", {"url": args.url}))


def cmd_tag_rename(args: argparse.Namespace) -> None:
    _finish(_call("/tags/rename", {"old": args.old, "new": args.new}))


def cmd_tag_delete(args: argparse.Namespace) -> None:
    _finish(_call("/tags/delete", {"tag": args.tag}))


def main() -> None:
    parser = argparse.ArgumentParser(description="Write operations for Pinboard.in bookmarks")
    sub = parser.add_subparsers(dest="command", required=True)

    p_add = sub.add_parser("add", help="Add (or replace) a bookmark")
    p_add.add_argument("--url", required=True)
    p_add.add_argument("--title", required=True, help="Bookmark title (Pinboard's 'description' field)")
    p_add.add_argument("--notes", help="Extended notes/description text")
    p_add.add_argument("--tags", help="Comma-separated tags, e.g. python,api")
    p_add.add_argument("--private", action="store_true", help="Mark not shared (default: shared)")
    p_add.add_argument("--toread", action="store_true", help="Mark to-read (default: not)")
    p_add.add_argument("--no-replace", action="store_true", help="Fail instead of replacing an existing bookmark at this URL")
    p_add.add_argument("--dt", help="Creation datetime (ISO 8601, e.g. 2026-01-01T12:00:00Z); default: now")
    p_add.set_defaults(func=cmd_add)

    p_del = sub.add_parser("delete", help="Delete a bookmark by URL")
    p_del.add_argument("--url", required=True)
    p_del.set_defaults(func=cmd_delete)

    p_tr = sub.add_parser("tag-rename", help="Rename a tag across all bookmarks")
    p_tr.add_argument("--old", required=True)
    p_tr.add_argument("--new", required=True)
    p_tr.set_defaults(func=cmd_tag_rename)

    p_td = sub.add_parser("tag-delete", help="Delete a tag from all bookmarks")
    p_td.add_argument("--tag", required=True)
    p_td.set_defaults(func=cmd_tag_delete)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
