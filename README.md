# tmux-overmind

**One character in your status bar tells you which AI agents need attention.**

If you run multiple AI coding agents (Claude Code, Gemini CLI, OpenCode, Codex, Copilot, Crush) across tmux sessions, you know the pain: constantly switching windows to check which agent finished and is waiting for input. tmux-overmind watches all of them and tells you at a glance.

```
                     ◐            ← an agent needs you
```

## What it does

A background daemon scrapes every AI agent pane across all your tmux sessions every second. It detects whether each agent is actively working or waiting for your input, then surfaces that as:

- **Status bar indicator** — `●` (green, all busy) or `◐` (yellow, needs attention). Hidden when no agents are running.
- **Floating dashboard** (`prefix + A`) — numbered list of all agents and their state. Type to filter, Enter to switch, Esc to close.
- **Quick-jump** (`prefix + Z`) — instantly switches to the agent that's been waiting the longest (FIFO).
- **Cycle-through** (`prefix + N`) — cycle through all agents in a tmux window across all sessions.

### Status bar

| Indicator | Color | Meaning |
|:---------:|-------|---------|
| *(nothing)* | — | No agents detected anywhere |
| `●` | green | All agents are busy working |
| `◐` | **yellow, bold** | **At least one agent is waiting for input** |

## Prerequisites

- **tmux 3.2+** — required for `display-popup` (the floating dashboard). Check with `tmux -V`.
- **[fzf](https://github.com/junegunn/fzf)** — the dashboard uses fzf for fuzzy selection. Install with `brew install fzf` or `apt install fzf`.
- **bash 4+** — the daemon uses associative arrays. macOS ships bash 3 but Homebrew's bash works (`brew install bash`).

## Installation

### With TPM (Tmux Plugin Manager)

Add to your `~/.tmux.conf`:

```bash
# Other plugins...
set -g @plugin 'tmux-plugins/tpm'

# Add tmux-overmind
set -g @plugin 'oksure/tmux-overmind'

# Keep this line at the very bottom of tmux.conf
run '~/.tmux/plugins/tpm/tpm'
```

Then reload tmux and press `prefix + I` to install.

### Manual

```bash
git clone https://github.com/oksure/tmux-overmind.git ~/.tmux/plugins/tmux-overmind
```

Add to your `~/.tmux.conf`:

```bash
run-shell ~/.tmux/plugins/tmux-overmind/overmind.tmux
```

Then reload:

```bash
tmux source-file ~/.tmux.conf
```

## Supported tools

| Tool | Detection method |
|------|-----------------|
| [Claude Code](https://github.com/anthropics/claude-code) | Pane title + braille spinner in title |
| [OpenCode](https://github.com/opencode-ai/opencode) | Process name |
| [Gemini CLI](https://github.com/google-gemini/gemini-cli) | Pane content (runs as `node`) |
| [Codex CLI](https://github.com/openai/codex) | Pane title (runs as `node`) |
| [GitHub Copilot CLI](https://githubnext.com/projects/copilot-cli) | Process name |
| [Crush](https://github.com/crush-ai/crush) | Process name |

Not all tools show up as their name in `pane_current_command`. Claude Code resolves to a version number on macOS, Gemini and Codex run as `node`. Overmind uses a 3-strategy detection: process name, then pane title, then pane content.

## Key bindings

| Key | Action |
|-----|--------|
| `prefix + A` | Open floating dashboard |
| `prefix + Z` | Jump to oldest waiting agent |
| `prefix + N` | Cycle through agentic coding windows |

## Configuration

```bash
# Where to place the indicator in status-right (default: prepend)
set -g @overmind_status_position 'prepend'   # prepend | append | none
```

Set to `none` to disable auto-integration and place it yourself:

```bash
set -g @overmind_status_position 'none'
set -g status-right '#(~/.tmux/plugins/tmux-overmind/scripts/status.sh) %H:%M'
```

### tmux-powerkit

If [tmux-powerkit](https://github.com/oksure/tmux-powerkit) is detected (via `@powerkit_theme`), overmind auto-registers as an external plugin. No extra config needed.

## How detection works

**Core principle: prove you're RUNNING, otherwise you're WAITING.**

Process-level monitoring (`ps`, `lsof`) doesn't work — TUI agents hold the tty in `S+` state even while fetching API responses. The only reliable approach is screen scraping + activity tracking.

An agent is **running** only if we find positive evidence:

1. **Braille spinner in pane title** — Claude Code puts braille chars (U+2800-U+28FF) in the pane title while actively working. Fastest signal.

2. **`window_activity` changed** — tmux updates this timestamp when a pane produces terminal output. If the timestamp changed since last poll (1s ago), the agent is producing output.

3. **Busy indicators in content** — braille spinners, `"ctrl+c to interrupt"`, asterisk spinners with ellipsis (`✳ pondering…`), token counters.

4. **Grace period** — 3 seconds after the last busy signal. Covers the brief gap between tool calls where no spinner is visible.

5. **Startup period** — 4 seconds after first detecting a new agent pane (avoids false "waiting" during initialization).

If none of the above are true, the agent is **waiting**.

### Multi-session

Overmind monitors **all tmux sessions**, not just the one where it was loaded. `tmux list-panes -a` covers every pane across every session. The dashboard and quick-jump also work cross-session via `tmux switch-client`.

## File structure

```
tmux-overmind/
├── overmind.tmux          # Entry point: daemon, bindings, status bar
├── scripts/
│   ├── monitor.sh         # Background daemon (1s loop, screen scraping)
│   ├── status.sh          # ●/◐ for status bar (hidden when no agents)
│   ├── dashboard.sh       # Floating popup with fzf
│   └── quick_jump.sh      # FIFO jump to oldest waiting agent
└── tests/
    └── test_suite.sh      # Unit tests
```

## Uninstall

```bash
# Kill daemon and clean up
kill $(cat ${TMPDIR}/tmux-overmind.pid) 2>/dev/null
rm -f ${TMPDIR}/tmux-overmind.pid ${TMPDIR}/tmux-overmind-state.csv
tmux unbind-key O; tmux unbind-key J
```

Then remove the plugin line from `~/.tmux.conf`.

## License

MIT
