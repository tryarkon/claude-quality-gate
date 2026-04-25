# Hooks Reference

This is the reference for every hook shipped in `claude-quality-gate`. Each section follows the same shape: summary, what it blocks, what it allows, how to override, configuration, and example output.

All hooks share two universal opt-outs:

- `QG_PROFILE=minimal` — the hook short-circuits at the top and does nothing.
- `QG_DISABLED_HOOKS=<tag>,<tag>` — disable specific checks by tag.

Hook-specific tags are listed in each section under **How to override**.

---

## `pre-read-gate`

**Event:** `PreToolUse` on `Read`
**File:** `hooks/pre-read-gate.sh`

### Summary

Blocks `Read` of files larger than 300 lines when the agent didn't supply `offset`/`limit`. Reading large files whole is the single fastest way to burn the agent's context budget on text it will never use. The hook nudges toward bounded reads and LSP queries instead.

### What it blocks

- `Read("src/server/handlers.ts")` where the file is 800 lines and no offset given.
- `Read("legacy/giant_module.py")` at 1500 lines without bounds.

In `strict`, these return exit code 2 and the read is denied. In `standard`, they pass with a warning in the agent's context.

### What it allows

- Any file with `offset` or `limit` set — the agent has bounded the read intentionally.
- Files with whitelisted extensions, regardless of size: `md`, `json`, `toml`, `yaml`, `yml`, `env`, `txt`, `csv`, `lock`, `conf`, `ini`, `cfg`, `gitignore`. Structured/config files are usually meant to be read whole.
- Files ≤100 lines: silent pass.
- Files 101–200 lines: pass with a soft hint.
- Files 201–300 lines: pass with a stronger warning.
- Files that don't exist: pass (let `Read` itself surface the error).

### How to override

- Tag: `read-gate` — disable entirely with `QG_DISABLED_HOOKS=read-gate`.
- Per-call: pass `offset` and/or `limit` to `Read`. The hook treats this as intentional bounding and exits silently.
- Profile: `QG_PROFILE=standard` downgrades blocks to warnings.

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `QG_PROFILE` | `strict` | `strict` blocks, `standard` warns, `minimal` skips |
| `QG_DISABLED_HOOKS` | unset | Add `read-gate` to skip |

### Example output

Blocked (strict, 1500-line file):

```
File handlers.ts is 1500 lines. Reading it whole wastes context.
Use one of:
- Read(path='/repo/src/handlers.ts', offset=N, limit=200)  # specific section
- LSP hover / documentSymbol                               # for signatures and structure
- grep/rg over the file                                    # for keyword lookup
```

Warned (200-300 lines):

```
⚠️ handlers.ts is 247 lines. Consider offset/limit or LSP to save context.
```

---

## `pre-write-gate`

**Event:** `PreToolUse` on `Write` and `Edit`
**File:** `hooks/pre-write-gate.sh`

### Summary

The most active gate in the system. Enforces seven distinct checks before allowing a write or edit: freshness (must Read first), concurrent-edit warning, loop block, backtrack lock, untested-edit counter, 3-file-without-plan gate, 5-file commit reminder. State for these checks is maintained by `track-activity`.

### What it blocks

- **Freshness:** `Edit("src/api.py")` when `api.py` was not Read this session, or was Read but has changed on disk since.
- **Loop:** Write/Edit while the agent is in a known command loop (set by `track-activity` after 6 repeated commands).
- **Backtrack lock:** Edit on a file that has been edited 5+ times this session — interpreted as tunnel vision. Lock until either a test runs or the agent submits `BACKTRACK_ACK:`.
- **Untested edits (strict):** 10+ code edits with no test run between them. Hard block.
- **3-file gate (strict):** 3+ unique files edited this session with no plan file present in `~/.claude/plans/`. The signal is "complex change without decomposition".

### What it allows

- Writes to files that have been Read in this session and not changed externally.
- First edit of the session — passes with a one-time prompt: *"fixing the root cause or a symptom?"*
- Files freshly touched by another process/commit in the last 30 min — passes with a `CONCURRENT EDIT WARNING`.
- Untested edits at counts 5 and 8 — passes with progressively stronger warnings.
- Markdown / `.txt` / `.gitignore` / `.command` files — bypass the freshness check.
- Standard profile: every block becomes a warning.

### How to override

| Behavior | Tag | Escape |
|---|---|---|
| Freshness check | `freshness` | Re-Read the file |
| Concurrent-edit warn | `concurrent-edit` | (warn only) |
| Loop block | `loop` | `echo LOOP_ACK: <reason>` in Bash |
| Backtrack lock | `backtrack` | `echo BACKTRACK_ACK: <new approach>` or run a test |
| Untested-edit block | `tests` | `echo TEST_SKIP: <reason>` |
| 3-file gate | `3-file` | Create a plan file in `~/.claude/plans/` |
| 5-file commit reminder | (always on) | (warn only — make a commit) |

Profile-level: `QG_PROFILE=standard` downgrades all blocks to warnings; `minimal` disables the hook entirely.

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `QG_PROFILE` | `strict` | Block-vs-warn behavior |
| `QG_DISABLED_HOOKS` | unset | Comma list of tags above |
| `QG_DISC_DIR` | `/tmp/claude-discipline` | Lock files, ACK markers |
| `QG_CC_READS_DIR` | `/tmp/cc-reads` | Per-session freshness hashes |
| `QG_CC_HOOKS_DIR` | `/tmp/cc-hooks` | Per-session counter state |
| `QG_PLANS_DIR` | `~/.claude/plans` | Where the 3-file gate looks for plans |

### Example output

Freshness block:

```
STOP. api.py was not Read in this session. Read it first (Read tool), then edit —
so you're not patching an outdated version.
```

Backtrack lock:

```
BACKTRACK LOCK: api.py was reset due to tunnel vision. Describe a DIFFERENT
approach via 'echo BACKTRACK_ACK: <new approach>'. Or run a test to unlock.
```

Untested-edit block (strict, 10+):

```
STOP: 12 code edits without a single test run. Write BLOCKED.
To unblock:
1. Run tests (pytest / cargo test / npm test), or
2. 'echo TEST_SKIP: <reason>' (explicit acknowledgement), or
3. git commit (freeze current state)
```

3-file gate:

```
STOP. 3+ files edited without a plan — this is a complex task that needs decomposition.
1. Write a plan: ~/.claude/plans/*.md, or use TaskCreate
2. Plan = list of files + what to change + order + how to verify
3. After the plan exists — continue
Write/Edit BLOCKED until a plan exists.
```

---

## `pre-bash-gate`

**Event:** `PreToolUse` on `Bash`
**File:** `hooks/pre-bash-gate.sh`

### Summary

Pattern-matches every Bash command before it runs. Blocks workaround patterns, destructive SQL without `WHERE`, deploys without recent tests, and non-conventional commit messages. Recognises ACK escapes (`CHANGELOG_ACK:`, etc.) emitted via `echo`.

### What it blocks

- **Workarounds:** `--no-verify`, `|| true` after test runners, `2>/dev/null` on test commands, `SKIP_*=1`/`DISABLE_*=1`, `sed` patterns that delete `assert` lines, `git checkout .` / `git restore --`, `rm -rf src/`.
- **Destructive SQL:** `DROP TABLE`, `TRUNCATE`, `DELETE FROM` without `WHERE`, `DELETE FROM ... WHERE 1`. Skipped for `:memory:` and `/tmp/` paths.
- **Conventional commits:** `git commit -m "..."` whose message doesn't start with `feat|fix|chore|docs|refactor|test|perf|build|ci|style|release|breaking(...):`. Whitelists `auto-save|auto-sync|auto-commit|release(...)` patterns.
- **Deploy without tests:** `scp` or `rsync` of source files when the untested-edit counter is non-zero.
- **CHANGELOG gate:** `git commit` when code changed but `CHANGELOG.md` is missing or stale (>14 days, not staged).

### What it allows

- `pytest`, `cargo test`, `npm test`, `go test`, etc. — actively detected and used to reset the untested-edit counter.
- `git commit` with conventional-commit-formatted message.
- Whitelisted command prefixes: `npm install`, `pip install`, `cargo install`, `brew`, `docker`, `systemctl`, `launchctl`.
- Any command tagged `# INTENTIONAL` or referencing `hooks/`/`quality-gate/` paths.
- Any command preceded by the corresponding `ACK:` marker in the same Bash invocation.

### How to override

| Behavior | Tag | Escape |
|---|---|---|
| Workaround patterns | `workaround` | `# INTENTIONAL` marker, or fix the cause |
| Destructive SQL | `workaround` | Use `:memory:` / `/tmp/` paths |
| Conventional commits | `conventional-commits` | (no escape — reformat the message) |
| Deploy-without-tests | `deploy-gate` | Run tests first; or `TEST_SKIP:` |
| CHANGELOG gate | `changelog-gate` | `echo CHANGELOG_ACK: <reason>` first |

Profile: `standard` downgrades all blocks except the destructive-SQL set to warnings. `minimal` disables.

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `QG_PROFILE` | `strict` | Block-vs-warn |
| `QG_DISABLED_HOOKS` | unset | Tag list |
| `QG_DISC_DIR` | `/tmp/claude-discipline` | ACK marker storage |

### Example output

Workaround block:

```
WORKAROUND BLOCKED: git --no-verify bypasses pre-commit / pre-push hooks. Fix the root cause instead of bypassing.
```

Deploy without tests:

```
DEPLOY BLOCKED: 7 code edits without tests. Run tests before scp/rsync.
Every prod bug = SSH debugging.
```

Conventional commit violation:

```
WORKAROUND BLOCKED: commit message is not conventional-commits.
Use: feat(scope): ..., fix: ..., chore: ..., etc.
```

---

## `track-activity`

**Event:** `PostToolUse` on `Read`, `Write`, `Edit`, `Bash`
**File:** `hooks/track-activity.sh`

### Summary

Stateful tracker. Doesn't block anything itself — it writes the state that the pre-tool gates read. After every Read, hashes the file for the freshness check. After every Write/Edit, increments the per-file churn counter and the global untested-edit counter. After every Bash, detects test commands, commits, ACK escapes, and command repetition.

### What it tracks

- **Freshness hashes** (`Read`): writes `md5(file)` into `$QG_CC_READS_DIR/<session>/<file_hash>`.
- **Per-file churn** (`Write`/`Edit`): counter at `churn_<file_hash>`. 3 = warn, 5 = backtrack-lock written.
- **Untested edits** (`Write`/`Edit`): global counter `edits_no_test`. 5/8/10 thresholds.
- **Loop detection** (`Bash`): hashes the command (or `ssh`/`scp` prefix only — they vary by destination), counters at `loop_<cmd_hash>`. 3 = warn, 6 = block.
- **Test detection** (`Bash`): regex match against `pytest|cargo test|npm test|go test|npx vitest|npx jest`. Resets `edits_no_test` to 0 and writes `tests-ran-<sid>` flag.
- **Commit detection** (`Bash`): `git commit` clears all session state.
- **ACK escapes** (`Bash`): `echo LOOP_ACK:|BACKTRACK_ACK:|TEST_SKIP:` clears the corresponding lock or sets the marker.

### What it allows

Everything. This hook never denies — it only updates state and emits informational context messages.

### How to override

There is no tag for this hook itself. The pre-tool gates whose state it feeds each have their own tags (see above). Disabling individual gates is the right level of control — disabling state collection at this layer just blinds the system without changing behavior.

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `QG_DISC_DIR` | `/tmp/claude-discipline` | Loop lock files |
| `QG_CC_READS_DIR` | `/tmp/cc-reads` | Freshness hashes |
| `QG_CC_HOOKS_DIR` | `/tmp/cc-hooks` | Per-session counters |
| `QG_METRICS_LOG` | `/tmp/qg-metrics.log` | Where state events get logged |

### Example output

After 3rd repeat of a command:

```
⚠️ LOOP: same command executed 3 times. After 6 executions Write/Edit will be blocked.
```

After 5th edit of the same file:

```
BACKTRACK LOCK: api.py edited 5 times — tunnel vision. File reset. Describe a DIFFERENT approach: echo 'BACKTRACK_ACK: <new approach>'.
```

After 10 untested code edits:

```
STOP: 10 code edits without running any tests. Write is now BLOCKED. Run pytest / cargo test, or 'echo TEST_SKIP: <reason>' to override.
```

---

## `auto-verify`

**Event:** `PostToolUse` on `Write`, `Edit`
**File:** `hooks/auto-verify.sh`

### Summary

Runs the project's quick type/lint check after every Write or Edit. Detects toolchain via `Cargo.toml` → `cargo check`, `tsconfig.json` → `tsc --noEmit`, `*.py` → `ruff check`. Errors ≤5 lines are inlined into the agent's context; longer outputs are written to `/tmp/cc-verify-<session>.log` with a 3-line preview.

### What it does

- Detects the appropriate verifier for the edited file's language.
- Walks up the directory tree to find the project root (`Cargo.toml` / `tsconfig.json`).
- Runs the verifier (with the timeout you configure in `settings.json`, default 30s).
- On success: silent, no output.
- On failure: emits a `PostToolUse` context message with either the inline error or a path + preview.

### What it allows

Everything. This is informational — it doesn't block. The agent sees the error in its next turn and can react.

### How to override

- Tag: `auto-verify` — disable entirely.
- Profile: `minimal` skips. `standard` runs unchanged (no notion of warn-vs-block here; it's already informational).

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `QG_PROFILE` | `strict` | `minimal` skips |
| `QG_DISABLED_HOOKS` | unset | Add `auto-verify` to skip |

### Example output

Inline (≤5-line error):

```
ruff check FAILED after editing handlers.py: src/handlers.py:42:8: F821 Undefined name 'foo'. Fix the error before continuing.
```

Long output:

```
cargo check FAILED after editing handlers.rs: error[E0277]: the trait bound `User: Serialize` is not satisfied
   --> src/handlers.rs:23:18
    |
 23 |     Json(payload).into_response()
 ... +44 more lines → Read /tmp/cc-verify-a1b2c3.log. Fix the error before continuing.
```

---

## `on-stop-discipline`

**Event:** `Stop`
**File:** `hooks/on-stop-discipline.sh`

### Summary

Definition-of-Done gate. Runs when the agent declares the session complete. If the session edited 3+ code files, requires that tests have run *and* there are no uncommitted changes in tracked files. Progressive escalation across stop attempts: warn → strong warn → hard gate (tests/commits only).

### What it blocks

- Sessions that edited 3+ code files but never ran a test command.
- Sessions that edited 3+ code files but have uncommitted changes in `git status`.

These are escalated:

- **Attempt 1:** warn, allow stop.
- **Attempt 2:** stronger warn, allow stop ("last warning").
- **Attempt 3+:** hard block — *but only for the tests-not-run and uncommitted-changes cases*. Other warnings always pass through after attempt 2.

### What it allows

- Sessions with <3 code-file edits where no code files were touched (trivial sessions).
- Sessions with no edits at all (read-only investigations).
- Sessions that ran tests *and* have a clean working tree.
- Profile `standard` or `minimal` — checks become informational only or disappear.
- `stop_hook_active=true` (the second-fire prevention flag) — short-circuits.

### How to override

| Behavior | Tag |
|---|---|
| Disable the hook entirely | `stop-discipline` |
| Disable tests-not-run check | `tests` |
| Disable uncommitted check | `commit` |

The natural override is "commit and run a test" — it's faster than disabling.

### Configuration

| Variable | Default | Purpose |
|---|---|---|
| `QG_PROFILE` | `strict` | `standard`/`minimal` downgrade everything to info |
| `QG_DISABLED_HOOKS` | unset | `stop-discipline`, `tests`, `commit` |
| `QG_DISC_DIR` | `/tmp/claude-discipline` | Stop-attempt counter, tests-ran flag |

### Example output

First attempt:

```
DEFINITION OF DONE: TESTS NOT RUN. Run cargo test / pytest / npm test before stopping. UNCOMMITTED CHANGES — run git commit before stopping.
```

Second attempt:

```
⚠️ REPEAT (2/3): TESTS NOT RUN. UNCOMMITTED CHANGES — next attempt will pass through.
```

Third attempt (hard gate, tests case):

```
TESTS ARE MANDATORY (attempt 3): TESTS NOT RUN. UNCOMMITTED CHANGES.
```

---

## `hook-utils.sh` (shared library)

**Not a hook itself.** Sourced by every other hook. Provides:

- `parse_input "$INPUT" field1 field2 …` — single python3 call to extract multiple fields from the stdin JSON. Sets `HU_<FIELD_UPPERCASE>`.
- `md5_string`, `md5_file`, `md5_short` — cross-platform (macOS `md5` + Linux `md5sum`).
- `json_deny "reason"` — stderr + exit 2.
- `json_allow "context"` — emit `hookSpecificOutput` JSON with `permissionDecision: allow` + `additionalContext`.
- `json_context "context" "Event"` — emit `additionalContext` for non-decision events (PostToolUse).
- `json_stop_block "reason"` — Stop-event equivalent of deny.
- `init_profile [default]` — sets `HU_PROFILE` and `HU_DISABLED` from `QG_PROFILE`/`QG_DISABLED_HOOKS`.
- `hook_disabled "tag"` — bool, true if tag is in `QG_DISABLED_HOOKS`.
- `log_metric "EVENT details"` — append to `$QG_METRICS_LOG`.
- `atomic_write content path` — write via `.tmp.$$` + `mv`.
- `atomic_increment path` — read-incr-write, prints new value.
- `hu_state_op get|set|incr|clear sid key [val]` — per-session state in `$QG_CC_HOOKS_DIR/<sid>/<key>`.
- `hu_timer_start` / `hu_timer_end` — performance metrics.

### Reading order if you want to write your own hook

1. `hook-utils.sh` itself (~200 lines, well-commented).
2. `pre-read-gate.sh` — simplest hook in the project (66 lines), good template.
3. `pre-write-gate.sh` — most complex, demonstrates state interaction.

---

## Custom hook development

To write your own hook, see [`docs/CUSTOMIZATION.md`](./CUSTOMIZATION.md). The contract is simple: read JSON from stdin, source `hook-utils.sh`, call `init_profile`, decide, emit via the `json_*` helpers. A worked example (vulnerability-blocking `npm install` hook) is included.
