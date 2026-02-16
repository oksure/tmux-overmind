#!/usr/bin/env bash

# tmux-overmind quick jump
# Jumps to the oldest waiting agent (FIFO).

STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"

if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
    exit 0
fi

oldest_timestamp=""
oldest_target=""

while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name || [[ -n "$pane_id" ]]; do
    [[ -z "$pane_id" ]] && continue

    if [[ "$state" == "waiting" ]] && [[ -n "$timestamp" ]]; then
        if [[ -z "$oldest_timestamp" ]] || [[ "$timestamp" -lt "$oldest_timestamp" ]]; then
            oldest_timestamp="$timestamp"
            oldest_target="${session_name}:${window_index}"
        fi
    fi
done < "$STATE_FILE"

if [[ -n "$oldest_target" ]]; then
    tmux switch-client -t "$oldest_target"
fi
