#!/usr/bin/env python3
"""qg quality-report — severity-classified metrics analysis.

Parses $QG_METRICS_LOG, classifies every BLOCK / WORKAROUND / WARN by
severity, and prints a quality-evidence report:

  - How many catastrophic / high / medium / low interventions per period
  - Override rate per severity (acceptance = (blocks - acks) / blocks)
  - Top 10 violation types
  - Trend: this 7d vs prior 7d

The point: BLOCK count alone is meaningless. Severity-weighted catches +
acceptance rate = real evidence the hooks prevent bad outcomes.

Usage:
  python3 quality_report.py [--log PATH] [--days 30] [--format table|json]
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import re
import sys
from pathlib import Path

LINE_RE = re.compile(
    r"^(?P<date>\d{4}-\d{2}-\d{2})\s(?P<time>\d{2}:\d{2}:\d{2})\s+"
    r"(?P<hook>\S+)\s+(?P<event>\S+)(?P<rest>.*)$"
)

# Severity classification. Keys are matched as substrings of the event
# token (e.g. "BLOCK:freshness-not-read" → matches "freshness-not-read").
SEVERITY = {
    "catastrophic": [
        # SQL data-loss
        "DROP/TRUNCATE", "DROP TABLE", "TRUNCATE", "DELETE FROM",
        # Filesystem nuke
        "rm -rf", "WORKAROUND:rm",
        # Git history rewrite
        "--force", "git push --force", "force-push",
        # Reset uncommitted work
        "git checkout .", "git restore --",
    ],
    "high": [
        "--no-verify", "no-verify",
        "--skip-tests", "--skip-checks", "--no-check", "--skip-",
        "|| true", "WORKAROUND:||",
        "2>/dev/null", "/dev/null",
        "DISABLE_", "SKIP_",
        "WORKAROUND:sed",
        "deploy-no-test", "untested-edits",
        "hard-gate",
        # All git workaround patterns from pre-bash (covers --no-verify,
        # checkout/restore variants caught under "WORKAROUND:git ...").
        "WORKAROUND:git",
    ],
    "medium": [
        "freshness-not-read", "freshness-stale", "freshness",
        "3-files-no-plan", "3-files",
        "loop", "LOOP_BLOCK",
        "backtrack-locked", "backtrack",
        "large-file",
        "stale", "tests-integrity",
        "tests", "uncommitted",
        "2nd-attempt",
    ],
    "low": [
        "concurrent-edit", "5-files", "WARN:5",
        "WARN:medium-file", "INFO:mid-file",
        "debrief",
        "no-recon",
    ],
}

# Cost estimate per severity (upper bound = damage if every catch fired).
SEVERITY_COST = {
    "catastrophic": (60, "min"),
    "high":         (15, "min"),
    "medium":       (5,  "min"),
    "low":          (1,  "min"),
}

# Realism factor: not every blocked action would have caused real damage.
# Catastrophic on a test DB ≠ catastrophic on prod. Apply per-severity discount.
SEVERITY_REALISM = {
    "catastrophic": 0.10,
    "high":         0.30,
    "medium":       0.50,
    "low":          0.20,
}


def classify(event: str) -> str:
    """Return severity bucket or 'unclassified'."""
    e = event.lower()
    # Catastrophic first (specific strings).
    for sev, patterns in SEVERITY.items():
        for p in patterns:
            if p.lower() in e:
                return sev
    return "unclassified"


def parse_log(path: Path, since: dt.date | None = None) -> list[dict]:
    """Yield event dicts with normalized fields. Skips PERF: lines."""
    out = []
    if not path.exists():
        return out
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = LINE_RE.match(line)
            if not m:
                continue
            event = m["event"]
            if event.startswith("PERF:"):
                continue
            try:
                d = dt.date.fromisoformat(m["date"])
            except ValueError:
                continue
            if since and d < since:
                continue

            kind = "other"
            if event.startswith("BLOCK:"):
                kind = "BLOCK"
                detail = event[6:]
            elif event.startswith("WORKAROUND"):
                kind = "WORKAROUND"
                detail = event[11:] if event.startswith("WORKAROUND:") else event
            elif event.startswith("WARN:"):
                kind = "WARN"
                detail = event[5:]
            elif event.startswith("INFO:"):
                kind = "INFO"
                detail = event[5:]
            elif event.endswith("_ACK") or event.startswith("CHANGELOG_ACK"):
                kind = "ACK"
                detail = event
            elif event.startswith("LOOP_BLOCK"):
                kind = "BLOCK"
                detail = "loop"
            else:
                detail = event

            out.append({
                "date": d, "hook": m["hook"], "kind": kind,
                "event": event, "detail": detail,
                "severity": classify(event),
            })
    return out


def render(events: list[dict], days: int) -> dict:
    blocks = [e for e in events if e["kind"] in ("BLOCK", "WORKAROUND")]
    acks = [e for e in events if e["kind"] == "ACK"]

    by_sev = collections.Counter(e["severity"] for e in blocks)
    by_pattern = collections.Counter(
        (e["hook"], e["detail"][:40], e["severity"]) for e in blocks
    )

    # Two estimates: upper bound (every catch = full damage) and realistic
    # (per-severity discount). Show both, let reader judge.
    minutes_upper = 0
    minutes_realistic = 0
    for sev, count in by_sev.items():
        mins, _ = SEVERITY_COST.get(sev, (0, ""))
        realism = SEVERITY_REALISM.get(sev, 0.1)
        minutes_upper += mins * count
        minutes_realistic += mins * count * realism

    # Acceptance rate per severity proxy: total blocks − total ACKs (overall,
    # since ACKs aren't per-severity in the log).
    total_blocks = len(blocks)
    total_acks = len(acks)
    accept_rate = (total_blocks - total_acks) / total_blocks if total_blocks else 0

    # Trend: blocks per week over the period.
    by_week: dict[int, int] = collections.Counter()
    for e in blocks:
        wk = (e["date"] - min(b["date"] for b in blocks)).days // 7 if blocks else 0
        by_week[wk] += 1

    return {
        "period_days":    days,
        "total_events":   len(events),
        "total_blocks":   total_blocks,
        "total_acks":     total_acks,
        "accept_rate":    accept_rate,
        "minutes_saved_realistic": int(minutes_realistic),
        "minutes_saved_upper":     minutes_upper,
        "hours_saved_realistic":   minutes_realistic / 60,
        "hours_saved_upper":       minutes_upper / 60,
        "by_severity":   dict(by_sev),
        "top_patterns":  by_pattern.most_common(15),
        "blocks_per_week": dict(by_week),
    }


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------
COLORS = {
    "catastrophic": "\033[1;31m",  # bold red
    "high":         "\033[31m",    # red
    "medium":       "\033[33m",    # yellow
    "low":          "\033[36m",    # cyan
    "reset":        "\033[0m",
    "bold":         "\033[1m",
    "dim":          "\033[2m",
}


def render_table(report: dict, log_path: Path):
    use_color = sys.stdout.isatty()
    def C(c): return COLORS[c] if use_color else ""
    R = COLORS["reset"] if use_color else ""

    print()
    print(f"{C('bold')}qg quality-report{R}  ·  {log_path}")
    print(f"{C('dim')}window: {report['period_days']} days  ·  events: {report['total_events']:,}{R}")
    print()

    # --- Severity table ---
    print(f"{C('bold')}Catches by severity{R}")
    sev_order = ("catastrophic", "high", "medium", "low", "unclassified")
    for sev in sev_order:
        n = report["by_severity"].get(sev, 0)
        if n == 0 and sev == "unclassified":
            continue
        bar = "█" * min(40, n // 10)
        c = C(sev) if sev in COLORS else ""
        print(f"  {c}{sev:14s}{R}  {n:>5d}  {c}{bar}{R}")

    # --- Headline numbers ---
    accept_pct = report["accept_rate"] * 100
    print()
    print(f"{C('bold')}Headline{R}")
    print(f"  Total blocks:                  {report['total_blocks']:,}")
    print(f"  User overrides (ACKs):         {report['total_acks']:,}")
    print(f"  Acceptance rate:               {accept_pct:.1f}%   "
          f"{C('dim')}(blocks user did NOT override){R}")
    print(f"  Time-saved (realistic ~):      {report['hours_saved_realistic']:.0f}h "
          f"({report['minutes_saved_realistic']:,} min)")
    print(f"  Time-saved (upper bound):      {report['hours_saved_upper']:.0f}h "
          f"({report['minutes_saved_upper']:,} min)   "
          f"{C('dim')}(if every catch had fully fired){R}")

    # --- Top patterns ---
    print()
    print(f"{C('bold')}Top patterns caught{R}")
    for (hook, label, sev), n in report["top_patterns"][:12]:
        c = C(sev) if sev in COLORS else ""
        print(f"  {n:>5d}  {c}{sev:13s}{R}  {hook:24s}  {label}")

    # --- Weekly trend ---
    if report["blocks_per_week"]:
        print()
        print(f"{C('bold')}Trend (blocks per week){R}")
        weeks = sorted(report["blocks_per_week"])
        for w in weeks:
            n = report["blocks_per_week"][w]
            bar = "▇" * min(50, n // 20)
            print(f"  week {w:>2d}:  {n:>5d}  {C('dim')}{bar}{R}")

    # --- Caveats ---
    print()
    print(f"{C('dim')}Caveats:{R}")
    print(f"  · Time-saved is an *estimate* (catastrophic=60min, high=15, medium=5, low=1).")
    print(f"  · Acceptance rate proxies how often the user agreed with the gate.")
    print(f"  · A high acceptance rate ≠ all those incidents would have happened —")
    print(f"    it means the user, when asked, didn't override the block.")
    print()


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--log", default=os.environ.get("QG_METRICS_LOG", "/tmp/qg-metrics.log"),
                   help="metrics log path")
    p.add_argument("--days", type=int, default=30, help="window in days (0 = all)")
    p.add_argument("--format", choices=("table", "json"), default="table")
    args = p.parse_args()

    log_path = Path(args.log).expanduser()
    if not log_path.exists():
        print(f"[qg] log not found: {log_path}", file=sys.stderr)
        return 1

    since = None
    if args.days > 0:
        since = dt.date.today() - dt.timedelta(days=args.days)

    events = parse_log(log_path, since=since)
    if not events:
        print("[qg] no events in window.")
        return 0

    report = render(events, args.days if args.days > 0 else 0)

    if args.format == "json":
        report["top_patterns"] = [
            {"hook": h, "pattern": p, "severity": s, "count": n}
            for (h, p, s), n in report["top_patterns"]
        ]
        print(json.dumps(report, indent=2))
    else:
        render_table(report, log_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
