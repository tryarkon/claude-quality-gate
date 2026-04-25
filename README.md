<div align="center">

# claude-quality-gate

**Mechanical guardrails for [Claude Code](https://docs.claude.com/en/docs/claude-code) agents.**

*Stop the agent from doing the dumb thing — at the kernel level, not in the prompt.*

[![tests](https://github.com/tryarkon/claude-quality-gate/actions/workflows/test.yml/badge.svg)](https://github.com/tryarkon/claude-quality-gate/actions)
[![license](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![bash](https://img.shields.io/badge/bash-3.2%2B-success)](docs/WINDOWS.md)
[![python](https://img.shields.io/badge/python-3.7%2B-success)](docs/QUICKSTART.md)
[![platforms](https://img.shields.io/badge/platforms-macOS%20·%20Linux%20·%20WSL%20·%20Windows-informational)](docs/WINDOWS.md)
[![status](https://img.shields.io/badge/status-production-brightgreen)](docs/PHILOSOPHY.md)

[Install](#install) · [What it catches](#what-it-catches) · [Dashboard](#dashboard) · [Philosophy](docs/PHILOSOPHY.md) · [Hooks reference](docs/HOOKS.md) · [Comparison](docs/COMPARISON.md)

</div>

---

## The problem

You hand Claude Code a task. Forty minutes later you come back to find:

- It read three 1500-line files end-to-end and burned half its context on code it didn't need.
- It edited `auth.py` *eight times* in a loop, never running a single test.
- When the test finally failed, it added `--no-verify` to the commit and moved on.
- Your `git status` is dirty across 14 files. None of the changes are committed. The session is "done".

`.cursorrules` told the agent not to do any of this. The agent read `.cursorrules` and ignored it. *Advice doesn't bind.*

## The solution

Seven bash hooks (~1100 lines, zero dependencies) that plug into Claude Code's hook system and refuse the action at the OS level. Not "warn". Not "remind". **Refuse.**

```
$ # agent tries:
$ git commit --no-verify -m 'wip'
WORKAROUND BLOCKED: --no-verify bypasses pre-commit hooks.
Fix the root cause instead of bypassing.
[exit 2]
```

There is no negotiation surface. The Bash tool returns non-zero. The action does not happen. The agent gets the block reason in its context window and adapts.

This is the same shift that happened with type checkers: don't write a comment about a contract — make the violation impossible to express.

---

## Install

**macOS / Linux / WSL:**

```bash
curl -sSL https://raw.githubusercontent.com/tryarkon/claude-quality-gate/main/install.sh | bash
```

**Windows (PowerShell + Git for Windows):**

```powershell
iwr -useb https://raw.githubusercontent.com/tryarkon/claude-quality-gate/main/install.ps1 | iex
```

The installer:

- Drops 7 hooks into `~/.claude/hooks/`.
- Smart-merges into your `~/.claude/settings.json` (existing keys preserved, backup written).
- Installs the `qg` CLI to `~/.local/bin/qg` (`qg.cmd` on Windows).

Then verify:

```bash
qg status
```

Open a new Claude Code session — the gates fire automatically.

→ Full quickstart: [`docs/QUICKSTART.md`](docs/QUICKSTART.md) · Windows specifics: [`docs/WINDOWS.md`](docs/WINDOWS.md)

---

## What it catches

Eight common autonomous-agent failure modes. Every one is opt-out, every one has an escape hatch.

| Failure mode | What the agent tries | What we do |
|---|---|---|
| **Context-bloat reads** | `Read("legacy.py")` (1800 lines) | Block, suggest `offset`/`limit` or LSP. *Whitelist:* `.md`/`.json`/`.yaml`/etc. |
| **Stale-edit** | `Edit("api.py")` without ever calling `Read` | Block. Mandatory: Read before Edit. *Whitelist:* `.md`. |
| **Infinite loop** | Same `ssh server 'systemctl status'` 6 times | Block at 6 (warn at 3). Escape: `echo LOOP_ACK: <reason>`. |
| **Tunnel vision** | 5+ edits to the same file in one session | Lock file. Escape: run a test, or `BACKTRACK_ACK: <new approach>`. |
| **Drift without tests** | 10 code edits, 0 test runs | Block. Escape: run tests, `git commit`, or `TEST_SKIP: <reason>`. |
| **Scope creep** | 3+ unique files edited, no plan | Block until a plan exists in `~/.claude/plans/`. |
| **Workaround culture** | `--no-verify`, `\|\| true`, `2>/dev/null` on tests, `SKIP_*=`, `git checkout .` | Block. The pattern is the signal — fix the cause. |
| **Deploy without tests** | `rsync build/ host:/var/www/` while untested-edit counter > 0 | Block. *"Every prod bug = SSH debugging."* |

Plus: destructive SQL gate (DROP/TRUNCATE/DELETE-without-WHERE), conventional-commits format check, CHANGELOG-stale gate, Definition-of-Done gate at session end (3+ code files → require tests + commits, with progressive escalation across 3 attempts).

→ Full reference for every hook: [`docs/HOOKS.md`](docs/HOOKS.md)

---

## The hooks

| Hook | Event | LOC | Notes |
|---|---|---|---|
| `pre-read-gate` | `PreToolUse` Read | 66 | Blocks `Read` >300 lines without `offset/limit` |
| `pre-write-gate` | `PreToolUse` Write/Edit | 217 | Freshness, loop, backtrack, untested, 3-file, 5-file |
| `pre-bash-gate` | `PreToolUse` Bash | 210 | Workaround patterns, destructive SQL, conventional commits, deploy gate |
| `track-activity` | `PostToolUse` * | 185 | Stateful tracker — feeds the pre-tool gates |
| `auto-verify` | `PostToolUse` Write/Edit | 110 | Runs `cargo check` / `tsc --noEmit` / `ruff` after every edit |
| `on-stop-discipline` | `Stop` | 120 | Definition-of-Done gate at session end |
| `hook-utils.sh` | (shared lib) | 202 | `parse_input`, `hu_state_op`, `json_*`, profile/disable helpers |

State is plain files in `/tmp` — no SQLite, no daemon, no background process. Per-hook overhead: ~10ms.

---

## Dashboard

```bash
qg dashboard
```

Open [http://localhost:7777](http://localhost:7777). Live metrics from `$QG_METRICS_LOG` — blocks fired, time saved, tokens saved (estimated for context-bloat reads), 24-hour timeline, top violations, recent sessions, live event feed. Auto-refresh every 5s.

Zero dependencies — pure Python `http.server` + vanilla JS.

→ How the savings numbers are calculated (and what they don't measure): [`docs/METRICS.md`](docs/METRICS.md)

---

## Configuration

Three knobs, no config file:

```bash
qg config QG_PROFILE strict       # default. blocks on violation.
qg config QG_PROFILE standard     # warns instead of blocks.
qg config QG_PROFILE minimal      # disables most checks (metrics still log).

qg config QG_DISABLED_HOOKS freshness,3-file,workaround   # disable specific tags
```

Per-tag opt-out (full list in [`HOOKS.md`](docs/HOOKS.md)):
`read-gate · freshness · concurrent-edit · loop · backtrack · tests · 3-file · workaround · conventional-commits · changelog-gate · deploy-gate · auto-verify · stop-discipline · commit`

Custom paths via env vars (`QG_DISC_DIR`, `QG_CC_READS_DIR`, `QG_CC_HOOKS_DIR`, `QG_PLANS_DIR`, `QG_METRICS_LOG`).

---

## Why mechanical gates beat prompt rules

| | `.cursorrules` / `CLAUDE.md` | claude-quality-gate |
|---|---|---|
| Enforcement | Advisory (model may ignore) | Mechanical (bash exit 2) |
| State | Stateless | Per-session counters, hashes, locks |
| Scope | Project-level rules | Action-level interception |
| Failure mode | Silent — agent did the bad thing | Loud — block with explanation |
| Tunable | Free-form text | 6 toggle profiles, 14 disable tags |

→ Full comparison vs husky / pre-commit / Guardrails AI / Cursor / Aider: [`docs/COMPARISON.md`](docs/COMPARISON.md)

---

## Philosophy in 6 lines

1. **Mechanical, not advisory.** Bash exit codes, not paragraphs.
2. **Architecture over runtime checks.** Make wrong actions un-expressible.
3. **Root cause over workaround.** Half the gates exist because agents under pressure reach for `--no-verify` first.
4. **Stateful, not stateless.** "You've edited this file 5 times" is the interesting check.
5. **Strict by default.** Loud-and-fixable beats silent-and-deployed.
6. **Progressive escalation.** Warn, warn-louder, block-with-escape. Designed for autonomous agents that need to recover without paging a human.

→ Full manifesto: [`docs/PHILOSOPHY.md`](docs/PHILOSOPHY.md)

---

## FAQ

<details>
<summary><b>Will this slow down my agent sessions?</b></summary>

~10ms per hook fire on Linux/macOS. ~80–150ms on Windows under Git Bash (use WSL for native speed). Negligible for normal workflows. The `auto-verify` hook can be slower because it runs `cargo check` / `tsc` — disable it (`qg config QG_DISABLED_HOOKS auto-verify`) if your project's check is slow.
</details>

<details>
<summary><b>Does this work outside Claude Code?</b></summary>

No. The hook contract is Claude Code-specific (it's wired through `~/.claude/settings.json`). The principles transfer to other agent runners (Cursor, Cline, Aider) but you'd have to port the integration layer. We're not planning to.
</details>

<details>
<summary><b>What if a gate fires on legitimate work?</b></summary>

Every gate has an escape: `LOOP_ACK:`, `BACKTRACK_ACK:`, `TEST_SKIP:`, `CHANGELOG_ACK:`. Each requires the agent to write the reason in plain text — useful as a forcing function. If a particular gate consistently false-positives in your workflow, disable it by tag (`QG_DISABLED_HOOKS=<tag>`).
</details>

<details>
<summary><b>Can I write my own hooks on top of this?</b></summary>

Yes — the shared lib (`hook-utils.sh`) is the foundation. See [`docs/CUSTOMIZATION.md`](docs/CUSTOMIZATION.md) for the contract, helpers, and a worked 30-line example.
</details>

<details>
<summary><b>Is there telemetry?</b></summary>

No. Hooks are local-only, the dashboard binds to `127.0.0.1`, no network calls anywhere. Full audit in [`SECURITY.md`](SECURITY.md).
</details>

<details>
<summary><b>Why bash and not Python/Go/Rust?</b></summary>

Three reasons: (1) zero install — bash is everywhere Claude Code can run; (2) the hook contract is JSON-on-stdin / exit-code-out, which bash handles in 5 lines; (3) every hook is small enough to read top-to-bottom. We escape into Python only for JSON parsing and `re` operations.
</details>

<details>
<summary><b>How is "time saved" calculated?</b></summary>

A static map of "minutes saved per blocked event class" (5 min for stale-edit catches, 8 min for loops, 15 min for untested-deploy catches, etc.). Estimates, not measurements — see [`docs/METRICS.md`](docs/METRICS.md) for the full table and how to override.
</details>

<details>
<summary><b>What's the project's status?</b></summary>

Production-used internally. Open-sourced as an artifact, not as a community project — issues may sit for weeks. PRs welcome but not promised review. Hard forks encouraged. See [`CONTRIBUTING.md`](CONTRIBUTING.md).
</details>

---

## Documentation

| Doc | What it covers |
|---|---|
| [`QUICKSTART.md`](docs/QUICKSTART.md) | 60 seconds from install to first block |
| [`PHILOSOPHY.md`](docs/PHILOSOPHY.md) | The six principles. Read before installing. |
| [`HOOKS.md`](docs/HOOKS.md) | Reference — every hook, every tag, every override |
| [`CUSTOMIZATION.md`](docs/CUSTOMIZATION.md) | Write your own hook on top of `hook-utils.sh` |
| [`COMPARISON.md`](docs/COMPARISON.md) | vs `.cursorrules`, husky, Guardrails, Cursor, Aider |
| [`METRICS.md`](docs/METRICS.md) | Dashboard math, savings model, how to A/B test |
| [`WINDOWS.md`](docs/WINDOWS.md) | Git Bash vs WSL setup, troubleshooting |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | What we'll merge, what we won't, how to add a hook |
| [`SECURITY.md`](SECURITY.md) | Threat model, reporting, known non-issues |

---

## License

Apache-2.0. See [`LICENSE`](LICENSE).

## Acknowledgements

Descends from `pre-commit` / `husky` (mechanical refusal at git stage), `make` (prerequisite-based contracts), type systems (un-expressible-wrong-programs), and capability-based security. We applied the pattern to the agent-action layer in Claude Code — to our knowledge, the first such implementation in this ecosystem.
