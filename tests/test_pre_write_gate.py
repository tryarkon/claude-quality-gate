"""pre-write-gate: freshness, loop, backtrack, untested, 3-file, 5-file, plan whitelist."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path

import pytest


# --- Helpers --------------------------------------------------------------


def _md5_echo(s: str) -> str:
    """md5 of `echo "$s"` — bash echo adds trailing newline before piping to md5."""
    return hashlib.md5((s + "\n").encode()).hexdigest()


def _md5_file_bytes(path: Path) -> str:
    """md5 of file contents (matches `md5 -q` / `md5sum`)."""
    return hashlib.md5(path.read_bytes()).hexdigest()


def _seed_freshness(reads_root: str, sid: str, path: str, content: str | None = None):
    """Mimic what track-activity.sh writes after a Read.

    Key file:  $CC_READS_DIR/$sid/<md5(echo path)>
    Body:      <md5(file content)>
    """
    sdir = Path(reads_root) / sid
    sdir.mkdir(parents=True, exist_ok=True)
    key = _md5_echo(path)
    if content is None:
        body = _md5_file_bytes(Path(path))
    else:
        body = hashlib.md5(content.encode()).hexdigest()
    sdir.joinpath(key).write_text(body)


# --- Fresh-file path: first edit / freshness ------------------------------


def test_first_edit_emits_intro_message(run_hook, make_input, tmp_path):
    f = tmp_path / "new.py"  # does not exist → freshness skipped
    r = run_hook("pre-write-gate", make_input("Write", file_path=str(f)))
    assert r.allowed
    assert "First edit" in r.stdout or "First edit" in r.stderr or r.stdout_json()


def test_freshness_blocks_edit_without_read(run_hook, make_input, tmp_path, qg_env, session_id):
    f = tmp_path / "existing.py"
    # Freshness block applies to non-trivial files (>=50 lines); tiny files
    # are downgraded to warn in strict mode to avoid Read-overhead churn.
    f.write_text("\n".join(f"x = {i}" for i in range(60)) + "\n")
    # CC_READS_DIR for this session must exist for the gate to engage.
    Path(qg_env["QG_CC_READS_DIR"]).joinpath(session_id).mkdir(parents=True, exist_ok=True)
    r = run_hook("pre-write-gate", make_input("Edit", file_path=str(f)))
    assert r.denied, r
    assert "not Read" in r.stderr


def test_freshness_warns_for_small_file_without_read(run_hook, make_input, tmp_path, qg_env, session_id):
    # Files under 50 lines downgrade the freshness-not-read block to a warning
    # (allow) in strict mode — Read roundtrip is pure overhead for tiny files.
    f = tmp_path / "tiny.py"
    f.write_text("print('hi')\n")
    Path(qg_env["QG_CC_READS_DIR"]).joinpath(session_id).mkdir(parents=True, exist_ok=True)
    r = run_hook("pre-write-gate", make_input("Edit", file_path=str(f)))
    assert r.allowed, r
    body = r.stdout_json() or {}
    extra = body.get("hookSpecificOutput", {}).get("additionalContext", "")
    assert "not Read" in extra or "sanity-check" in extra


def test_freshness_passes_when_hash_matches(run_hook, make_input, tmp_path, qg_env, session_id):
    f = tmp_path / "existing.py"
    f.write_text("print('hi')\n")
    _seed_freshness(qg_env["QG_CC_READS_DIR"], session_id, str(f))
    r = run_hook("pre-write-gate", make_input("Edit", file_path=str(f)))
    assert r.allowed, r


def test_freshness_warns_when_file_changed(run_hook, make_input, tmp_path, qg_env, session_id):
    f = tmp_path / "existing.py"
    f.write_text("print('hi')\n")
    _seed_freshness(qg_env["QG_CC_READS_DIR"], session_id, str(f), content="old\n")
    r = run_hook("pre-write-gate", make_input("Edit", file_path=str(f)))
    assert r.allowed
    assert "changed" in r.stdout.lower() or "re-read" in r.stdout.lower()


def test_freshness_standard_profile_warns_not_blocks(
    run_hook, make_input, tmp_path, qg_env, session_id
):
    f = tmp_path / "existing.py"
    f.write_text("x\n")
    Path(qg_env["QG_CC_READS_DIR"]).joinpath(session_id).mkdir(parents=True, exist_ok=True)
    r = run_hook(
        "pre-write-gate",
        make_input("Edit", file_path=str(f)),
        extra_env={"QG_PROFILE": "standard"},
    )
    assert r.allowed
    assert "not Read" in r.stdout or "not Read" in r.stderr


def test_freshness_md_whitelist(run_hook, make_input, tmp_path, qg_env, session_id):
    f = tmp_path / "doc.md"
    f.write_text("hello\n")
    Path(qg_env["QG_CC_READS_DIR"]).joinpath(session_id).mkdir(parents=True, exist_ok=True)
    r = run_hook("pre-write-gate", make_input("Edit", file_path=str(f)))
    assert r.allowed, r


def test_freshness_disabled(run_hook, make_input, tmp_path, qg_env, session_id):
    f = tmp_path / "x.py"
    f.write_text("y\n")
    Path(qg_env["QG_CC_READS_DIR"]).joinpath(session_id).mkdir(parents=True, exist_ok=True)
    r = run_hook(
        "pre-write-gate",
        make_input("Edit", file_path=str(f)),
        extra_env={"QG_DISABLED_HOOKS": "freshness"},
    )
    assert r.allowed, r


# --- Loop block -----------------------------------------------------------


def test_loop_block_denies_write(run_hook, make_input, tmp_path, qg_env, session_id):
    Path(qg_env["QG_DISC_DIR"]).joinpath(f"loop-{session_id}").write_text(
        "LOOP BLOCKED: same command 6 times. echo LOOP_ACK to override."
    )
    f = tmp_path / "x.py"
    r = run_hook("pre-write-gate", make_input("Write", file_path=str(f)))
    assert r.denied
    assert "LOOP" in r.stderr


def test_loop_whitelists_plan_files(run_hook, make_input, tmp_path, qg_env, session_id):
    Path(qg_env["QG_DISC_DIR"]).joinpath(f"loop-{session_id}").write_text("LOOP")
    plans = tmp_path / ".claude" / "plans"
    plans.mkdir(parents=True)
    f = plans / "task.md"
    r = run_hook("pre-write-gate", make_input("Write", file_path=str(f)))
    assert r.allowed, r


# --- Backtrack lock -------------------------------------------------------


def test_backtrack_lock_blocks_write(run_hook, make_input, tmp_path, qg_env, session_id):
    f = tmp_path / "thrashed.py"
    f.write_text("x\n")
    bt_dir = Path(qg_env["QG_DISC_DIR"]) / f"backtrack-{session_id}"
    bt_dir.mkdir()
    short_hash = _md5_echo(str(f))[:16]
    bt_dir.joinpath(f"{short_hash}-locked").touch()
    _seed_freshness(qg_env["QG_CC_READS_DIR"], session_id, str(f))
    r = run_hook("pre-write-gate", make_input("Write", file_path=str(f)))
    assert r.denied
    assert "BACKTRACK" in r.stderr


# --- Untested-edit block --------------------------------------------------


def test_untested_block_denies_code_file(run_hook, make_input, tmp_path, qg_env, session_id):
    Path(qg_env["QG_DISC_DIR"]).joinpath(f"untested-block-{session_id}").write_text("12")
    f = tmp_path / "code.py"
    r = run_hook("pre-write-gate", make_input("Write", file_path=str(f)))
    assert r.denied
    assert "without a single test" in r.stderr or "test" in r.stderr.lower()


def test_untested_block_allows_test_file(run_hook, make_input, tmp_path, qg_env, session_id):
    Path(qg_env["QG_DISC_DIR"]).joinpath(f"untested-block-{session_id}").write_text("12")
    f = tmp_path / "test_thing.py"
    r = run_hook("pre-write-gate", make_input("Write", file_path=str(f)))
    assert r.allowed, r


def test_untested_block_standard_warns(run_hook, make_input, tmp_path, qg_env, session_id):
    Path(qg_env["QG_DISC_DIR"]).joinpath(f"untested-block-{session_id}").write_text("11")
    f = tmp_path / "x.py"
    r = run_hook(
        "pre-write-gate",
        make_input("Write", file_path=str(f)),
        extra_env={"QG_PROFILE": "standard"},
    )
    assert r.allowed
    assert "test" in (r.stdout + r.stderr).lower()


# --- 3-file gate ----------------------------------------------------------


def test_three_files_without_plan_blocks(run_hook, make_input, tmp_path, qg_env, session_id):
    sf = Path(qg_env["QG_DISC_DIR"]) / f"session-{session_id}"
    sf.write_text("/tmp/a.py\n/tmp/b.py\n")  # already 2 unique files
    f3 = tmp_path / "c.py"
    r = run_hook("pre-write-gate", make_input("Write", file_path=str(f3)))
    assert r.denied, r
    assert "plan" in r.stderr.lower()


def test_three_files_with_plan_passes(run_hook, make_input, tmp_path, qg_env, session_id):
    sf = Path(qg_env["QG_DISC_DIR"]) / f"session-{session_id}"
    sf.write_text("/tmp/a.py\n/tmp/b.py\n")
    # Drop a recent plan into QG_PLANS_DIR
    plan = Path(qg_env["QG_PLANS_DIR"]) / "task.md"
    plan.write_text("plan body\n")
    f3 = tmp_path / "c.py"
    r = run_hook("pre-write-gate", make_input("Write", file_path=str(f3)))
    assert r.allowed, r


def test_three_files_session_plan_path_passes(
    run_hook, make_input, tmp_path, qg_env, session_id
):
    """Mention of /plans/ inside session list also counts as plan."""
    sf = Path(qg_env["QG_DISC_DIR"]) / f"session-{session_id}"
    sf.write_text("/tmp/a.py\n/home/x/.claude/plans/task.md\n")
    f3 = tmp_path / "c.py"
    r = run_hook("pre-write-gate", make_input("Write", file_path=str(f3)))
    assert r.allowed, r


def test_three_file_gate_disabled(run_hook, make_input, tmp_path, qg_env, session_id):
    sf = Path(qg_env["QG_DISC_DIR"]) / f"session-{session_id}"
    sf.write_text("/tmp/a.py\n/tmp/b.py\n")
    f3 = tmp_path / "c.py"
    r = run_hook(
        "pre-write-gate",
        make_input("Write", file_path=str(f3)),
        extra_env={"QG_DISABLED_HOOKS": "3-file"},
    )
    assert r.allowed, r


# --- minimal profile -------------------------------------------------------


def test_minimal_profile_skips_everything(run_hook, make_input, tmp_path, qg_env, session_id):
    f = tmp_path / "x.py"
    f.write_text("x\n")
    Path(qg_env["QG_CC_READS_DIR"]).joinpath(session_id).mkdir(parents=True, exist_ok=True)
    r = run_hook(
        "pre-write-gate",
        make_input("Write", file_path=str(f)),
        extra_env={"QG_PROFILE": "minimal"},
    )
    assert r.allowed
    assert r.stdout == ""
