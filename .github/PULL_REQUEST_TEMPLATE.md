## What does this PR do

Brief description.

## Type

- [ ] Bug fix
- [ ] New hook
- [ ] Refactor (please read CONTRIBUTING.md first — refactors are usually closed)
- [ ] Doc fix
- [ ] CI / build

## Checklist

- [ ] `pytest tests/` passes locally on macOS or Linux
- [ ] If adding a hook: tests cover allow path, deny path, profile=standard, profile=minimal, disable-by-tag
- [ ] If adding a hook: documentation added to `docs/HOOKS.md` matching existing format
- [ ] Bash 3.2 compatible (no `${var:1:-1}`, no `declare -A`, no `mapfile`)
- [ ] Python is stdlib only (no `pip install`)
- [ ] Cross-platform `md5` (use `md5_string` / `md5_file` from `hook-utils.sh`)
- [ ] Updated `CHANGELOG.md` under `## Unreleased`

## Why

Link to a concrete agent failure that motivates this. *"This would be nice"* PRs are usually closed.
