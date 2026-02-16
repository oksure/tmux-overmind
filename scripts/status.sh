#!/usr/bin/env bash

# tmux-overmind status indicator
# Outputs exactly ONE character based on global state
# ○ = No agents running (or all idle/viewed)
# ● = All agents running (busy)
# ◐ = Some agents waiting for input (unseen)

STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"

# Check if state file exists and has content
if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
    echo "○"
    exit 0
fi

# Count agents and their states
total_agents=0
waiting_agents=0    # Unseen waiting
running_agents=0
idle_agents=0       # Seen waiting

while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name viewed_flag || [[ -n "$pane_id" ]]; do
    [[ -z "$pane_id" ]] && continue
    
    total_agents=$((total_agents + 1))
    
    case "$state" in
        "waiting")
            # Only count as waiting if not viewed
            if [[ "$viewed_flag" == "1" ]]; then
                idle_agents=$((idle_agents + 1))
            else
                waiting_agents=$((waiting_agents + 1))
            fi
            ;;
        "running")
            running_agents=$((running_agents + 1))
            ;;
        "idle")
            idle_agents=$((idle_agents + 1))
            ;;
    esac
done < "$STATE_FILE"

# Determine output character
if [[ $total_agents -eq 0 ]]; then
    # No agents running
    echo "○"
elif [[ $waiting_agents -eq 0 && $running_agents -eq 0 ]]; then
    # All idle (seen by user)
    echo "○"
elif [[ $waiting_agents -eq 0 ]]; then
    # At least 1 agent running, none waiting (all busy or idle)
    echo "●"
else
    # At least 1 agent waiting (unseen)
    echo "◐"
fi
