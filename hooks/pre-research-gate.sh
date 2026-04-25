#!/bin/bash
# pre-research-gate.sh — force context accumulation before first Edit.
#
# Observation from SWE-bench A/B: agents that solved hard tasks read 3+ files
# before editing. Agents that failed jumped straight into Edit. This gate
# enforces that pattern: before the first Edit of an existing file, require
# at least N (default 3) Read/Grep/Glob tool calls in this session.
#
# Applies only to Edit of existing files. Write (new file) and all non-file
# tools are unaffected.
#
# State:  $CC_HOOKS_DIR/$sid/research_done   (touched once threshold met)
# Counter: tracked by track-activity ("research_count" key).
#
# Config:
#   QG_RESEARCH_MIN     default 3   Read/Grep/Glob calls before first Edit
#
# Disable: QG_DISABLED_HOOKS="research-gate"

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" && source "$HOOK_DIR/hook-utils.sh"
HU_HOOK_NAME="pre-research-gate"
hu_timer_start

MIN="${QG_RESEARCH_MIN:-3}"

init_profile
[ "$HU_PROFILE" = "minimal" ] && exit 0
hu_is_easy_mode && exit 0
hook_disabled "research-gate" && exit 0

parse_input "$INPUT" session_id tool_name file_path
SID="$HU_SESSION_ID"
TOOL="$HU_TOOL_NAME"
FPATH="$HU_FILE_PATH"

# Only gate Edit — Write (new file) is creation, not revision.
[ "$TOOL" != "Edit" ] && exit 0
[ -z "$FPATH" ] && exit 0
[ ! -f "$FPATH" ] && exit 0

init_dirs "$SID"

DONE_MARKER="$CC_HOOKS_DIR/$SID/research_done"
[ -f "$DONE_MARKER" ] && exit 0

# ACK escape: user explicitly overrode.
ACK_FILE="$DISC_DIR/research-ack-${SID}"
if [ -f "$ACK_FILE" ]; then
    rm -f "$ACK_FILE"
    touch "$DONE_MARKER"
    log_metric "RESEARCH_ACK_USED"
    exit 0
fi

# Count research actions (written by track-activity).
RCOUNT=$(hu_state_op get "$SID" "research_count")
[ -z "$RCOUNT" ] && RCOUNT=0

if [ "$RCOUNT" -ge "$MIN" ]; then
    touch "$DONE_MARKER"
    exit 0
fi

BASENAME=$(basename "$FPATH")
log_metric "BLOCK:research-gate rcount=$RCOUNT needed=$MIN file=$BASENAME"

MSG="RESEARCH GATE: you have made $RCOUNT Read/Grep/Glob calls this session — before editing ${BASENAME}, $MIN are expected.

Editing before understanding is the single most expensive mistake — every wrong edit costs a re-read, a failing test, and a revert.

What to do:
  1. Read the file you're about to edit (full file, or a bounded section).
  2. Read adjacent test files (how is the behaviour specified?).
  3. grep for all callers of the function you're changing (what's the impact radius?).
  4. Then Edit.

Escape: 'echo RESEARCH_ACK: <why this edit is safe without more research>'"

if [ "$HU_PROFILE" = "strict" ]; then
    json_deny "$MSG"
else
    json_allow "⚠️ ${MSG}"
fi

hu_timer_end
exit 0
