# Quickstart

From zero to your first blocked agent action in 60 seconds.

## 1. Install (one line)

**macOS / Linux / WSL:**

```bash
curl -sSL https://raw.githubusercontent.com/tryarkon/claude-quality-gate/main/scripts/install.sh | bash
```

**Windows (PowerShell, Git for Windows installed):**

```powershell
iwr -useb https://raw.githubusercontent.com/tryarkon/claude-quality-gate/main/scripts/install.ps1 | iex
```

The installer:

- Detects your OS, checks `python3` and `bash` versions.
- Copies 7 hooks into `~/.claude/hooks/`.
- Backs up your existing `~/.claude/settings.json` (if any) to `settings.json.bak.<timestamp>`.
- Smart-merges our hook block into `settings.json` (your other env vars, permissions, hooks are preserved).
- Installs the `qg` CLI to `~/.local/bin/qg` (Mac/Linux) or `%USERPROFILE%\.local\bin\qg.cmd` (Windows).

If `~/.local/bin` isn't in your `PATH`, the installer prints the line to add to `~/.bashrc` / `~/.zshrc`.

## 2. Verify

```bash
qg status
```

Expected output:

```
claude-quality-gate v0.1.1

Hooks dir:             /home/you/.claude/hooks
Settings:              /home/you/.claude/settings.json
Profile (QG_PROFILE):  strict
Disabled hooks:        <none>
Metrics log:           /tmp/qg-metrics.log

Hook files
  ✓ pre-read-gate.sh
  ✓ pre-write-gate.sh
  ✓ pre-bash-gate.sh
  ✓ track-activity.sh
  ✓ auto-verify.sh
  ✓ on-stop-discipline.sh
  ✓ hook-utils.sh

Activity: no metrics yet (gates not triggered)

Dashboard: run 'qg dashboard' → http://localhost:7777
```

## 3. Trigger your first block

Open a new Claude Code session (close any open ones first — settings are read at startup) and ask the agent to do something dumb on purpose, for example:

> "Run `git commit --no-verify -m 'wip'` for me."

The agent will try, hit `pre-bash-gate`, and report back:

```
WORKAROUND BLOCKED: git --no-verify bypasses pre-commit / pre-push hooks.
Fix the root cause instead of bypassing.
```

That's the gate working. The Bash tool returned a non-zero exit, and the agent now has the block reason in its context to react to.

## 4. Open the dashboard

```bash
qg dashboard
```

Visit [http://localhost:7777](http://localhost:7777). You'll see the block you just triggered in the **Recent events** feed and counted in **Blocks fired** at the top.

The dashboard polls `/api/*` every 5 seconds — leave it open in a tab while you work.

## 5. (Optional) Tune the strictness

The default is `strict`. If you want to feel out the gates without being blocked while you adjust:

```bash
qg config QG_PROFILE standard      # warns instead of blocks
```

To disable a single gate by name:

```bash
qg config QG_DISABLED_HOOKS freshness,3-file
```

(See [`HOOKS.md`](./HOOKS.md) for the full list of tags.)

To go back to default:

```bash
qg config QG_PROFILE strict
qg config QG_DISABLED_HOOKS ""
```

## What's next

- Read [`PHILOSOPHY.md`](./PHILOSOPHY.md) for why each gate exists.
- Read [`HOOKS.md`](./HOOKS.md) for what each gate blocks and how to override.
- Read [`METRICS.md`](./METRICS.md) for how the dashboard calculates "time saved" and "tokens saved".
- Read [`CUSTOMIZATION.md`](./CUSTOMIZATION.md) to write your own hook on top of `hook-utils.sh`.

## Troubleshooting

**"qg: command not found" after install.**
Add `~/.local/bin` to your `PATH`:
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

**Hooks don't fire in Claude Code.**
You opened the session before installing. Restart Claude Code; settings are read on startup, not on demand.

**Hooks fire but block too much.**
Switch to `qg config QG_PROFILE standard` for a week. See what the gates flag in your codebase. Then re-enable strict, with specific hooks disabled if needed.

**`auto-verify` is slow.**
It runs `cargo check` / `tsc --noEmit` / `ruff` after every edit. On large Rust projects this can take 30s+. Either disable it (`qg config QG_DISABLED_HOOKS auto-verify`) or increase the hook timeout in `~/.claude/settings.json`.

**Uninstall.**
```bash
qg uninstall
```
This removes our hooks from `~/.claude/hooks/` and restores `settings.json` from the most recent backup.
