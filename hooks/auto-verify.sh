#!/bin/bash
# PostToolUse hook: automatically verify after Edit/Write.
# .rs  → cargo check
# .ts/.tsx → tsc --noEmit
# .py → ruff check
# Errors ≤5 lines go inline into Claude's context.
# Larger output → /tmp file + a short preview.
INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" && source "$HOOK_DIR/hook-utils.sh"

HU_HOOK_NAME="auto-verify"
hu_timer_start

parse_input "$INPUT" session_id file_path

init_profile strict
if [ "$HU_PROFILE" = "minimal" ] || hook_disabled "auto-verify"; then
    exit 0
fi

if [ -z "$HU_FILE_PATH" ]; then
    exit 0
fi

BASENAME=$(basename "$HU_FILE_PATH")
EXT="${HU_FILE_PATH##*.}"
MESSAGES=""
msg() { [ -n "$MESSAGES" ] && MESSAGES="$MESSAGES"$'\n'"$1" || MESSAGES="$1"; }

# === Verify cache (per-session, per-file) =====================================
# Skip the verification run when:
#   1. the last run for this file in this session was "ok",
#   2. the current file hash matches the cached hash, AND
#   3. the file size has changed by fewer than 20 lines since the cached size.
# Any successful run rewrites the cache; any failure invalidates it.
VERIFY_CACHE_DIR=""
VERIFY_CACHE_FILE=""
VERIFY_CACHE_SKIP="false"
CURRENT_FHASH=""
CURRENT_FSIZE=""
if [ -n "$HU_SESSION_ID" ] && [ -f "$HU_FILE_PATH" ]; then
    VERIFY_CACHE_DIR="$CC_HOOKS_DIR/$HU_SESSION_ID"
    mkdir -p "$VERIFY_CACHE_DIR" 2>/dev/null
    FPATH_HASH=$(md5_short "$HU_FILE_PATH")
    VERIFY_CACHE_FILE="$VERIFY_CACHE_DIR/verify-last-${FPATH_HASH}"
    CURRENT_FHASH=$(md5_file "$HU_FILE_PATH")
    CURRENT_FSIZE=$(wc -l < "$HU_FILE_PATH" 2>/dev/null | tr -d ' ')
    if [ -f "$VERIFY_CACHE_FILE" ]; then
        CACHE_STATUS=$(sed -n '1p' "$VERIFY_CACHE_FILE" 2>/dev/null)
        CACHE_HASH=$(sed -n '2p' "$VERIFY_CACHE_FILE" 2>/dev/null)
        CACHE_SIZE=$(sed -n '3p' "$VERIFY_CACHE_FILE" 2>/dev/null)
        if [ "$CACHE_STATUS" = "ok" ] && [ -n "$CACHE_HASH" ] && [ "$CACHE_HASH" = "$CURRENT_FHASH" ]; then
            SIZE_DIFF=0
            if [ -n "$CACHE_SIZE" ] && [ -n "$CURRENT_FSIZE" ]; then
                if [ "$CURRENT_FSIZE" -ge "$CACHE_SIZE" ]; then
                    SIZE_DIFF=$((CURRENT_FSIZE - CACHE_SIZE))
                else
                    SIZE_DIFF=$((CACHE_SIZE - CURRENT_FSIZE))
                fi
            fi
            if [ "$SIZE_DIFF" -lt 20 ]; then
                VERIFY_CACHE_SKIP="true"
                log_metric "CACHE_HIT file=$BASENAME"
            fi
        fi
    fi
fi

# Helper: record a successful run in the cache.
verify_cache_ok() {
    [ -z "$VERIFY_CACHE_FILE" ] && return
    [ -z "$CURRENT_FHASH" ] && return
    atomic_write "ok
$CURRENT_FHASH
$CURRENT_FSIZE" "$VERIFY_CACHE_FILE"
}

# Helper: drop cache entry after a failure.
verify_cache_invalidate() {
    [ -z "$VERIFY_CACHE_FILE" ] && return
    rm -f "$VERIFY_CACHE_FILE" 2>/dev/null
}

if [ "$VERIFY_CACHE_SKIP" = "true" ]; then
    hu_timer_end
    exit 0
fi

# Sandbox output: small errors inline, big output → /tmp file.
sandbox_output() {
    local RESULT="$1"
    local LABEL="$2"
    local RC="$3"

    if [ "$RC" -eq 0 ]; then
        return
    fi

    LINES=$(echo "$RESULT" | wc -l | tr -d ' ')
    if [ "$LINES" -le 5 ]; then
        msg "$LABEL FAILED after editing $BASENAME: $RESULT. Fix the error before continuing."
    else
        LOG_FILE="/tmp/cc-verify-${HU_SESSION_ID}.log"
        echo "$RESULT" > "$LOG_FILE"
        FIRST_LINES=$(echo "$RESULT" | head -3)
        msg "$LABEL FAILED after editing $BASENAME: $FIRST_LINES ... +$((LINES-3)) more lines → Read $LOG_FILE. Fix the error before continuing."
    fi
}

case "$EXT" in
    rs)
        DIR=$(dirname "$HU_FILE_PATH")
        while [ "$DIR" != "/" ] && [ ! -f "$DIR/Cargo.toml" ]; do
            DIR=$(dirname "$DIR")
        done
        if [ -f "$DIR/Cargo.toml" ]; then
            FULL_OUTPUT=$(cd "$DIR" && cargo check --quiet 2>&1)
            RC=$?
            if [ "$RC" -ne 0 ]; then
                TOTAL_ERRORS=$(echo "$FULL_OUTPUT" | grep -c '^error')
                TOTAL_WARNINGS=$(echo "$FULL_OUTPUT" | grep -c '^warning')
                COMPRESSED=$(echo "$FULL_OUTPUT" | grep -A2 '^error' | head -12)
                RESULT="cargo check: ${TOTAL_ERRORS} errors, ${TOTAL_WARNINGS} warnings. First errors:"$'\n'"${COMPRESSED}"
                echo "$FULL_OUTPUT" > "/tmp/cc-verify-${HU_SESSION_ID}.log"
                verify_cache_invalidate
            else
                verify_cache_ok
            fi
            sandbox_output "${RESULT:-}" "cargo check" "$RC"
        fi
        ;;
    ts|tsx)
        DIR=$(dirname "$HU_FILE_PATH")
        while [ "$DIR" != "/" ] && [ ! -f "$DIR/tsconfig.json" ]; do
            DIR=$(dirname "$DIR")
        done
        if [ -f "$DIR/tsconfig.json" ]; then
            if command -v npx &>/dev/null; then
                FULL_OUTPUT=$(cd "$DIR" && npx tsc --noEmit 2>&1)
                RC=$?
                if [ "$RC" -ne 0 ]; then
                    TOTAL_ERRORS=$(echo "$FULL_OUTPUT" | grep -c 'error TS')
                    COMPRESSED=$(echo "$FULL_OUTPUT" | grep 'error TS' | head -5)
                    RESULT="tsc: ${TOTAL_ERRORS} errors. First:"$'\n'"${COMPRESSED}"
                    echo "$FULL_OUTPUT" > "/tmp/cc-verify-${HU_SESSION_ID}.log"
                    verify_cache_invalidate
                else
                    verify_cache_ok
                fi
                sandbox_output "${RESULT:-}" "tsc" "$RC"
            fi
        fi
        ;;
    py)
        if command -v ruff &>/dev/null; then
            FULL_OUTPUT=$(ruff check --quiet "$HU_FILE_PATH" 2>&1)
            RC=$?
            if [ "$RC" -ne 0 ]; then
                TOTAL_ERRORS=$(echo "$FULL_OUTPUT" | wc -l | tr -d ' ')
                COMPRESSED=$(echo "$FULL_OUTPUT" | head -5)
                RESULT="ruff: ${TOTAL_ERRORS} issues. First:"$'\n'"${COMPRESSED}"
                echo "$FULL_OUTPUT" > "/tmp/cc-verify-${HU_SESSION_ID}.log"
                verify_cache_invalidate
            else
                verify_cache_ok
            fi
            sandbox_output "${RESULT:-}" "ruff check" "$RC"
        fi
        ;;
esac

if [ -n "$MESSAGES" ]; then
    json_context "$MESSAGES" "PostToolUse"
fi

hu_timer_end
exit 0
