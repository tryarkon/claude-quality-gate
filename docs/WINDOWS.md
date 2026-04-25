# Windows

The hooks are bash scripts. To run them on Windows, you need a bash that Claude Code can execute. There are two supported ways.

## Option A — Git for Windows (recommended)

Git for Windows ships with `bash.exe` (MSYS2 bash, version 5.x). Claude Code finds it automatically when invoking hook executables, provided Git's `bin` directory is on `PATH`.

### Install

1. Install [Git for Windows](https://git-scm.com/download/win). Default options are fine; the installer adds `C:\Program Files\Git\bin` to your `PATH`.

2. Open a new PowerShell window (so the updated `PATH` is picked up) and run:

```powershell
iwr -useb https://raw.githubusercontent.com/tryarkon/claude-quality-gate/main/scripts/install.ps1 | iex
```

3. Verify:

```powershell
qg status
```

The installer:
- Locates `bash.exe` under `C:\Program Files\Git\bin\` (or `Program Files (x86)`, or `LOCALAPPDATA\Programs\Git\bin\`).
- Copies hooks to `%USERPROFILE%\.claude\hooks\`.
- Drops a `qg.cmd` shim in `%USERPROFILE%\.local\bin\` that invokes the bash CLI through git-bash.
- Adds `%USERPROFILE%\.local\bin` to your User PATH.

### Path translation

Git Bash uses Unix-style paths (`/c/Users/you/...`). Claude Code passes hook paths in Windows form (`C:\Users\you\...`). The installer handles the translation when generating `qg.cmd`. If you write a custom hook, use bash's path tools — `realpath`, `dirname`, etc. — and don't hardcode `C:\` style paths.

### Performance note

Git Bash on Windows starts each subprocess via `fork`-emulation, which adds ~80–150ms of latency vs. native Linux bash. With 7 hooks firing on Read/Write/Edit/Bash, you may notice a slight pause on each tool call. For most workflows this is fine. If it becomes noticeable, use Option B.

## Option B — WSL (faster, more involved)

If you already use WSL for development, run the install there:

1. Open your WSL distribution (Ubuntu, Debian, etc.):

```bash
wsl
```

2. Inside WSL, install normally:

```bash
curl -sSL https://raw.githubusercontent.com/tryarkon/claude-quality-gate/main/scripts/install.sh | bash
```

3. **Important:** Claude Code on Windows needs to invoke the WSL hooks. Edit `%USERPROFILE%\.claude\settings.json` (the *Windows* one) and rewrite each hook entry to call WSL:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "wsl bash /home/<you>/.claude/hooks/pre-bash-gate.sh" }
        ]
      }
    ]
  }
}
```

Replace `<you>` with your WSL username and repeat for each hook.

If you only ever use Claude Code from inside WSL itself, you don't need this — the hooks are already wired up correctly inside the WSL `~/.claude/`.

### Download install.ps1 first when using -UseWSL

The piped install (`iwr | iex`) doesn't accept parameters. If you want to install via WSL through PowerShell:

```powershell
iwr -useb https://raw.githubusercontent.com/tryarkon/claude-quality-gate/main/scripts/install.ps1 -OutFile install.ps1
.\install.ps1 -UseWSL
```

## Uninstall

```powershell
qg uninstall
```

This removes hooks from `%USERPROFILE%\.claude\hooks\` and restores the most recent `settings.json` backup. The `qg.cmd` shim in `~/.local/bin` and the PATH entry remain — delete them manually if you want a complete cleanup:

```powershell
Remove-Item "$env:USERPROFILE\.local\bin\qg.cmd"
Remove-Item "$env:USERPROFILE\.local\bin\qg"
# PATH cleanup: System Properties → Environment Variables → User → Path → Edit
```

## Troubleshooting

### "Cannot locate bash"

The installer didn't find Git Bash at any of the standard paths. Either install Git for Windows (default options), or run the installer with `-UseWSL` (see Option B).

### "qg: command not found" in a new terminal

You need to open a new shell after install — Windows reads `PATH` from the registry on shell start. If it still fails, check: `[Environment]::GetEnvironmentVariable("Path", "User")` should contain `%USERPROFILE%\.local\bin` (or your custom prefix).

### Hooks fire but produce errors

Most likely cause: line endings. Git Bash is generally tolerant, but if you've cloned the repo with a strict `core.autocrlf` setting, hook files may have CRLF line endings, which `bash` doesn't accept. Fix:

```bash
cd ~/.claude/hooks
dos2unix *.sh    # or: sed -i 's/\r$//' *.sh
```

The installer ships hooks with LF endings, but a manual re-clone may pick up the wrong ones depending on your global git config.

### Slow agent responses

Each hook invocation incurs ~80–150ms of bash startup overhead under Git Bash. With 7 hooks active, this can add up. Mitigations, in order of preference:

1. Switch to WSL (Option B) — native Linux bash, ~10ms per invocation.
2. Disable hooks you don't need: `qg config QG_DISABLED_HOOKS auto-verify,3-file`.
3. Profile-level relax: `qg config QG_PROFILE standard` short-circuits some checks.

### `auto-verify` doesn't find your toolchain

The hook walks up from the edited file looking for `Cargo.toml` / `tsconfig.json`. On Windows, watch out for symlinked drives or junction points — `dirname` may not traverse them as you expect. Workaround: ensure your project root is on a real path, not a substituted drive.

### Permission errors on `~/.local/bin`

Some Windows setups have ACLs on `%USERPROFILE%` that block creation under hidden folders. If the installer reports access denied, manually create the dir first:

```powershell
New-Item -ItemType Directory -Path "$env:USERPROFILE\.local\bin" -Force
```

Then re-run the installer.

## What works, what doesn't

| Feature | Git Bash | WSL |
|---|---|---|
| All 7 hooks | ✅ | ✅ |
| `qg dashboard` | ✅ (binds to localhost only) | ✅ (use Windows browser to visit localhost:7777) |
| Cross-platform `md5_*` helpers | ✅ (uses `md5sum` from Git Bash bin) | ✅ |
| `auto-verify` with native toolchains | ✅ if `cargo`/`tsc`/`ruff` are on PATH | ✅ inside WSL |
| Hook latency | ~80-150ms each | ~10ms each |
| Path translation | Handled by installer | Native |

## Reporting Windows-specific bugs

When opening an issue, please include:

- Output of `qg status`.
- `bash --version` (run inside Git Bash or WSL).
- `git --version` and the path to your bash binary (`where bash`).
- Whether you used Option A or Option B.
- The full error message and the command that triggered it.
