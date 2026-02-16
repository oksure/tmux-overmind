#!/usr/bin/env bash

# tmux-overmind status indicator
# Outputs nothing, ●, or ◐ for the tmux status bar.
#
#   (empty) — No agents detected
#   ●       — All agents running, none waiting
#   ◐       — At least 1 agent waiting for input

STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"

if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
    exit 0
fi

has_waiting=false
has_running=false
has_any=false

while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name || [[ -n "$pane_id" ]]; do
    [[ -z "$pane_id" ]] && continue
    has_any=true
    case "$state" in
        waiting) has_waiting=true ;;
        running) has_running=true ;;
    esac
done < "$STATE_FILE"

if ! $has_any; then
    : # nothing
elif $has_waiting; then
    printf '#[fg=colour214,bold]◐#[nobold,fg=default]'
elif $has_running; then
    printf '#[fg=colour76]●#[fg=default]'
fi
