---
name: Feature request
about: Suggest a new gate or behavior
labels: enhancement
---

## The problem

What agent failure mode are you seeing? Be concrete — *"the agent keeps doing X, here's a transcript snippet"*.

## Proposed gate

What should the new hook check for, and what should it block / warn / inform?

| Field | Value |
|---|---|
| Event | `PreToolUse` / `PostToolUse` / `Stop` |
| Tool matcher | `Bash` / `Write` / `Edit` / `Read` / etc. |
| Disable tag | proposed kebab-case tag name |
| Strict behavior | block / warn |
| Standard behavior | warn / silent |
| Escape mechanism | `XYZ_ACK:` / re-Read / disable tag / none |

## Alternatives considered

What else could solve this? `.cursorrules`? A pre-commit hook? Manual review?

## Are you offering to implement it?

(Yes/No — see [`CONTRIBUTING.md`](../../CONTRIBUTING.md) for what we're likely to merge.)
