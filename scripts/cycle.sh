#!/usr/bin/env bash

# tmux-overmind cycle
# Cycle through all agent windows sorted by pane_id (creation order).
# If current pane is an agent, jump to the next one (wrapping).
# If not, jump to the first agent.

STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"

if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
    exit 0
fi

# Collect pane_ids and targets, sorted by pane_id numerically
pane_ids=()
targets=()

while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name || [[ -n "$pane_id" ]]; do
    [[ -z "$pane_id" ]] && continue
    # Strip % prefix for numeric sorting
    pane_ids+=("${pane_id#%}")
    targets+=("${session_name}:${window_index}")
done < "$STATE_FILE"

[[ ${#pane_ids[@]} -eq 0 ]] && exit 0

# Sort by pane_id numerically (parallel arrays → index sort)
sorted_indices=()
for i in "${!pane_ids[@]}"; do
    sorted_indices+=("$i")
done
IFS=$'\n' sorted_indices=($(for i in "${sorted_indices[@]}"; do echo "${pane_ids[$i]} $i"; done | sort -n | awk '{print $2}'))
unset IFS

# Find current pane_id
current_pane=$(tmux display-message -p '#{pane_id}')
current_num="${current_pane#%}"

# Find current position in sorted list
current_pos=-1
for idx in "${!sorted_indices[@]}"; do
    si="${sorted_indices[$idx]}"
    if [[ "${pane_ids[$si]}" == "$current_num" ]]; then
        current_pos=$idx
        break
    fi
done

# Pick target: next agent (wrapping) or first agent
if [[ $current_pos -ge 0 ]]; then
    next_pos=$(( (current_pos + 1) % ${#sorted_indices[@]} ))
else
    next_pos=0
fi

target_idx="${sorted_indices[$next_pos]}"
tmux switch-client -t "${targets[$target_idx]}"
