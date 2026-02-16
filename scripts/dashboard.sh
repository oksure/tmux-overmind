#!/usr/bin/env bash

# tmux-overmind dashboard
# Runs INSIDE a tmux display-popup. Uses plain fzf.

STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"

if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf not found. Install with: brew install fzf"
    sleep 2
    exit 1
fi

if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
    echo "No AI agents currently running."
    sleep 1
    exit 0
fi

items=""
count=0

while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name || [[ -n "$pane_id" ]]; do
    [[ -z "$pane_id" ]] && continue

    local_icon=""
    case "$state" in
        running) local_icon="●" ;;
        waiting) local_icon="◐" ;;
        *)       local_icon="●" ;;
    esac

    count=$((count + 1))

    line=$(printf "%d  %s %-10s %s [%s:%s]\t%s:%s" \
        "$count" "$local_icon" "$agent_name" "$state" \
        "$session_name" "$window_name" \
        "$session_name" "$window_index")

    if [[ -z "$items" ]]; then
        items="$line"
    else
        items="${items}
${line}"
    fi
done < "$STATE_FILE"

if [[ $count -eq 0 ]]; then
    echo "No AI agents currently running."
    sleep 1
    exit 0
fi

selected=$(echo "$items" | fzf \
    --prompt="  Overmind > " \
    --reverse \
    --no-info \
    --no-preview \
    --with-nth=1 \
    --delimiter=$'\t' \
    --header="  Enter=switch  Esc=close" \
    --header-first)

if [[ -n "$selected" ]]; then
    target=$(echo "$selected" | cut -f2)
    [[ -n "$target" ]] && tmux switch-client -t "$target"
fi
