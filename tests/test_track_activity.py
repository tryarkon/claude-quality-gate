"""track-activity: PostToolUse state tracker that feeds the gates."""
from __future__ import annotations

import hashlib
from pathlib import Path

import pytest


def _md5_echo(s: str) -> str:
    return hashlib.md5((s + "\n").encode()).hexdigest()


# --- Read → freshness hash --------------------------------------------------


def test_read_writes_freshness_hash(run_hook, make_input, qg_env, session_id, tmp_path):
    f = tmp_path / "src.py"
    f.write_text("hello\n")
    r = run_hook("track-activity", make_input("Read", file_path=str(f)))
    assert r.allowed
    key = _md5_echo(str(f))
    hash_file = Path(qg_env["QG_CC_READS_DIR"]) / session_id / key
    assert hash_file.exists()
    assert hash_file.read_text().strip() == hashlib.md5(b"hello\n").hexdigest()


def test_read_nonexistent_file_skips(run_hook, make_input, qg_env, session_id):
    r = run_hook("track-activity", make_input("Read", file_path="/nope/missing.py"))
    assert r.allowed
    sd = Path(qg_env["QG_CC_READS_DIR"]) / session_id
    assert not sd.exists() or not any(sd.iterdir())


# --- Write/Edit → session list + churn -------------------------------------


def test_write_appends_to_session_file(run_hook, make_input, qg_env, session_id, tmp_path):
    f = tmp_path / "x.py"
    run_hook("track-activity", make_input("Write", file_path=str(f)))
    sf = Path(qg_env["QG_DISC_DIR"]) / f"session-{session_id}"
    assert sf.exists()
    assert str(f) in sf.read_text()


def test_churn_warns_at_3_edits(run_hook, make_input, qg_env, session_id, tmp_path):
    f = tmp_path / "y.py"
    for _ in range(2):
        run_hook("track-activity", make_input("Edit", file_path=str(f)))
    r = run_hook("track-activity", make_input("Edit", file_path=str(f)))
    assert "CHURN" in r.stdout, r


def test_churn_locks_at_5_edits(run_hook, make_input, qg_env, session_id, tmp_path):
    f = tmp_path / "z.py"
    for _ in range(4):
        run_hook("track-activity", make_input("Edit", file_path=str(f)))
    r = run_hook("track-activity", make_input("Edit", file_path=str(f)))
    assert "BACKTRACK" in r.stdout, r
    bt_dir = Path(qg_env["QG_DISC_DIR"]) / f"backtrack-{session_id}"
    assert bt_dir.is_dir()
    short_hash = _md5_echo(str(f))[:16]
    assert (bt_dir / f"{short_hash}-locked").exists()


# --- Untested edits counter ------------------------------------------------


def test_untested_warns_at_5_code_edits(run_hook, make_input, qg_env, session_id, tmp_path):
    out = ""
    for i in range(5):
        f = tmp_path / f"f{i}.py"
        r = run_hook("track-activity", make_input("Write", file_path=str(f)))
        out += r.stdout
    assert "5 code edits" in out or "INFO" in out


def test_untested_blocks_at_10_code_edits(run_hook, make_input, qg_env, session_id, tmp_path):
    for i in range(10):
        f = tmp_path / f"file{i}.py"
        run_hook("track-activity", make_input("Write", file_path=str(f)))
    block = Path(qg_env["QG_DISC_DIR"]) / f"untested-block-{session_id}"
    assert block.exists()
    assert block.read_text().strip() == "10"


def test_untested_ignores_non_code(run_hook, make_input, qg_env, session_id, tmp_path):
    for i in range(15):
        f = tmp_path / f"d{i}.md"
        run_hook("track-activity", make_input("Write", file_path=str(f)))
    block = Path(qg_env["QG_DISC_DIR"]) / f"untested-block-{session_id}"
    assert not block.exists()


# --- Test command resets counters -----------------------------------------


def test_pytest_resets_untested_block(run_hook, make_input, qg_env, session_id, tmp_path):
    block = Path(qg_env["QG_DISC_DIR"]) / f"untested-block-{session_id}"
    block.write_text("12")
    deploy_block = Path(qg_env["QG_DISC_DIR"]) / f"deploy-block-{session_id}"
    deploy_block.write_text("12")

    run_hook("track-activity", make_input("Bash", command="pytest tests/"))

    assert not block.exists()
    assert not deploy_block.exists()
    assert (Path(qg_env["QG_DISC_DIR"]) / f"tests-ran-{session_id}").exists()


@pytest.mark.parametrize(
    "cmd",
    ["cargo test", "npm test", "npx vitest run", "go test ./...", "python3 -m pytest"],
)
def test_other_test_runners_set_flag(run_hook, make_input, qg_env, session_id, cmd):
    run_hook("track-activity", make_input("Bash", command=cmd))
    assert (Path(qg_env["QG_DISC_DIR"]) / f"tests-ran-{session_id}").exists()


def test_git_commit_resets_churn(run_hook, make_input, qg_env, session_id, tmp_path):
    f = tmp_path / "a.py"
    for _ in range(3):
        run_hook("track-activity", make_input("Edit", file_path=str(f)))
    state_dir = Path(qg_env["QG_CC_HOOKS_DIR"]) / session_id
    assert any(p.name.startswith("churn_") for p in state_dir.iterdir())
    run_hook("track-activity", make_input("Bash", command="git commit -m 'feat: x'"))
    # After commit, churn keys are wiped; only the loop counter for git-commit
    # itself may remain.
    remaining = [p.name for p in state_dir.iterdir()] if state_dir.exists() else []
    assert not any(n.startswith("churn_") for n in remaining), remaining


# --- ACK escapes ----------------------------------------------------------


def test_loop_ack_clears_loop_file(run_hook, make_input, qg_env, session_id):
    loop = Path(qg_env["QG_DISC_DIR"]) / f"loop-{session_id}"
    loop.write_text("LOOP")
    run_hook("track-activity", make_input("Bash", command="echo LOOP_ACK: tried different angle"))
    assert not loop.exists()


def test_backtrack_ack_clears_backtrack_dir(run_hook, make_input, qg_env, session_id):
    bt = Path(qg_env["QG_DISC_DIR"]) / f"backtrack-{session_id}"
    bt.mkdir()
    (bt / "x-locked").touch()
    run_hook("track-activity", make_input("Bash", command="echo BACKTRACK_ACK: rewrote logic"))
    assert not bt.exists()


def test_test_skip_clears_untested_block(run_hook, make_input, qg_env, session_id):
    block = Path(qg_env["QG_DISC_DIR"]) / f"untested-block-{session_id}"
    block.write_text("11")
    run_hook("track-activity", make_input("Bash", command="echo TEST_SKIP: docs only"))
    assert not block.exists()


# --- Loop detection (bash command repetition) -----------------------------


def test_loop_warns_at_3rd_repetition(run_hook, make_input, qg_env, session_id):
    cmd = "ls -la /tmp/something"
    out = ""
    for _ in range(3):
        r = run_hook("track-activity", make_input("Bash", command=cmd))
        out += r.stdout
    assert "LOOP" in out


def test_loop_blocks_at_6th_repetition(run_hook, make_input, qg_env, session_id):
    cmd = "make build"
    for _ in range(6):
        run_hook("track-activity", make_input("Bash", command=cmd))
    loop = Path(qg_env["QG_DISC_DIR"]) / f"loop-{session_id}"
    assert loop.exists()
    assert "LOOP" in loop.read_text()


def test_ssh_loop_uses_prefix_only(run_hook, make_input, qg_env, session_id):
    """ssh host 'cmd1' and ssh host 'cmd2' should hash to the same loop key."""
    for cmd in (
        "ssh host 'date'",
        "ssh host 'uptime'",
        "ssh host 'who'",
        "ssh host 'ls'",
        "ssh host 'pwd'",
        "ssh host 'whoami'",
    ):
        run_hook("track-activity", make_input("Bash", command=cmd))
    loop = Path(qg_env["QG_DISC_DIR"]) / f"loop-{session_id}"
    assert loop.exists()


def test_unique_commands_do_not_loop(run_hook, make_input, qg_env, session_id):
    for cmd in ("ls", "pwd", "date", "whoami", "uptime", "uname"):
        run_hook("track-activity", make_input("Bash", command=cmd))
    loop = Path(qg_env["QG_DISC_DIR"]) / f"loop-{session_id}"
    assert not loop.exists()
