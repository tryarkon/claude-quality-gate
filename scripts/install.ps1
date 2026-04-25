<#
.SYNOPSIS
  claude-quality-gate Windows installer.

.DESCRIPTION
  Installs claude-quality-gate hooks on Windows. Hooks themselves are bash —
  they run via git-bash (shipped with Git for Windows) or WSL.

.EXAMPLE
  iwr -useb https://raw.githubusercontent.com/tryarkon/claude-quality-gate/main/install.ps1 | iex

.EXAMPLE
  # From a checkout
  pwsh scripts\install.ps1
#>

[CmdletBinding()]
param(
    [string]$Branch = "main",
    [string]$ClaudeHome = (Join-Path $env:USERPROFILE ".claude"),
    [string]$Prefix = (Join-Path $env:USERPROFILE ".local"),
    [switch]$UseWSL
)

$ErrorActionPreference = "Stop"
$Repo = "tryarkon/claude-quality-gate"

function Step($msg)  { Write-Host "`n$msg" -ForegroundColor White }
function Ok($msg)    { Write-Host "  OK   $msg" -ForegroundColor Green }
function Warn($msg)  { Write-Host "  WARN $msg" -ForegroundColor Yellow }
function Fail($msg)  { Write-Host "  FAIL $msg" -ForegroundColor Red; exit 1 }
function Info($msg)  { Write-Host "       $msg" -ForegroundColor DarkCyan }

# --- 1. preflight --------------------------------------------------------
Step "[1/6] Preflight checks"

# Need bash. Either git-bash or WSL.
$BashPath = $null
if ($UseWSL) {
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        Fail "WSL not installed. Install WSL: 'wsl --install'."
    }
    $BashPath = "wsl bash"
    Ok "Using WSL bash"
} else {
    $gitBash = @(
        "C:\Program Files\Git\bin\bash.exe",
        "C:\Program Files (x86)\Git\bin\bash.exe",
        (Join-Path $env:LOCALAPPDATA "Programs\Git\bin\bash.exe")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $gitBash) {
        Warn "Git Bash not found at standard paths."
        Info "Install Git for Windows: https://git-scm.com/download/win"
        Info "Or re-run with -UseWSL: 'iwr -useb ... | iex' won't work — download install.ps1 and run with -UseWSL."
        Fail "Cannot locate bash."
    }
    $BashPath = $gitBash
    Ok "Found Git Bash: $gitBash"
}

if (-not (Get-Command python -ErrorAction SilentlyContinue) -and `
    -not (Get-Command python3 -ErrorAction SilentlyContinue)) {
    Fail "python3 not found. Install Python 3.7+: https://python.org/downloads"
}
$PyExe = if (Get-Command python3 -ErrorAction SilentlyContinue) { "python3" } else { "python" }
$PyVersion = (& $PyExe --version 2>&1).ToString()
Ok "Python: $PyVersion"

# --- 2. resolve source ---------------------------------------------------
Step "[2/6] Locating source"

$ScriptDir = $PSScriptRoot
$SourceDir = $null

if ($ScriptDir -and (Test-Path (Join-Path $ScriptDir "..\hooks"))) {
    $SourceDir = Resolve-Path (Join-Path $ScriptDir "..")
    Info "Local checkout: $SourceDir"
} else {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Fail "git not found and no local checkout."
    }
    $TmpDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "qg-$(Get-Random)") -Force
    Info "Cloning $Repo @ $Branch to $TmpDir"
    git clone -q --depth 1 --branch $Branch "https://github.com/$Repo.git" (Join-Path $TmpDir "qg") | Out-Null
    $SourceDir = Join-Path $TmpDir "qg"
    Ok "Cloned"
}

# --- 3. copy hooks -------------------------------------------------------
Step "[3/6] Installing hooks → $ClaudeHome\hooks\"

$HooksDir = Join-Path $ClaudeHome "hooks"
New-Item -ItemType Directory -Path $HooksDir -Force | Out-Null

$Hooks = @(
    "pre-read-gate", "pre-write-gate", "pre-bash-gate",
    "auto-verify", "track-activity", "on-stop-discipline", "hook-utils"
)
foreach ($h in $Hooks) {
    $src = Join-Path $SourceDir "hooks\$h.sh"
    $dst = Join-Path $HooksDir  "$h.sh"
    Copy-Item $src $dst -Force
    Ok "$h.sh"
}

# --- 4. merge settings.json ----------------------------------------------
Step "[4/6] Merging settings.json (existing keys preserved)"

$SettingsPath = Join-Path $ClaudeHome "settings.json"
$MergeScript  = Join-Path $SourceDir "scripts\merge_settings.py"

& $PyExe $MergeScript --settings $SettingsPath --hooks-dir $HooksDir
Ok "settings.json updated"

# --- 5. install qg CLI ---------------------------------------------------
Step "[5/6] Installing qg CLI → $Prefix\bin\"

$BinDir = Join-Path $Prefix "bin"
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null

$QgSrc = Join-Path $SourceDir "bin\qg"
$QgDst = Join-Path $BinDir   "qg"
Copy-Item $QgSrc $QgDst -Force

# Windows wrapper: qg.cmd that delegates to bash qg
$DataDir = Join-Path $ClaudeHome "quality-gate"
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
Copy-Item (Join-Path $SourceDir "scripts") (Join-Path $DataDir "scripts") -Recurse -Force
if (Test-Path (Join-Path $SourceDir "tests")) {
    Copy-Item (Join-Path $SourceDir "tests") (Join-Path $DataDir "tests") -Recurse -Force
}
Copy-Item (Join-Path $SourceDir "hooks") (Join-Path $DataDir "hooks") -Recurse -Force

# Patch qg with QG_ROOT pointing at the data dir
$QgContent = Get-Content $QgDst -Raw
$BashDataDir = $DataDir.Replace('\', '/').Replace('C:', '/c').Replace('D:', '/d')
$QgContent = $QgContent -replace 'QG_ROOT="\$\{QG_ROOT:-\$\(_resolve_root\)\}"', "QG_ROOT=`"`${QG_ROOT:-$BashDataDir}`""
Set-Content -Path $QgDst -Value $QgContent -Encoding UTF8

# qg.cmd wrapper
$QgCmd = @"
@echo off
"$BashPath" "$BashDataDir/bin/qg" %*
"@
Set-Content -Path (Join-Path $BinDir "qg.cmd") -Value $QgCmd -Encoding ASCII
Ok "qg.cmd installed"

# Add to PATH (User scope) if not already there
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable("Path", "$UserPath;$BinDir", "User")
    Warn "Added $BinDir to your User PATH. Open a new terminal for it to take effect."
}

# --- 6. summary ----------------------------------------------------------
Step "[6/6] Done"

Write-Host ""
Write-Host "  claude-quality-gate is installed." -ForegroundColor White
Write-Host ""
Write-Host "  Hooks:    $HooksDir"     -ForegroundColor DarkCyan
Write-Host "  Settings: $SettingsPath" -ForegroundColor DarkCyan
Write-Host "  CLI:      $BinDir\qg.cmd" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "    qg status                        # check what's active"
Write-Host "    qg dashboard                     # open metrics on http://localhost:7777"
Write-Host "    qg config QG_PROFILE standard    # less strict mode"
Write-Host "    qg uninstall                     # revert"
Write-Host ""
Write-Host "  Open a new Claude Code session — gates fire automatically."
Write-Host ""
Write-Host "  Docs:   https://github.com/$Repo"
Write-Host "  Issues: https://github.com/$Repo/issues"
Write-Host ""
