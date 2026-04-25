"""auto-verify: cargo / tsc / ruff after Write/Edit. Tool-presence is opportunistic."""
from __future__ import annotations

import shutil

import pytest

ruff_present = shutil.which("ruff") is not None


def test_no_file_path_skips(run_hook, make_input):
    r = run_hook("auto-verify", make_input("Write"))
    assert r.allowed
    assert r.stdout == ""


def test_unknown_extension_skips(run_hook, make_input, tmp_path):
    f = tmp_path / "notes.txt"
    f.write_text("hello\n")
    r = run_hook("auto-verify", make_input("Write", file_path=str(f)))
    assert r.allowed
    assert r.stdout == ""


def test_minimal_profile_skips(run_hook, make_input, tmp_path):
    f = tmp_path / "x.py"
    f.write_text("import sys\nsys.exit(\n")  # syntax error
    r = run_hook(
        "auto-verify",
        make_input("Write", file_path=str(f)),
        extra_env={"QG_PROFILE": "minimal"},
    )
    assert r.allowed
    assert r.stdout == ""


def test_disabled_via_env(run_hook, make_input, tmp_path):
    f = tmp_path / "x.py"
    f.write_text("def broken(:\n")
    r = run_hook(
        "auto-verify",
        make_input("Write", file_path=str(f)),
        extra_env={"QG_DISABLED_HOOKS": "auto-verify"},
    )
    assert r.allowed
    assert r.stdout == ""


@pytest.mark.skipif(not ruff_present, reason="ruff not installed")
def test_ruff_clean_file_silent(run_hook, make_input, tmp_path):
    f = tmp_path / "good.py"
    f.write_text("x = 1\n")
    r = run_hook("auto-verify", make_input("Write", file_path=str(f)))
    assert r.allowed
    assert r.stdout == ""


@pytest.mark.skipif(not ruff_present, reason="ruff not installed")
def test_ruff_broken_file_emits_context(run_hook, make_input, tmp_path):
    f = tmp_path / "bad.py"
    f.write_text("def broken(:\n")
    r = run_hook("auto-verify", make_input("Write", file_path=str(f)))
    assert r.allowed
    assert "ruff" in r.stdout.lower() or "FAILED" in r.stdout
