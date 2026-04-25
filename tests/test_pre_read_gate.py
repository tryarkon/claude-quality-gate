"""pre-read-gate: warns/blocks on Read of large files; respects offset & whitelisted extensions."""
from __future__ import annotations


def test_small_file_passes_silently(run_hook, make_input, write_lines):
    f = write_lines("small.py", 50)
    r = run_hook("pre-read-gate", make_input("Read", file_path=str(f)))
    assert r.allowed
    assert r.stdout == ""


def test_mid_file_emits_soft_hint(run_hook, make_input, write_lines):
    f = write_lines("mid.py", 150)
    r = run_hook("pre-read-gate", make_input("Read", file_path=str(f)))
    assert r.allowed
    assert "lines" in r.stdout
    payload = r.stdout_json()
    assert payload and payload["hookSpecificOutput"]["permissionDecision"] == "allow"


def test_medium_file_warns_with_offset_suggestion(run_hook, make_input, write_lines):
    f = write_lines("medium.py", 250)
    r = run_hook("pre-read-gate", make_input("Read", file_path=str(f)))
    assert r.allowed
    assert "offset" in r.stdout.lower() or "lsp" in r.stdout.lower()


def test_large_file_blocked_in_strict(run_hook, make_input, write_lines):
    f = write_lines("big.py", 500)
    r = run_hook("pre-read-gate", make_input("Read", file_path=str(f)))
    assert r.denied, r
    assert "300 lines" in r.stderr or "500 lines" in r.stderr or "lines" in r.stderr.lower()


def test_large_file_warns_in_standard(run_hook, make_input, write_lines):
    f = write_lines("big.py", 500)
    r = run_hook(
        "pre-read-gate",
        make_input("Read", file_path=str(f)),
        extra_env={"QG_PROFILE": "standard"},
    )
    assert r.allowed
    assert "lines" in r.stdout.lower()


def test_offset_passes_large_file(run_hook, make_input, write_lines):
    f = write_lines("big.py", 500)
    r = run_hook("pre-read-gate", make_input("Read", file_path=str(f), offset=100, limit=200))
    assert r.allowed
    assert r.stdout == ""


def test_limit_alone_passes_large_file(run_hook, make_input, write_lines):
    f = write_lines("big.py", 500)
    r = run_hook("pre-read-gate", make_input("Read", file_path=str(f), limit=50))
    assert r.allowed


def test_minimal_profile_skips_check(run_hook, make_input, write_lines):
    f = write_lines("big.py", 500)
    r = run_hook(
        "pre-read-gate",
        make_input("Read", file_path=str(f)),
        extra_env={"QG_PROFILE": "minimal"},
    )
    assert r.allowed
    assert r.stdout == ""


def test_disabled_via_env(run_hook, make_input, write_lines):
    f = write_lines("big.py", 500)
    r = run_hook(
        "pre-read-gate",
        make_input("Read", file_path=str(f)),
        extra_env={"QG_DISABLED_HOOKS": "read-gate"},
    )
    assert r.allowed


def test_md_extension_whitelisted(run_hook, make_input, write_lines):
    f = write_lines("big.md", 500)
    r = run_hook("pre-read-gate", make_input("Read", file_path=str(f)))
    assert r.allowed
    assert r.stdout == ""


def test_json_extension_whitelisted(run_hook, make_input, write_lines):
    f = write_lines("big.json", 500)
    r = run_hook("pre-read-gate", make_input("Read", file_path=str(f)))
    assert r.allowed
    assert r.stdout == ""


def test_yaml_extension_whitelisted(run_hook, make_input, write_lines):
    f = write_lines("big.yaml", 500)
    r = run_hook("pre-read-gate", make_input("Read", file_path=str(f)))
    assert r.allowed


def test_nonexistent_file_passes(run_hook, make_input, tmp_path):
    r = run_hook("pre-read-gate", make_input("Read", file_path=str(tmp_path / "nope.py")))
    assert r.allowed
    assert r.stdout == ""
