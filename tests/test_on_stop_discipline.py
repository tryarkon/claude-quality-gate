"""on-stop-discipline: Definition-of-Done gate at session stop."""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest


def _git_init(d: Path):
    subprocess.run(
        ["git", "init", "-q", "-b", "main", str(d)],
        check=True,
        capture_output=True,
    )
    subprocess.run(["git", "-C", str(d), "config", "user.email", "t@t"], check=True)
    subprocess.run(["git", "-C", str(d), "config", "user.name", "t"], check=True)


def _seed_session(qg_env, sid, files):
    sf = Path(qg_env["QG_DISC_DIR"]) / f"session-{sid}"
    sf.write_text("\n".join(files) + "\n")
    return sf


def test_no_session_passes(run_hook, make_input):
    r = run_hook("on-stop-discipline", make_input(cwd="/tmp"))
    assert r.allowed
    assert r.stdout == "" and r.stderr == ""


def test_trivial_edits_pass(run_hook, make_input, qg_env, session_id, tmp_path):
    _seed_session(qg_env, session_id, [str(tmp_path / "README.md")])
    r = run_hook("on-stop-discipline", make_input(cwd=str(tmp_path)))
    assert r.allowed


def test_stop_hook_active_short_circuits(run_hook, make_input, qg_env, session_id, tmp_path):
    _seed_session(
        qg_env,
        session_id,
        [str(tmp_path / f"f{i}.py") for i in range(5)],
    )
    r = run_hook(
        "on-stop-discipline",
        make_input(cwd=str(tmp_path), stop_hook_active=True),
    )
    assert r.allowed


def test_code_files_without_tests_block_first_attempt(
    run_hook, make_input, qg_env, session_id, tmp_path
):
    # Make HAS_TESTS=true via pyproject.toml; no tests-ran flag → block.
    _git_init(tmp_path)
    (tmp_path / "pyproject.toml").write_text("[tool.poetry]\nname='x'\n")
    files = [str(tmp_path / f"f{i}.py") for i in range(3)]
    for f in files:
        Path(f).write_text("x\n")
    _seed_session(qg_env, session_id, files)
    # Commit so they aren't dirty (we want only the tests-not-run violation).
    subprocess.run(["git", "-C", str(tmp_path), "add", "."], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(tmp_path), "commit", "-q", "-m", "init"],
        check=True,
        capture_output=True,
    )

    r = run_hook("on-stop-discipline", make_input(cwd=str(tmp_path)))
    assert r.denied, r
    assert "TESTS NOT RUN" in r.stderr or "TESTS" in r.stderr.upper()


def test_tests_ran_flag_unblocks(run_hook, make_input, qg_env, session_id, tmp_path):
    _git_init(tmp_path)
    (tmp_path / "pyproject.toml").write_text("[tool.poetry]\nname='x'\n")
    files = [str(tmp_path / f"f{i}.py") for i in range(3)]
    for f in files:
        Path(f).write_text("x\n")
    _seed_session(qg_env, session_id, files)
    subprocess.run(["git", "-C", str(tmp_path), "add", "."], check=True, capture_output=True)
    subprocess.run(
        ["git", "-C", str(tmp_path), "commit", "-q", "-m", "init"],
        check=True,
        capture_output=True,
    )
    Path(qg_env["QG_DISC_DIR"]).joinpath(f"tests-ran-{session_id}").touch()

    r = run_hook("on-stop-discipline", make_input(cwd=str(tmp_path)))
    assert r.allowed, r


def test_uncommitted_changes_block(run_hook, make_input, qg_env, session_id, tmp_path):
    _git_init(tmp_path)
    files = [str(tmp_path / f"f{i}.py") for i in range(3)]
    for f in files:
        Path(f).write_text("x\n")
    _seed_session(qg_env, session_id, files)
    Path(qg_env["QG_DISC_DIR"]).joinpath(f"tests-ran-{session_id}").touch()

    r = run_hook("on-stop-discipline", make_input(cwd=str(tmp_path)))
    assert r.denied
    assert "UNCOMMITTED" in r.stderr


def test_progressive_escalation_2nd_attempt_repeat(
    run_hook, make_input, qg_env, session_id, tmp_path
):
    _git_init(tmp_path)
    files = [str(tmp_path / f"f{i}.py") for i in range(3)]
    for f in files:
        Path(f).write_text("x\n")
    _seed_session(qg_env, session_id, files)
    Path(qg_env["QG_DISC_DIR"]).joinpath(f"tests-ran-{session_id}").touch()

    r1 = run_hook("on-stop-discipline", make_input(cwd=str(tmp_path)))
    r2 = run_hook("on-stop-discipline", make_input(cwd=str(tmp_path)))
    assert r1.denied and r2.denied
    assert "REPEAT" in r2.stderr or "2/3" in r2.stderr


def test_3rd_attempt_uncommitted_hard_gates(
    run_hook, make_input, qg_env, session_id, tmp_path
):
    _git_init(tmp_path)
    files = [str(tmp_path / f"f{i}.py") for i in range(3)]
    for f in files:
        Path(f).write_text("x\n")
    _seed_session(qg_env, session_id, files)
    Path(qg_env["QG_DISC_DIR"]).joinpath(f"tests-ran-{session_id}").touch()

    for _ in range(3):
        r = run_hook("on-stop-discipline", make_input(cwd=str(tmp_path)))
    assert r.denied
    assert "MANDATORY" in r.stderr or "COMMIT" in r.stderr


def test_disabled_via_env(run_hook, make_input, qg_env, session_id, tmp_path):
    _git_init(tmp_path)
    files = [str(tmp_path / f"f{i}.py") for i in range(3)]
    for f in files:
        Path(f).write_text("x\n")
    _seed_session(qg_env, session_id, files)

    r = run_hook(
        "on-stop-discipline",
        make_input(cwd=str(tmp_path)),
        extra_env={"QG_PROFILE": "minimal"},
    )
    assert r.allowed


def test_standard_profile_warns_not_blocks(
    run_hook, make_input, qg_env, session_id, tmp_path
):
    _git_init(tmp_path)
    files = [str(tmp_path / f"f{i}.py") for i in range(3)]
    for f in files:
        Path(f).write_text("x\n")
    _seed_session(qg_env, session_id, files)

    r = run_hook(
        "on-stop-discipline",
        make_input(cwd=str(tmp_path)),
        extra_env={"QG_PROFILE": "standard"},
    )
    assert r.allowed
    assert "RECOMMEND" in r.stderr or "UNCOMMITTED" in r.stderr
