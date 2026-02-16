#!/usr/bin/env bash

# tmux-overmind quick jump
# Jumps to the oldest UNSEEN agent waiting for user input (FIFO)
# Only jumps to agents the user hasn't viewed yet
# Triggered by prefix + J

STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"

# Check if state file exists
if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
    # No agents running, do nothing
    exit 0
fi

# Find unseen waiting agents and sort by timestamp (oldest first)
# CSV format: pane_id,session,window,window_index,state,timestamp,agent_name,viewed
oldest_waiting=""
oldest_timestamp=""
oldest_target=""

while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name viewed_flag || [[ -n "$pane_id" ]]; do
    [[ -z "$pane_id" ]] && continue
    
    # Only consider agents in waiting state that haven't been viewed yet
    if [[ "$state" == "waiting" ]] && [[ "$viewed_flag" != "1" ]] && [[ -n "$timestamp" ]]; then
        # Check if this is the oldest (smallest timestamp)
        if [[ -z "$oldest_timestamp" ]] || [[ "$timestamp" -lt "$oldest_timestamp" ]]; then
            oldest_timestamp="$timestamp"
            oldest_target="${session_name}:${window_index}"
        fi
    fi
done < "$STATE_FILE"

# If we found an unseen waiting agent, jump to it
if [[ -n "$oldest_target" ]]; then
    tmux switch-client -t "$oldest_target"
else
    # No unseen agents waiting, do nothing silently
    :
fi
