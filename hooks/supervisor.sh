#!/bin/bash
# supervisor.sh — Self-reflection supervisor + tool execution watchdog.
#
# Two roles in one hook:
#   1. (PostToolUse) Every N actions, read the last N tool uses from the
#      session transcript, detect symptom-patching cycles + file churn,
#      inject a self-check prompt into the agent's context.
#   2. (PreToolUse, called as `supervisor.sh pre`) Records a start timestamp
#      so the post hook can detect tool calls that took too long (hanging
#      compiler, endless test runner, unresponsive subagent).
#
# Zero API cost — the agent evaluates itself using its own next-turn
# reasoning. No external LLM call.
#
# State:
#   $CC_HOOKS_DIR/supervisor-count-<sid16>    counter (atomic_increment)
#   $CC_HOOKS_DIR/supervisor-watchdog-<sid16> "<epoch> <tool>" from pre
#
# Config:
#   QG_SUPERVISOR_INTERVAL  default 10    inject every Nth tool call
#   QG_SLOW_TOOL_SECS       default 90    generic "slow" threshold
#   QG_SLOW_BASH_SECS       default 180   bash gets more time (builds/tests)
#   QG_SLOW_TASK_SECS       default 300   subagent Task gets even more
#
# Disable: QG_DISABLED_HOOKS="supervisor"

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" && source "$HOOK_DIR/hook-utils.sh"
HU_HOOK_NAME="supervisor"
hu_timer_start

INTERVAL="${QG_SUPERVISOR_INTERVAL:-10}"
SLOW_THRESHOLD="${QG_SLOW_TOOL_SECS:-90}"
SLOW_BASH="${QG_SLOW_BASH_SECS:-180}"
SLOW_TASK="${QG_SLOW_TASK_SECS:-300}"

parse_input "$INPUT" session_id tool_name transcript_path
SID="$HU_SESSION_ID"
TOOL="$HU_TOOL_NAME"
TRANSCRIPT="$HU_TRANSCRIPT_PATH"

init_profile
hook_disabled "supervisor" && exit 0
[ "$HU_PROFILE" = "minimal" ] && exit 0
hu_is_easy_mode && exit 0

init_dirs "$SID"
SID16="${SID:0:16}"
WATCHDOG_FILE="$CC_HOOKS_DIR/supervisor-watchdog-${SID16}"

# --- PreToolUse mode: timestamp + tool, exit ---
if [ "${1:-}" = "pre" ]; then
    echo "$(date +%s) $TOOL" > "$WATCHDOG_FILE"
    hu_timer_end
    exit 0
fi

# --- PostToolUse mode ---

# Slow-tool detection (fires regardless of interval).
SLOW_MSG=""
if [ -f "$WATCHDOG_FILE" ]; then
    PRE_DATA=$(cat "$WATCHDOG_FILE")
    PRE_TS=$(echo "$PRE_DATA" | cut -d' ' -f1)
    PRE_TOOL=$(echo "$PRE_DATA" | cut -d' ' -f2-)
    NOW_TS=$(date +%s)
    ELAPSED=$((NOW_TS - PRE_TS))

    THRESHOLD=$SLOW_THRESHOLD
    case "$PRE_TOOL" in
        Bash) THRESHOLD=$SLOW_BASH ;;
        Task) THRESHOLD=$SLOW_TASK ;;
    esac

    if [ "$ELAPSED" -gt "$THRESHOLD" ]; then
        ELAPSED_MIN=$((ELAPSED / 60))
        ELAPSED_SEC=$((ELAPSED % 60))
        SLOW_MSG="SLOW TOOL: ${PRE_TOOL} took ${ELAPSED_MIN}m${ELAPSED_SEC}s (threshold: ${THRESHOLD}s). If this tool was hanging or unresponsive — consider a different approach or smaller scope."
        log_metric "SLOW_TOOL tool=$PRE_TOOL elapsed=${ELAPSED}s"
    fi
    rm -f "$WATCHDOG_FILE"
fi

COUNTER_FILE="$CC_HOOKS_DIR/supervisor-count-${SID16}"
COUNT=$(atomic_increment "$COUNTER_FILE")

# Emit slow warning immediately.
if [ -n "$SLOW_MSG" ]; then
    json_context "$SLOW_MSG" "PostToolUse"
fi

# Not time for periodic reflection?
[ $((COUNT % INTERVAL)) -ne 0 ] && { hu_timer_end; exit 0; }

# Need a transcript to reflect on.
[ -z "$TRANSCRIPT" ] && { hu_timer_end; exit 0; }
[ ! -f "$TRANSCRIPT" ] && { hu_timer_end; exit 0; }

# --- Periodic reflection: parse last N tool uses from transcript JSONL ---
SUMMARY=$(python3 - "$TRANSCRIPT" "$INTERVAL" "$COUNT" <<'PYEOF' 2>/dev/null
import json, sys, os

transcript = sys.argv[1]
n = int(sys.argv[2])
total = int(sys.argv[3])

code_exts = ('.py', '.rs', '.ts', '.tsx', '.js', '.jsx', '.sh', '.go', '.rb', '.c', '.cpp', '.swift', '.java')
test_cmd_markers = ('pytest', 'cargo test', 'npm test', 'npx vitest', 'npx jest', 'go test', 'mocha', 'phpunit', 'rspec')

# Read last N tool_use events. Claude Code JSONL: each line is {"type":...,"message":...}
# Tool calls appear inside assistant messages as content[...] with type=="tool_use".
try:
    with open(transcript, encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
except OSError:
    sys.exit(0)

tools = []  # list of {"name","input","ts"}
for ln in lines:
    try:
        obj = json.loads(ln)
    except Exception:
        continue
    msg = obj.get("message") if isinstance(obj, dict) else None
    ts = obj.get("timestamp", "")
    content = msg.get("content") if isinstance(msg, dict) else None
    if not isinstance(content, list):
        continue
    for item in content:
        if isinstance(item, dict) and item.get("type") == "tool_use":
            tools.append({
                "name": item.get("name", ""),
                "input": item.get("input", {}) or {},
                "ts": ts[-8:-3] if len(ts) >= 8 else "",
            })

recent = tools[-n:]
if not recent:
    sys.exit(0)

files_edited = {}
commands_run = {}
test_runs = 0
edits_after_test = 0
last_was_test = False
any_code = False
actions_out = []

for t in recent:
    nm = t["name"]
    inp = t["input"]
    ts = t["ts"] or "--:--"
    if nm in ("Write", "Edit"):
        fpath = inp.get("file_path", "")
        fname = fpath.rsplit("/", 1)[-1] if fpath else "?"
        files_edited[fname] = files_edited.get(fname, 0) + 1
        if fname.endswith(code_exts):
            any_code = True
        if last_was_test:
            edits_after_test += 1
        last_was_test = False
        actions_out.append(f"  {ts} {nm} {fname}")
    elif nm == "Bash":
        cmd = (inp.get("command") or "")[:60]
        key = cmd[:40]
        commands_run[key] = commands_run.get(key, 0) + 1
        low = cmd.lower()
        if any(marker in low for marker in test_cmd_markers):
            test_runs += 1
            last_was_test = True
        else:
            last_was_test = False
        actions_out.append(f"  {ts} Bash {cmd}")
    else:
        last_was_test = False
        label = inp.get("file_path") or inp.get("command") or inp.get("pattern") or ""
        if label:
            label = str(label)[:60]
        actions_out.append(f"  {ts} {nm} {label}")

is_symptom_cycle = test_runs >= 2 and edits_after_test >= 2

lines_out = [f"--- SUPERVISOR (action {total}) ---"]
lines_out.extend(actions_out)

alerts = []
for fname, c in files_edited.items():
    if c >= 3:
        alerts.append(f"{fname} edited {c}x")
for cmd, c in commands_run.items():
    if c >= 3:
        alerts.append(f"{cmd!r} repeated {c}x")

# Conditional inject: emit ONLY when a concrete pattern is detected.
# No-pattern = silent (avoids periodic "Self-check" prompt-overhead).
if is_symptom_cycle:
    lines_out.append(f"SYMPTOM-FIX CYCLE DETECTED: {test_runs} test runs, {edits_after_test} edits after failures.")
    lines_out.append("STOP. You are patching symptoms, not fixing the root cause.")
    lines_out.append("Before your next edit: (1) What is the ACTUAL error? (2) WHERE does it originate — not where it manifests? (3) Use goToDefinition/findReferences to trace it. One fix at the source > five patches at symptoms.")
    print("\n".join(lines_out))
elif alerts:
    lines_out.append("PATTERNS: " + "; ".join(alerts))
    if any_code:
        lines_out.append("Self-check: are you fixing the ROOT CAUSE or patching symptoms? If the same file keeps changing — you probably haven't found the real problem yet. STOP, re-read the error, trace it to the source.")
    else:
        lines_out.append("Self-check: are you spinning or making real progress?")
    print("\n".join(lines_out))
# else: silent — no pattern detected, no need to inject a generic prompt.
PYEOF
)

if [ -n "$SUMMARY" ]; then
    json_context "$SUMMARY" "PostToolUse"
    log_metric "SUPERVISOR_CHECK count=$COUNT"
fi

hu_timer_end
exit 0
