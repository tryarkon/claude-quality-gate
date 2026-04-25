#!/usr/bin/env python3
"""bench/swe_ab.py — A/B SWE-bench runner for claude-quality-gate.

Picks one SWE-bench Lite task, clones the repo at base_commit, applies
the test_patch, then runs Claude Code twice on the problem statement:
  A: QG_PROFILE=minimal  (gates effectively off)
  B: QG_PROFILE=strict   (gates on)

For each run records: session_id, wall-clock, tokens, cost, whether
FAIL_TO_PASS tests subsequently pass, and files-modified count.

Requires:  datasets  (for dataset load)  +  claude (auth'd, on PATH)  +  git

Run:  python3 bench/swe_ab.py --task pallets__flask-4045
      python3 bench/swe_ab.py --task pallets__flask-4045 --profiles minimal,strict
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

try:
    from datasets import load_dataset
except ImportError:
    print("Install: pip install datasets")
    sys.exit(1)


def sh(cmd, cwd=None, env=None, timeout=600, check=True):
    """Run a shell command, return (exit_code, stdout, stderr)."""
    proc = subprocess.run(
        cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout,
    )
    if check and proc.returncode != 0:
        print(f"[!] failed: {' '.join(cmd)}\n{proc.stderr[-500:]}")
    return proc.returncode, proc.stdout, proc.stderr


def fetch_task(task_id):
    print(f"[swe] loading dataset, filtering {task_id!r}")
    ds = load_dataset("princeton-nlp/SWE-bench_Lite", split="test")
    for t in ds:
        if t["instance_id"] == task_id:
            return t
    raise SystemExit(f"task {task_id} not in SWE-bench Lite")


def prep_workdir(task, workdir):
    """Clone repo at base_commit into workdir. Apply test_patch."""
    if workdir.exists():
        shutil.rmtree(workdir)
    repo = task["repo"]
    print(f"[prep] cloning https://github.com/{repo} -> {workdir}")
    sh(["git", "clone", "--quiet", f"https://github.com/{repo}.git", str(workdir)])
    sh(["git", "checkout", "--quiet", task["base_commit"]], cwd=str(workdir))
    if task.get("test_patch"):
        patch_file = workdir / ".test.patch"
        patch_file.write_text(task["test_patch"])
        rc, out, err = sh(["git", "apply", str(patch_file)], cwd=str(workdir), check=False)
        if rc != 0:
            print(f"[prep] git apply failed, trying --reject: {err[:200]}")
            sh(["git", "apply", "--reject", str(patch_file)], cwd=str(workdir), check=False)


def install_deps(workdir):
    """Best-effort install of the repo's dev dependencies."""
    print("[prep] installing deps")
    for cmd in (
        ["pip", "install", "--quiet", "--break-system-packages", "-e", ".[dev]"],
        ["pip", "install", "--quiet", "--break-system-packages", "-e", ".[test]"],
        ["pip", "install", "--quiet", "--break-system-packages", "-e", "."],
    ):
        rc, out, err = sh(cmd, cwd=str(workdir), timeout=600, check=False)
        if rc == 0:
            return
    print("[prep] warning: editable install failed, tests may not run")


def run_claude(task, workdir, profile, timeout=1800):
    """Invoke claude -p headless. Return parsed metrics dict."""
    prompt = (task["problem_statement"] + "\n\n" +
              "You are in the project root. Locate the relevant code, make the fix, "
              "and verify by running the affected tests. When the tests pass, commit your changes.")
    env = {**os.environ, "QG_PROFILE": profile}
    print(f"[run] claude -p ... (profile={profile}, cwd={workdir})")
    t0 = time.time()
    proc = subprocess.run(
        ["claude", "-p", prompt, "--output-format", "json",
         "--permission-mode", "acceptEdits"],
        cwd=str(workdir), env=env, capture_output=True, text=True, timeout=timeout,
    )
    wall = time.time() - t0
    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError:
        result = {"is_error": True, "result": proc.stdout[-500:]}
    metrics = {
        "profile":   profile,
        "wall_sec":  round(wall, 1),
        "cost_usd":  result.get("total_cost_usd", 0),
        "tokens_in": result.get("usage", {}).get("input_tokens", 0),
        "tokens_out": result.get("usage", {}).get("output_tokens", 0),
        "num_turns": result.get("num_turns", 0),
        "is_error":  bool(result.get("is_error", True)),
        "session_id": result.get("session_id", ""),
        "final":     (result.get("result", "") or "")[:500],
    }
    return metrics


def post_metrics(task, workdir, metrics):
    """After the claude run, count tests passing + files modified."""
    rc, out, _ = sh(["git", "diff", "--stat", task["base_commit"]],
                    cwd=str(workdir), check=False)
    files_changed = 0
    for line in out.splitlines():
        if "|" in line:
            files_changed += 1
    metrics["files_changed"] = files_changed

    def parse_tests_field(v):
        if isinstance(v, str):
            try:
                return json.loads(v)
            except Exception:
                return [v]
        return v or []

    f2p = parse_tests_field(task.get("FAIL_TO_PASS"))
    p2p = parse_tests_field(task.get("PASS_TO_PASS"))

    def _django_test_name(t):
        """Convert 'test_foo (module.ClassName)' → 'module.ClassName.test_foo'."""
        import re
        m = re.match(r"(\S+)\s+\(([^)]+)\)", t)
        if m:
            return f"{m.group(2)}.{m.group(1)}"
        return t

    def run_tests(test_list, label):
        if not test_list:
            return 0, 0
        import re
        is_django = task.get("repo") == "django/django"
        is_sympy = task.get("repo") == "sympy/sympy"

        if is_django:
            # Django uses its own runtests.py — pytest format doesn't match.
            mapped = [_django_test_name(t) for t in test_list]
            runner = ["python3", "tests/runtests.py", "-v", "0", *mapped]
        else:
            mapped = test_list
            runner = ["python3", "-m", "pytest", "--tb=no", "-q", *mapped]

        rc, out, err = sh(runner, cwd=str(workdir), check=False, timeout=600)
        full = (out or "") + "\n" + (err or "")

        passed = failed = 0
        # pytest format
        m = re.search(r"(\d+) passed", full)
        if m:
            passed = int(m.group(1))
        m = re.search(r"(\d+) failed", full)
        if m:
            failed = int(m.group(1))
        # Django unittest: "Ran N tests in ... OK" / "FAILED (failures=N, errors=M)"
        if passed == 0 and failed == 0:
            m = re.search(r"Ran (\d+) tests?", full)
            total = int(m.group(1)) if m else 0
            failed_m = re.search(r"failures=(\d+)", full)
            errors_m = re.search(r"errors=(\d+)", full)
            failed = (int(failed_m.group(1)) if failed_m else 0) + \
                     (int(errors_m.group(1)) if errors_m else 0)
            if "OK" in full or (total > 0 and failed == 0):
                passed = total
            else:
                passed = max(0, total - failed)
        print(f"[test] {label}: {passed} passed, {failed} failed (rc={rc})")
        return passed, failed

    metrics["fail2pass_passed"], metrics["fail2pass_failed"] = run_tests(f2p, "FAIL_TO_PASS")
    metrics["pass2pass_passed"], metrics["pass2pass_failed"] = run_tests(p2p[:10], "PASS_TO_PASS (sample 10)")
    metrics["solved"] = metrics["fail2pass_failed"] == 0 and metrics["fail2pass_passed"] > 0
    return metrics


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--task", required=True)
    p.add_argument("--profiles", default="minimal,strict")
    p.add_argument("--workdir-base", default="/tmp/swe-ab")
    p.add_argument("--skip-setup", action="store_true")
    p.add_argument("--output", default="bench/swe_ab_results.json")
    args = p.parse_args()

    task = fetch_task(args.task)
    print(f"\n[task] {task['instance_id']}  ({task['repo']})")
    print(f"[task] base: {task['base_commit'][:12]}")
    print(f"[task] FAIL_TO_PASS: {task['FAIL_TO_PASS']}\n")

    results = []
    for profile in args.profiles.split(","):
        profile = profile.strip()
        workdir = Path(f"{args.workdir_base}-{profile}")
        if not args.skip_setup:
            prep_workdir(task, workdir)
            install_deps(workdir)
        metrics = run_claude(task, workdir, profile)
        metrics = post_metrics(task, workdir, metrics)
        results.append(metrics)
        print(f"\n[summary:{profile}] {json.dumps(metrics, indent=2)}\n")

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps({"task": task["instance_id"], "runs": results}, indent=2))
    print(f"\n[done] results -> {out_path}")

    if len(results) == 2:
        a, b = results
        print("\n=== A/B comparison ===")
        print(f"{'metric':<18} {'A ('+a['profile']+')':<20} {'B ('+b['profile']+')':<20}")
        for k in ("wall_sec", "cost_usd", "tokens_in", "tokens_out", "num_turns",
                  "files_changed", "fail2pass_passed", "fail2pass_failed",
                  "pass2pass_passed", "pass2pass_failed", "solved", "is_error"):
            print(f"{k:<18} {str(a.get(k,'-')):<20} {str(b.get(k,'-')):<20}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
