# Customization

How to write your own hook on top of `hook-utils.sh`, and how to wire it into Claude Code.

This doc assumes you've read [`HOOKS.md`](./HOOKS.md) and understand what the existing hooks do.

## The hook contract

Claude Code invokes hooks as plain executables. Each hook:

1. Reads a JSON payload from **stdin**.
2. Decides allow / deny / informational.
3. Either:
   - Emits JSON on **stdout** describing the decision (`hookSpecificOutput`), and exits 0; **or**
   - Emits a reason on **stderr** and exits 2 (deny).

That's the whole contract. Everything in `claude-quality-gate` is built on it.

### The stdin JSON

Shape varies by event. The most useful fields:

```json
{
  "session_id": "abc123…",
  "tool_name": "Bash",
  "tool_input": {
    "file_path": "/repo/src/api.py",
    "command": "git commit -m 'feat: add auth'",
    "offset": null,
    "limit": null
  },
  "cwd": "/repo",
  "transcript_path": "/path/to/session.jsonl",
  "source": "user"
}
```

For Stop events, you also get `stop_hook_active`. For PostToolUse events, the model's last `content` array is included.

### The stdout JSON

For PreToolUse:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "additionalContext": "Note that this file is auto-generated."
  }
}
```

`permissionDecision` is `"allow"` or omitted (deny is signalled by exit 2, not by this field). `additionalContext` is text injected into the agent's context window — use it for warnings.

For PostToolUse, `hookEventName` is `"PostToolUse"` and there's no `permissionDecision`. Just `additionalContext`.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Allow (with whatever stdout you emit) |
| 2 | Deny (stderr is shown to the agent as the reason) |
| anything else | Treated as a hook error — Claude Code will surface a warning to you |

## Using `hook-utils.sh`

Source it at the top of your hook:

```bash
#!/bin/bash
INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOK_DIR/hook-utils.sh"
```

You now have all the helpers documented in [`HOOKS.md` → `hook-utils.sh`](./HOOKS.md#hook-utilssh-shared-library) available.

## Standard hook skeleton

Every shipped hook follows roughly this shape. Use it as your template:

```bash
#!/bin/bash
INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOK_DIR/hook-utils.sh"

HU_HOOK_NAME="my-hook"           # used in metrics
hu_timer_start                   # optional: log perf
init_profile strict              # sets HU_PROFILE, HU_DISABLED
[ "$HU_PROFILE" = "minimal" ] && exit 0
hook_disabled "my-tag" && exit 0

# Parse the fields you care about.
parse_input "$INPUT" session_id command cwd

# Make a decision.
if echo "$HU_COMMAND" | grep -q "dangerous-pattern"; then
    log_metric "BLOCK:dangerous-pattern"
    json_deny "Refusing: dangerous-pattern detected. <suggested fix>"
fi

# Allow with optional context.
hu_timer_end
exit 0
```

## State management

For per-session state (counters, flags, hashes), use `hu_state_op`:

```bash
# Increment a counter, get the new value.
COUNT=$(hu_state_op incr "$HU_SESSION_ID" "my_counter")

# Read a value (default 0).
COUNT=$(hu_state_op get "$HU_SESSION_ID" "my_counter")

# Set explicitly.
hu_state_op set "$HU_SESSION_ID" "my_counter" "0" >/dev/null

# Clear a single key, or all keys for the session.
hu_state_op clear "$HU_SESSION_ID" "my_counter"
hu_state_op clear "$HU_SESSION_ID" "*"     # nuke session state
```

State files live in `$QG_CC_HOOKS_DIR/<session>/<key>`. They're plain text. Nothing else to learn.

For shared (cross-session) state, write directly to `$DISC_DIR` (also exposed by `hook-utils.sh`). Use `atomic_write` for safety:

```bash
atomic_write "$value" "$DISC_DIR/my-shared-marker"
```

## Wiring it into `settings.json`

Add an entry under the appropriate event in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "/Users/you/.claude/hooks/my-hook.sh" }
        ]
      }
    ]
  }
}
```

`matcher` filters by tool name (`Read`, `Write`, `Edit`, `Bash`, etc.). Multiple matcher blocks per event are fine; multiple hooks per matcher run in array order.

## Profile and disable conventions

If you want your hook to play nicely with the project's profile and disable conventions:

- Always call `init_profile`. Honour `minimal` by exiting at the top.
- Pick a unique tag and check `hook_disabled "your-tag"`. Document the tag in your hook's docstring.
- For block decisions, gate on `[ "$HU_PROFILE" = "strict" ]` for `json_deny`, otherwise `json_allow` with a warning. Many shipped hooks do this:

```bash
if [ "$HU_PROFILE" = "standard" ]; then
    json_allow "⚠️ <warning text>"
else
    json_deny "<deny text with suggestion>"
fi
```

## Worked example: vulnerable-package gate

A 30-line hook that blocks `npm install <pkg>` if the package is on a local known-vulnerable list. Pseudo — substitute a real vuln source if you ship this.

```bash
#!/bin/bash
# pre-npm-install-gate.sh — block install of known-vulnerable packages.
INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOK_DIR/hook-utils.sh"

HU_HOOK_NAME="pre-npm-install-gate"
init_profile strict
[ "$HU_PROFILE" = "minimal" ] && exit 0
hook_disabled "npm-vuln" && exit 0

parse_input "$INPUT" command session_id

# Only act on `npm install <something>`.
case "$HU_COMMAND" in
    npm\ install\ *|npm\ i\ *|npm\ add\ *) ;;
    *) exit 0 ;;
esac

# Extract requested packages (skip flags).
PKGS=$(echo "$HU_COMMAND" | tr ' ' '\n' | grep -vE '^(npm|install|i|add|-.*|@.*\..*)$')

VULN_FILE="${QG_VULN_LIST:-$HOOK_DIR/vuln-packages.txt}"
[ ! -f "$VULN_FILE" ] && exit 0

for pkg in $PKGS; do
    name="${pkg%@*}"          # strip version pin
    if grep -qFx "$name" "$VULN_FILE"; then
        log_metric "BLOCK:vuln-pkg pkg=$name"
        if [ "$HU_PROFILE" = "standard" ]; then
            json_allow "⚠️ $name is on the known-vulnerable list. Pin to a known-good version or pick a different package."
        else
            json_deny "BLOCKED: $name is on the known-vulnerable list ($VULN_FILE). Use a patched version or a different package."
        fi
    fi
done

exit 0
```

Wire it in:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "/Users/you/.claude/hooks/pre-npm-install-gate.sh" }
        ]
      }
    ]
  }
}
```

Provide `vuln-packages.txt` (one package name per line). Set `QG_VULN_LIST=/path/to/list` to override location.

## Tips from building the shipped hooks

- **Stay under 250 lines.** Anything bigger should probably be two hooks.
- **Use `parse_input` once.** Don't shell out to `python3` repeatedly to read JSON fields — `parse_input` does it in a single call and sets shell vars.
- **Atomic writes.** State files are read by other hooks. A half-written file will corrupt their behavior. Always `atomic_write` or `mv` from `.tmp.$$`.
- **Bash 3.2 compat.** macOS still ships bash 3.2. No `${var:1:-1}`, no associative arrays (`declare -A`), no `mapfile`. The `tests/` directory enforces this.
- **Log everything you deny.** `log_metric "BLOCK:reason"` makes the dashboard useful.
- **Test your hook standalone.** Pipe a sample JSON to it: `echo '{"session_id":"test","tool_name":"Bash","tool_input":{"command":"npm install lodash"}}' | ./pre-npm-install-gate.sh`.

## Going further

If you want to contribute a hook back upstream rather than maintain it locally, see [`CONTRIBUTING.md`](../CONTRIBUTING.md). PR review is best-effort, but well-scoped hooks with tests and documentation are welcome.
