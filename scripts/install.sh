#!/usr/bin/env bash
# install.sh — claude-quality-gate installer (Mac/Linux/WSL/git-bash)
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/tryarkon/claude-quality-gate/main/install.sh | bash
#   bash scripts/install.sh                # from a checkout
#   QG_PREFIX=$HOME/.local bash install.sh # custom prefix
#
# What it does:
#   1. Detects OS, ensures bash >=3.2 and python3 are available
#   2. Clones repo to /tmp if invoked via curl (no checkout context)
#   3. Copies hooks/* → ~/.claude/hooks/
#   4. Backs up ~/.claude/settings.json → settings.json.bak.<ts>
#   5. Smart-merges our gates into settings.json (no overwrite of user keys)
#   6. Installs `qg` CLI to ~/.local/bin/qg (creates dir if needed)
#   7. Prints "next steps"

set -euo pipefail

REPO="tryarkon/claude-quality-gate"
BRANCH="${QG_BRANCH:-main}"
QG_HOME="${QG_HOME:-$HOME/.claude}"
QG_PREFIX="${QG_PREFIX:-$HOME/.local}"
BIN_DIR="$QG_PREFIX/bin"

# --- pretty output --------------------------------------------------------
if [ -t 1 ]; then
    BOLD='\033[1m'; OFF='\033[0m'
    GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; CYAN='\033[36m'
else
    BOLD=''; OFF=''; GREEN=''; YELLOW=''; RED=''; CYAN=''
fi
ok()    { printf "${GREEN}✓${OFF} %s\n" "$1"; }
warn()  { printf "${YELLOW}!${OFF} %s\n" "$1"; }
fail()  { printf "${RED}✗${OFF} %s\n" "$1" >&2; }
info()  { printf "${CYAN}·${OFF} %s\n" "$1"; }
step()  { printf "\n${BOLD}%s${OFF}\n" "$1"; }

# --- 1. preflight ---------------------------------------------------------
step "[1/6] Preflight checks"

case "$(uname -s)" in
    Darwin*)  PLATFORM="macos" ;;
    Linux*)   PLATFORM="linux" ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM="windows-bash" ;;
    *)
        fail "Unsupported OS: $(uname -s). For Windows use install.ps1."
        exit 1
        ;;
esac
ok "Platform: $PLATFORM"

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 not found. Install Python 3.7+ first."
    case "$PLATFORM" in
        macos) info "Try: brew install python3" ;;
        linux) info "Try: sudo apt install python3 (or your distro equivalent)" ;;
    esac
    exit 1
fi
PY_VERSION=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
ok "python3: $PY_VERSION"

BASH_MAJ=$(echo "$BASH_VERSION" | cut -d. -f1)
if [ "$BASH_MAJ" -lt 3 ]; then
    fail "bash $BASH_VERSION too old (need 3.2+)"
    exit 1
fi
ok "bash: $BASH_VERSION"

# --- 2. resolve source --------------------------------------------------
step "[2/6] Locating source"

# If invoked from a checkout, use the script's parent dir.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
SOURCE_DIR=""
if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/../hooks" ]; then
    SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    info "Local checkout: $SOURCE_DIR"
fi

# If invoked via curl | bash, $0 is "bash" and we have no source.
if [ -z "$SOURCE_DIR" ]; then
    if ! command -v git >/dev/null 2>&1; then
        fail "git not found and no local checkout — install git or clone the repo manually."
        exit 1
    fi
    TMPDIR=$(mktemp -d)
    info "Cloning $REPO@$BRANCH to $TMPDIR"
    git clone -q --depth 1 --branch "$BRANCH" "https://github.com/$REPO.git" "$TMPDIR/qg"
    SOURCE_DIR="$TMPDIR/qg"
    ok "Cloned"
fi

# --- 3. copy hooks --------------------------------------------------------
step "[3/6] Installing hooks → $QG_HOME/hooks/"

mkdir -p "$QG_HOME/hooks"
for h in pre-read-gate pre-write-gate pre-bash-gate auto-verify track-activity on-stop-discipline hook-utils; do
    cp "$SOURCE_DIR/hooks/${h}.sh" "$QG_HOME/hooks/"
    chmod +x "$QG_HOME/hooks/${h}.sh"
    ok "${h}.sh"
done

# --- 4. merge settings.json -----------------------------------------------
step "[4/6] Merging settings.json (existing keys preserved)"

mkdir -p "$QG_HOME"
python3 "$SOURCE_DIR/scripts/merge_settings.py" \
    --settings "$QG_HOME/settings.json" \
    --hooks-dir "$QG_HOME/hooks"
ok "settings.json updated"

# --- 5. install qg CLI ----------------------------------------------------
step "[5/6] Installing qg CLI → $BIN_DIR/qg"

mkdir -p "$BIN_DIR"
cp "$SOURCE_DIR/bin/qg" "$BIN_DIR/qg"
chmod +x "$BIN_DIR/qg"

# Symlink to a stable location for `qg dashboard` to find dashboard.py and tests/.
QG_DATA_DIR="$QG_HOME/quality-gate"
mkdir -p "$QG_DATA_DIR"
cp -R "$SOURCE_DIR/scripts" "$QG_DATA_DIR/"
[ -d "$SOURCE_DIR/tests" ] && cp -R "$SOURCE_DIR/tests" "$QG_DATA_DIR/" || true
[ -d "$SOURCE_DIR/hooks" ]  && cp -R "$SOURCE_DIR/hooks"  "$QG_DATA_DIR/" || true

# Patch qg with QG_ROOT pointing at the data dir so subcommands find dashboard.py.
sed -i.bak "s|QG_ROOT=\"\${QG_ROOT:-\$(_resolve_root)}\"|QG_ROOT=\"\${QG_ROOT:-$QG_DATA_DIR}\"|" "$BIN_DIR/qg"
rm -f "$BIN_DIR/qg.bak"
ok "qg installed"

# Check PATH
if ! echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
    warn "$BIN_DIR is not in your PATH."
    info "Add this to your ~/.bashrc or ~/.zshrc:"
    info "    export PATH=\"$BIN_DIR:\$PATH\""
fi

# --- 6. summary -----------------------------------------------------------
step "[6/6] Done"

cat <<EOF

  ${BOLD}claude-quality-gate is installed.${OFF}

  Hooks:    ${CYAN}$QG_HOME/hooks/${OFF}
  Settings: ${CYAN}$QG_HOME/settings.json${OFF}
  CLI:      ${CYAN}$BIN_DIR/qg${OFF}

  Next steps:
    ${BOLD}qg status${OFF}              — check what's active
    ${BOLD}qg dashboard${OFF}           — open metrics on http://localhost:7777
    ${BOLD}qg config QG_PROFILE standard${OFF}  — switch to less strict mode
    ${BOLD}qg uninstall${OFF}           — revert all changes (uses backup)

  Open a new Claude Code session and the gates will fire automatically.

  Docs:     https://github.com/$REPO
  Issues:   https://github.com/$REPO/issues

EOF
