#!/bin/bash
# Stop gate: Definition of Done.
# If the session edited 3+ code files, require: tests ran + no uncommitted changes.
# Progressive escalation: 1st attempt warns, 2nd is final warning, 3rd passes through
# except for tests (hard gate) and commits (hard gate).

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" && source "$HOOK_DIR/hook-utils.sh"

INPUT=$(cat)
parse_input "$INPUT" session_id stop_hook_active cwd
HU_HOOK_NAME="on-stop-discipline"
hu_timer_start

init_profile
if [ "$HU_PROFILE" = "minimal" ] || hook_disabled "stop-discipline"; then exit 0; fi

# Prevent infinite loop when Claude re-prompts after our block.
if [ "$HU_STOP_HOOK_ACTIVE" = "true" ] || [ "$HU_STOP_HOOK_ACTIVE" = "True" ]; then
    exit 0
fi

SESSION_FILE="$DISC_DIR/session-${HU_SESSION_ID}"

if [ ! -f "$SESSION_FILE" ] || [ ! -s "$SESSION_FILE" ]; then
    exit 0
fi

ISSUES=""

EDITED_COUNT=0
HAS_CODE=false
if [ -f "$SESSION_FILE" ]; then
    EDITED_COUNT=$(sort -u "$SESSION_FILE" | wc -l | tr -d ' ')
    if grep -qE '\.(rs|py|ts|tsx|js|go|rb|c|cpp|swift|java)$' "$SESSION_FILE" 2>/dev/null; then
        HAS_CODE=true
    fi
fi

if [ "$EDITED_COUNT" -eq 0 ]; then
    log_metric "PASS:no-edits"
    exit 0
fi

if [ "$EDITED_COUNT" -le 2 ] && [ "$HAS_CODE" = "false" ]; then
    log_metric "PASS:trivial"
    exit 0
fi

# --- Check 1: tests ran? ---
# track-activity.sh is expected to touch this flag when a test command runs.
TESTS_RAN=false
if [ -f "$DISC_DIR/tests-ran-${HU_SESSION_ID}" ]; then
    TESTS_RAN=true
fi

HAS_TESTS=false
if [ -n "$HU_CWD" ]; then
    if [ -f "$HU_CWD/Cargo.toml" ]; then HAS_TESTS=true; fi
    if ls "$HU_CWD"/test_*.py "$HU_CWD"/tests/test_*.py "$HU_CWD"/*_test.py 2>/dev/null | head -1 | grep -q .; then HAS_TESTS=true; fi
    if [ -f "$HU_CWD/pytest.ini" ] || [ -f "$HU_CWD/pyproject.toml" ]; then HAS_TESTS=true; fi
    if [ -f "$HU_CWD/package.json" ] && grep -q '"test"' "$HU_CWD/package.json" 2>/dev/null; then HAS_TESTS=true; fi
fi

if [ "$TESTS_RAN" = "false" ] && [ "$HAS_CODE" = "true" ] && [ "$HAS_TESTS" = "true" ] && ! hook_disabled "tests"; then
    ISSUES="${ISSUES}TESTS NOT RUN. Run cargo test / pytest / npm test before stopping. "
fi

# --- Check 2: uncommitted changes in session-edited files? ---
if [ -f "$SESSION_FILE" ] && ! hook_disabled "commit" && git -C "$HU_CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    DIRTY=""
    while IFS= read -r edited_file; do
        [ -z "$edited_file" ] && continue
        FILE_STATUS=$(git -C "$HU_CWD" status --short -- "$edited_file" 2>/dev/null)
        if [ -n "$FILE_STATUS" ]; then
            DIRTY="${DIRTY}${FILE_STATUS}\n"
        fi
    done < <(sort -u "$SESSION_FILE")
    if [ -n "$DIRTY" ]; then
        ISSUES="${ISSUES}UNCOMMITTED CHANGES — run git commit before stopping. "
    fi
fi

if [ -n "$ISSUES" ]; then
    ATTEMPT=$(hu_state_op incr "$HU_SESSION_ID" "stop_attempt")

    if [ "$ATTEMPT" -eq 2 ]; then
        log_metric "BLOCK:2nd-attempt:${ISSUES}"
        json_stop_block "⚠️ REPEAT (2/3): ${ISSUES}— next attempt will pass through."
    elif [ "$ATTEMPT" -ge 3 ]; then
        if echo "$ISSUES" | grep -q "TESTS NOT RUN"; then
            log_metric "BLOCK:hard-gate:${ISSUES}"
            json_stop_block "TESTS ARE MANDATORY (attempt $ATTEMPT): ${ISSUES}"
        fi
        if echo "$ISSUES" | grep -q "UNCOMMITTED"; then
            log_metric "BLOCK:hard-gate:${ISSUES}"
            json_stop_block "COMMIT IS MANDATORY (attempt $ATTEMPT): ${ISSUES}"
        fi
        log_metric "PASS:3rd-attempt:${ISSUES}"
        exit 0
    fi

    if [ "$HU_PROFILE" = "standard" ]; then
        log_metric "WARN:${ISSUES}"
        echo "⚠️ RECOMMEND: ${ISSUES}" >&2
    else
        log_metric "BLOCK:${ISSUES}"
        touch "$DISC_DIR/stop-blocked-${HU_SESSION_ID}"
        json_stop_block "DEFINITION OF DONE: ${ISSUES}"
    fi
fi

log_metric "PASS:all-checks"

rm -f "$DISC_DIR"/*-${HU_SESSION_ID} 2>/dev/null
rm -f "$DISC_DIR/tests-ran-${HU_SESSION_ID}" 2>/dev/null
rm -rf "$CC_READS_DIR/${HU_SESSION_ID}" 2>/dev/null
hu_state_op clear "$HU_SESSION_ID" "*" 2>/dev/null

hu_timer_end
exit 0
