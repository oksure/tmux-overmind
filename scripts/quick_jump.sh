#!/usr/bin/env bash

# tmux-overmind smart jump (prefix+Z)
#
# Behaviour depends on how many agents are waiting:
#   0 waiting  →  brief status message (nothing to do)
#   1 waiting  →  jump directly (no menu, instant)
#   2+ waiting →  open the dashboard sorted with waiting agents on top

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"

if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
    tmux display-message "Overmind: no agents tracked yet"
    exit 0
fi

# Collect all waiting agents, sorted oldest-first
waiting_targets=()
waiting_agents=()

# Read into temp arrays first so we can sort
raw_waiting=()
while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name || [[ -n "$pane_id" ]]; do
    [[ -z "$pane_id" ]] && continue
    [[ "$state" != "waiting" ]] && continue
    [[ -z "$timestamp" ]] && timestamp=0
    raw_waiting+=("${timestamp}|${session_name}:${window_index}|${agent_name}")
done < "$STATE_FILE"

# Sort by timestamp (oldest first = smallest epoch)
IFS=$'\n' sorted_waiting=($(printf '%s\n' "${raw_waiting[@]}" | sort -t'|' -k1,1n))
unset IFS

for entry in "${sorted_waiting[@]}"; do
    IFS='|' read -r ts target agent <<< "$entry"
    waiting_targets+=("$target")
    waiting_agents+=("$agent")
done

count=${#waiting_targets[@]}

if [[ $count -eq 0 ]]; then
    # Nothing waiting — show running count if any
    running_count=$(grep -c ',running,' "$STATE_FILE" 2>/dev/null || echo 0)
    if [[ "$running_count" -gt 0 ]]; then
        tmux display-message "Overmind: ${running_count} agent(s) running, none waiting"
    else
        tmux display-message "Overmind: no agents waiting"
    fi
elif [[ $count -eq 1 ]]; then
    # Single waiting agent — jump instantly, no menu
    tmux switch-client -t "${waiting_targets[0]}"
else
    # Multiple waiting agents — open dashboard for selection
    # Pass env var so dashboard knows to sort waiting first (it already does)
    tmux display-popup -E -w 60% -h 40% -T " Overmind — ${count} waiting " \
        "${SCRIPT_DIR}/dashboard.sh"
fi
