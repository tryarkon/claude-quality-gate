# Security Policy

## Threat model

`claude-quality-gate` consists of bash scripts invoked by Claude Code as user-permission subprocesses. They:

- Run with the **invoking user's permissions** — no setuid, no privilege escalation, no daemon.
- Read state from `$QG_DISC_DIR` (default `/tmp/claude-discipline`), `$QG_CC_READS_DIR` (default `/tmp/cc-reads`), and `$QG_CC_HOOKS_DIR` (default `/tmp/cc-hooks`). All under `/tmp`, all per-user.
- Make **no network calls.** No telemetry, no analytics, no remote configuration fetch. The optional `qg dashboard` listens on `localhost:7777` and serves only local state.
- Shell out to a small set of standard utilities. Full list:

| Tool | Used for | Where |
|---|---|---|
| `python3` | JSON parse, JSON escape, ms timer | every hook |
| `md5` (macOS) / `md5sum` (Linux) | freshness hashes, command/loop hashes | `hook-utils.sh` |
| `git` | commit/status/log inspection | `pre-bash-gate`, `on-stop-discipline` |
| `wc`, `sort`, `grep`, `sed`, `tr`, `cat`, `find`, `awk` | text processing | various |
| `cargo`, `tsc`, `ruff` (optional) | language-specific verification | `auto-verify` only when toolchain is detected |

No `eval`, no `curl`, no `wget`, no `bash -c "$user_input"`.

## Scope

This policy covers the code in this repository. It does **not** cover:

- Vulnerabilities in Claude Code itself (report to Anthropic).
- Vulnerabilities in `python3`, `git`, or other system utilities the hooks shell out to.
- Vulnerabilities in third-party hooks you've added to your own `settings.json`.

## Reporting a vulnerability

**Do not open a public issue for security problems.**

Two reporting channels:

1. **Private security advisory on GitHub.** Go to the repo → Security → Advisories → New draft security advisory. We get notified directly.
2. **Email:** `security@tryarkon.dev`

Please include:

- Affected hook(s) and version.
- A minimal reproduction (command + JSON stdin).
- Impact assessment (what an attacker could do, given what access).
- Suggested fix if you have one.

We aim to acknowledge within 5 business days. We aim to ship a fix or workaround within 30 days for high-severity issues. We will credit you in the release notes unless you ask us not to.

## Known non-issues

The following are intentional design choices, not vulnerabilities:

- **State files in `/tmp` are world-readable on some systems.** They contain file paths and command hashes, not secrets. If your `/tmp` is shared with untrusted users, use `QG_CC_HOOKS_DIR=$HOME/.cache/qg` etc.
- **Hooks see every Bash command before execution.** This is the entire point. The hooks log decisions to `$QG_METRICS_LOG` (default `/tmp/qg-metrics.log`). Be aware that this log will contain the first 80 chars of any command the agent runs, including potentially sensitive ones. Override the path or disable logging via `QG_METRICS_LOG=/dev/null`.
- **`pre-bash-gate` reads command stdin.** It does not modify the command. If the command contains a secret, the hook sees it but does not transmit it anywhere.

## Supported versions

Pre-1.0: only the latest minor version is supported. Security fixes will land in `main` and be cut into a new patch release.

Post-1.0: TBD.
