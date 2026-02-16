# tmux-overmind

An overarching monitor for interactive AI CLI agents running inside Tmux panes. Detects their state (Running vs. Waiting vs. Idle), provides a compact status indicator, an fzf-based dashboard, and quick-jump functionality.

## Features

- **Auto-integrating status indicator**: Works with vanilla tmux AND status bar plugins (tmux-powerline, tmux-powerkit, etc.)
- **Ultra-compact display**: Shows ○ (no agents/idle), ● (all busy), or ◐ (needs attention)
- **3-state detection system**:
  - ● **Running**: Agent is actively working (spinners, processing, etc.)
  - ◐ **Waiting**: Agent shows prompt, waiting for input (unseen by user)
  - ○ **Idle**: Agent waiting, but user has already viewed it
- **Smart prompt detection**: Uses Braille spinners, asterisk spinners, ANSI code stripping, and tool-specific patterns
- **Spike filtering**: Prevents flickering by requiring multiple state changes in 1 second
- **Window activity tracking**: Distinguishes between unseen (◐) and seen/idle (○) waiting states
- **FIFO quick-jump**: Press `prefix + J` to instantly jump to the oldest UNSEEN waiting agent
- **fzf dashboard**: Press `prefix + O` to see all running agents and their states
- **Supports**: Claude, OpenCode, Codex, Gemini, Copilot, Crush

## Installation

### Using TPM (Tmux Plugin Manager)

Add to your `~/.tmux.conf` (order matters - place overmind AFTER other plugins):

```bash
# Your other plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'fabioluciano/tmux-powerkit'

# Add tmux-overmind LAST so it can detect and integrate with other plugins
set -g @plugin 'yourusername/tmux-overmind'

run '~/.tmux/plugins/tpm/tpm'
```

Then press `prefix + I` to install.

### Manual Installation

```bash
git clone https://github.com/yourusername/tmux-overmind.git ~/.tmux/plugins/tmux-overmind
```

Add to your `~/.tmux.conf` (place AFTER other status bar plugins):

```bash
run-shell ~/.tmux/plugins/tmux-overmind/overmind.tmux
```

## Configuration

### Status Bar Integration

**By default, tmux-overmind automatically integrates with your existing status bar.** It detects if you have plugins like tmux-powerkit, tmux-powerline, etc., and injects the indicator without breaking your setup.

#### Customization Options

```bash
# Position of the indicator (default: prepend)
set -g @overmind_status_position 'prepend'  # Options: prepend, append, none

# 'prepend' - puts indicator at the start of status-right (default)
# 'append'  - puts indicator at the end of status-right
# 'none'    - disables automatic status integration (manual mode)
```

#### Manual Mode (If You Want Full Control)

If you set `@overmind_status_position` to `none`, you can manually add the indicator:

```bash
# In ~/.tmux.conf
set -g status-right '#(~/.tmux/plugins/tmux-overmind/scripts/status.sh) %H:%M'
```

#### Status Bar Plugin Compatibility

| Plugin | Integration Method |
|--------|-------------------|
| tmux-powerkit | Detects `@powerkit_theme` and appends to `@powerkit_status_right_area` |
| tmux-powerline | Direct status-right modification |
| vanilla tmux | Direct status-right modification |
| Custom setups | Direct status-right modification |

### Key Bindings

| Key | Action |
|-----|--------|
| `prefix + O` | Open fzf dashboard with all agents |
| `prefix + J` | Jump to oldest **unseen** waiting agent (shows ◐) |

## How It Works

The plugin uses a background daemon (`monitor.sh`) that continuously monitors tmux panes:

1. **Pane Detection**: Identifies AI agents by process name (claude, opencode, codex, gemini, copilot, crush)
2. **State Detection**: Every 2 seconds:
   - Captures bottom 5 lines of each agent pane
   - Strips ANSI escape codes for clean matching
   - **Priority 1**: Checks for busy indicators (spinners, progress bars, processing text)
   - **Priority 2**: If not busy, checks for prompt patterns (`>`, `?`, `❯`, `⬝`, confirmations)
3. **Activity Tracking**: Uses `#{window_activity}` to detect if user has viewed waiting agents
4. **Spike Filtering**: Requires 2+ state changes in 1 second to prevent flickering
5. **State Persistence**: Writes to a CSV file that other scripts read

The 3-state system (● running, ◐ waiting, ○ idle) provides accurate representation of agent states while avoiding notification fatigue.

## Requirements

- tmux 3.0a or later
- **fzf** (for the dashboard) - `brew install fzf` or `apt install fzf`
- bash

## State Indicators

| Symbol | Meaning | Details |
|--------|---------|---------|
| `○` | No agents / All idle | Either no agents running, or all waiting agents have been viewed by user |
| `●` | All busy | Agents are actively working (showing spinners, processing, etc.) |
| `◐` | Needs attention | At least one agent is waiting for input AND the user hasn't viewed it yet |

### How It Works

The plugin uses a sophisticated detection algorithm:

1. **Busy Detection** (checked first):
   - Braille spinners: ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
   - Asterisk spinners: ✳✽✶✢
   - "ctrl+c to interrupt" text
   - Processing keywords + ellipsis patterns

2. **Prompt Detection** (if not busy):
   - Standard prompts: `> `, `? `, `❯`, `⬝`
   - Confirmation dialogs: `(Y/n)`, `[y/N]`, "Continue?"
   - Permission dialogs: "Yes, allow once", "No, and tell..."

3. **Idle Detection**:
   - Tracks window activity timestamps
   - If window was viewed after agent started waiting → shows `○`
   - Quick-jump only jumps to UNSEEN waiting agents (`◐`)

4. **Spike Filtering**:
   - Requires 2+ state changes in 1 second to prevent flickering
   - 2-second grace period between state transitions

## Troubleshooting

### Status indicator not showing

1. Make sure tmux-overmind is loaded AFTER other status bar plugins in `.tmux.conf`
2. Check if `@overmind_status_position` is set to `none` (disables auto-integration)
3. Reload tmux configuration: `prefix + r` or `tmux source-file ~/.tmux.conf`

### Duplicate indicators

If you see the indicator twice, you might have both automatic integration enabled AND manually set it in `status-right`. Either:
- Remove your manual status-right setting, OR
- Set `set -g @overmind_status_position 'none'` to disable auto-integration

### Using with tmux-powerkit

If the indicator doesn't appear with tmux-powerkit:
1. Clear powerkit's cache: Press `prefix + C-d` or run:
   ```bash
   tmux run-shell "POWERKIT_ROOT='$HOME/.tmux/plugins/tmux-powerkit' bash -c '. \${POWERKIT_ROOT}/src/core/bootstrap.sh && cache_clear_all && load_powerkit_theme'"
   ```
2. Ensure overmind is loaded BEFORE tmux-powerkit initializes in your `.tmux.conf`

## License

MIT
