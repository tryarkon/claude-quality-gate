#!/bin/bash
# PreToolUse gate: blocks Read of large files; suggests offset/limit instead.
# Rationale: reading a 1000-line file eats context; agents rarely need all of it.

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOK_DIR/hook-utils.sh"

HU_HOOK_NAME="pre-read-gate"
hu_timer_start
init_profile strict
[ "$HU_PROFILE" = "minimal" ] && exit 0
hook_disabled "read-gate" && exit 0

parse_input "$INPUT" file_path has_offset

# Agent already bounded the read — let it through.
[ "$HU_HAS_OFFSET" = "yes" ] && exit 0

# File doesn't exist — let Read surface the error.
[ ! -f "$HU_FILE_PATH" ] && exit 0

# Whitelist extensions — structured/small files pass without check.
case "${HU_FILE_PATH##*.}" in
    md|json|toml|yaml|yml|env|txt|csv|lock|conf|ini|cfg|gitignore)
        exit 0 ;;
esac

LINES=$(wc -l < "$HU_FILE_PATH" 2>/dev/null | tr -d ' ')
[ -z "$LINES" ] && exit 0

if [ "$LINES" -gt 300 ]; then
    BASENAME=$(basename "$HU_FILE_PATH")
    log_metric "BLOCK:large-file lines=$LINES"

    if [ "$HU_PROFILE" = "standard" ]; then
        json_allow "⚠️ ${BASENAME} is ${LINES} lines. Prefer Read(path, offset=N, limit=200) for the specific section, or use LSP (hover, documentSymbol) for signatures."
    else
        json_deny "File ${BASENAME} is ${LINES} lines. Reading it whole wastes context.
Use one of:
- Read(path='${HU_FILE_PATH}', offset=N, limit=200)  # specific section
- LSP hover / documentSymbol                         # for signatures and structure
- grep/rg over the file                              # for keyword lookup"
    fi
    exit 0
fi

# 200-300 lines: allow with warning.
if [ "$LINES" -gt 200 ]; then
    BASENAME=$(basename "$HU_FILE_PATH")
    log_metric "WARN:medium-file lines=$LINES"
    json_allow "⚠️ ${BASENAME} is ${LINES} lines. Consider offset/limit or LSP to save context."
    exit 0
fi

# 100-200 lines: allow with soft hint.
if [ "$LINES" -gt 100 ]; then
    BASENAME=$(basename "$HU_FILE_PATH")
    log_metric "INFO:mid-file lines=$LINES"
    json_allow "${BASENAME} is ${LINES} lines. Use offset/limit or LSP if you only need a section."
    exit 0
fi

# ≤100 lines: pass silently.
hu_timer_end
exit 0
