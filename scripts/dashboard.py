#!/usr/bin/env python3
"""qg dashboard — local web UI for claude-quality-gate metrics.

Serves a single-page dark dashboard at http://localhost:7777 (configurable).
Reads $QG_METRICS_LOG (default /tmp/qg-metrics.log), parses event lines into
structured records, and exposes a JSON API consumed by the static UI.

Zero dependencies — uses only http.server + json + re + os from stdlib.

Run:  python3 dashboard.py [--port 7777]
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import re
import socketserver
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

# Lines look like:
#   2026-04-24 06:18:00 pre-write-gate BLOCK:freshness-not-read sid=abc12345 file=existing.py
#   2026-04-24 06:19:01 track-activity LOOP_BLOCK count=6
#   2026-04-24 06:20:30 auto-verify PERF:42ms

LINE_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+"
    r"(?P<hook>\S+)\s+"
    r"(?P<event>\S+)"
    r"(?P<rest>.*)$"
)
KV_RE = re.compile(r"(\w+)=([^\s]+)")

# Estimated savings per gate trigger (average operator time + tokens).
# Conservative numbers, tunable via env.
TIME_SAVED_MIN = {
    "BLOCK:freshness-not-read":   5,   # patching a stale copy → re-read + diff
    "BLOCK:freshness-stale":      3,
    "BLOCK:large-file":           1,   # context drained, more API cost
    "BLOCK:loop":                 8,   # debugging a runaway loop
    "BLOCK:backtrack-locked":    10,   # tunnel vision recovery
    "BLOCK:untested-edits":      15,   # untested deploy bug
    "BLOCK:3-files-no-plan":      6,
    "BLOCK:deploy-no-test":      20,   # SSH debugging in prod
    "WORKAROUND":                 5,   # bad-habit catch
    "LOOP_BLOCK":                 8,
    "BLOCK:hard-gate":           12,
    "BLOCK:2nd-attempt":          4,
}

TOKENS_SAVED = {
    "BLOCK:large-file":   8000,
    "WARN:medium-file":   3000,
    "INFO:mid-file":      1000,
}


def _classify_savings(event: str) -> tuple[int, int]:
    """Return (minutes_saved, tokens_saved) heuristic for an event token."""
    minutes = 0
    tokens = 0
    for prefix, mins in TIME_SAVED_MIN.items():
        if event.startswith(prefix):
            minutes = max(minutes, mins)
    for prefix, t in TOKENS_SAVED.items():
        if event.startswith(prefix):
            tokens = max(tokens, t)
    return minutes, tokens


def _is_block(event: str) -> bool:
    return event.startswith(("BLOCK:", "LOOP_BLOCK", "WORKAROUND"))


def _is_warn(event: str) -> bool:
    return event.startswith(("WARN:", "INFO:"))


def parse_line(line: str) -> dict | None:
    m = LINE_RE.match(line.rstrip("\n"))
    if not m:
        return None
    rest = m["rest"]
    kv = dict(KV_RE.findall(rest))
    try:
        ts_dt = datetime.strptime(m["ts"], "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None
    return {
        "ts": m["ts"],
        "ts_epoch": int(ts_dt.timestamp()),
        "hook": m["hook"],
        "event": m["event"],
        "kv": kv,
        "is_block": _is_block(m["event"]),
        "is_warn": _is_warn(m["event"]),
    }


def load_events(log_path: Path, max_lines: int = 50_000) -> list[dict]:
    if not log_path.exists():
        return []
    with log_path.open("r", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
    if len(lines) > max_lines:
        lines = lines[-max_lines:]
    out = []
    for ln in lines:
        e = parse_line(ln)
        if e:
            out.append(e)
    return out


# ---------------------------------------------------------------------------
# Aggregations
# ---------------------------------------------------------------------------

def summary(events: list[dict]) -> dict:
    blocks = [e for e in events if e["is_block"]]
    warns  = [e for e in events if e["is_warn"]]
    sessions = {e["kv"].get("sid") for e in events if e["kv"].get("sid")}
    sessions.discard(None)

    total_minutes = 0
    total_tokens = 0
    for e in events:
        m, t = _classify_savings(e["event"])
        total_minutes += m
        total_tokens += t

    return {
        "events_total":      len(events),
        "blocks_total":      len(blocks),
        "warns_total":       len(warns),
        "sessions_total":    len(sessions),
        "minutes_saved":     total_minutes,
        "tokens_saved":      total_tokens,
        "first_seen":        events[0]["ts"]  if events else None,
        "last_seen":         events[-1]["ts"] if events else None,
    }


def violations(events: list[dict], top_n: int = 10) -> list[dict]:
    counter: Counter = Counter()
    for e in events:
        if e["is_block"] or e["is_warn"]:
            # Bucket by event class (everything before the first ':')
            bucket = e["event"].split(":", 1)[0] if ":" in e["event"] else e["event"]
            sub = e["event"].split(":", 1)[1] if ":" in e["event"] else ""
            label = f"{bucket}: {sub}" if sub else bucket
            counter[(e["hook"], label)] += 1
    out = []
    for (hook, label), count in counter.most_common(top_n):
        out.append({"hook": hook, "kind": label, "count": count})
    return out


def timeline(events: list[dict], bucket_minutes: int = 60, hours: int = 24) -> list[dict]:
    """Return [{bucket_iso, blocks, warns, total}] for the last `hours` hours."""
    if not events:
        return []
    now = max(e["ts_epoch"] for e in events)
    cutoff = now - hours * 3600
    bucket_sec = bucket_minutes * 60

    buckets: dict[int, dict] = defaultdict(lambda: {"blocks": 0, "warns": 0, "total": 0})
    for e in events:
        if e["ts_epoch"] < cutoff:
            continue
        b = e["ts_epoch"] - (e["ts_epoch"] % bucket_sec)
        buckets[b]["total"] += 1
        if e["is_block"]:
            buckets[b]["blocks"] += 1
        if e["is_warn"]:
            buckets[b]["warns"] += 1

    out = []
    for b in sorted(buckets):
        out.append({
            "bucket": datetime.fromtimestamp(b).strftime("%Y-%m-%d %H:%M"),
            **buckets[b],
        })
    return out


def sessions_overview(events: list[dict]) -> list[dict]:
    by_sid: dict[str, dict] = defaultdict(lambda: {
        "events": 0, "blocks": 0, "warns": 0, "first": None, "last": None,
    })
    for e in events:
        sid = e["kv"].get("sid")
        if not sid:
            continue
        s = by_sid[sid]
        s["events"] += 1
        if e["is_block"]:
            s["blocks"] += 1
        if e["is_warn"]:
            s["warns"] += 1
        s["first"] = e["ts"] if s["first"] is None else min(s["first"], e["ts"])
        s["last"]  = e["ts"] if s["last"]  is None else max(s["last"],  e["ts"])
    out = []
    for sid, s in by_sid.items():
        out.append({"sid": sid, **s})
    out.sort(key=lambda x: x["last"], reverse=True)
    return out[:50]


def recent(events: list[dict], n: int = 50) -> list[dict]:
    return [
        {"ts": e["ts"], "hook": e["hook"], "event": e["event"],
         "sid": e["kv"].get("sid"), "file": e["kv"].get("file"),
         "is_block": e["is_block"], "is_warn": e["is_warn"]}
        for e in events[-n:][::-1]
    ]


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):
    static_dir: Path = Path(__file__).parent / "dashboard"
    log_path: Path = Path(os.environ.get("QG_METRICS_LOG", "/tmp/qg-metrics.log"))

    def _send_json(self, payload: Any, status: int = 200):
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_static(self, rel_path: str, content_type: str):
        p = self.static_dir / rel_path
        if not p.exists():
            self.send_error(404, f"Not found: {rel_path}")
            return
        body = p.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # silence default noisy log
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path == "/":
            return self._send_static("index.html", "text/html; charset=utf-8")
        if path.startswith("/static/"):
            sub = path[len("/static/"):]
            ext = sub.rsplit(".", 1)[-1].lower()
            ctype = {"css": "text/css", "js": "application/javascript",
                     "svg": "image/svg+xml", "png": "image/png"}.get(ext, "application/octet-stream")
            return self._send_static(sub, ctype)

        if path.startswith("/api/"):
            events = load_events(self.log_path)
            if path == "/api/summary":
                return self._send_json(summary(events))
            if path == "/api/violations":
                return self._send_json(violations(events))
            if path == "/api/timeline":
                return self._send_json(timeline(events))
            if path == "/api/sessions":
                return self._send_json(sessions_overview(events))
            if path == "/api/recent":
                return self._send_json(recent(events))
            if path == "/api/health":
                return self._send_json({
                    "ok": True,
                    "log": str(self.log_path),
                    "log_exists": self.log_path.exists(),
                    "events": len(events),
                })

        self.send_error(404)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=int(os.environ.get("QG_DASHBOARD_PORT", 7777)))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--log",  default=os.environ.get("QG_METRICS_LOG", "/tmp/qg-metrics.log"))
    args = parser.parse_args()

    Handler.log_path = Path(args.log)

    with socketserver.TCPServer((args.host, args.port), Handler) as httpd:
        httpd.allow_reuse_address = True
        print(f"[qg] dashboard ready: http://{args.host}:{args.port}")
        print(f"[qg] reading metrics from: {Handler.log_path}")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n[qg] dashboard stopped.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
