#!/bin/bash
# session-timeout.sh — PostToolUse nudge when a session runs too long
# without a git commit.
#
# Logic:
#   - On first invocation per session, record epoch in session-start.
#   - On subsequent calls, check elapsed wall-clock time.
#   - If > QG_SESSION_MAX_MIN (default 15) AND no commit marker AND not
#     already warned this session → inject a "commit-or-explain" prompt.
#
# State:
#   $CC_HOOKS_DIR/$sid/session-start          epoch of first invocation
#   $CC_HOOKS_DIR/$sid/has-commit             touched by track-activity on commit
#   $DISC_DIR/session-timeout-warned-<sid>    one-shot marker
#
# Config:
#   QG_SESSION_MAX_MIN   default 15
#
# Disable: QG_DISABLED_HOOKS="session-timeout"
# Skipped in: minimal, easy.

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" && source "$HOOK_DIR/hook-utils.sh"
HU_HOOK_NAME="session-timeout"
hu_timer_start

init_profile
hook_disabled "session-timeout" && exit 0
[ "$HU_PROFILE" = "minimal" ] && exit 0
hu_is_easy_mode && exit 0

parse_input "$INPUT" session_id

SID="$HU_SESSION_ID"
[ -z "$SID" ] && exit 0

init_dirs "$SID"
STATE_DIR="$CC_HOOKS_DIR/$SID"
mkdir -p "$STATE_DIR" 2>/dev/null

START_FILE="$STATE_DIR/session-start"
COMMIT_MARKER="$STATE_DIR/has-commit"
WARNED_MARKER="$DISC_DIR/session-timeout-warned-${SID}"
MAX_MIN="${QG_SESSION_MAX_MIN:-15}"

NOW=$(date +%s)

# Record first-invocation timestamp.
if [ ! -f "$START_FILE" ]; then
    atomic_write "$NOW" "$START_FILE"
    hu_timer_end
    exit 0
fi

# Already warned? one-shot.
[ -f "$WARNED_MARKER" ] && { hu_timer_end; exit 0; }

# A commit happened this session → nothing to nudge.
[ -f "$COMMIT_MARKER" ] && { hu_timer_end; exit 0; }

START_TS=$(cat "$START_FILE" 2>/dev/null)
case "$START_TS" in
    ''|*[!0-9]*) hu_timer_end; exit 0 ;;
esac

ELAPSED=$((NOW - START_TS))
LIMIT=$((MAX_MIN * 60))

if [ "$ELAPSED" -lt "$LIMIT" ]; then
    hu_timer_end
    exit 0
fi

touch "$WARNED_MARKER"
ELAPSED_MIN=$((ELAPSED / 60))
log_metric "SESSION_TIMEOUT elapsed_min=$ELAPSED_MIN"

MSG="SESSION TIMEOUT: ${ELAPSED_MIN}m elapsed without a git commit. Commit what already works, or explain in one line why more time is needed before the next edit."

json_context "$MSG" "PostToolUse"
hu_timer_end
exit 0
