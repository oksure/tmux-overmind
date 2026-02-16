#!/usr/bin/env bash

# tmux-overmind dashboard
# Runs INSIDE a tmux display-popup. Uses plain fzf.
# Sorted by pane_id (creation order). Highlights current agent.

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

# Read entries into parallel arrays
pane_ids=()
entries=()

while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name || [[ -n "$pane_id" ]]; do
    [[ -z "$pane_id" ]] && continue
    pane_ids+=("${pane_id#%}")
    entries+=("${pane_id},${session_name},${window_name},${window_index},${state},${timestamp},${agent_name}")
done < "$STATE_FILE"

if [[ ${#pane_ids[@]} -eq 0 ]]; then
    echo "No AI agents currently running."
    sleep 1
    exit 0
fi

# Sort by pane_id numerically
sorted_indices=()
for i in "${!pane_ids[@]}"; do
    sorted_indices+=("$i")
done
IFS=$'\n' sorted_indices=($(for i in "${sorted_indices[@]}"; do echo "${pane_ids[$i]} $i"; done | sort -n | awk '{print $2}'))
unset IFS

# Get current pane_id to highlight
current_pane=$(tmux display-message -p '#{pane_id}')
current_num="${current_pane#%}"

# Build display lines
items=""
highlight_pos=0
count=0

for idx in "${sorted_indices[@]}"; do
    IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name <<< "${entries[$idx]}"
    count=$((count + 1))

    local_icon=""
    case "$state" in
        running) local_icon="●" ;;
        waiting) local_icon="◐" ;;
        *)       local_icon="●" ;;
    esac

    # Check if this is the current pane
    if [[ "${pane_ids[$idx]}" == "$current_num" ]]; then
        highlight_pos=$count
    fi

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
done

# Build fzf args
fzf_args=(
    --prompt="  Overmind > "
    --reverse
    --no-info
    --no-preview
    --with-nth=1
    --delimiter=$'\t'
    --header="  Enter=switch  Esc=close"
    --header-first
)

# Pre-select current agent's position if found
if [[ $highlight_pos -gt 0 ]]; then
    fzf_args+=(--bind "start:pos($highlight_pos)")
fi

selected=$(echo "$items" | fzf "${fzf_args[@]}")

if [[ -n "$selected" ]]; then
    target=$(echo "$selected" | cut -f2)
    [[ -n "$target" ]] && tmux switch-client -t "$target"
fi
