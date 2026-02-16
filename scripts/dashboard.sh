#!/usr/bin/env bash

# tmux-overmind dashboard
# Opens an fzf interface in a tmux popup to view and switch to AI agent panes

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"

# Check if fzf is available
if ! command -v fzf >/dev/null 2>&1; then
    tmux display-message "Error: fzf is not installed. Install with: brew install fzf"
    exit 1
fi

# Check if state file exists
if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
    tmux display-message "No AI agents currently running"
    exit 0
fi

# Build the list of agents for fzf
# Format: [Session:Window] agent_name - ● Running
build_agent_list() {
    while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name viewed_flag || [[ -n "$pane_id" ]]; do
        [[ -z "$pane_id" ]] && continue

        local status_icon status_text
        case "$state" in
            "waiting")
                if [[ "$viewed_flag" == "1" ]]; then
                    status_icon="○"
                    status_text="Idle (viewed)"
                else
                    status_icon="◐"
                    status_text="Waiting"
                fi
                ;;
            "running")
                status_icon="●"
                status_text="Running"
                ;;
            "idle")
                status_icon="○"
                status_text="Idle"
                ;;
            *)
                status_icon="●"
                status_text="Running"
                ;;
        esac

        # Output format for display
        # Store pane_id at the end for selection handling
        printf "[%s:%s] %s - %s %s\t%s:%s\n" "$session_name" "$window_name" "$agent_name" "$status_icon" "$status_text" "$session_name" "$window_index"
    done < "$STATE_FILE"
}

# Create a temporary file for the list
TEMP_LIST=$(mktemp)
build_agent_list > "$TEMP_LIST"

# Check if we have any agents
if [[ ! -s "$TEMP_LIST" ]]; then
    rm -f "$TEMP_LIST"
    tmux display-message "No AI agents currently running"
    exit 0
fi

# Create result file for fzf selection
RESULT_FILE=$(mktemp)

# Build fzf command
FZF_CMD="cat '$TEMP_LIST' | fzf --prompt='AI Agents > ' --ansi --no-preview --reverse --height=100% > '$RESULT_FILE'"

# Use tmux popup (tmux 3.2+) or split-window for older versions
if tmux display-message -p "#{client_popup}" >/dev/null 2>&1 || tmux popup -E true 2>/dev/null; then
    # Popup is available (tmux 3.2+)
    tmux popup -w 80% -h 50% -E "$FZF_CMD"
else
    # Fall back to split-window for tmux 3.0a
    tmux split-window -v -l 50% -c "#{pane_current_path}" "$FZF_CMD"
fi

# Read the result
if [[ -s "$RESULT_FILE" ]]; then
    selected=$(cat "$RESULT_FILE")
    # Extract session:window from the selection (after the tab character)
    target=$(echo "$selected" | cut -f2)

    if [[ -n "$target" ]]; then
        # Switch to the selected session and window
        tmux switch-client -t "$target"
    fi
fi

# Clean up temp files
rm -f "$TEMP_LIST" "$RESULT_FILE"
