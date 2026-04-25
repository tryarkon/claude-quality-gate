# Comparison

A fair look at how `claude-quality-gate` relates to neighbouring tools. None of these are direct competitors — they operate at different layers — but each one has overlap somewhere, and choosing between them comes down to which layer you actually need to control.

## At a glance

| Tool | Enforcement | State | Scope | Layer | Languages | Install effort | Opinionated |
|---|---|---|---|---|---|---|---|
| **claude-quality-gate** | Mechanical (exit 2) | Stateful, per-session | Session, file, command | Agent action | Any | One script + settings.json | Strict by default |
| `.cursorrules` / `CLAUDE.md` | Advisory (prompt) | Stateless | Project | Prompt | Any | One file | None — you write it |
| `husky` / `lint-staged` | Mechanical (exit 1) | Stateless | Git stage | Git stage | Any | npm + config | Per-rule |
| `pre-commit` (Python) | Mechanical (exit 1) | Stateless | Git stage | Git stage | Any | pip + yaml | Per-hook |
| Guardrails AI | Mechanical (validator) | Stateless | LLM output | LLM output | LLM-agnostic | pip + schema | Per-validator |
| NeMo Guardrails | Mechanical (rail) | Stateful (conv-level) | LLM I/O | LLM I/O | LLM-agnostic | pip + colang | Per-rail |
| Cursor built-in rules | Advisory + IDE blocks | Mostly stateless | Project, file | Prompt + IDE | Any | Built into Cursor | Mild defaults |
| Aider `--auto-commits` etc | Mechanical (single feature) | Stateless | Per command | Agent action | Any | Aider flag | Mild |
| Vanilla Claude Code | None | N/A | N/A | N/A | Any | N/A | None |

## What each row means in plain English

**Enforcement.** *Advisory* means the rule is text the model reads and may ignore. *Mechanical* means a process returns a non-zero exit code and the action does not happen.

**State.** *Stateless* checks one input at a time and forgets. *Stateful* remembers across calls — "you've done this 5 times now", "you read this file 10 minutes ago".

**Scope.** What unit the tool reasons about: a single file, a git commit, a session, a project, a conversation.

**Layer.** *Prompt* = before the LLM generates. *LLM output* = after the LLM generates, before action. *Agent action* = after action plan, before execution. *Git stage* = after execution, before commit.

**Opinionated.** Whether the tool ships with strong defaults, or expects you to configure everything from scratch.

## Trade-offs

### If you want prompt-level steering, choose `.cursorrules` / `CLAUDE.md`.
These are zero-cost to write, free-form, and the model will *usually* follow them on simple tasks. They're complementary, not competing — we recommend writing both. Their failure mode is silent: when the agent ignores the rule, you don't get a notification, you get a bad commit.

### If you want git-stage gates, choose `husky`, `lint-staged`, or `pre-commit`.
These run when *anyone* (human, agent, CI) attempts to commit. They are language- and tool-agnostic. They are the right answer if your concern is "don't let bad code reach `main`". They are the wrong answer if your concern is "don't let the agent burn 30 minutes editing the wrong file" — that damage already happened by the time the pre-commit hook fires.

### If you want LLM-output validation, choose Guardrails AI or NeMo Guardrails.
These check the *content* the model emits — PII leakage, factual claims, output schema compliance, jailbreak detection. They are essential for user-facing LLM products. They don't help with agent action quality, because they don't see actions, they see strings.

### If you want IDE-locked AI features, choose Cursor's built-in rules.
Cursor has a polished, integrated experience. Their rules system is more sophisticated than `.cursorrules` files. The constraint is that you must be in Cursor — the rules don't follow you to other tools or to headless agent runs.

### If you want a single-feature gate from your agent runner, look at flags like Aider's `--auto-commits`.
These solve one problem well (auto-committing after each successful change). They aren't a system — you can't compose them, you can't add your own, and they're per-tool.

### If you want mechanical, stateful, exit-code-based gates on agent actions in Claude Code, this project is the only thing in that cell as of writing.
We didn't pick a fight on purpose. We built it because we needed it and nothing else fit.

## Stacking

These tools compose well. A reasonable production setup for a Claude Code project:

1. `CLAUDE.md` for project-specific context (architecture decisions, naming conventions).
2. `claude-quality-gate` for mechanical agent gates (this project).
3. `pre-commit` or `husky` for git-stage checks (linters, formatters, secret detection).
4. CI (GitHub Actions etc.) for full test runs and deploy gates.

Each layer catches a different class of problem at a different time. We aren't trying to replace any of them.
