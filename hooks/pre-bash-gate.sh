#!/bin/bash
# PreToolUse Bash hook: detects workaround patterns.
# Blocks: --no-verify, || true, --skip-tests, SKIP_* env vars, destructive SQL, etc.
# Profile-aware: strict=deny, standard=warn, minimal=skip.

INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)" && source "$HOOK_DIR/hook-utils.sh"
HU_HOOK_NAME="pre-bash-gate"
hu_timer_start

parse_input "$INPUT" session_id command cwd
init_profile strict

if [ "$HU_PROFILE" = "minimal" ] || hook_disabled "workaround"; then
    hu_timer_end
    exit 0
fi

CMD="$HU_COMMAND"
[ -z "$CMD" ] && exit 0

# === WHITELIST: skip checks for safe commands ===
# Own hooks, package managers, container / system tools.
if echo "$CMD" | grep -qE '(hooks/|quality-gate/|# INTENTIONAL)'; then
    hu_timer_end
    exit 0
fi
if echo "$CMD" | grep -qE '^(npm install|pip install|cargo install|brew |docker |systemctl |launchctl )'; then
    hu_timer_end
    exit 0
fi

# === WORKAROUND PATTERNS ===
VIOLATION=""

# git commit --no-verify / git push --force
if echo "$CMD" | grep -qE 'git (commit|push).*--no-verify'; then
    VIOLATION="git --no-verify bypasses pre-commit / pre-push hooks"
fi
if echo "$CMD" | grep -qE 'git push.*--force'; then
    VIOLATION="git push --force can rewrite / destroy history"
fi

# --skip-tests / --skip-checks / --no-check
if echo "$CMD" | grep -qE '\-\-(skip-tests|skip-checks|no-check)\b'; then
    VIOLATION="--skip-* bypasses checks"
fi

# || true / || exit 0 at end of command (suppressing errors)
if echo "$CMD" | grep -qE '\|\|\s*(true|exit 0)\s*$'; then
    VIOLATION="|| true suppresses errors — masks real bugs"
fi

# 2>/dev/null on compilers/test runners
if echo "$CMD" | grep -qE '(cargo|tsc|pytest|npm test|jest|vitest|go test).*2>/dev/null'; then
    VIOLATION="2>/dev/null on compiler or test runner hides failures"
fi

# DISABLE_* / SKIP_* env vars
if echo "$CMD" | grep -qE '\b(DISABLE_|SKIP_)[A-Z_]+='; then
    VIOLATION="DISABLE_* / SKIP_* env var disables validation"
fi

# sed removing assert/test lines
if echo "$CMD" | grep -qE "sed.*-[ie].*/(assert|test|#\[test\]|def test_)/d"; then
    VIOLATION="sed deleting assert/test lines hides the problem, not fixes it"
fi

# git checkout/restore to discard local changes (hides the problem)
# Catches: `git checkout .`, `git checkout --`, `git restore .`, `git checkout -- file`, etc.
if echo "$CMD" | grep -qE 'git (checkout|restore)[[:space:]]+(--?[[:space:]]*)?(\.|--)'; then
    VIOLATION="git checkout/restore discards work — fix the root cause, don't throw away the code"
fi

# rm -rf on source dirs (nuclear option)
if echo "$CMD" | grep -qE 'rm -rf?\s+\S*(src|lib|app|pkg|crate)'; then
    VIOLATION="rm -rf on source directories is not a fix"
fi

# === CHANGELOG GATE: git commit must touch CHANGELOG if src/ changed ===
# Invariant: code changes → CHANGELOG updates. Prevents version drift.
# Applies only to manual commits (skips auto-save / auto-sync / auto-commit).
# Escape: `echo CHANGELOG_ACK: reason` before git commit.
if [ -z "$VIOLATION" ] && ! hook_disabled "changelog-gate" && ! hu_is_easy_mode; then
    if echo "$CMD" | grep -qE 'git commit' && ! echo "$CMD" | grep -qE '(auto-save|auto-sync|auto-commit)'; then
        REPO=$(git -C "${HU_CWD:-.}" rev-parse --show-toplevel 2>/dev/null)
        if [ -n "$REPO" ]; then
            ACK_FILE="$DISC_DIR/changelog-ack-${HU_SESSION_ID}"
            if [ -f "$ACK_FILE" ]; then
                rm -f "$ACK_FILE"
            else
                CODE_STAGED=$(git -C "$REPO" diff --cached --name-only 2>/dev/null | grep -E '\.(py|rs|ts|tsx|go|js|jsx|java|rb|c|cpp|swift)$' | head -1)
                if [ -n "$CODE_STAGED" ]; then
                    CHANGELOG="$REPO/CHANGELOG.md"
                    if [ ! -f "$CHANGELOG" ]; then
                        VIOLATION="code changed but CHANGELOG.md is missing. Create it, or run 'echo CHANGELOG_ACK: reason' to override"
                    else
                        CL_STAGED=$(git -C "$REPO" diff --cached --name-only 2>/dev/null | grep -E '^CHANGELOG\.md$')
                        if [ -z "$CL_STAGED" ]; then
                            CL_AGE_DAYS=$(( ($(date +%s) - $(stat -f %m "$CHANGELOG" 2>/dev/null || stat -c %Y "$CHANGELOG" 2>/dev/null || echo 0)) / 86400 ))
                            if [ "$CL_AGE_DAYS" -gt 14 ]; then
                                VIOLATION="code changed but CHANGELOG.md is stale (${CL_AGE_DAYS} days) and not staged. Update it, or run 'echo CHANGELOG_ACK: reason' to override"
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi
fi

# === CHANGELOG_ACK escape ===
if echo "$CMD" | grep -qE '^\s*echo\s+(["\x27])?CHANGELOG_ACK:'; then
    mkdir -p "$DISC_DIR" 2>/dev/null
    touch "$DISC_DIR/changelog-ack-${HU_SESSION_ID}"
    log_metric "CHANGELOG_ACK cmd=$(echo "$CMD" | head -c 80)"
    hu_timer_end
    exit 0
fi

# === CONVENTIONAL COMMITS ===
if [ -z "$VIOLATION" ] && ! hook_disabled "conventional-commits" && ! hu_is_easy_mode; then
    if echo "$CMD" | grep -qE 'git commit'; then
        # Extract commit message: -m 'MSG' or -m "MSG"
        COMMIT_MSG=$(echo "$CMD" | sed -nE "s/.*-m[[:space:]]+['\"]([^'\"]+)['\"].*/\1/p" | head -1)
        # Fallback: heredoc body — first non-empty line between EOF markers.
        if [ -z "$COMMIT_MSG" ] && echo "$CMD" | grep -qE '<<.*EOF'; then
            COMMIT_MSG=$(echo "$CMD" | awk '/EOF/{f=!f; next} f && NF{gsub(/^[[:space:]]+/,""); print; exit}')
        fi

        if [ -n "$COMMIT_MSG" ]; then
            # Whitelist: auto-* and release() commits
            if ! echo "$COMMIT_MSG" | grep -qE '^(auto-save|auto-sync|auto-commit|release\()'; then
                # Enforce conventional format: type(scope): desc OR type: desc
                if ! echo "$COMMIT_MSG" | grep -qE '^(feat|fix|refactor|docs|style|test|chore|perf|ci|build|release|breaking)(\([a-zA-Z0-9_-]+\))?(!)?:'; then
                    VIOLATION="commit message is not conventional-commits. Use: feat(scope): ..., fix: ..., chore: ..., etc."
                fi
            fi
        fi
    fi
fi

# === SQL SAFETY ===
# Skip checks for temp databases (:memory:, /tmp/)
if ! echo "$CMD" | grep -qE '(:memory:|/tmp/)'; then
    # DROP TABLE / TRUNCATE — always destructive
    if echo "$CMD" | grep -qiE '(DROP\s+TABLE|TRUNCATE\s+(TABLE\s+)?)'; then
        VIOLATION="DROP / TRUNCATE TABLE is irreversible"
    fi
    # DELETE FROM without WHERE — deletes ALL rows
    if [ -z "$VIOLATION" ] && echo "$CMD" | grep -qiE 'DELETE\s+FROM\s+\w+' && ! echo "$CMD" | grep -qiE 'DELETE\s+FROM\s+\w+.*WHERE\s'; then
        VIOLATION="DELETE FROM without WHERE wipes the entire table"
    fi
    # DELETE FROM ... WHERE 1 / WHERE true — effectively no filter
    if [ -z "$VIOLATION" ] && echo "$CMD" | grep -qiE 'DELETE\s+FROM\s+\w+.*WHERE\s+(1|true)\b'; then
        VIOLATION="DELETE FROM WHERE 1 / true is effectively DELETE with no filter"
    fi
fi

# === DEPLOY GATE: block scp/rsync without tests ===
# Set marker via another hook (e.g. post-Write) that records untested edits.
# The deploy block file lives at $DISC_DIR/deploy-block-$session_id and
# contains the count of untested edits. Remove it after tests pass.
if echo "$CMD" | grep -qE '^(scp |rsync )' && ! hook_disabled "deploy-gate"; then
    DEPLOY_BLOCK="$DISC_DIR/deploy-block-${HU_SESSION_ID}"
    if [ -f "$DEPLOY_BLOCK" ]; then
        UNTESTED=$(cat "$DEPLOY_BLOCK" 2>/dev/null || echo "?")
        log_metric "BLOCK:deploy-no-test edits=$UNTESTED"
        if [ "$HU_PROFILE" = "strict" ]; then
            json_deny "DEPLOY BLOCKED: $UNTESTED code edits without tests. Run tests before scp/rsync. Every prod bug = SSH debugging."
        else
            json_allow "⚠️ DEPLOY WITHOUT TESTS: $UNTESTED edits untested. Run tests before scp/rsync."
        fi
        hu_timer_end
        exit 0
    fi
fi

# === VERDICT ===
if [ -n "$VIOLATION" ]; then
    log_metric "WORKAROUND:$VIOLATION cmd=$(echo "$CMD" | head -c 80)"
    if [ "$HU_PROFILE" = "strict" ]; then
        json_deny "WORKAROUND BLOCKED: $VIOLATION. Fix the root cause instead of bypassing."
        hu_timer_end
        exit 0
    else
        json_allow "WORKAROUND WARNING: $VIOLATION. Consider fixing the root cause."
        hu_timer_end
        exit 0
    fi
fi

hu_timer_end
exit 0
