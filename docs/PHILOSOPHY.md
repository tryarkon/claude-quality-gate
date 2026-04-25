# Philosophy

`claude-quality-gate` exists because we kept watching agents do the same five mistakes in a row. We don't think the agents are bad. We think the *interface* between the agent and the codebase is missing a kernel — a thin, mechanical layer that refuses certain actions outright instead of asking nicely.

This document lays out the six principles that shape every hook in this project. If you disagree with these, the tool will fight you. Read this first; decide if we're aligned; install second.

---

## 1. Mechanical, not advisory

Most tooling for AI coding agents lives at the prompt level. `.cursorrules`, `CLAUDE.md`, system prompts, custom instructions — these are all *advice*. The agent reads the advice, internalises some of it, and then proceeds to do whatever its sampler decides on the next token.

Advice works in short sessions, on easy tasks, with strong models. It collapses under any of: long context, repeated failure, time pressure, tool errors that look like code errors. The agent has been told "always run tests before committing" — and yet, on the eighteenth attempt to fix the same flaky integration test, it adds `--no-verify` because it just wants to be done.

Our gates are not advice. They are bash exit codes.

When `pre-bash-gate` sees `git commit --no-verify`, it does not write a stern paragraph into the agent's context window and hope. It returns exit code 2. The Claude Code harness intercepts that exit code and the command does not run. There is no negotiation surface. The agent can produce whatever explanation it likes; the kernel of bash is unmoved.

This is the same shift that happened with type systems. You can document that `getUser()` returns `User | null` in a comment. Programmers will still forget the `null` half. A type checker is not advice — it's a refusal. We treat agent actions the same way.

> Brian Kernighan: *"Don't comment bad code — rewrite it."* Same principle. Don't document the rule the agent should follow — make the violation impossible.

---

## 2. Architecture over runtime checks

There is a tempting design for an agent quality tool: a watchdog that scans the agent's outputs and flags problems. *"You committed without tests, please fix."* That works in theory. In practice, by the time the watchdog flags the problem, the bad commit is in `main` and the deploy is halfway done.

We don't catch errors. We make them impossible to express.

Concrete examples:

- **`pre-write-gate` freshness check.** The agent cannot Edit a file it didn't Read in this session. Not "shouldn't" — *cannot*. The hook computes a hash of the file at Read time, stores it in `/tmp/cc-reads/<session>/`, and compares on Edit. No matching hash, no Edit. This eliminates an entire class of bug — *"agent edited a stale copy of the file from its own context window"* — by making the precondition mandatory.

- **`pre-write-gate` backtrack lock.** If the agent has edited the same file 5+ times in a session, the hook locks that file. Not "warns about". Locks. To unlock, the agent must run a test (which proves it's about to validate, not flail) or explicitly acknowledge the situation with a `BACKTRACK_ACK:` escape and describe a *different* approach. The architecture makes "make a 6th identical edit" non-expressible.

- **`pre-bash-gate` workaround patterns.** `|| true`, `2>/dev/null` on test commands, `SKIP_*=1` env vars, `sed` deleting assertions, `git checkout .` on uncommitted work — these are all blocked by pattern. Not because we're paranoid. Because every one of these patterns is a known agent recovery move that destroys signal. The gate makes them un-runnable.

The principle is general: *don't try to detect bad outcomes; refuse the inputs that produce them.* This is more work upfront. It produces fewer surprises later.

---

## 3. Root cause over workaround

About half the gates in this repository exist for one reason: agents under pressure will reach for the workaround before they reach for the root cause. They will silence a failing test before they will read its output. They will catch and ignore an exception before they will fix the bug it points at. They will `--force` a push before they will resolve the conflict.

We catch this because we have to. Once a workaround lands, the signal is gone. The test is now silently passing — nobody will look at it again. The exception is now swallowed — the bug it pointed to is now a mystery production failure six weeks from now. The force-push erased the merge conflict — and also the other developer's work.

The hooks treat workaround patterns as *symptoms of the agent giving up on the real problem*. Each block comes with a one-line nudge back to the real work:

```
WORKAROUND BLOCKED: --no-verify in git commit. Fix the root cause instead of bypassing.
```

The agent, on receiving this, has two options: actually fix what the pre-commit hook is complaining about, or escalate to the human. Both outcomes are better than the silenced commit.

This is opinionated. There are real cases where you need to bypass — emergency hotfixes, known-flaky tests during a known-bad period, documentation-only changes where the linter is wrong. For those, we provide explicit ACK escapes (`CHANGELOG_ACK:`, `TEST_SKIP:`, `LOOP_ACK:`, `BACKTRACK_ACK:`) that require the agent to write the reason out loud. The override exists. It just isn't the path of least resistance.

---

## 4. Stateful, not stateless

A linter looks at one file. A type checker looks at one program. A code review tool looks at one diff. Each of those is stateless with respect to time — you could shuffle the order of inputs and the output wouldn't change.

The interesting failure modes of an autonomous agent are temporal:

- *"You've edited `auth.py` five times this session — you're spinning."*
- *"You've made 10 code edits and run 0 tests — you don't actually know if any of this works."*
- *"You've run `ssh user@host 'systemctl status'` six times in a row — the server isn't going to magically respond differently."*
- *"You're about to deploy code that hasn't been tested since the last deploy."*

None of these are visible in any single action. They're only visible in the *trajectory*. So our gates are stateful by design.

State lives in plain files in `/tmp/claude-discipline/` and `/tmp/cc-hooks/<session>/`. Per-session counters for: edits-without-test, commands-and-their-frequency, files-edited-this-session, plan-files-read, last-commit-time. The `track-activity` hook updates these on every PostToolUse. The pre-tool gates read them and decide.

State decays naturally — `/tmp` empties on reboot, sessions are scoped by Claude Code's session ID. There is no SQLite, no daemon, no background process. Just files, written atomically (`mv` from a `.tmp.$$` file), read on the next hook fire.

The cost of this design is modest: ~10ms of overhead per hook call. The benefit is that every hook can ask questions like *"how many times has this command been run in a row?"* and get an answer.

---

## 5. Strict by default

Most quality tooling defaults to permissive. ESLint ships with maybe ten rules on; the rest you opt into. Prettier picks deliberately mild defaults. The reasoning is sensible — you want adoption, you don't want to scare new users with red error markers on their first save.

We default to strict. `QG_PROFILE=strict` is the unset value. Every block is enforced. Every workaround pattern is denied.

The reasoning: people install this tool *specifically* because their agent is doing things they don't want it to. The failure mode of "tool doesn't catch enough" is invisible — the agent does the bad thing, you find out in production. The failure mode of "tool catches too much" is loud and immediate — you see the block, you decide whether to override. Loud-and-fixable beats silent-and-deployed every time.

For incremental adoption, two relaxer profiles exist:

- **`standard`** — same checks, but `json_allow` instead of `json_deny`. The agent gets a warning in its context and continues. Useful for the first week, while you're seeing what the gates flag in your codebase.
- **`minimal`** — most checks short-circuit at the top. Use this if you want to install the tool for metrics only.

You can also disable individual hooks by tag: `QG_DISABLED_HOOKS=freshness,3-file,workaround`. Surgical opt-out, not all-or-nothing.

But strict is the default because strict is what produces the outcome you wanted when you installed the tool.

---

## 6. Progressive escalation

Hard gates have a known failure mode: the agent hits the gate, can't proceed, can't ask a human (it might be unattended), and the session deadlocks. So our gates have a graduated response that gives the agent room to recover without needing a human in the loop.

The patterns:

- **Loop detection.** Same command 3 times: warning. Same command 6 times: block, with an explicit `LOOP_ACK:` escape. The agent, if it has a reason, can write `echo LOOP_ACK: server takes 60s to boot, polling intentionally` and continue.
- **Untested-edit counter.** 5 edits without a test: warning. 8 edits: stronger warning. 10 edits: block (in `strict`), with `TEST_SKIP:` escape. The numbers are deliberately not "1 edit = block" — agents need room to make small composite changes before validating.
- **Backtrack lock.** 5 edits to the same file: lock. To unlock: run a test (proof of validation intent), or `BACKTRACK_ACK:` with a description of a *different* approach.
- **`on-stop-discipline`.** Definition-of-Done gate at session end. First failure: warning (allows stop). Second failure: stronger warning. Third failure: hard gate, *only for tests-not-run and uncommitted-changes* — those are the two things we're willing to be uncompromising about.

The shape is: **warn, warn-louder, block-with-escape**. Designed for the agent that needs to escape a dead-end without paging a human. The escapes are not free — they require the agent to write out a reason in plain text, which is itself a useful forcing function (writing the reason often surfaces that there *isn't* a good reason).

The two exceptions to the "always provide an escape" rule are *tests* and *commits* in `on-stop-discipline`. We don't believe there's a good reason for an agent to stop a session having edited 3+ code files without ever running a test or committing. That's not "blocked" — that's "incomplete".

---

## When NOT to use this

Honest assessment of where this tool is the wrong choice:

- **You don't run Claude Code.** This tool plugs into Claude Code's hook system specifically. It does not work with other agents (Cursor, Aider, Cline, raw API calls). It is not portable to those, by design — the hook contract is Claude Code's.

- **You want maximum agent autonomy.** If your workflow is "let the agent do anything for an hour and check the result", you don't want strict gates getting in the way. You want this tool in `minimal` profile, used purely for metrics — at which point you should ask whether you want it at all.

- **You're prototyping, not building.** Throwaway code doesn't need a freshness gate. Single-file scripts don't need a 3-file plan check. The discipline assumes you're building something you intend to keep.

- **Your agent runs without bash access.** A few hooks (`pre-bash-gate`, the test/commit detection in `track-activity`) only fire when the agent uses the Bash tool. If you've restricted the agent to Read/Write/Edit only, you're getting maybe 60% of the value.

- **You have a process that conflicts.** If your CI requires `--no-verify` for a reason we don't understand, our gate will block your CI helper. Either disable the `workaround` hook (`QG_DISABLED_HOOKS=workaround`), or reconsider why CI needs to bypass git hooks.

- **You don't believe in opinionated tools.** This is one. We made calls about "5 files = commit reminder", "300 lines = block large Read", "edit-without-Read = freshness violation". The numbers are tunable but the philosophy isn't. If you want a configurable framework, this isn't it.

If none of those describe you, install it.

---

## Acknowledgements

The mechanical-gate approach is not original. It descends directly from:

- **Type systems** — make wrong programs unexpressible, don't try to detect them at runtime.
- **`pre-commit` and `husky`** — git-stage hooks proved that mechanical refusal beats documentation.
- **`make`'s prerequisite model** — a target cannot be built before its dependencies exist. We borrow this for "Edit cannot fire before Read".
- **Capability-based security** — the right to do a thing is a token you must hold, not a rule you should follow.

What we contribute is the application of these patterns to the *agent action layer* in Claude Code, which to our knowledge has no other implementation at the time of writing.
