# Changelog

## 0.1.0 — 2026-04-24

Initial public release.

### Hooks

- `pre-read-gate.sh` — block/warn on large file reads (>300 lines without `offset`/`limit`)
- `pre-write-gate.sh` — freshness check, concurrent-edit warn, loop block, backtrack lock, untested-edit gate, 3-file plan gate, 5-file commit reminder
- `pre-bash-gate.sh` — workaround detection (`--no-verify`, `|| true`, `2>/dev/null` on tests, `SKIP_*=`, `sed` deleting asserts, `git checkout .`, `rm -rf src/`), destructive SQL gate, deploy-without-tests gate, conventional-commits format gate, CHANGELOG-stale gate
- `track-activity.sh` — stateful per-session tracker (freshness hashes, churn counters, untested-edit counter, loop detection with ssh-prefix hashing, ACK escapes)
- `auto-verify.sh` — `cargo check` / `tsc --noEmit` / `ruff check` after Write/Edit
- `on-stop-discipline.sh` — Definition-of-Done gate at session end with progressive escalation (1st warn → 2nd warn → 3rd hard-gate for tests/commits)
- `hook-utils.sh` — shared lib (parse_input, json helpers, hu_state_op, profile/disable, metrics)

### Tooling

- `qg` CLI — install/uninstall/status/config/dashboard/test/version
- `install.sh` — one-line installer for macOS / Linux / WSL
- `install.ps1` — Windows installer (Git Bash or WSL)
- `merge_settings.py` — idempotent settings.json merger that preserves user keys
- `dashboard.py` + UI — local web dashboard at `http://localhost:7777` (zero deps, vanilla JS, Neon Night theme)
- `bench/ab.sh` — reproducible A/B benchmark vs gates-off baseline

### Tests

- 104 pytest tests across 6 hook test files + conftest with isolated tmp_path fixtures
- Bash 3.2 compatible (macOS default shell)
- Python stdlib only

### Documentation

- `README.md` — marketing-grade overview
- `docs/PHILOSOPHY.md` — the six principles (mechanical, architectural, root-cause, stateful, strict-default, progressive-escalation)
- `docs/HOOKS.md` — full per-hook reference (what blocks, what allows, override mechanism, configuration, example output)
- `docs/QUICKSTART.md` — 60-second install-to-first-block
- `docs/COMPARISON.md` — vs `.cursorrules` / husky / pre-commit / Guardrails AI / Cursor / Aider
- `docs/CUSTOMIZATION.md` — write your own hook on top of `hook-utils.sh` with worked example
- `docs/METRICS.md` — dashboard math, savings model, A/B protocol
- `docs/WINDOWS.md` — Git Bash vs WSL setup, troubleshooting
- `docs/CASE-STUDY.md` — A/B benchmark result (0 vs 11 of 14 actions blocked)
- `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`

### Bug fixes during testing

The test suite exposed three real bugs in the extracted hooks:

- `hook-utils.sh` — `${var:1:-1}` substring expansion is bash 4.4+, broke on macOS bash 3.2. Replaced with `${var#\"}` / `${var%\"}`.
- `pre-bash-gate.sh` — regex for `git checkout/restore` discard pattern required at least one dash, missed the canonical `git checkout .`. Pattern rewritten.
- `pre-bash-gate.sh` — conventional-commits parser used nested bash quoting inside `python3 -c "..."` which Heredoc-escaped wrong; rewritten in pure `sed`/`awk` with no Python.
- `track-activity.sh` — `h16()` piped `echo -n` into `md5_string` which doesn't read stdin → all commands hashed identically → loop block triggered on any 6 commands. Single-character fix.

### Notes

- File-based per-session state (no SQLite, no daemon).
- All comments and messages in English.
- Bash 3.2 compatible; Python stdlib only (no third-party deps).
