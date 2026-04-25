#!/bin/bash
# PreToolUse gate for Write/Edit.
# Enforces:
#   - Freshness: file must be Read before Write (md5 hash compared)
#   - Concurrent-edit warning: warn if file was committed in last 30 min
#   - Loop block: honour $LOOP_FILE set by track-activity.sh
#   - Backtrack lock: file reset requires acknowledging a different approach
#   - Untested-edit block: 10+ code edits without tests → deny
#   - 3-file gate: 3 unique files edited without a plan → deny
#   - 5-file reminder: remind to commit + run tests at 5, 10, 15... files

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" && source "$HOOK_DIR/hook-utils.sh"
HU_HOOK_NAME="pre-write-gate"
hu_timer_start
INPUT=$(cat)

init_profile "strict"
if [ "$HU_PROFILE" = "minimal" ]; then exit 0; fi

parse_input "$INPUT" session_id file_path

SESSION_ID="$HU_SESSION_ID"
FILE_PATH="$HU_FILE_PATH"

init_dirs "$SESSION_ID"
SESSION_FILE="$DISC_DIR/session-${SESSION_ID}"
LOOP_FILE="$DISC_DIR/loop-${SESSION_ID}"

# === FRESHNESS CHECK: file must be Read before Write ===
if [ -n "$FILE_PATH" ]; then
    READS_DIR="$CC_READS_DIR/${SESSION_ID}"
    if [ -d "$READS_DIR" ]; then
        HASH_KEY=$(md5_string "$FILE_PATH")
        HASH_FILE="$READS_DIR/$HASH_KEY"
        BASENAME=$(basename "$FILE_PATH")

        # Is this a small file? (<50 LOC) If so, strict mode downgrades
        # a missing-Read block to a warning — cost/benefit: the agent can
        # re-grok a 30-line file in one thought, and the Read roundtrip
        # is pure overhead for tiny files.
        SMALL_FILE=false
        if [ -f "$FILE_PATH" ]; then
            LINES=$(wc -l < "$FILE_PATH" 2>/dev/null | tr -d ' ')
            if [ -n "$LINES" ] && [ "$LINES" -lt 50 ]; then
                SMALL_FILE=true
            fi
        fi

        if [ ! -f "$HASH_FILE" ] && [ -f "$FILE_PATH" ]; then
            # File exists but was never Read in this session.
            # Whitelist: markdown and small config files can be edited without Read.
            case "$BASENAME" in
                *.md|*.txt|*.gitignore|.gitignore|*.command)
                    ;;  # whitelisted, skip
                *)
                    if ! hook_disabled "freshness"; then
                        if [ "$HU_PROFILE" = "standard" ]; then
                            log_metric "WARN:freshness-not-read"
                            json_allow "⚠️ ${BASENAME} was not Read this session. Read before Edit to avoid patching an outdated copy."
                            exit 0
                        elif [ "$SMALL_FILE" = "true" ]; then
                            log_metric "WARN:freshness-not-read-small"
                            json_allow "⚠️ ${BASENAME} (<50 lines) was not Read this session. Proceeding, but sanity-check the current contents match your assumptions."
                            exit 0
                        else
                            log_metric "BLOCK:freshness-not-read"
                            json_deny "STOP. ${BASENAME} was not Read in this session. Read it first (Read tool), then edit — so you're not patching an outdated version."
                            exit 0
                        fi
                    fi
                    ;;
            esac
        elif [ -f "$HASH_FILE" ] && [ -f "$FILE_PATH" ]; then
            # File was Read — verify it hasn't changed since.
            SAVED_HASH=$(cat "$HASH_FILE")
            CURRENT_HASH=$(md5_file "$FILE_PATH")
            if [ "$SAVED_HASH" != "$CURRENT_HASH" ]; then
                log_metric "WARN:freshness-stale"
                json_allow "WARNING: ${BASENAME} changed since you Read it. Re-read before edit to confirm your change still applies."
                exit 0
            fi
        fi
    fi
fi

# === CONCURRENT-EDIT WARNING: git log recent activity on this file ===
# Someone (or a parallel agent) may have just committed this file.
# Not a block — freshness gate catches real stale. This warns about context.
if [ -n "$FILE_PATH" ] && [ -f "$FILE_PATH" ] && ! hook_disabled "concurrent-edit"; then
    CE_DIR="$(dirname "$FILE_PATH")"
    CE_REPO=""
    while [ "$CE_DIR" != "/" ] && [ "$CE_DIR" != "$HOME" ]; do
        if [ -d "$CE_DIR/.git" ] || [ -f "$CE_DIR/.git" ]; then
            CE_REPO="$CE_DIR"
            break
        fi
        CE_DIR="$(dirname "$CE_DIR")"
    done

    if [ -n "$CE_REPO" ]; then
        CE_LOG=$(cd "$CE_REPO" && git log --since="30 minutes ago" \
                 --pretty=format:"%h %s (%ar)" -- "$FILE_PATH" 2>/dev/null | head -3)
        if [ -n "$CE_LOG" ]; then
            BASENAME=$(basename "$FILE_PATH")
            CE_WARN_KEY=$(md5_string "concurrent-edit:${FILE_PATH}")
            CE_WARN_FILE="$DISC_DIR/ce-warn-${SESSION_ID}-${CE_WARN_KEY}"
            if [ ! -f "$CE_WARN_FILE" ]; then
                touch "$CE_WARN_FILE"
                log_metric "WARN:concurrent-edit"
                json_allow "⚠️ CONCURRENT EDIT WARNING: ${BASENAME} was committed in the last 30 minutes:
${CE_LOG}

If that's not your commit, another agent/process may have touched the file. Run git diff HEAD~1 (if you haven't) before overwriting their work."
                exit 0
            fi
        fi
    fi
fi

# === LOOP BLOCK (set by track-activity.sh) ===
# track-activity.sh writes $LOOP_FILE when it detects repeated identical commands.
# Whitelist: plan files and docs always allowed (escape hatch).
if [ -f "$LOOP_FILE" ] && ! hook_disabled "loop"; then
    LOOP_WHITELIST=false
    case "$FILE_PATH" in
        */.claude/plans/*|*/CLAUDE.md|*/README.md|*/AGENTS.md)
            LOOP_WHITELIST=true ;;
    esac
    if [ "$LOOP_WHITELIST" = "false" ]; then
        log_metric "BLOCK:loop"
        LOOP_MSG=$(cat "$LOOP_FILE" | sed 's/\\/\\\\/g; s/"/\\"/g')
        json_deny "$LOOP_MSG"
        exit 0
    fi
fi

# === BACKTRACK LOCK: file was reset due to tunnel vision ===
# To unlock: 'echo BACKTRACK_ACK: description-of-new-approach'
if [ -n "$FILE_PATH" ] && ! hook_disabled "backtrack"; then
    BT_DIR="$DISC_DIR/backtrack-${SESSION_ID}"
    if [ -d "$BT_DIR" ]; then
        BT_HASH=$(md5_short "$FILE_PATH")
        if [ -f "$BT_DIR/${BT_HASH}-locked" ]; then
            log_metric "BLOCK:backtrack-locked"
            json_deny "BACKTRACK LOCK: $(basename "$FILE_PATH") was reset due to tunnel vision. Describe a DIFFERENT approach via 'echo BACKTRACK_ACK: <new approach>'. Or run a test to unlock."
            exit 0
        fi
    fi
fi

# === UNTESTED EDITS BLOCK ===
# track-activity.sh sets this when 10+ code edits happen without a test run.
# Whitelist: test files are always allowed (so the agent can write tests to unblock).
if [ -n "$SESSION_ID" ] && ! hook_disabled "tests"; then
    UNTESTED_BLOCK="$DISC_DIR/untested-block-${SESSION_ID}"
    if [ -f "$UNTESTED_BLOCK" ]; then
        BASENAME=$(basename "$FILE_PATH" 2>/dev/null)
        case "$BASENAME" in
            test_*|*_test.py|conftest.py|*_test.rs|*_test.ts|*_test.js|*.test.ts|*.test.js)
                ;;  # test files — allow
            *)
                EDITS_COUNT=$(cat "$UNTESTED_BLOCK" 2>/dev/null || echo "10+")
                log_metric "BLOCK:untested-edits count=$EDITS_COUNT"
                if [ "$HU_PROFILE" = "standard" ]; then
                    json_allow "⚠️ $EDITS_COUNT code edits without a test run. Run tests, or 'echo TEST_SKIP: <reason>' to override."
                else
                    json_deny "STOP: $EDITS_COUNT code edits without a single test run. Write BLOCKED.
To unblock:
1. Run tests (pytest / cargo test / npm test), or
2. 'echo TEST_SKIP: <reason>' (explicit acknowledgement), or
3. git commit (freeze current state)"
                fi
                exit 0
                ;;
        esac
    fi
fi

# === FIRST EDIT OF SESSION: initialize session file ===
if [ ! -f "$SESSION_FILE" ]; then
    touch "$SESSION_FILE"
    echo "$FILE_PATH" >> "$SESSION_FILE"
    json_allow "First edit of the session. Quick check: fixing the root cause or a symptom? Confident, or guessing?"
    exit 0
fi

# === UNIQUE-FILE COUNTER ===
echo "$FILE_PATH" >> "$SESSION_FILE"
UNIQUE_FILES=$(sort -u "$SESSION_FILE" | wc -l | tr -d ' ')

# Plan detection: any file path containing /plans/ or plan.md in session,
# or a recent plan file in ~/.claude/plans/.
HAS_PLAN=""
HAS_PLAN=$(grep -iE "/plans/|plan\.md" "$SESSION_FILE" 2>/dev/null | head -1)
PLANS_DIR="${QG_PLANS_DIR:-$HOME/.claude/plans}"
if [ -z "$HAS_PLAN" ]; then
    HAS_PLAN=$(find "$PLANS_DIR" -name "*.md" -mmin -30 2>/dev/null | head -1)
fi

# === 3-FILE GATE: 3 unique files without a plan → block ===
# (process-level — skipped in easy profile)
if [ "$UNIQUE_FILES" -ge 3 ] && [ -z "$HAS_PLAN" ] && ! hook_disabled "3-file" && ! hu_is_easy_mode; then
    if [ "$HU_PROFILE" = "standard" ]; then
        log_metric "WARN:3-files-no-plan"
        json_allow "⚠️ 3+ files without a plan. Consider creating a plan: TaskCreate, or ~/.claude/plans/*.md"
        exit 0
    else
        log_metric "BLOCK:3-files-no-plan"
        json_deny "STOP. 3+ files edited without a plan — this is a complex task that needs decomposition.
1. Write a plan: ~/.claude/plans/*.md, or use TaskCreate
2. Plan = list of files + what to change + order + how to verify
3. After the plan exists — continue
Write/Edit BLOCKED until a plan exists."
        exit 0
    fi
fi

# === 5-FILE REMINDER: remind to commit + test at each milestone ===
# (process-level — skipped in easy profile)
if [ "$UNIQUE_FILES" -ge 5 ] && [ $(( UNIQUE_FILES % 5 )) -eq 0 ] && [ -n "$HAS_PLAN" ] && ! hu_is_easy_mode; then
    LAST_WARNED=$(hu_state_op get "$SESSION_ID" "warn5_milestone")
    if [ "$UNIQUE_FILES" -gt "${LAST_WARNED:-0}" ]; then
        hu_state_op set "$SESSION_ID" "warn5_milestone" "$UNIQUE_FILES" >/dev/null
        log_metric "WARN:5-files-commit"
        json_allow "$UNIQUE_FILES files edited. Reminder:
- git commit a completed block
- run tests before the next block
- stay inside the plan"
        exit 0
    fi
fi

# Default: allow silently
hu_timer_end
exit 0
