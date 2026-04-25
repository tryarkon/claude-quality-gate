---
name: Bug report
about: A hook misfires, blocks legitimate work, or fails silently
labels: bug
---

## Environment

- **OS:** (output of `uname -a`, or "Windows 11" + bash variant)
- **bash version:** (output of `bash --version | head -1`)
- **python3 version:** (output of `python3 --version`)
- **`qg status` output:**
  ```
  (paste here)
  ```

## What happened

A clear description of the misfire. Which hook fired (or failed to fire), what the agent was trying to do, what the user expected.

## Reproduction

1. Step one
2. Step two
3. ...

If possible, the JSON payload that triggered the bug (you can grab it from the agent's tool-call log):

```json
{ "session_id": "...", "tool_name": "...", "tool_input": { ... } }
```

## Relevant log lines

From `$QG_METRICS_LOG` (default `/tmp/qg-metrics.log`):

```
(paste recent lines)
```

## What you tried

Disable a tag? Switch to `standard` profile? `qg uninstall && reinstall`? List what didn't work.
