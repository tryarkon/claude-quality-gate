#!/bin/bash
# error-parser-hook.sh — PostToolUse hook.
#
# Detects test/compile failures in Bash tool output. After N consecutive
# failing outputs for the same session, injects a targeted "what will you
# fix?" prompt that names the first parsed error line — forcing the agent
# to trace the error before its next edit instead of blindly retrying.
#
# State:
#   $CC_HOOKS_DIR/$sid/errfix-streak        consecutive-failure counter
#   $CC_HOOKS_DIR/$sid/last-errfix-injected marker to throttle injections
#
# Config:
#   QG_ERRFIX_STREAK   default 3   inject after this many consecutive fails
#
# Disable: QG_DISABLED_HOOKS="error-parser"
# Skipped in: minimal, easy.

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" && source "$HOOK_DIR/hook-utils.sh"
HU_HOOK_NAME="error-parser"
hu_timer_start

init_profile
hook_disabled "error-parser" && exit 0
[ "$HU_PROFILE" = "minimal" ] && exit 0
hu_is_easy_mode && exit 0

parse_input "$INPUT" session_id tool_name tool_output

SID="$HU_SESSION_ID"
TOOL="$HU_TOOL_NAME"
OUT="$HU_TOOL_OUTPUT"

[ -z "$SID" ] && exit 0
[ "$TOOL" != "Bash" ] && exit 0
[ -z "$OUT" ] && exit 0

init_dirs "$SID"

STREAK_KEY="errfix-streak"
INJECTED_KEY="last-errfix-injected"
THRESHOLD="${QG_ERRFIX_STREAK:-3}"

# --- Detect failure patterns and extract first offending line ---
# Use python for reliable multi-pattern match + short-line extraction.
ERR_LINE=$(python3 - "$OUT" <<'PYEOF' 2>/dev/null
import re, sys
text = sys.argv[1] if len(sys.argv) > 1 else ""
patterns = [
    r"AssertionError:.*",
    r"FAILED\s+\S+.*",
    r"^\s*assert\s+.*",
    r"failed with error.*",
    r"test_\w+\s+.*FAIL",
    r"error\[E\d+\].*",
    r"error TS\d+:.*",
    r"^\s*error:.*",
]
for p in patterns:
    m = re.search(p, text, re.IGNORECASE | re.MULTILINE)
    if m:
        line = m.group(0).strip()
        # trim excessive length
        if len(line) > 240:
            line = line[:240] + "..."
        print(line)
        sys.exit(0)
PYEOF
)

if [ -z "$ERR_LINE" ]; then
    # Output is clean → reset streak and exit.
    hu_state_op set "$SID" "$STREAK_KEY" "0" >/dev/null
    hu_state_op clear "$SID" "$INJECTED_KEY" >/dev/null
    hu_timer_end
    exit 0
fi

# Bump streak
STREAK=$(hu_state_op incr "$SID" "$STREAK_KEY")

if [ "$STREAK" -lt "$THRESHOLD" ]; then
    hu_timer_end
    exit 0
fi

# Throttle: inject only once per THRESHOLD window (at streak = THRESHOLD,
# 2*THRESHOLD, 3*THRESHOLD, ...). Avoids a prompt on every single failure
# after the first threshold has been crossed.
MOD=$(( STREAK % THRESHOLD ))
if [ "$MOD" -ne 0 ]; then
    hu_timer_end
    exit 0
fi

LAST_INJECTED=$(hu_state_op get "$SID" "$INJECTED_KEY")
if [ "${LAST_INJECTED:-0}" -ge "$STREAK" ]; then
    hu_timer_end
    exit 0
fi
hu_state_op set "$SID" "$INJECTED_KEY" "$STREAK" >/dev/null

log_metric "ERRFIX_INJECT streak=$STREAK"

MSG="TEST FAILURE: ${ERR_LINE}
Before your next edit: What exactly is wrong? What will you change? Don't retry — trace the error."

json_context "$MSG" "PostToolUse"
hu_timer_end
exit 0
