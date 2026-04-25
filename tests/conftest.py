"""Pytest fixtures for claude-quality-gate hook tests.

Each hook is a bash script that reads JSON from stdin and exits with:
  0 — allow / pass (optional JSON or context on stdout)
  2 — deny / block (reason on stderr)

All hooks honour QG_* env vars for state-dir isolation, which lets us run
every test inside a clean tmp_path without touching real /tmp state.
"""
from __future__ import annotations

import json
import os
import subprocess
import uuid
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
HOOKS_DIR = PROJECT_ROOT / "hooks"


@pytest.fixture
def hooks_dir() -> Path:
    return HOOKS_DIR


@pytest.fixture
def session_id() -> str:
    return f"test-{uuid.uuid4().hex[:12]}"


@pytest.fixture
def qg_env(tmp_path: Path, monkeypatch) -> dict:
    """Isolate every state dir into tmp_path and return the env dict.

    Tests that call run_hook receive this env automatically; tests that
    invoke bash subprocesses manually can pass it as the env= argument.
    """
    disc = tmp_path / "disc"
    reads = tmp_path / "reads"
    state = tmp_path / "state"
    plans = tmp_path / "plans"
    metrics = tmp_path / "metrics.log"
    for d in (disc, reads, state, plans):
        d.mkdir(parents=True, exist_ok=True)

    env = {
        "QG_DISC_DIR": str(disc),
        "QG_CC_READS_DIR": str(reads),
        "QG_CC_HOOKS_DIR": str(state),
        "QG_PLANS_DIR": str(plans),
        "QG_METRICS_LOG": str(metrics),
        "QG_PROFILE": "strict",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(tmp_path / "home"),
    }
    (tmp_path / "home").mkdir(exist_ok=True)
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    return env


class HookResult:
    def __init__(self, returncode: int, stdout: str, stderr: str):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr

    @property
    def allowed(self) -> bool:
        return self.returncode == 0

    @property
    def denied(self) -> bool:
        return self.returncode == 2

    def stdout_json(self) -> dict | None:
        if not self.stdout.strip():
            return None
        try:
            return json.loads(self.stdout)
        except json.JSONDecodeError:
            return None

    def __repr__(self) -> str:
        return (
            f"HookResult(rc={self.returncode}, "
            f"stdout={self.stdout!r}, stderr={self.stderr!r})"
        )


@pytest.fixture
def run_hook(hooks_dir, qg_env):
    """Run hook by bare name. Returns HookResult."""

    def _run(hook_name: str, payload: dict, extra_env: dict | None = None) -> HookResult:
        script = hooks_dir / f"{hook_name}.sh"
        assert script.exists(), f"hook {script} not found"
        env = dict(qg_env)
        if extra_env:
            env.update(extra_env)
        proc = subprocess.run(
            ["bash", str(script)],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            env=env,
            timeout=10,
        )
        return HookResult(proc.returncode, proc.stdout, proc.stderr)

    return _run


@pytest.fixture
def make_input(session_id):
    """Build the JSON payload Claude Code sends to a hook."""

    def _make(
        tool_name: str = "",
        file_path: str = "",
        command: str = "",
        offset: int | None = None,
        limit: int | None = None,
        cwd: str = "",
        stop_hook_active: bool = False,
        sid: str | None = None,
    ) -> dict:
        tool_input: dict = {}
        if file_path:
            tool_input["file_path"] = file_path
        if command:
            tool_input["command"] = command
        if offset is not None:
            tool_input["offset"] = offset
        if limit is not None:
            tool_input["limit"] = limit
        return {
            "session_id": sid or session_id,
            "tool_name": tool_name,
            "tool_input": tool_input,
            "cwd": cwd,
            "stop_hook_active": stop_hook_active,
        }

    return _make


@pytest.fixture
def write_lines(tmp_path):
    """Helper: create a file in tmp_path with N lines. Returns its path."""

    def _make(name: str, n: int, content: str = "x") -> Path:
        p = tmp_path / name
        p.write_text("\n".join(f"{content}{i}" for i in range(n)) + "\n")
        return p

    return _make
