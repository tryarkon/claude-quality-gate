"""quality_report: severity classification + log parsing + JSON output.

Verifies the reporter:
  - parses well-formed metric lines
  - skips PERF: lines and malformed input
  - classifies events into catastrophic / high / medium / low buckets
  - honours the --days window
  - produces both table and JSON output
  - cost estimates are non-negative and self-consistent
"""
from __future__ import annotations

import datetime as dt
import importlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = PROJECT_ROOT / "scripts"

# Make scripts/ importable regardless of test invocation cwd.
sys.path.insert(0, str(PROJECT_ROOT))
qr = importlib.import_module("scripts.quality_report")


# ---------------------------------------------------------------------------
# classify()
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "event,expected",
    [
        ("BLOCK:DROP TABLE users",          "catastrophic"),
        ("WORKAROUND:rm -rf src/",          "catastrophic"),
        ("BLOCK:git push --force",          "catastrophic"),
        ("WORKAROUND:git checkout .",       "catastrophic"),
        ("BLOCK:DELETE FROM users",         "catastrophic"),

        ("WORKAROUND:--no-verify",          "high"),
        ("WORKAROUND:|| true",              "high"),
        ("BLOCK:deploy-no-test",            "high"),
        ("BLOCK:untested-edits",            "high"),
        ("WORKAROUND:DISABLE_AUTH",         "high"),
        ("WORKAROUND:SKIP_LINT",            "high"),
        ("BLOCK:hard-gate-uncommitted",     "high"),

        ("BLOCK:freshness-not-read",        "medium"),
        ("BLOCK:freshness-stale",           "medium"),
        ("BLOCK:3-files-no-plan",           "medium"),
        ("BLOCK:loop",                      "medium"),
        ("LOOP_BLOCK:ssh:foo",              "medium"),
        ("BLOCK:backtrack-locked",          "medium"),
        ("WARN:large-file",                 "medium"),

        ("WARN:concurrent-edit",            "low"),
        ("WARN:5-files",                    "low"),
        ("INFO:mid-file-soft",              "low"),

        # Severity classifier returns 'medium' for any event substring-matching
        # 'loop'; the ACK *kind* is determined separately by parse_log().
        ("PERF:hook-pre-write 12ms",        "unclassified"),
    ],
)
def test_classify(event, expected):
    assert qr.classify(event) == expected


# ---------------------------------------------------------------------------
# parse_log()
# ---------------------------------------------------------------------------
def _write_log(path: Path, lines: list[str]) -> None:
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def test_parse_log_returns_empty_for_missing_file(tmp_path):
    assert qr.parse_log(tmp_path / "nope.log") == []


def test_parse_log_well_formed_lines(tmp_path):
    log = tmp_path / "metrics.log"
    _write_log(log, [
        "2026-04-20 10:00:00 pre-bash-gate WORKAROUND:--no-verify",
        "2026-04-20 10:01:00 pre-write-gate BLOCK:freshness-not-read",
        "2026-04-20 10:02:00 track-activity LOOP_ACK",
        "2026-04-20 10:03:00 pre-read-gate WARN:medium-file",
        "2026-04-20 10:04:00 pre-write-gate INFO:mid-file-soft",
    ])
    events = qr.parse_log(log)
    assert len(events) == 5
    kinds = [e["kind"] for e in events]
    assert "WORKAROUND" in kinds
    assert "BLOCK" in kinds
    assert "ACK" in kinds
    assert "WARN" in kinds
    assert "INFO" in kinds


def test_parse_log_skips_perf(tmp_path):
    log = tmp_path / "metrics.log"
    _write_log(log, [
        "2026-04-20 10:00:00 pre-bash-gate PERF:hook 8ms",
        "2026-04-20 10:01:00 pre-bash-gate BLOCK:loop",
    ])
    events = qr.parse_log(log)
    assert len(events) == 1
    assert events[0]["kind"] == "BLOCK"


def test_parse_log_skips_malformed(tmp_path):
    log = tmp_path / "metrics.log"
    _write_log(log, [
        "garbage line nothing here",
        "2026-04-20 10:00:00 pre-bash-gate BLOCK:loop",
        "another garbage",
    ])
    events = qr.parse_log(log)
    assert len(events) == 1


def test_parse_log_window_filter(tmp_path):
    log = tmp_path / "metrics.log"
    _write_log(log, [
        "2026-04-01 10:00:00 pre-bash-gate BLOCK:loop",
        "2026-04-20 10:00:00 pre-bash-gate BLOCK:loop",
    ])
    events = qr.parse_log(log, since=dt.date(2026, 4, 15))
    assert len(events) == 1
    assert events[0]["date"] == dt.date(2026, 4, 20)


# ---------------------------------------------------------------------------
# render()
# ---------------------------------------------------------------------------
def test_render_aggregates_and_computes_acceptance(tmp_path):
    log = tmp_path / "metrics.log"
    _write_log(log, [
        "2026-04-20 10:00:00 pre-bash-gate WORKAROUND:--no-verify",
        "2026-04-20 10:01:00 pre-bash-gate WORKAROUND:--no-verify",
        "2026-04-20 10:02:00 pre-write-gate BLOCK:freshness-not-read",
        "2026-04-20 10:03:00 track-activity LOOP_ACK",
    ])
    events = qr.parse_log(log)
    report = qr.render(events, days=7)

    assert report["total_blocks"] == 3
    assert report["total_acks"] == 1
    assert 0.0 <= report["accept_rate"] <= 1.0
    # Two high-sev workarounds + one medium block.
    assert report["by_severity"].get("high", 0) == 2
    assert report["by_severity"].get("medium", 0) == 1
    # Cost is non-negative; upper bound >= realistic.
    assert report["minutes_saved_realistic"] >= 0
    assert report["minutes_saved_upper"] >= report["minutes_saved_realistic"]


def test_render_empty_events_safe():
    report = qr.render([], days=7)
    assert report["total_blocks"] == 0
    assert report["total_acks"] == 0
    assert report["accept_rate"] == 0


# ---------------------------------------------------------------------------
# CLI integration
# ---------------------------------------------------------------------------
def _run_cli(args: list[str], env: dict | None = None) -> subprocess.CompletedProcess:
    cmd = [sys.executable, str(SCRIPTS_DIR / "quality_report.py"), *args]
    return subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=15)


def test_cli_missing_log_returns_nonzero(tmp_path):
    res = _run_cli(["--log", str(tmp_path / "missing.log")])
    assert res.returncode == 1
    assert "not found" in res.stderr


def test_cli_empty_window_returns_zero(tmp_path):
    log = tmp_path / "metrics.log"
    log.write_text("")  # empty file is "exists but no events"
    res = _run_cli(["--log", str(log), "--days", "30"])
    assert res.returncode == 0
    assert "no events" in res.stdout


def test_cli_json_format(tmp_path):
    log = tmp_path / "metrics.log"
    _write_log(log, [
        "2026-04-20 10:00:00 pre-bash-gate WORKAROUND:--no-verify",
        "2026-04-20 10:01:00 pre-write-gate BLOCK:freshness-not-read",
    ])
    res = _run_cli(["--log", str(log), "--days", "0", "--format", "json"])
    assert res.returncode == 0
    data = json.loads(res.stdout)
    assert data["total_blocks"] == 2
    assert "by_severity" in data
    assert isinstance(data["top_patterns"], list)


def test_cli_table_format_smoke(tmp_path):
    log = tmp_path / "metrics.log"
    _write_log(log, [
        "2026-04-20 10:00:00 pre-bash-gate WORKAROUND:--no-verify",
        "2026-04-20 10:01:00 pre-write-gate BLOCK:freshness-not-read",
    ])
    res = _run_cli(["--log", str(log), "--days", "0", "--format", "table"])
    assert res.returncode == 0
    assert "qg quality-report" in res.stdout
    assert "Catches by severity" in res.stdout
    assert "Headline" in res.stdout
