#!/bin/bash
# hook-utils.sh — shared library for quality-gate hooks
# Source this file: HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" && source "$HOOK_DIR/hook-utils.sh"
#
# Provides: parse_input, md5_string, md5_file, md5_short,
#           json_deny, json_allow, json_context, json_stop_block,
#           init_profile, hook_disabled, log_metric,
#           atomic_write, atomic_increment, init_dirs,
#           hu_timer_start, hu_timer_end

# === parse_input: one python call for all fields ===
# Usage: parse_input "$INPUT" "session_id file_path has_offset"
# Sets: HU_SESSION_ID, HU_FILE_PATH, HU_HAS_OFFSET etc.
# Field names: session_id, tool_name, file_path, cwd, command, source,
#              stop_hook_active, has_offset, content, transcript_path, tool_output
parse_input() {
    local input="$1"
    shift
    local fields=("$@")

    local py_lines=""
    for f in "${fields[@]}"; do
        case "$f" in
            session_id)       py_lines+="print(d.get('session_id',''))"$'\n' ;;
            tool_name)        py_lines+="print(d.get('tool_name',''))"$'\n' ;;
            file_path)        py_lines+="print(d.get('tool_input',{}).get('file_path',''))"$'\n' ;;
            cwd)              py_lines+="print(d.get('cwd',''))"$'\n' ;;
            command)          py_lines+="print((d.get('tool_input',{}).get('command','') or '')[:500])"$'\n' ;;
            source)           py_lines+="print(d.get('source','startup'))"$'\n' ;;
            stop_hook_active) py_lines+="print(d.get('stop_hook_active','false'))"$'\n' ;;
            has_offset)       py_lines+="ti=d.get('tool_input',{}); print('yes' if ti.get('offset') or ti.get('limit') else 'no')"$'\n' ;;
            content)          py_lines+="c=d.get('content',''); print((' '.join(x.get('text','') for x in c if isinstance(x,dict) and x.get('type')=='text') if isinstance(c,list) else str(c))[:500])"$'\n' ;;
            transcript_path)  py_lines+="print(d.get('transcript_path',''))"$'\n' ;;
            tool_output)      py_lines+="tr=d.get('tool_response',d.get('tool_output',{}))"$'\n'"_out=''"$'\n'"if isinstance(tr,dict):"$'\n'"    _so=tr.get('stdout','') or ''"$'\n'"    _se=tr.get('stderr','') or ''"$'\n'"    _out=(_so+'\\n'+_se).strip()"$'\n'"    if not _out: _out=str(tr.get('content','') or tr.get('output','') or '')"$'\n'"elif isinstance(tr,str): _out=tr"$'\n'"print(_out.replace(chr(10),' ')[:4000])"$'\n' ;;
        esac
    done

    local parsed
    parsed=$(echo "$input" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
$py_lines" 2>/dev/null)

    local i=1
    for f in "${fields[@]}"; do
        local varname="HU_$(echo "$f" | tr '[:lower:]' '[:upper:]')"
        local value
        value=$(echo "$parsed" | sed -n "${i}p")
        eval "$varname=\"\$value\""
        i=$((i + 1))
    done
}

# === md5 functions (cross-platform: macOS + Linux) ===
md5_string() {
    echo "$1" | md5 2>/dev/null || echo "$1" | md5sum | cut -d' ' -f1
}

md5_file() {
    md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1
}

md5_short() {
    local full
    full=$(echo "$1" | md5 2>/dev/null || echo "$1" | md5sum | cut -d' ' -f1)
    echo "${full:0:16}"
}

# === JSON output (safe via python3 json.dumps) ===
_json_escape() {
    python3 -c "import json,sys; print(json.dumps(sys.stdin.read().rstrip('\n')))" <<< "$1"
}

json_deny() {
    local reason="$1"
    echo "$reason" >&2
    exit 2
}

json_allow() {
    local context="$1"
    if [ -z "$context" ]; then
        exit 0
    fi
    local escaped
    escaped=$(_json_escape "$context")
    # Strip leading and trailing double-quote (bash 3.2 compatible).
    escaped="${escaped#\"}"
    escaped="${escaped%\"}"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","additionalContext":"$escaped"}}
EOF
}

json_context() {
    local context="$1"
    local event="${2:-PreToolUse}"
    local escaped
    escaped=$(_json_escape "$context")
    escaped="${escaped#\"}"
    escaped="${escaped%\"}"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"$event","additionalContext":"$escaped"}}
EOF
}

json_stop_block() {
    local reason="$1"
    echo "$reason" >&2
    exit 2
}

# === Profile & disabled hooks ===
# Usage: init_profile [default_profile]
# Sets: HU_PROFILE (strict|easy|standard|minimal), HU_DISABLED
#
# Profile semantics:
#   strict    — all gates enforced (default). Blocks on violations.
#   easy      — safety gates only: freshness, loop, backtrack, untested-edits,
#               workaround-patterns, SQL-safety, tests-integrity, tool-failure.
#               Skipped: 3-file plan, CHANGELOG, conventional-commits,
#                        supervisor, research-gate.
#   standard  — all gates, but downgrade to warnings (json_allow).
#   minimal   — all gates skip entirely at the top.
init_profile() {
    # Default changed strict→standard after SWE-bench showed strict-mode blocks
    # cost more in solve-rate than they save in token-discipline. Hooks now
    # warn (inject context) by default; strict remains opt-in for users who
    # want hard refusal of bad patterns.
    local default="${1:-standard}"
    HU_PROFILE="${QG_PROFILE:-$default}"
    HU_DISABLED="${QG_DISABLED_HOOKS:-}"
}

# Convenience: true if a process-level gate (plan/changelog/commit-format
# /supervisor/research) should skip. Safety gates ignore this.
hu_is_easy_mode() {
    [ "$HU_PROFILE" = "easy" ]
}

# Usage: hook_disabled "freshness" && return
hook_disabled() {
    echo ",$HU_DISABLED," | grep -q ",$1,"
}

# === Metrics logging ===
# Set HU_HOOK_NAME before calling. Uses HU_SESSION_ID, HU_FILE_PATH if available.
log_metric() {
    local event="$1"
    local metrics="${QG_METRICS_LOG:-/tmp/qg-metrics.log}"
    local sid_short="${HU_SESSION_ID:0:8}"
    local fname=""
    [ -n "$HU_FILE_PATH" ] && fname=$(basename "$HU_FILE_PATH" 2>/dev/null)
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${HU_HOOK_NAME:-unknown} $event sid=$sid_short file=$fname" >> "$metrics" 2>/dev/null
}

# === Atomic file operations ===
atomic_write() {
    local content="$1"
    local target="$2"
    local tmp="${target}.tmp.$$"
    echo "$content" > "$tmp" && mv "$tmp" "$target"
}

# Atomic read-increment-write. Prints new value.
atomic_increment() {
    local target="$1"
    local current
    current=$(cat "$target" 2>/dev/null || echo 0)
    current=$((current + 1))
    atomic_write "$current" "$target"
    echo "$current"
}

# === Performance profiling ===
hu_timer_start() {
    HU_START_MS=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null)
}

hu_timer_end() {
    [ -z "$HU_START_MS" ] && return
    local end
    end=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null)
    [ -z "$end" ] && return
    local ms=$((end - HU_START_MS))
    local metrics="${QG_METRICS_LOG:-/tmp/qg-metrics.log}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${HU_HOOK_NAME:-unknown} PERF:${ms}ms" >> "$metrics" 2>/dev/null
}

# === Configurable paths (for test isolation) ===
DISC_DIR="${QG_DISC_DIR:-/tmp/claude-discipline}"
CC_READS_DIR="${QG_CC_READS_DIR:-/tmp/cc-reads}"
CC_HOOKS_DIR="${QG_CC_HOOKS_DIR:-/tmp/cc-hooks}"
# Optional SQLite state DB. If not set, hooks use /tmp files only.
QG_DB="${QG_DB:-}"

# === Simple state helper (per-session state in /tmp) ===
# For hooks needing 1-2 state lookups (counters, flags).
# Stored as plain text files in CC_HOOKS_DIR/$sid/ for zero dependencies.
hu_state_op() {
    local op="$1" sid="$2" key="$3" val="${4:-0}"
    local state_dir="$CC_HOOKS_DIR/${sid:-default}"
    local state_file="$state_dir/$key"
    mkdir -p "$state_dir" 2>/dev/null
    case "$op" in
        get)   cat "$state_file" 2>/dev/null || echo "0" ;;
        set)   echo "$val" > "$state_file" ;;
        incr)  local cur; cur=$(cat "$state_file" 2>/dev/null || echo 0); cur=$((cur + 1)); echo "$cur" > "$state_file"; echo "$cur" ;;
        clear)
            if [ "$key" = "*" ]; then
                rm -rf "$state_dir"
            else
                rm -f "$state_file"
            fi ;;
        *) echo "0" ;;
    esac
}

# === Directory init ===
init_dirs() {
    local sid="$1"
    mkdir -p "$DISC_DIR" 2>/dev/null
    mkdir -p "$CC_HOOKS_DIR" 2>/dev/null
    [ -n "$sid" ] && mkdir -p "$CC_READS_DIR/$sid" 2>/dev/null
}
