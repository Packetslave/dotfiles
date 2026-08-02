#!/usr/bin/env python3
"""cursor2md — export Cursor chat/agent (composer) sessions to Markdown.

Stdlib only. Read-only against Cursor's SQLite databases.

Storage layout (macOS default: ~/Library/Application Support/Cursor/User):

  globalStorage/state.vscdb
      table cursorDiskKV:
        composerData:<composerId>        -> session metadata (+ message
                                            headers in newer versions)
        bubbleId:<composerId>:<bubbleId> -> individual message ("bubble")

  workspaceStorage/<hash>/
      workspace.json                     -> {"folder": "file:///path/to/proj"}
      state.vscdb, table ItemTable:
        composer.composerData            -> which composer IDs belong to
                                            this workspace
        workbench.panel.aichat.view.aichat.chatdata
                                         -> legacy chat tabs (old versions)

Usage:
  cursor2md.py list [--workspace NAME] [--since YYYY-MM-DD] [--search TEXT]
  cursor2md.py export [--output DIR] [--workspace NAME] [--since YYYY-MM-DD]
                      [--search TEXT] [--include-tools] [--legacy]
  cursor2md.py doctor      # inspect DBs, report key counts / schema drift
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import re
import shutil
import sqlite3
import sys
import tempfile
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------
# Locating Cursor data
# --------------------------------------------------------------------------

def default_cursor_user_dir() -> Path:
    system = platform.system()
    home = Path.home()
    if system == "Darwin":
        return home / "Library/Application Support/Cursor/User"
    if system == "Windows":
        appdata = os.environ.get("APPDATA")
        if appdata:
            return Path(appdata) / "Cursor/User"
        return home / "AppData/Roaming/Cursor/User"
    return home / ".config/Cursor/User"


# --------------------------------------------------------------------------
# SQLite helpers (read-only, lock-tolerant)
# --------------------------------------------------------------------------

def open_ro(db_path: Path) -> sqlite3.Connection:
    """Open a database read-only. If locked (Cursor running), fall back to a
    temp copy so we never block or touch the live DB."""
    uri = f"file:{urllib.parse.quote(str(db_path))}?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=2.0)
        conn.execute("SELECT 1")  # force open / detect lock early
        return conn
    except sqlite3.OperationalError:
        tmpdir = Path(tempfile.mkdtemp(prefix="cursor2md_"))
        tmp = tmpdir / db_path.name
        shutil.copy2(db_path, tmp)
        for suffix in ("-wal", "-shm"):
            side = db_path.with_name(db_path.name + suffix)
            if side.exists():
                shutil.copy2(side, tmpdir / side.name)
        return sqlite3.connect(f"file:{urllib.parse.quote(str(tmp))}?mode=ro",
                               uri=True)


def table_exists(conn: sqlite3.Connection, name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ).fetchone()
    return row is not None


def kv_get(conn: sqlite3.Connection, table: str, key: str):
    row = conn.execute(
        f"SELECT value FROM {table} WHERE [key]=?", (key,)
    ).fetchone()
    if not row or row[0] is None:
        return None
    val = row[0]
    if isinstance(val, bytes):
        val = val.decode("utf-8", errors="replace")
    try:
        return json.loads(val)
    except (json.JSONDecodeError, TypeError):
        return None


# --------------------------------------------------------------------------
# Data model
# --------------------------------------------------------------------------

@dataclass
class Bubble:
    role: str                 # "user" | "assistant" | "unknown"
    text: str = ""
    tool_calls: list = field(default_factory=list)
    code_blocks: list = field(default_factory=list)


@dataclass
class Session:
    composer_id: str
    name: str = ""
    created_at: dt.datetime | None = None
    updated_at: dt.datetime | None = None
    workspace: str | None = None      # human-readable project path
    bubbles: list[Bubble] = field(default_factory=list)
    source: str = "composer"          # "composer" | "legacy"

    @property
    def title(self) -> str:
        if self.name:
            return self.name
        for b in self.bubbles:
            if b.role == "user" and b.text.strip():
                return b.text.strip().splitlines()[0][:60]
        return f"untitled-{self.composer_id[:8]}"


def ms_to_dt(ms) -> dt.datetime | None:
    if not ms:
        return None
    try:
        return dt.datetime.fromtimestamp(int(ms) / 1000)
    except (ValueError, OSError, OverflowError):
        return None


# --------------------------------------------------------------------------
# Workspace mapping: composerId -> project folder
# --------------------------------------------------------------------------

def build_workspace_map(user_dir: Path, warn) -> dict[str, str]:
    """Return {composerId: project_path} by scanning workspaceStorage."""
    mapping: dict[str, str] = {}
    ws_root = user_dir / "workspaceStorage"
    if not ws_root.is_dir():
        warn(f"workspaceStorage not found at {ws_root}")
        return mapping

    for ws_dir in sorted(ws_root.iterdir()):
        db = ws_dir / "state.vscdb"
        if not db.is_file():
            continue
        folder = _workspace_folder(ws_dir)
        try:
            conn = open_ro(db)
        except Exception as e:
            warn(f"skipping {ws_dir.name}: {e}")
            continue
        try:
            if not table_exists(conn, "ItemTable"):
                continue
            data = kv_get(conn, "ItemTable", "composer.composerData")
            if not data:
                continue
            for comp in data.get("allComposers", []) or []:
                cid = comp.get("composerId")
                if cid:
                    mapping[cid] = folder or ws_dir.name
        except Exception as e:
            warn(f"error reading {ws_dir.name}: {e}")
        finally:
            conn.close()
    return mapping


def _workspace_folder(ws_dir: Path) -> str | None:
    wj = ws_dir / "workspace.json"
    if not wj.is_file():
        return None
    try:
        data = json.loads(wj.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    uri = data.get("folder") or data.get("workspace")
    if not uri:
        return None
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme == "file":
        return urllib.parse.unquote(parsed.path)
    return uri


# --------------------------------------------------------------------------
# Composer sessions (modern format, globalStorage)
# --------------------------------------------------------------------------

BUBBLE_ROLE = {1: "user", 2: "assistant"}


def load_composer_sessions(user_dir: Path, ws_map: dict[str, str],
                           warn) -> list[Session]:
    db = user_dir / "globalStorage/state.vscdb"
    if not db.is_file():
        warn(f"global DB not found at {db}")
        return []
    conn = open_ro(db)
    sessions: list[Session] = []
    try:
        if not table_exists(conn, "cursorDiskKV"):
            warn("cursorDiskKV table missing in global DB — schema may have "
                 "changed; run `doctor`")
            return []
        rows = conn.execute(
            "SELECT [key], value FROM cursorDiskKV "
            "WHERE [key] LIKE 'composerData:%'"
        ).fetchall()
        for key, raw in rows:
            cid = key.split(":", 1)[1]
            try:
                data = json.loads(raw if isinstance(raw, str)
                                  else raw.decode("utf-8", "replace"))
            except (json.JSONDecodeError, AttributeError):
                warn(f"unparseable composerData for {cid}")
                continue
            sess = Session(
                composer_id=cid,
                name=(data.get("name") or "").strip(),
                created_at=ms_to_dt(data.get("createdAt")),
                updated_at=ms_to_dt(data.get("lastUpdatedAt")
                                    or data.get("createdAt")),
                workspace=ws_map.get(cid),
            )
            sess.bubbles = _load_bubbles(conn, cid, data, warn)
            sessions.append(sess)
    finally:
        conn.close()
    return sessions


def _load_bubbles(conn, cid: str, data: dict, warn) -> list[Bubble]:
    """Bubbles are either inline (older) or referenced by header (newer)."""
    bubbles: list[Bubble] = []

    inline = data.get("conversation")
    if inline:  # older composerData embeds the whole conversation
        for b in inline:
            bubbles.append(_parse_bubble(b))
        return bubbles

    headers = data.get("fullConversationHeadersOnly") or []
    for h in headers:
        bid = h.get("bubbleId")
        if not bid:
            continue
        row = conn.execute(
            "SELECT value FROM cursorDiskKV WHERE [key]=?",
            (f"bubbleId:{cid}:{bid}",),
        ).fetchone()
        if not row or row[0] is None:
            continue
        try:
            raw = row[0]
            b = json.loads(raw if isinstance(raw, str)
                           else raw.decode("utf-8", "replace"))
        except (json.JSONDecodeError, AttributeError):
            warn(f"unparseable bubble {bid} in {cid}")
            continue
        if "type" not in b and h.get("type") is not None:
            b["type"] = h["type"]
        bubbles.append(_parse_bubble(b))
    return bubbles


def _parse_bubble(b: dict) -> Bubble:
    role = BUBBLE_ROLE.get(b.get("type"), "unknown")
    text = b.get("text") or b.get("richText") or ""
    if not isinstance(text, str):
        text = ""

    tool_calls = []
    tfd = b.get("toolFormerData")
    if tfd:
        tool_calls.append({
            "name": tfd.get("name") or tfd.get("tool") or "tool",
            "params": tfd.get("params") or tfd.get("rawArgs"),
            "status": tfd.get("status"),
        })

    code_blocks = []
    for cb in b.get("codeBlocks") or []:
        if isinstance(cb, dict):
            code_blocks.append({
                "language": cb.get("languageId") or cb.get("language") or "",
                "uri": _cb_uri(cb),
                "content": cb.get("content") or cb.get("code") or "",
            })
    return Bubble(role=role, text=text, tool_calls=tool_calls,
                  code_blocks=code_blocks)


def _cb_uri(cb: dict) -> str:
    uri = cb.get("uri")
    if isinstance(uri, dict):
        return uri.get("fsPath") or uri.get("path") or ""
    return uri or ""


# --------------------------------------------------------------------------
# Legacy chat tabs (old versions, workspaceStorage ItemTable)
# --------------------------------------------------------------------------

LEGACY_KEY = "workbench.panel.aichat.view.aichat.chatdata"


def load_legacy_sessions(user_dir: Path, warn) -> list[Session]:
    sessions: list[Session] = []
    ws_root = user_dir / "workspaceStorage"
    if not ws_root.is_dir():
        return sessions
    for ws_dir in sorted(ws_root.iterdir()):
        db = ws_dir / "state.vscdb"
        if not db.is_file():
            continue
        folder = _workspace_folder(ws_dir)
        try:
            conn = open_ro(db)
        except Exception as e:
            warn(f"skipping legacy scan of {ws_dir.name}: {e}")
            continue
        try:
            if not table_exists(conn, "ItemTable"):
                continue
            data = kv_get(conn, "ItemTable", LEGACY_KEY)
            if not data:
                continue
            for tab in data.get("tabs", []) or []:
                sess = Session(
                    composer_id=tab.get("tabId", f"legacy-{ws_dir.name}"),
                    name=(tab.get("chatTitle") or "").strip(),
                    created_at=ms_to_dt(tab.get("lastSendTime")),
                    updated_at=ms_to_dt(tab.get("lastSendTime")),
                    workspace=folder or ws_dir.name,
                    source="legacy",
                )
                for b in tab.get("bubbles", []) or []:
                    role = "user" if b.get("type") == "user" else "assistant"
                    sess.bubbles.append(Bubble(role=role,
                                               text=b.get("text") or ""))
                sessions.append(sess)
        except Exception as e:
            warn(f"legacy parse error in {ws_dir.name}: {e}")
        finally:
            conn.close()
    return sessions


# --------------------------------------------------------------------------
# Filtering
# --------------------------------------------------------------------------

def apply_filters(sessions: list[Session], args) -> list[Session]:
    out = sessions
    if args.workspace:
        needle = args.workspace.lower()
        out = [s for s in out if s.workspace and needle in s.workspace.lower()]
    if args.since:
        cutoff = dt.datetime.strptime(args.since, "%Y-%m-%d")
        out = [s for s in out
               if (s.updated_at or s.created_at or dt.datetime.min) >= cutoff]
    if args.search:
        needle = args.search.lower()
        out = [s for s in out
               if needle in s.title.lower()
               or any(needle in b.text.lower() for b in s.bubbles)]
    out.sort(key=lambda s: s.updated_at or s.created_at or dt.datetime.min,
             reverse=True)
    return out


# --------------------------------------------------------------------------
# Markdown rendering
# --------------------------------------------------------------------------

def slugify(text: str, maxlen: int = 50) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", text).strip("-").lower()
    return slug[:maxlen].rstrip("-") or "untitled"


def render_markdown(sess: Session, include_tools: bool) -> str:
    lines: list[str] = []
    lines.append("---")
    lines.append(f"title: {json.dumps(sess.title)}")
    lines.append(f"composer_id: {sess.composer_id}")
    if sess.workspace:
        lines.append(f"workspace: {json.dumps(sess.workspace)}")
    if sess.created_at:
        lines.append(f"created: {sess.created_at.isoformat()}")
    if sess.updated_at:
        lines.append(f"updated: {sess.updated_at.isoformat()}")
    lines.append(f"source: {sess.source}")
    lines.append(f"messages: {len(sess.bubbles)}")
    lines.append("---")
    lines.append("")
    lines.append(f"# {sess.title}")
    lines.append("")

    for b in sess.bubbles:
        if not b.text.strip() and not b.code_blocks and not (
                include_tools and b.tool_calls):
            continue
        header = {"user": "## 🧑 User", "assistant": "## 🤖 Assistant"}.get(
            b.role, "## ❓ Unknown")
        lines.append(header)
        lines.append("")
        if b.text.strip():
            lines.append(b.text.strip())
            lines.append("")
        if include_tools:
            for tc in b.tool_calls:
                lines.append(f"> **Tool:** `{tc['name']}`"
                             + (f" — {tc['status']}" if tc.get("status")
                                else ""))
                if tc.get("params"):
                    params = tc["params"]
                    if not isinstance(params, str):
                        params = json.dumps(params, indent=2)[:2000]
                    lines.append(">")
                    lines.append("> ```json")
                    for ln in str(params).splitlines():
                        lines.append(f"> {ln}")
                    lines.append("> ```")
                lines.append("")
        for cb in b.code_blocks:
            label = f" ({cb['uri']})" if cb["uri"] else ""
            if cb["content"].strip():
                lines.append(f"```{cb['language']}{label}".rstrip())
                lines.append(cb["content"].rstrip())
                lines.append("```")
                lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def export_sessions(sessions: list[Session], out_dir: Path,
                    include_tools: bool) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    used: set[str] = set()
    for sess in sessions:
        stamp = (sess.updated_at or sess.created_at)
        prefix = stamp.strftime("%Y-%m-%d") if stamp else "undated"
        base = f"{prefix}__{slugify(sess.title)}"
        name = base
        n = 2
        while name in used:
            name = f"{base}-{n}"
            n += 1
        used.add(name)
        path = out_dir / f"{name}.md"
        path.write_text(render_markdown(sess, include_tools),
                        encoding="utf-8")
        written.append(path)
    return written


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def gather(args, warn) -> list[Session]:
    user_dir = Path(args.cursor_dir).expanduser()
    ws_map = build_workspace_map(user_dir, warn)
    sessions = load_composer_sessions(user_dir, ws_map, warn)
    if args.legacy:
        sessions += load_legacy_sessions(user_dir, warn)
    return apply_filters(sessions, args)


def cmd_list(args, warn):
    sessions = gather(args, warn)
    if not sessions:
        print("No sessions found.")
        return
    for s in sessions:
        stamp = (s.updated_at or s.created_at)
        when = stamp.strftime("%Y-%m-%d %H:%M") if stamp else "????-??-??"
        ws = s.workspace or "-"
        print(f"{when}  [{len(s.bubbles):>3} msg]  {s.title[:50]:<50}  {ws}")
    print(f"\n{len(sessions)} session(s)")


def cmd_export(args, warn):
    sessions = gather(args, warn)
    if not sessions:
        print("No sessions found — nothing to export.")
        return
    out_dir = Path(args.output).expanduser()
    written = export_sessions(sessions, out_dir, args.include_tools)
    for p in written:
        print(f"  wrote {p}")
    print(f"\nExported {len(written)} session(s) to {out_dir}")


def cmd_doctor(args, warn):
    user_dir = Path(args.cursor_dir).expanduser()
    print(f"Cursor user dir: {user_dir}  (exists: {user_dir.is_dir()})")
    gdb = user_dir / "globalStorage/state.vscdb"
    print(f"\nglobalStorage DB: {gdb}")
    if gdb.is_file():
        print(f"  size: {gdb.stat().st_size / 1e6:.1f} MB")
        conn = open_ro(gdb)
        try:
            tables = [r[0] for r in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")]
            print(f"  tables: {', '.join(tables)}")
            if "cursorDiskKV" in tables:
                for prefix in ("composerData:", "bubbleId:", "checkpointId:",
                               "messageRequestContext:"):
                    n = conn.execute(
                        "SELECT COUNT(*) FROM cursorDiskKV WHERE [key] LIKE ?",
                        (prefix + "%",)).fetchone()[0]
                    print(f"  {prefix:<28} {n}")
        finally:
            conn.close()
    ws_root = user_dir / "workspaceStorage"
    if ws_root.is_dir():
        dirs = [d for d in ws_root.iterdir() if (d / "state.vscdb").is_file()]
        print(f"\nworkspaceStorage: {len(dirs)} workspace DB(s)")
        mapping = build_workspace_map(user_dir, warn)
        print(f"  composer->workspace mappings: {len(mapping)}")


def main(argv=None):
    p = argparse.ArgumentParser(prog="cursor2md", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--cursor-dir", default=str(default_cursor_user_dir()),
                   help="Cursor User directory (default: platform standard)")
    p.add_argument("-q", "--quiet", action="store_true",
                   help="suppress warnings")
    sub = p.add_subparsers(dest="cmd", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--workspace", help="filter by project path substring")
    common.add_argument("--since", help="only sessions updated since YYYY-MM-DD")
    common.add_argument("--search", help="filter by text in title or messages")
    common.add_argument("--legacy", action="store_true",
                        help="also scan legacy per-workspace chat tabs")

    sub.add_parser("list", parents=[common], help="list sessions")
    pe = sub.add_parser("export", parents=[common], help="export to Markdown")
    pe.add_argument("-o", "--output", default="./cursor-chats",
                    help="output directory (default: ./cursor-chats)")
    pe.add_argument("--include-tools", action="store_true",
                    help="include agent tool calls in output")
    sub.add_parser("doctor", help="inspect databases and report schema info")

    args = p.parse_args(argv)

    def warn(msg: str):
        if not args.quiet:
            print(f"warning: {msg}", file=sys.stderr)

    {"list": cmd_list, "export": cmd_export, "doctor": cmd_doctor}[args.cmd](
        args, warn)


if __name__ == "__main__":
    main()
