# CLAUDE.md

## Project overview

tmux-overmind is a tmux plugin that monitors AI coding agents (Claude Code, OpenCode, Gemini CLI, Codex, Copilot, Crush) running across all tmux sessions. It shows a status bar indicator (`●` running / `◐` waiting) and provides a floating dashboard (`prefix+O`) and quick-jump (`prefix+J`).

## Architecture

Bash-only, TPM-compatible. A background daemon (`monitor.sh`) polls every 2 seconds. No compiled dependencies.

```
overmind.tmux  →  starts daemon, sets bindings, integrates status bar
monitor.sh     →  background loop: detect agents, scrape panes, write CSV
status.sh      →  reads CSV, outputs colored ●/◐ for status-right
dashboard.sh   →  reads CSV, runs fzf inside tmux display-popup
quick_jump.sh  →  reads CSV, switches to oldest waiting agent
```

State file: `${TMPDIR}/tmux-overmind-state.csv`
PID file: `${TMPDIR}/tmux-overmind.pid`

CSV format (7 fields):
```
pane_id,session_name,window_name,window_index,state,timestamp,agent_name
```

## Key design decisions

### "Prove you're RUNNING, otherwise you're WAITING"

The default state is **waiting**. An agent is only **running** if we find positive evidence:
1. Braille spinner in `pane_title` (Claude-specific)
2. `window_activity` changed since last poll (terminal producing output)
3. Busy indicators in captured content (spinners, "to interrupt", token counters)
4. Within 6s grace period after any of the above
5. Within 4s startup period for newly-detected panes

This is the opposite of the original spec's approach ("default to running, try to detect waiting") which was fragile and wrong.

### 3-strategy agent detection

`pane_current_command` is unreliable on macOS:
- Claude Code → `2.1.41` (version number, not `claude`)
- Gemini CLI → `node`
- Codex CLI → `node`

Detection order: command name match → pane title keyword → pane content keyword.

### No idle state

Earlier versions had a 3-state model (running/waiting/idle) with viewed-window tracking. This was removed as unnecessary complexity. Two states suffice.

### Status bar color

Uses `#[fg=colourN]` tmux formatting. Resets with `#[nobold,fg=default]` (NOT `#[default]` which nukes the background color and creates a visual hole in the status bar).

### Dashboard uses display-popup, not run-shell

`tmux run-shell` blocks the client — interactive programs like fzf deadlock. `tmux display-popup -E` creates a floating overlay that captures input correctly.

### Single-instance daemon

`monitor.sh` kills any previous instance (by PID file) on startup. `overmind.tmux` also calls `stop_monitor()` before starting. Prevents duplicate daemons writing duplicate CSV rows.

## Development

### Running tests

```bash
bash tests/test_suite.sh
```

### Reloading during development

```bash
tmux run-shell ~/Documents/Dev/tmux/tmux-overmind/overmind.tmux
```

The daemon auto-replaces itself (single-instance enforcement).

### Checking state

```bash
cat ${TMPDIR}/tmux-overmind-state.csv
```

### Killing cleanly

```bash
kill $(cat ${TMPDIR}/tmux-overmind.pid) 2>/dev/null
rm -f ${TMPDIR}/tmux-overmind.pid ${TMPDIR}/tmux-overmind-state.csv
```

## Patterns learned

- `pane_current_command` on macOS resolves symlinks to the binary basename. Claude Code's binary is literally named with the version number.
- `window_activity` is the most reliable generic signal — it updates on any terminal output, regardless of tool.
- `#[default]` in tmux status bar resets background color. Use `#[fg=default]` to only reset foreground.
- `pkill -f` can match the calling process itself. Use PID file + direct `kill` instead.
- `set -euo pipefail` in a daemon is dangerous — any transient tmux error kills the entire monitor.
- `nohup` without `disown` can leave zombies. Always pair them.
