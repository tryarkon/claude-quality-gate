#!/bin/bash
# pre-edit-tests-gate.sh — protect tests/ directories from silent tampering.
#
# Blocks Edit/Write on files that look like test files (test_*.py, *_test.py,
# conftest.py, tests/* .rs/.ts/.js) unless the agent has explicitly written
# `echo TEST_EDIT_ACK: <reason>` in a Bash command.
#
# Why:
#   Agents under pressure will sometimes remove assertions or dilute test
#   cases to make a failing test pass. That's the single most destructive
#   workaround pattern — it silently makes the test suite useless for
#   regression detection. Bash-level sed-removes-assert is already caught
#   by pre-bash-gate, but the same effect is easily achieved via Edit/Write
#   directly. This gate closes that hole.
#
# Allow:
#   - Creating NEW test files (file doesn't exist yet).
#   - Files outside recognised test paths.
#   - After echo TEST_EDIT_ACK: reason   (one-shot unlock).
#
# Disable: QG_DISABLED_HOOKS="tests-integrity"
# Profile: strict = deny, standard = warn, minimal = skip

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" && source "$HOOK_DIR/hook-utils.sh"
HU_HOOK_NAME="pre-edit-tests-gate"
hu_timer_start

init_profile
[ "$HU_PROFILE" = "minimal" ] && exit 0
hook_disabled "tests-integrity" && exit 0

parse_input "$INPUT" session_id file_path tool_name
SID="$HU_SESSION_ID"
FPATH="$HU_FILE_PATH"
TOOL="$HU_TOOL_NAME"

[ -z "$FPATH" ] && exit 0

# Identify test files by common conventions.
BASENAME=$(basename "$FPATH")
IS_TEST=false
case "$BASENAME" in
    test_*.py|*_test.py|conftest.py|*_test.rs|*_test.go|*_spec.rb) IS_TEST=true ;;
    *.test.ts|*.test.tsx|*.test.js|*.test.jsx|*.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx) IS_TEST=true ;;
esac

# Also catch anything under a top-level tests/ or __tests__/ directory.
case "$FPATH" in
    */tests/*|*/test/*|*/__tests__/*|*/spec/*|*/specs/*) IS_TEST=true ;;
esac

[ "$IS_TEST" = "false" ] && exit 0

# New file creation is allowed — the gate is only about *modifying* existing tests.
if [ ! -f "$FPATH" ]; then
    exit 0
fi

# One-shot ACK?  track-activity (via pre-bash-gate) writes the marker.
init_dirs "$SID"
ACK_FILE="$DISC_DIR/tests-edit-ack-${SID}"
if [ -f "$ACK_FILE" ]; then
    rm -f "$ACK_FILE"
    log_metric "TESTS_EDIT_ACK_USED file=$BASENAME"
    exit 0
fi

# Block.
MSG="BLOCKED: modifying existing test file ${BASENAME} without acknowledgement.

Editing tests while trying to make them pass is the single most destructive
workaround pattern — it turns your test suite into decoration.

If you genuinely need to update this test (API changed, test was wrong):
  1. State why in plain words: echo 'TEST_EDIT_ACK: <reason>'
  2. Then retry the Edit.

If you were about to weaken an assertion to get green — stop and fix the code instead."

log_metric "BLOCK:tests-integrity file=$BASENAME"

if [ "$HU_PROFILE" = "standard" ]; then
    json_allow "⚠️ ${MSG}"
else
    json_deny "$MSG"
fi

hu_timer_end
exit 0
