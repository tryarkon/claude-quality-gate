#!/bin/bash
# PostToolUse hook: tracks session activity to feed other hooks.
# Writes state files in $DISC_DIR used by pre-write-gate / pre-bash-gate / on-stop-discipline.
#
# Tracked behaviours:
#   - Loop detection: N identical bash commands → write $LOOP_FILE
#   - Churn detection: same file edited 3+ times → set backtrack markers
#   - Untested edits: 10+ code edits without a test run → set $UNTESTED_BLOCK
#   - Test / commit / ACK markers: clear counters when the user actually runs tests,
#     commits, or acknowledges via echo LOOP_ACK / BACKTRACK_ACK / TEST_SKIP
#
# Everything is plain files under $DISC_DIR — no database dependency.

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" && source "$HOOK_DIR/hook-utils.sh"
HU_HOOK_NAME="track-activity"
hu_timer_start

parse_input "$INPUT" session_id tool_name file_path command tool_output

SID="$HU_SESSION_ID"
TOOL="$HU_TOOL_NAME"
FPATH="$HU_FILE_PATH"
CMD="$HU_COMMAND"

# Nothing to track without at least a tool name.
[ -z "$TOOL" ] && exit 0

init_dirs "$SID"
SESSION_FILE="$DISC_DIR/session-${SID}"
LOOP_FILE="$DISC_DIR/loop-${SID}"

MESSAGES=""
msg() { [ -n "$MESSAGES" ] && MESSAGES="$MESSAGES"$'\n'"$1" || MESSAGES="$1"; }

# --- Helper: short hash of a string ---
h16() { md5_string "$1" | cut -c1-16; }

# ============================================================
# BASH: test / commit / ACK detection + loop counter
# ============================================================
if [ "$TOOL" = "Bash" ] && [ -n "$CMD" ]; then
    # Test command → reset untested counter + set tests-ran flag
    case "$CMD" in
        pytest*|"cargo test"*|"npm test"*|"npx vitest"*|"npx jest"*|"python3 -m pytest"*|"go test"*)
            touch "$DISC_DIR/tests-ran-${SID}"
            hu_state_op set "$SID" "edits_no_test" "0" >/dev/null
            hu_state_op set "$SID" "edits_warned5" "0" >/dev/null
            hu_state_op set "$SID" "edits_warned8" "0" >/dev/null
            hu_state_op set "$SID" "edits_warned10" "0" >/dev/null
            rm -f "$DISC_DIR/untested-block-${SID}" 2>/dev/null
            rm -f "$DISC_DIR/deploy-block-${SID}" 2>/dev/null
            log_metric "TEST_RAN"
            ;;
    esac

    # git commit → reset churn + edits + set has-commit marker
    case "$CMD" in
        "git commit"*)
            # Clear all per-file churn markers
            hu_state_op clear "$SID" "*" >/dev/null
            rm -f "$DISC_DIR/untested-block-${SID}" 2>/dev/null
            # Breadcrumb for session-timeout hook (stays inside CC_HOOKS_DIR/$sid).
            mkdir -p "$CC_HOOKS_DIR/$SID" 2>/dev/null
            touch "$CC_HOOKS_DIR/$SID/has-commit" 2>/dev/null
            log_metric "COMMIT"
            ;;
    esac

    # ACK escapes: LOOP_ACK, BACKTRACK_ACK, TEST_SKIP
    if echo "$CMD" | grep -q 'LOOP_ACK:'; then
        rm -f "$LOOP_FILE" 2>/dev/null
        log_metric "LOOP_ACK"
    fi
    if echo "$CMD" | grep -q 'BACKTRACK_ACK:'; then
        rm -rf "$DISC_DIR/backtrack-${SID}" 2>/dev/null
        log_metric "BACKTRACK_ACK"
    fi
    if echo "$CMD" | grep -q 'TEST_SKIP:'; then
        hu_state_op set "$SID" "edits_no_test" "0" >/dev/null
        rm -f "$DISC_DIR/untested-block-${SID}" 2>/dev/null
        log_metric "TEST_SKIP_ACK"
    fi
    if echo "$CMD" | grep -q 'TEST_EDIT_ACK:'; then
        mkdir -p "$DISC_DIR" 2>/dev/null
        touch "$DISC_DIR/tests-edit-ack-${SID}"
        log_metric "TEST_EDIT_ACK"
    fi
    if echo "$CMD" | grep -q 'RESEARCH_ACK:'; then
        mkdir -p "$DISC_DIR" 2>/dev/null
        touch "$DISC_DIR/research-ack-${SID}"
        log_metric "RESEARCH_ACK"
    fi

    # Loop detection: increment counter for this command's hash.
    # For ssh/scp, hash only the host/prefix so varying inline code still collides.
    LOOP_KEY="$CMD"
    case "$CMD" in
        "ssh "*)
            LOOP_KEY=$(echo "$CMD" | awk '{print $1" "$2}') ;;
        "scp "*)
            HOST_PART=$(echo "$CMD" | tr ' ' '\n' | grep -m1 ':' | cut -d: -f1)
            [ -n "$HOST_PART" ] && LOOP_KEY="scp $HOST_PART" ;;
    esac
    LH=$(h16 "$LOOP_KEY")
    LC=$(hu_state_op incr "$SID" "loop_${LH}")
    # Threshold: 6+ identical commands → write LOOP_FILE (read by pre-write-gate)
    if [ "$LC" -ge 6 ]; then
        CMD_SHORT=$(echo "$CMD" | head -c 80)
        echo "LOOP BLOCKED: command '$CMD_SHORT' executed $LC times. Write/Edit blocked. To unlock: echo 'LOOP_ACK: <reason>'." > "$LOOP_FILE"
        log_metric "LOOP_BLOCK count=$LC"
    elif [ "$LC" -ge 3 ]; then
        msg "⚠️ LOOP: same command executed $LC times. After 6 executions Write/Edit will be blocked."
    fi
fi

# ============================================================
# WRITE/EDIT: churn + untested edits + session counter
# ============================================================
if { [ "$TOOL" = "Write" ] || [ "$TOOL" = "Edit" ]; } && [ -n "$FPATH" ]; then
    # Record file in session list (used by pre-write-gate / on-stop-discipline).
    mkdir -p "$DISC_DIR" 2>/dev/null
    echo "$FPATH" >> "$SESSION_FILE"

    # Per-file churn counter
    FH=$(h16 "$FPATH")
    CC=$(hu_state_op incr "$SID" "churn_${FH}")

    if [ "$CC" -ge 5 ]; then
        # Hard: backtrack lock
        W5=$(hu_state_op get "$SID" "churn_warned5_${FH}")
        if [ "${W5:-0}" -eq 0 ]; then
            hu_state_op set "$SID" "churn_warned5_${FH}" "1" >/dev/null
            BT_DIR="$DISC_DIR/backtrack-${SID}"
            mkdir -p "$BT_DIR"
            touch "$BT_DIR/$(md5_short "$FPATH")-locked"
            msg "BACKTRACK LOCK: $(basename "$FPATH") edited $CC times — tunnel vision. File reset. Describe a DIFFERENT approach: echo 'BACKTRACK_ACK: <new approach>'."
            log_metric "CHURN:backtrack-lock file=$(basename "$FPATH") count=$CC"
        fi
    elif [ "$CC" -ge 3 ]; then
        # Soft: warning
        W3=$(hu_state_op get "$SID" "churn_warned3_${FH}")
        if [ "${W3:-0}" -eq 0 ]; then
            hu_state_op set "$SID" "churn_warned3_${FH}" "1" >/dev/null
            msg "⚠️ CHURN: $(basename "$FPATH") edited $CC times. Are you fixing the root or thrashing symptoms?"
            log_metric "CHURN:warn file=$(basename "$FPATH") count=$CC"
        fi
    fi

    # Untested edits (code files only)
    EXT="${FPATH##*.}"
    case "$EXT" in
        rs|py|ts|tsx|js|jsx|go|rb|c|cpp|swift|java)
            EC=$(hu_state_op incr "$SID" "edits_no_test")
            if [ "$EC" -ge 10 ]; then
                W10=$(hu_state_op get "$SID" "edits_warned10")
                if [ "${W10:-0}" -eq 0 ]; then
                    hu_state_op set "$SID" "edits_warned10" "1" >/dev/null
                    echo "$EC" > "$DISC_DIR/untested-block-${SID}"
                    msg "STOP: $EC code edits without running any tests. Write is now BLOCKED. Run pytest / cargo test, or 'echo TEST_SKIP: <reason>' to override."
                    log_metric "EDITS:block count=$EC"
                fi
            elif [ "$EC" -ge 8 ]; then
                W8=$(hu_state_op get "$SID" "edits_warned8")
                if [ "${W8:-0}" -eq 0 ]; then
                    hu_state_op set "$SID" "edits_warned8" "1" >/dev/null
                    msg "⚠️ $EC code edits, no tests yet. At 10 Write will be blocked."
                fi
            elif [ "$EC" -ge 5 ]; then
                W5e=$(hu_state_op get "$SID" "edits_warned5")
                if [ "${W5e:-0}" -eq 0 ]; then
                    hu_state_op set "$SID" "edits_warned5" "1" >/dev/null
                    msg "INFO: $EC code edits without tests. Consider running tests before continuing."
                fi
            fi
            ;;
    esac
fi

# ============================================================
# READ: freshness hash (read-before-write contract)
# ============================================================
if [ "$TOOL" = "Read" ] && [ -n "$FPATH" ] && [ -f "$FPATH" ]; then
    READS_DIR="$CC_READS_DIR/${SID}"
    mkdir -p "$READS_DIR"
    HASH_KEY=$(md5_string "$FPATH")
    md5_file "$FPATH" > "$READS_DIR/$HASH_KEY"
fi

# ============================================================
# RESEARCH counter (feeds pre-research-gate)
# ============================================================
case "$TOOL" in
    Read|Grep|Glob)
        hu_state_op incr "$SID" "research_count" >/dev/null
        ;;
esac

# ============================================================
# Emit context messages (if any)
# ============================================================
if [ -n "$MESSAGES" ]; then
    json_context "$MESSAGES" "PostToolUse"
fi

hu_timer_end
exit 0
