#!/usr/bin/env python3
"""Smart-merge claude-quality-gate hooks into ~/.claude/settings.json.

Idempotent: re-running adds nothing. Removing only qg-managed entries on
uninstall is supported via --remove.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path

QG_HOOK_NAMES = {
    "pre-read-gate.sh",
    "pre-write-gate.sh",
    "pre-bash-gate.sh",
    "track-activity.sh",
    "auto-verify.sh",
    "on-stop-discipline.sh",
}

DEFAULT_HOOKS = {
    "PreToolUse": [
        {"matcher": "Read",        "hook": "pre-read-gate.sh",  "timeout": 2},
        {"matcher": "Write|Edit",  "hook": "pre-write-gate.sh", "timeout": 3},
        {"matcher": "Bash",        "hook": "pre-bash-gate.sh",  "timeout": 3},
    ],
    "PostToolUse": [
        {"matcher": "Read|Write|Edit|Bash", "hook": "track-activity.sh", "timeout": 3},
        {"matcher": "Write|Edit",           "hook": "auto-verify.sh",    "timeout": 30},
    ],
    "Stop": [
        {"matcher": None, "hook": "on-stop-discipline.sh", "timeout": 5},
    ],
}

DEFAULT_DENY = [
    "Bash(rm -rf *)",
    "Bash(git push --force *)",
    "Bash(git reset --hard *)",
    "Bash(git clean -f *)",
]

DEFAULT_ENV = {"QG_PROFILE": "strict"}


def _hook_path(hooks_dir: Path, name: str) -> str:
    """Use ~ form if path is under HOME, so settings.json stays portable."""
    p = hooks_dir / name
    home = Path.home()
    try:
        rel = p.relative_to(home)
        return f"~/{rel}"
    except ValueError:
        return str(p)


def _is_qg_hook_entry(entry: dict, hooks_dir: Path) -> bool:
    cmd = entry.get("command", "")
    return any(name in cmd for name in QG_HOOK_NAMES)


def _entry_for(matcher, hook_name, hooks_dir: Path, timeout: int) -> dict:
    block = {"hooks": [{"type": "command",
                        "command": _hook_path(hooks_dir, hook_name),
                        "timeout": timeout}]}
    if matcher is not None:
        block["matcher"] = matcher
    return block


def _strip_qg_blocks(hooks_section: dict, hooks_dir: Path) -> dict:
    """Remove any matcher block whose `hooks` list is solely qg-managed."""
    out = {}
    for event, blocks in hooks_section.items():
        new_blocks = []
        for blk in blocks:
            entries = blk.get("hooks", [])
            non_qg = [e for e in entries if not _is_qg_hook_entry(e, hooks_dir)]
            if non_qg:
                # Mixed block — keep the non-qg parts
                clean = {**blk, "hooks": non_qg}
                new_blocks.append(clean)
            # else: pure qg block, drop
        if new_blocks:
            out[event] = new_blocks
    return out


def merge(settings_path: Path, hooks_dir: Path, *, remove: bool = False) -> dict:
    settings = {}
    if settings_path.exists():
        try:
            settings = json.loads(settings_path.read_text())
        except json.JSONDecodeError as e:
            print(f"[qg] settings.json is invalid JSON ({e}). Backing up and starting fresh.")
            backup = settings_path.with_suffix(f".json.bak.{int(time.time())}")
            shutil.copy(settings_path, backup)
            settings = {}

    # Backup if it exists.
    if settings_path.exists():
        backup = settings_path.with_suffix(f".json.bak.{int(time.time())}")
        shutil.copy(settings_path, backup)

    if remove:
        if "hooks" in settings:
            settings["hooks"] = _strip_qg_blocks(settings["hooks"], hooks_dir)
            if not settings["hooks"]:
                del settings["hooks"]
        settings_path.write_text(json.dumps(settings, indent=2) + "\n")
        return settings

    # === MERGE ===

    # 1. env: only set keys that are missing — never overwrite user values.
    env = settings.setdefault("env", {})
    for k, v in DEFAULT_ENV.items():
        env.setdefault(k, v)

    # 2. permissions.deny: append our defaults, dedupe.
    perms = settings.setdefault("permissions", {})
    perms.setdefault("allow", ["Read", "Glob", "Grep", "Edit", "Write", "Bash(*)"])
    deny = perms.setdefault("deny", [])
    for d in DEFAULT_DENY:
        if d not in deny:
            deny.append(d)

    # 3. hooks: strip any pre-existing qg entries (idempotent re-install),
    #          then re-insert our blocks.
    hooks_section = settings.setdefault("hooks", {})
    hooks_section_clean = _strip_qg_blocks(hooks_section, hooks_dir)
    settings["hooks"] = hooks_section_clean

    for event, items in DEFAULT_HOOKS.items():
        blocks = settings["hooks"].setdefault(event, [])
        for item in items:
            blocks.append(_entry_for(item["matcher"], item["hook"], hooks_dir, item["timeout"]))

    settings_path.write_text(json.dumps(settings, indent=2) + "\n")
    return settings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--settings", required=True, help="Path to settings.json")
    parser.add_argument("--hooks-dir", required=True, help="Path to hooks dir")
    parser.add_argument("--remove", action="store_true", help="Remove qg entries instead of adding")
    args = parser.parse_args()

    settings_path = Path(args.settings).expanduser()
    hooks_dir = Path(args.hooks_dir).expanduser()
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    merge(settings_path, hooks_dir, remove=args.remove)
    print(f"[qg] {'removed from' if args.remove else 'merged into'} {settings_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
