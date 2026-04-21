# Changelog -- @ijfw/install

## [1.1.2] -- 2026-04-21

Reach + bug fixes. Two new platforms (Hermes + Wayland), deep installer repairs uncovered by live-platform testing, cross-platform sync of new behavioral rules. Ships with a full end-to-end smoke harness at `scripts/e2e-smoke.sh` that now has to pass before any future release.

### New platforms

- **Hermes** (`hermes/`): MCP registration in `~/.hermes/config.yaml`, `HERMES.md` context file, 19 IJFW skills dropped into `~/.hermes/skills/ijfw-*` in agentskills.io format. Python CLI (`hermes` command).
- **Wayland** (`wayland/`): same shape. MCP registration in `~/.wayland/config.yaml`, `WAYLAND.md` context file, skills bundle in `~/.wayland/skills/ijfw-*`. Python CLI (`wayland` command).
- `scripts/install.sh` gains a `merge_yaml_mcp` helper (prefers python3+PyYAML for parser-safe merge; sentinel-anchored fallback if PyYAML isn't available).
- Default target list expands to 8: `claude codex gemini cursor windsurf copilot hermes wayland`. `is_live` and `pretty_name` updated to match.

### Installer repairs (high -- announcement blockers)

- **Bug A: platform-config writes now respect `IJFW_CUSTOM_DIR`.** The 1.1.2 prep pass only guarded sibling links and bin wiring. The `~/.claude/settings.json`, `~/.codex/`, `~/.gemini/`, `~/.codeium/windsurf/` merges were still running during scratch installs and clobbering real user configs with scratch paths. Every platform case block now short-circuits early when `IJFW_CUSTOM_DIR=1`, prints a single "real platform config left untouched" line, and still classifies the platform as live/standby for the summary banner.
- **Bug B: Codex `hooks.json` schema migrated to the current nested format.** Codex CLI 0.120+ rejects both the legacy `{"hooks":[...]}` object-wrapper and the bare-array shape this release started with. Authoritative schema (per `codex-rs/hooks/src/engine/config.rs`): `{"hooks": {EventName: [MatcherGroup]}}` where each MatcherGroup is `{matcher?, hooks: [{type: "command", command, timeout?, ...}]}`. Installer writer now emits this shape, absorbs either legacy shape on read, drops the non-existent `AfterAgent` event, renames `script` to `command`, and adds the `"type": "command"` discriminator.
- **Bug C: `suppress_unstable_features_warning = true` is now written to `~/.codex/config.toml`.** Stops the "under-development features enabled: codex_hooks" banner on every Codex startup.
- **Self-loop guards now canonicalize `$HOME`.** On macOS `/var/folders` is a symlink to `/private/var/folders`; the `cd -P` used for `REPO_ROOT` resolved that, but `$HOME` did not, so the `PLUGIN_SRC == PLUGIN_DST` and `MCP_SRC == MCP_DST` comparisons missed the equal case and created recursive self-symlinks ("too many levels of symbolic links" on next access). Installer now computes `HOME_REAL="$(cd -P "$HOME" && pwd)"` once and uses it for all self-loop comparisons.
- **`C_RED` variable declared.** Previously only initialized on interactive TTYs; a failing post-install gate in a non-TTY context (CI, harness, `npx` capture) would crash the installer with `C_RED: unbound variable` under `set -u`. Declared in both branches of the color-init block.

### Behavioral additions (synced across Claude / Codex / Gemini / Cursor / Windsurf / Copilot / Hermes / Wayland / universal where relevant)

- `ijfw-core` and platform rules-files: explicit banned openers ("Great question", "You're absolutely right", "Excellent idea", "I'd be happy to") and a sharpened two-strikes session-reset rule that asks the user to start a fresh session with a tighter prompt rather than burning context on a third failed attempt.
- `ijfw-debug`: new Step 6 templating the two-strikes reset with a memory-store call so lessons inherit forward without context noise.
- `ijfw-verify`: opens with "Plausibility is not correctness." Every claim must trace to a command output, test pass, or manual verification.
- `ijfw-workflow` Quick FRAME: five concrete goal-rewrite examples ("Add validation" -> "Write tests for invalid inputs..."). Vague asks must surface the gap rather than silently proceed.
- `ijfw-memory-audit`: pruning question added ("Would removing this rule cause the agent to make a mistake?") so memory stays sharp instead of bloated.
- `ijfw-critique`: refactor reframe ("Knowing everything I know now, what would the elegant solution look like?") for breaking frame on non-trivial decisions.

### End-to-end smoke harness

- New `scripts/e2e-smoke.sh`. Two modes, both must pass:
  1. **Scratch-guard check** -- runs installer with `IJFW_CUSTOM_DIR=1` pointed at a throwaway dir, verifies zero drift across 10 real-home config paths (hashes before and after). Catches any future Bug A regression.
  2. **Canonical isolated-HOME install** -- runs installer with `HOME=$(mktemp -d)`, parses every platform's written config against its expected schema (Codex nested hooks, Gemini JSON, YAML for Hermes/Wayland, etc.), completes the MCP `initialize + tools/list` handshake, and fails loudly on any mismatch.
- 13 gates total. Harness must be green before any future `npm publish`.

### Uninstaller

- `installer/src/uninstall.js:removeCodexHooks` now handles all three hook-file shapes we have ever shipped (bare array, legacy `{hooks:[...]}` object-wrapper, current nested-map). Uninstall works regardless of which version the user last installed.
- New `removeYamlMcpEntry` helper (python3+PyYAML preferred, regex fallback). Cleans `~/.hermes/config.yaml` and `~/.wayland/config.yaml`, removes skill dirs and context files for both new platforms.
- `cleanPlatforms()` comment updated: "all 8 platforms".

### Installer scope-leak fixes (carried from 1.1.2 prep)

- `scripts/install.sh` now respects `IJFW_CUSTOM_DIR` from `install.js`. Custom-dir installs (`--dir <scratch>`) skip user-home mutations: no sibling links into `~/.ijfw/`, no bin symlinks into `~/.local/bin/`, no `.mcp.json` patching of the real plugin, no `~/.claude/plugins/cache/ijfw` invalidation. Default canonical install behavior unchanged.
- Self-loop guard: when `PLUGIN_SRC == PLUGIN_DST` (install dir is the canonical home and source happens to live there), the symlink step is skipped instead of creating a recursive `~/.ijfw/claude -> ~/.ijfw/claude` loop.
- `installer/src/uninstall.js`: `uninstall --dir <scratch>` now leaves `~/.codex/`, `~/.gemini/`, `~/.codeium/windsurf/` configs and skill dirs alone. Only canonical uninstalls (`~/.ijfw`) clean platform configs.

### Dynamic version strings

- `mcp-server/src/server.js` and `mcp-server/src/dashboard-server.js` now read version from `mcp-server/package.json` at module load instead of hardcoding. MCP `serverInfo` and `/api/health` always match the shipped version.

### Internal

- `mcp-server/package.json` bumped from 1.1.0 to 1.1.2 (was lagging two minor cycles).
- `.gitattributes`: added LF normalization rules (carried from 1.1.1).
- Banner on successful install now says "8 platforms" instead of "7".

## [1.1.1] -- 2026-04-19

Docs and discoverability.

- New `ijfw help` command. Pages the full guide in your terminal (less -R fallback), or opens a rendered browser tab with `ijfw help --browser`.
- Ships `docs/GUIDE.md` inside the npm tarball: Part 1 quickstart with three 90-second wins, Part 2 command / skill / workflow reference, plus FAQ and troubleshooting.
- Browser render is pre-generated server-side via marked. No client-side script, no XSS surface. GitHub dark CSS, local assets copied to `~/.ijfw/guide/`.
- Claude Code slash command: `/ijfw-help`.

## [1.1.0] -- 2026-04-19

Public launch. One install, every AI coding agent, zero config.

### Cross-platform install verified

- macOS (Homebrew node)
- Linux (apt node) on a fresh hostkey VM
- Windows (Git Bash with Git for Windows)

### Unified `ijfw` CLI

One dispatcher, one source of truth:

- `ijfw install` -- install or re-install IJFW into every detected agent
- `ijfw uninstall` (alias `ijfw off`) -- revert, preserving memory by default
- `ijfw preflight` -- 11-gate quality pipeline, blocking + advisory
- `ijfw dashboard start|stop|status` -- local dashboard, zero deps
- `ijfw doctor` -- CLI and API-key reachability with literal fix commands
- `ijfw status` -- hero line, recent activity, cache savings
- `ijfw update` -- pull latest, reinstall merge-safely
- `ijfw cross audit|research|critique|project-audit` -- multi-AI adversarial review
- `ijfw import claude-mem [--all]` -- absorb existing claude-mem memory, per-project routing
- `ijfw receipt last` -- shareable, redacted block from the last Trident run

### Installer hardening

- Plugin cache invalidation on every install (fixes stale `.mcp.json`)
- Plugin source + `mcp-server` sibling-link auto-creation (POSIX) or copy (Windows)
- `server.js` falls back to HOME when CWD is unwritable -- no stderr spam during MCP handshake
- `.mcp.json` patched with absolute node + server.js paths at install time
- `install.ps1` invokes the same `install.sh` via bash.exe -- one code path, three platforms
- Post-install verification gates: plugin manifest, sibling link, MCP handshake, settings.json registration, CLI wiring. Exits non-zero if any gate fails.

### claude-mem migration

- `ijfw import claude-mem --all` auto-discovers projects from claude-mem's `project` column, matches to on-disk locations via `~/.claude/projects` and common dev parents, routes each project's entries into its own `.ijfw/memory/`.
- Schema introspection (PRAGMA table_info) tolerates claude-mem version drift.
- Idempotent -- safe to rerun.

### Publish

```bash
cd installer && npm publish --access public
```

---

## [1.1.0-rc.1] -- 2026-04-16 (pre-1.0 internal release candidate, superseded by 1.0.0)

Release candidate. Soak 24h before stable 1.1.0.

### New verbs on the `ijfw` binary

- `ijfw preflight` -- 11-gate blocking quality pipeline. Replaces ad-hoc manual checks before publish.
- `ijfw dashboard start|stop|status` -- local SSE dashboard on 127.0.0.1:37891, zero deps, single-file HTML client.

### Preflight highlights

- Gates: shellcheck, oxlint, eslint-security, PSScriptAnalyzer (CI Windows only), publint, gitleaks, audit-ci, knip, license-check, pack-smoke, upgrade-smoke.
- Blocking gates exit 1 on fail. Advisory gates warn only. Missing tools skip gracefully with install hint.
- `prepublishOnly` now runs preflight: no tag can publish with a blocking gate open.

### Dashboard highlights

- Observation ledger at `~/.ijfw/observations.jsonl` fed by PostToolUse hooks on Claude, Codex, and Gemini.
- SSE live feed delivers new observations within ~150ms of ledger append.
- Localhost-only (127.0.0.1); non-loopback requests receive 403.
- Zero runtime dependencies. `npm ls --production`: 0 entries.

### Unified cockpit: costs + savings + memory (Waves H + I)

- Hero bar shows live Today / 7d spend and a savings bubble (cache, memory, terse, trident savings totals).
- New endpoints: `/api/cost/today`, `/api/cost/period`, `/api/cost/history`, `/api/memory`, `/api/memory/search`, `/api/memory/recall-stats`. All localhost-guarded.
- Memory rail lists all `.ijfw/memory/` files with recall count badges and full-text BM25 search.
- Path traversal fix on `/api/memory/file`: uses `resolve()` before prefix check.
- Credit: cost tracking adapted from CodeBurn (AgentSeal, MIT) and ccusage (ryoppippi, MIT).

### Tests

- 392 passing. Cost and memory module tests included in the mcp-server suite.

Full project changelog at <https://github.com/TheRealSeanDonahoe/ijfw/blob/main/CHANGELOG.md>.

## [1.0.0] -- 2026-04-17

First stable release. One-command installer configures IJFW across six AI
coding agents (Claude Code, Codex, Gemini CLI, Cursor, Windsurf, Copilot).

### Highlights

- Cross-platform: bash installer for macOS/Linux/WSL, PowerShell installer
  for Windows (PS 5.1+, uses Git Bash under the hood -- no WSL required).
- Merge-safe: backs up existing platform configs before modifying, never
  clobbers user MCP servers or model preferences.
- Pre-staging: configures every supported platform even if only a subset
  is installed; the rest auto-activate the moment they are installed.
- Graceful fallbacks: state-machine JSONC parser for the Claude settings
  merge; on parse failure, backs up the file and prints the manual
  `/plugin marketplace add` + `/plugin install ijfw` commands.
- Polished output: ANSI-colored boxed banner, Live-now / Standing-by
  summary, full-log redirection to `~/.ijfw/install.log`.
- Zero runtime dependencies; 4 KB tarball.

Full project changelog at <https://github.com/TheRealSeanDonahoe/ijfw/blob/main/CHANGELOG.md>.
