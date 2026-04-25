"""pre-bash-gate: workaround / SQL / deploy / commit-format gates."""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest


def _bash(cmd_input: str, env: dict, hook: Path) -> tuple[int, str, str]:
    p = subprocess.run(
        ["bash", str(hook)],
        input=cmd_input,
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
    )
    return p.returncode, p.stdout, p.stderr


# --- workaround patterns: deny in strict ---------------------------------


@pytest.mark.parametrize(
    "command,fragment",
    [
        ("git commit --no-verify -m 'fix: x'", "no-verify"),
        ("git push --force origin main", "force"),
        ("pytest --skip-tests", "skip"),
        ("cargo build --no-check", "skip"),
        ("npm test || true", "true"),
        ("pytest 2>/dev/null", "/dev/null"),
        ("DISABLE_AUTH=1 pytest", "DISABLE_"),
        ("SKIP_LINT=1 npm run build", "SKIP_"),
        ("sed -i '/assert/d' code.py", "sed"),
        ("git checkout .", "discards"),
        ("git restore --", "discards"),
        ("rm -rf src/", "source"),
    ],
)
def test_workaround_patterns_blocked(run_hook, make_input, command, fragment):
    r = run_hook("pre-bash-gate", make_input("Bash", command=command))
    assert r.denied, f"expected deny for {command!r}, got {r}"
    assert fragment.lower() in r.stderr.lower()


def test_safe_command_passes(run_hook, make_input):
    r = run_hook("pre-bash-gate", make_input("Bash", command="ls -la"))
    assert r.allowed
    assert r.stdout == ""


def test_workaround_warns_in_standard(run_hook, make_input):
    r = run_hook(
        "pre-bash-gate",
        make_input("Bash", command="git push --force origin main"),
        extra_env={"QG_PROFILE": "standard"},
    )
    assert r.allowed
    assert "WORKAROUND" in r.stdout or "WARNING" in r.stdout


def test_minimal_profile_skips(run_hook, make_input):
    r = run_hook(
        "pre-bash-gate",
        make_input("Bash", command="git commit --no-verify -m x"),
        extra_env={"QG_PROFILE": "minimal"},
    )
    assert r.allowed


def test_disabled_via_env(run_hook, make_input):
    r = run_hook(
        "pre-bash-gate",
        make_input("Bash", command="git commit --no-verify -m x"),
        extra_env={"QG_DISABLED_HOOKS": "workaround"},
    )
    assert r.allowed


def test_intentional_marker_bypasses(run_hook, make_input):
    r = run_hook(
        "pre-bash-gate",
        make_input("Bash", command="git push --force origin main # INTENTIONAL: rewrite"),
    )
    assert r.allowed


def test_install_commands_whitelisted(run_hook, make_input):
    for cmd in ("pip install ruff", "npm install", "brew install python", "docker ps"):
        r = run_hook("pre-bash-gate", make_input("Bash", command=cmd))
        assert r.allowed, f"{cmd} should pass: {r}"


# --- SQL safety ----------------------------------------------------------


@pytest.mark.parametrize(
    "command",
    [
        "sqlite3 prod.db 'DROP TABLE users;'",
        "psql -c 'TRUNCATE TABLE orders;'",
        "psql -c 'DELETE FROM users;'",
        "sqlite3 db 'DELETE FROM users WHERE 1;'",
    ],
)
def test_destructive_sql_blocked(run_hook, make_input, command):
    r = run_hook("pre-bash-gate", make_input("Bash", command=command))
    assert r.denied, r


def test_temp_db_paths_skipped(run_hook, make_input):
    for cmd in (
        "sqlite3 :memory: 'DROP TABLE x;'",
        "sqlite3 /tmp/test.db 'DROP TABLE x;'",
    ):
        r = run_hook("pre-bash-gate", make_input("Bash", command=cmd))
        assert r.allowed, f"{cmd} should pass: {r}"


def test_delete_with_where_passes(run_hook, make_input):
    r = run_hook(
        "pre-bash-gate",
        make_input("Bash", command="psql -c 'DELETE FROM users WHERE id = 5;'"),
    )
    assert r.allowed


# --- conventional-commits ------------------------------------------------


@pytest.mark.parametrize(
    "msg,ok",
    [
        ("feat: add x", True),
        ("fix(api): wrong header", True),
        ("chore!: drop python 3.8", True),
        ("docs: update README", True),
        ("just fixing some stuff", False),
        ("WIP", False),
        ("update code", False),
    ],
)
def test_conventional_commit_format(run_hook, make_input, msg, ok):
    r = run_hook("pre-bash-gate", make_input("Bash", command=f"git commit -m '{msg}'"))
    if ok:
        assert r.allowed, f"{msg!r} should pass: {r}"
    else:
        assert r.denied, f"{msg!r} should be denied: {r}"
        assert "conventional" in r.stderr.lower()


def test_conventional_disabled(run_hook, make_input):
    r = run_hook(
        "pre-bash-gate",
        make_input("Bash", command="git commit -m 'just fixing'"),
        extra_env={"QG_DISABLED_HOOKS": "conventional-commits,changelog-gate"},
    )
    assert r.allowed


def test_auto_save_messages_whitelisted(run_hook, make_input):
    for msg in ("auto-save xyz", "auto-sync host", "auto-commit 12:00"):
        r = run_hook("pre-bash-gate", make_input("Bash", command=f"git commit -m '{msg}'"))
        assert r.allowed, f"{msg} should pass: {r}"


# --- CHANGELOG_ACK escape -------------------------------------------------


def test_changelog_ack_marker_passes(run_hook, make_input):
    r = run_hook(
        "pre-bash-gate",
        make_input("Bash", command="echo CHANGELOG_ACK: emergency hotfix"),
    )
    assert r.allowed


# --- deploy-gate ----------------------------------------------------------


def test_deploy_blocked_when_untested(run_hook, make_input, qg_env, session_id):
    Path(qg_env["QG_DISC_DIR"]).joinpath(f"deploy-block-{session_id}").write_text("12")
    r = run_hook(
        "pre-bash-gate",
        make_input("Bash", command="rsync -av build/ host:/var/www/"),
    )
    assert r.denied
    assert "DEPLOY" in r.stderr


def test_deploy_passes_when_no_block(run_hook, make_input):
    r = run_hook(
        "pre-bash-gate",
        make_input("Bash", command="rsync -av build/ host:/var/www/"),
    )
    assert r.allowed


def test_deploy_warns_in_standard(run_hook, make_input, qg_env, session_id):
    Path(qg_env["QG_DISC_DIR"]).joinpath(f"deploy-block-{session_id}").write_text("8")
    r = run_hook(
        "pre-bash-gate",
        make_input("Bash", command="scp build/x host:/var/www/"),
        extra_env={"QG_PROFILE": "standard"},
    )
    assert r.allowed
    assert "DEPLOY" in r.stdout
