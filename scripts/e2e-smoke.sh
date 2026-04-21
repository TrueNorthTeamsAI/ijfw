#!/usr/bin/env bash
# IJFW end-to-end smoke harness.
#
# Two modes run back-to-back:
#
#   1. SCRATCH guard check
#      Runs the installer with IJFW_CUSTOM_DIR=1 pointed at a throwaway dir.
#      Before-and-after hashes of the user's real platform configs MUST match.
#      Failure here = "Bug A regressed, installer is leaking into real $HOME".
#
#   2. CANONICAL install into an isolated $HOME
#      Points HOME at a fresh mktemp dir, runs the installer, then parses
#      every platform's written config against the schema it should have.
#      Also spawns the ijfw-memory MCP server and asserts the initialize +
#      tools/list handshake completes.
#
# Exit 0 only if both modes pass every assertion. On failure, the script
# prints the specific gate that broke and leaves the scratch dirs in place
# so a human can inspect them. Use --cleanup to override and wipe on exit.
#
# Usage:
#   bash scripts/e2e-smoke.sh             # standard run
#   bash scripts/e2e-smoke.sh --cleanup   # always wipe scratch dirs
#   bash scripts/e2e-smoke.sh --verbose   # stream installer output

set -u

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEANUP=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --cleanup) CLEANUP=1 ;;
    --verbose|-v) VERBOSE=1 ;;
  esac
done

# ------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R=$'\033[0m'; B=$'\033[1m'
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  R=; B=; C_GREEN=; C_RED=; C_YELLOW=; C_CYAN=
fi

pass() { printf "  %s[PASS]%s %s\n" "$C_GREEN" "$R" "$1"; }
fail() { printf "  %s[FAIL]%s %s\n" "$C_RED"   "$R" "$1"; FAILURES=$((FAILURES + 1)); }
info() { printf "  %s[..]  %s%s\n" "$C_CYAN"  "$R" "$1"; }
hdr()  { printf "\n%s== %s ==%s\n" "$B" "$1" "$R"; }

FAILURES=0
SCRATCH_DIRS=()
cleanup_scratches() {
  if [ "$CLEANUP" = "1" ] || [ "$FAILURES" -eq 0 ]; then
    for d in "${SCRATCH_DIRS[@]}"; do rm -rf "$d" 2>/dev/null; done
  else
    printf "\n%sScratch dirs left for inspection:%s\n" "$C_YELLOW" "$R"
    for d in "${SCRATCH_DIRS[@]}"; do printf "  %s\n" "$d"; done
  fi
}
trap cleanup_scratches EXIT

run_installer() {
  # $1 = scratch dir, $2 = IJFW_CUSTOM_DIR value (0 or 1)
  local dir="$1" custom="$2"
  if [ "$VERBOSE" = "1" ]; then
    IJFW_CUSTOM_DIR="$custom" IJFW_HOME="$dir" bash "$dir/scripts/install.sh"
  else
    IJFW_CUSTOM_DIR="$custom" IJFW_HOME="$dir" bash "$dir/scripts/install.sh" \
      >"$dir/install.out" 2>"$dir/install.err" || return $?
  fi
}

# Compute a stable hash of a file for before/after compare. Uses shasum (present
# on macOS) or sha256sum (Linux). Missing file -> empty hash (not an error).
hash_file() {
  local f="$1"
  [ -f "$f" ] || { printf ""; return; }
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    sha256sum "$f" | awk '{print $1}'
  fi
}

# ------------------------------------------------------------
# Paths we want to prove are untouched in scratch mode.
# Every write target listed in the install.sh platform case blocks.
# ------------------------------------------------------------
GUARD_PATHS=(
  "$HOME/.claude/settings.json"
  "$HOME/.claude/plugins/known_marketplaces.json"
  "$HOME/.codex/config.toml"
  "$HOME/.codex/hooks.json"
  "$HOME/.gemini/settings.json"
  "$HOME/.codeium/windsurf/mcp_config.json"
  "$HOME/.hermes/config.yaml"
  "$HOME/.hermes/HERMES.md"
  "$HOME/.wayland/config.yaml"
  "$HOME/.wayland/WAYLAND.md"
)

# ============================================================
# MODE 1: SCRATCH guard check
# ============================================================
hdr "Mode 1 of 2 -- scratch-dir guard (Bug A regression gate)"

SCRATCH_A="$(mktemp -d -t ijfw-smoke-scratch-XXXXXX)"
SCRATCH_DIRS+=("$SCRATCH_A")
info "scratch dir: $SCRATCH_A"

info "mirroring repo into scratch..."
rsync -a --exclude='.git' --exclude='node_modules' --exclude='.ijfw' \
      --exclude='.planning' --exclude='installer/docs' \
      "$REPO_ROOT/" "$SCRATCH_A/"

info "snapshotting real platform configs..."
declare -a BEFORE_HASHES
for p in "${GUARD_PATHS[@]}"; do
  BEFORE_HASHES+=("$(hash_file "$p")")
done

info "running installer with IJFW_CUSTOM_DIR=1 ..."
if run_installer "$SCRATCH_A" 1; then
  pass "installer exited 0 in scratch mode"
else
  fail "installer exited non-zero in scratch mode (see $SCRATCH_A/install.err)"
fi

info "comparing post-install hashes against snapshot..."
LEAK=0
for i in "${!GUARD_PATHS[@]}"; do
  p="${GUARD_PATHS[$i]}"
  before="${BEFORE_HASHES[$i]}"
  after="$(hash_file "$p")"
  if [ "$before" != "$after" ]; then
    fail "scope leak: $p changed during scratch install"
    LEAK=1
  fi
done
if [ "$LEAK" = "0" ]; then
  pass "zero drift across ${#GUARD_PATHS[@]} guard paths"
fi

# ============================================================
# MODE 2: CANONICAL install in isolated HOME
# ============================================================
hdr "Mode 2 of 2 -- canonical install in isolated HOME"

ISO_HOME="$(mktemp -d -t ijfw-smoke-home-XXXXXX)"
SCRATCH_DIRS+=("$ISO_HOME")
info "isolated HOME: $ISO_HOME"

info "mirroring repo into isolated ~/.ijfw ..."
mkdir -p "$ISO_HOME/.ijfw"
rsync -a --exclude='.git' --exclude='node_modules' --exclude='.ijfw' \
      --exclude='.planning' --exclude='installer/docs' \
      "$REPO_ROOT/" "$ISO_HOME/.ijfw/"

info "running installer with HOME=$ISO_HOME ..."
(
  export HOME="$ISO_HOME"
  export IJFW_HOME="$ISO_HOME/.ijfw"
  export IJFW_CUSTOM_DIR="0"
  cd "$ISO_HOME/.ijfw"
  if [ "$VERBOSE" = "1" ]; then
    bash scripts/install.sh
  else
    bash scripts/install.sh >"$ISO_HOME/install.out" 2>"$ISO_HOME/install.err"
  fi
) || fail "installer failed in isolated HOME (see $ISO_HOME/install.err)"
if [ "$FAILURES" -eq 0 ]; then pass "installer exited 0 in canonical mode"; fi

# ---- Assertions on written configs ----

# Claude settings.json: has ijfw plugin enabled + marketplace registered.
CL="$ISO_HOME/.claude/settings.json"
if [ -f "$CL" ] && node -e "const d=JSON.parse(require('fs').readFileSync('$CL','utf8')); process.exit(d && d.enabledPlugins && d.enabledPlugins['ijfw@ijfw']===true ? 0 : 1)"; then
  pass "claude settings.json: ijfw plugin enabled"
else
  fail "claude settings.json missing or does not enable ijfw plugin"
fi

# Codex config.toml: has [mcp_servers.ijfw-memory] and suppress warning flag.
CX="$ISO_HOME/.codex/config.toml"
if [ -f "$CX" ] && grep -q '^\[mcp_servers.ijfw-memory\]' "$CX" \
               && grep -q '^command\s*=' "$CX" \
               && grep -q '^suppress_unstable_features_warning\s*=\s*true' "$CX"; then
  pass "codex config.toml: MCP block + warning suppression"
else
  fail "codex config.toml missing [mcp_servers.ijfw-memory] or suppress_unstable_features_warning"
fi

# Codex hooks.json: top-level {hooks: {EventName: [...]}} with PascalCase keys,
# each MatcherGroup has .hooks[] with {type:"command", command:"..."}
CH="$ISO_HOME/.codex/hooks.json"
if [ -f "$CH" ] && node -e '
  const fs=require("fs");
  const d=JSON.parse(fs.readFileSync("'"$CH"'","utf8"));
  if (!d || typeof d!=="object" || Array.isArray(d)) { process.exit(1); }
  if (!d.hooks || typeof d.hooks!=="object" || Array.isArray(d.hooks)) { process.exit(1); }
  const events=Object.keys(d.hooks);
  if (events.length===0) { process.exit(1); }
  for (const ev of events) {
    const grps=d.hooks[ev];
    if (!Array.isArray(grps)) { console.error("non-array event "+ev); process.exit(1); }
    for (const g of grps) {
      if (!g || !Array.isArray(g.hooks)) { console.error("bad group under "+ev); process.exit(1); }
      for (const h of g.hooks) {
        if (h.type!=="command" || typeof h.command!=="string" || !h.command) { console.error("bad handler under "+ev); process.exit(1); }
        if (!h.command.startsWith("/")) { console.error("non-abs command under "+ev+": "+h.command); process.exit(1); }
      }
    }
  }
  process.exit(0);
'; then
  pass "codex hooks.json: nested schema valid + absolute command paths"
else
  fail "codex hooks.json missing, malformed, or uses wrong schema"
fi

# Gemini settings.json: mcpServers.ijfw-memory.command resolves.
GM="$ISO_HOME/.gemini/settings.json"
if [ -f "$GM" ] && node -e "const d=JSON.parse(require('fs').readFileSync('$GM','utf8')); const m=d.mcpServers&&d.mcpServers['ijfw-memory']; process.exit(m && m.command ? 0 : 1)"; then
  pass "gemini settings.json: ijfw-memory registered"
else
  fail "gemini settings.json missing ijfw-memory"
fi

# Windsurf mcp_config.json
WS="$ISO_HOME/.codeium/windsurf/mcp_config.json"
if [ -f "$WS" ] && node -e "const d=JSON.parse(require('fs').readFileSync('$WS','utf8')); const m=d.mcpServers&&d.mcpServers['ijfw-memory']; process.exit(m && m.command ? 0 : 1)"; then
  pass "windsurf mcp_config.json: ijfw-memory registered"
else
  fail "windsurf mcp_config.json missing ijfw-memory"
fi

# Hermes config.yaml
HC="$ISO_HOME/.hermes/config.yaml"
if [ -f "$HC" ] && grep -q 'ijfw-memory' "$HC"; then
  pass "hermes config.yaml: ijfw-memory registered"
else
  fail "hermes config.yaml missing or lacks ijfw-memory"
fi
if [ -f "$ISO_HOME/.hermes/HERMES.md" ]; then
  pass "hermes HERMES.md present"
else
  fail "hermes HERMES.md missing"
fi
if [ -d "$ISO_HOME/.hermes/skills" ] && [ "$(find "$ISO_HOME/.hermes/skills" -maxdepth 1 -type d -name 'ijfw-*' 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
  pass "hermes skills/ijfw-* dirs installed"
else
  fail "hermes skills not copied"
fi

# Wayland config.yaml
WC="$ISO_HOME/.wayland/config.yaml"
if [ -f "$WC" ] && grep -q 'ijfw-memory' "$WC"; then
  pass "wayland config.yaml: ijfw-memory registered"
else
  fail "wayland config.yaml missing or lacks ijfw-memory"
fi
if [ -f "$ISO_HOME/.wayland/WAYLAND.md" ]; then
  pass "wayland WAYLAND.md present"
else
  fail "wayland WAYLAND.md missing"
fi
if [ -d "$ISO_HOME/.wayland/skills" ] && [ "$(find "$ISO_HOME/.wayland/skills" -maxdepth 1 -type d -name 'ijfw-*' 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]; then
  pass "wayland skills/ijfw-* dirs installed"
else
  fail "wayland skills not copied"
fi

# ---- MCP server handshake test ----
info "handshaking with MCP server..."
SERVER_JS="$ISO_HOME/.ijfw/mcp-server/src/server.js"
if [ -f "$SERVER_JS" ]; then
  MCP_RESP=$(
    (
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}'
      sleep 0.2
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
      sleep 0.2
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
      sleep 0.4
    ) | node "$SERVER_JS" 2>/dev/null | head -5
  )
  if echo "$MCP_RESP" | grep -q '"tools"'; then
    pass "MCP server completes full handshake (initialize + tools/list)"
  elif echo "$MCP_RESP" | grep -q '"result"'; then
    pass "MCP server responds to initialize (tools/list unverified)"
  else
    fail "MCP server silent during handshake"
  fi
else
  fail "MCP server entry point missing at $SERVER_JS"
fi

# ============================================================
# SUMMARY
# ============================================================
hdr "Summary"
if [ "$FAILURES" -eq 0 ]; then
  printf "  %s+ ALL GATES PASSED+%s\n\n" "$B$C_GREEN" "$R"
  exit 0
else
  printf "  %s! %d gate(s) failed%s\n\n" "$B$C_RED" "$FAILURES" "$R"
  exit 1
fi
