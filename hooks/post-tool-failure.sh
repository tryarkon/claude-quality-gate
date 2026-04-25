#!/bin/bash
# post-tool-failure.sh — track repeated tool failures in a session.
#
# PostToolUseFailure hook. Claude Code invokes this when a tool call returns
# an error. We count per-session failures and inject a "you may be looping"
# warning after the 5th failure.
#
# Why: agents under pressure will sometimes retry the same broken command
# 10 times in a row. A single failure is normal; five in one session is a
# signal to step back and reconsider the approach.
#
# Disable: QG_DISABLED_HOOKS="tool-failure"

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" && source "$HOOK_DIR/hook-utils.sh"

HU_HOOK_NAME="post-tool-failure"
hu_timer_start

init_profile
[ "$HU_PROFILE" = "minimal" ] && exit 0
hook_disabled "tool-failure" && exit 0

parse_input "$INPUT" session_id tool_name
SID="$HU_SESSION_ID"

log_metric "ERROR:tool-failure tool=$HU_TOOL_NAME"

mkdir -p "$DISC_DIR" 2>/dev/null
FAIL_FILE="$DISC_DIR/fail-count-${SID}"
FAIL_COUNT=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
FAIL_COUNT=$((FAIL_COUNT + 1))
atomic_write "$FAIL_COUNT" "$FAIL_FILE"

if [ "$FAIL_COUNT" -ge 5 ]; then
    WARN_FILE="$DISC_DIR/fail-warned-${SID}"
    if [ ! -f "$WARN_FILE" ]; then
        touch "$WARN_FILE"
        json_context "${FAIL_COUNT} tool failures in this session. Step back: are you retrying the same broken command? What's the root cause? Changing approach beats re-running." "PostToolUseFailure"
        log_metric "FAIL_WARN count=$FAIL_COUNT"
    fi
fi

hu_timer_end
exit 0
