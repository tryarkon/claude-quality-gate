# Contributing

Thanks for your interest in `claude-quality-gate`. Before you spend time on a contribution, please read this honestly.

## What this project is

This is an artifact. We use it in our own production setup. We open-sourced it because (a) the design pattern is reusable and (b) we wanted the OSS-program eligibility that comes with a public Apache-2.0 repo.

## What this project is not

- **Not a community project.** We may not respond to issues for weeks at a time. Please don't take this personally — we're not staffed for it.
- **Not a framework with a roadmap.** We add features when our internal use surfaces a need. We don't accept "nice-to-have" features that don't address a concrete problem.
- **Not promised to be backwards-compatible** before 1.0. The hook contract follows Claude Code's; the env var names and state file paths are ours and may change.

## What we will likely do with your PR

- **Bug fix with a test:** merged within a week or two if the fix is correct.
- **New hook with tests and docs:** considered, may be merged or may be suggested as a separate plugin.
- **Refactor of existing hooks:** likely closed unless it's a clear win on readability or correctness. Stability matters more than elegance here.
- **Doc fix:** merged quickly.
- **Feature request without PR:** may sit in issues for a long time. Hard forks are encouraged if you need it sooner.

## How to contribute well

### Setup

```bash
git clone https://github.com/tryarkon/claude-quality-gate
cd claude-quality-gate
pytest tests/                     # run the suite
```

You need: bash 3.2+, python3, `md5` or `md5sum`. That's it.

### Tests

There are 100+ tests across `tests/test_*.py`. They invoke the hooks as subprocesses with crafted JSON stdin and assert on exit code, stdout, stderr. Adding a hook means adding tests. The bar is **all tests must still pass**.

```bash
pytest tests/                     # all
pytest tests/test_pre_bash_gate.py # one file
pytest tests/ -k freshness        # one feature
pytest tests/ -x                  # stop on first failure
```

### Code style

- **Bash 3.2 compatible.** macOS ships 3.2. No `${var:1:-1}` slicing, no associative arrays (`declare -A`), no `mapfile`/`readarray`. `[ ]` over `[[ ]]` where there's no functional difference.
- **Python is stdlib only.** We use `python3 -c "import json, sys; ..."` for JSON parsing. No `pip install` ever.
- **Cross-platform `md5`.** Use `md5_string` / `md5_file` / `md5_short` from `hook-utils.sh` — they handle macOS (`md5`) vs Linux (`md5sum`).
- **Atomic writes.** State files are read by sibling hooks. Use `atomic_write` (or `mv` from `.tmp.$$`) — never write directly.
- **English only** in source, comments, doc strings, error messages. The project is OSS for an English-speaking audience.
- **`log_metric` your decisions.** Every block, warn, and ack should produce a metric line — that's what the dashboard renders.

### Adding a new hook

1. Read [`docs/CUSTOMIZATION.md`](./docs/CUSTOMIZATION.md).
2. Pick a tag for the disable mechanism. Keep it short, kebab-case (e.g. `npm-vuln`, `branch-naming`).
3. Implement under `hooks/your-hook.sh`. Follow the skeleton in `CUSTOMIZATION.md`.
4. Add tests under `tests/test_your_hook.py`. Cover: allow path, deny path, profile=standard downgrade, profile=minimal skip, disable-by-tag.
5. Add a section to `docs/HOOKS.md` matching the existing format.
6. Add the hook to `examples/settings.json` if it should be on by default.
7. Update `CHANGELOG.md` under `Unreleased`.

### Updating docs

Docs live in `docs/`, plus the four root files (`README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`). Style notes:

- Keep examples concrete. No "for instance, you might want to do something like..." — show the actual command.
- Mock outputs should be plausible — match the format the hooks actually produce.
- No emojis except in mock outputs (where the hooks themselves use them as severity markers).

## Reporting bugs

Open an issue with:

1. Your `QG_PROFILE` and `QG_DISABLED_HOOKS` values.
2. Your OS (`uname -a`) and bash version (`bash --version`).
3. The shipped command line that triggered the bug.
4. Expected vs actual behavior.
5. Relevant log lines from `$QG_METRICS_LOG` (default `/tmp/qg-metrics.log`).

## Reporting security issues

See [`SECURITY.md`](./SECURITY.md). Don't open public issues for security problems.

## License

By contributing you agree your contribution will be licensed under Apache-2.0, the same as the project.
