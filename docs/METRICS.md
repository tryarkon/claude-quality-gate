# Metrics

Every block, warning, and ACK escape produces one line in `$QG_METRICS_LOG` (default `/tmp/qg-metrics.log`). The `qg dashboard` command parses that log and renders four headline numbers plus a violation breakdown, a 24-hour timeline, a sessions list, and a live event feed.

This doc explains:

1. The log format.
2. How the dashboard derives the headline numbers.
3. The savings model (and its honest limitations).
4. How to use the metrics in your own analysis.

## 1. Log format

One event per line. Tab-or-space-separated:

```
<YYYY-MM-DD HH:MM:SS>  <hook-name>  <event>  <key>=<value>  <key>=<value>  ...
```

Example lines:

```
2026-04-24 09:12:03 pre-write-gate BLOCK:freshness-not-read sid=a1b2c3d4 file=auth.py
2026-04-24 09:13:42 pre-bash-gate WORKAROUND:git --no-verify bypasses pre-commit / pre-push hooks cmd=git commit --no-verify -m fix
2026-04-24 09:25:01 track-activity LOOP_BLOCK count=6
2026-04-24 09:31:42 track-activity COMMIT
2026-04-24 09:31:18 on-stop-discipline BLOCK:UNCOMMITTED ...
2026-04-24 09:48:11 pre-write-gate PERF:8ms
```

Event tokens follow conventions:

- **`BLOCK:<reason>`** — the hook denied an action. Reason is a short kebab-case identifier.
- **`WARN:<reason>`** — the hook allowed but emitted a warning into the agent's context.
- **`INFO:<reason>`** — informational only (`5-file reminder`, `mid-file size hint`).
- **`WORKAROUND:<text>`** — `pre-bash-gate` blocked a workaround pattern. `cmd=…` shows the first 80 chars of the offending command.
- **`LOOP_BLOCK count=N`** — `track-activity` flipped the loop bit after N repeats.
- **`COMMIT` / `TEST_RAN`** — clean state transitions worth tracking.
- **`PERF:<ms>ms`** — hook performance, when `hu_timer_*` is enabled.
- **`PASS:<reason>`** — `on-stop-discipline` letting a session through cleanly.

The format is intentionally trivial to parse with `awk`, `grep`, or `python3`. Don't expect it to be JSON.

## 2. Headline numbers

The dashboard computes these from a single pass over the log:

| Card | What it counts |
|---|---|
| **Time saved** | Sum of estimated minutes per event, by event class (see §3 for the table). |
| **Tokens saved** | Sum of estimated tokens, only for `pre-read-gate` blocks/warns on large files. |
| **Blocks fired** | Count of events whose token starts with `BLOCK:`, `LOOP_BLOCK`, or `WORKAROUND:`. |
| **Sessions tracked** | Distinct `sid=` values across the whole log. |
| **First seen** | Timestamp of the oldest event. |

The **Activity** chart buckets events by hour over the last 24 hours, stacking blocks (magenta) on top of warnings (amber).

The **Top violations** table groups events by `(hook, event-class)` and shows the top 10 by count. Useful for seeing what your agent keeps trying to do.

The **Sessions** table shows the most recent 50 distinct sessions with per-session block/event counts.

The **Recent events** feed shows the tail of the log — colour-coded by severity.

## 3. The savings model

Every event class has an estimated cost-saved value, baked into `dashboard.py`:

| Event class | Time saved (min) | Why |
|---|---:|---|
| `BLOCK:freshness-not-read` | 5 | Avg debugging cost when an agent patches a stale copy and the diff is wrong |
| `BLOCK:freshness-stale` | 3 | Same class, less severe (file changed externally) |
| `BLOCK:large-file` | 1 | Mostly a token savings, modest time savings |
| `BLOCK:loop` / `LOOP_BLOCK` | 8 | Infinite loop debugging cost |
| `BLOCK:backtrack-locked` | 10 | Tunnel-vision recovery |
| `BLOCK:untested-edits` | 15 | Untested deploy bug — high-end estimate, optimistic |
| `BLOCK:3-files-no-plan` | 6 | Wrong-architecture rework |
| `BLOCK:deploy-no-test` | 20 | "SSH into prod and grep logs" cost — pessimistic |
| `BLOCK:hard-gate` (DoD) | 12 | Half-finished session that would be picked up tomorrow |
| `BLOCK:2nd-attempt` (DoD) | 4 | Lighter, since first attempt already warned |
| `WORKAROUND:*` | 5 | Bad-habit catch — short-term fix attempt prevented |

| Event class | Tokens saved | Why |
|---|---:|---|
| `BLOCK:large-file` | 8000 | Avg 800-line file = ~8K tokens at typical density |
| `WARN:medium-file` | 3000 | 200-300 line file warned-but-allowed = avg ~3K |
| `INFO:mid-file` | 1000 | 100-200 lines = ~1K |

These numbers are **deliberately conservative on the upside, pessimistic on the downside**. We don't want the dashboard to overstate the benefit. A `BLOCK:untested-edits` is credited 15 minutes — that's "if the agent had committed and you found out the next morning". It could easily be 4 hours if it reached production. We picked the lower end of the credible range.

To override the model with your own numbers, edit `TIME_SAVED_MIN` and `TOKENS_SAVED` in `scripts/dashboard.py`. Both are small dicts at the top of the file.

## 4. Limitations and honest caveats

- **The savings are an estimate, not a measurement.** They're based on our experience watching agents trip these gates. Your savings depend on your codebase, your task complexity, and how much the agent would have done before you noticed.

- **A block doesn't always save time — sometimes it costs.** A false positive (the gate fires on legitimate work) costs the override-and-retry time. The dashboard doesn't subtract this. We've tuned the gates to keep false positives low (the test suite has 100+ regression tests), but they exist.

- **Loop counts can include intentional polling.** `ssh host 'systemctl status foo'` 6 times in a row will trip the loop block. If you genuinely need to poll, use `LOOP_ACK:` to escape — the metric will still log the block, but you'll know it's a known-good escape.

- **No per-codebase normalisation.** The dashboard sums across all sessions on this machine. If you work on multiple projects, set `QG_METRICS_LOG=/path/per/project.log` per project (in your project's `.envrc` or shell config) and view them separately.

- **Memory of `/tmp` is volatile.** On reboot, your metrics log resets unless you set `QG_METRICS_LOG` to a persistent path. We recommend `QG_METRICS_LOG=$HOME/.qg/metrics.log` for long-term stats.

- **The dashboard is local-only.** It binds to `127.0.0.1` and serves only the local log. There's no auth, no TLS, no multi-user mode. If you want a team-wide view, run a separate aggregator that tails everyone's log into one source.

## 5. Using the metrics for an A/B test

Want to measure the gate's actual impact on your workflow? Reasonable protocol:

1. Pick a representative task — something that takes the agent ~30 minutes when things go well.
2. Run it twice in a clean Claude Code session: once with `QG_PROFILE=minimal` (gates disabled), once with `QG_PROFILE=strict`.
3. After each run, capture: total session time, files edited, tests run, commits made, final outcome (working / broken / abandoned).
4. Compare. If strict mode produced fewer files-edited-without-test and more commits, the gates are doing what they're supposed to.

We ran this exact protocol while developing the tool. Numbers vary heavily by task, but the consistent pattern is: strict mode produces *more commits*, *more test runs*, and *fewer files touched* per task. Whether that's faster overall depends on whether the agent would have made an unrecoverable mistake without the gates — which is the thing the test is trying to measure.

## 6. Exporting raw data

The log is plain text. Import into anything:

```bash
# How many blocks per hook over the past week?
awk -v cutoff="$(date -d '7 days ago' '+%Y-%m-%d')" \
    '$1 > cutoff && /BLOCK:/ {print $3}' /tmp/qg-metrics.log \
    | sort | uniq -c | sort -rn

# Median hook latency (when hu_timer_* is enabled).
grep PERF: /tmp/qg-metrics.log | awk -F: '{print $NF}' | sed 's/ms//' \
    | sort -n | awk '{a[NR]=$1} END{print a[int(NR/2)]}'
```

For real analysis, suck the log into a Pandas notebook and partition on `(hook, event)`. The fields are stable.
