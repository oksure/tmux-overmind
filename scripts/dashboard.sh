#!/usr/bin/env bash

# tmux-overmind dashboard
# Runs INSIDE a tmux display-popup. Uses plain fzf.
#
# Sort order: waiting agents first (oldest wait at top), then running (by pane_id).
# Waiting agents show how long they've been waiting.

STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"

if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf not found. Install with: brew install fzf"
    sleep 2
    exit 1
fi

if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
    echo "No AI agents currently tracked."
    sleep 1
    exit 0
fi

NOW=$(date +%s)

# ── Collect entries into two buckets ──────────────────────────────────────────
# Each entry: "sort_key|display_text\tswitch_target"
waiting_rows=()
running_rows=()

while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name || [[ -n "$pane_id" ]]; do
    [[ -z "$pane_id" ]] && continue

    switch_target="${session_name}:${window_index}"
    pane_num="${pane_id#%}"

    case "$state" in
      waiting)
        ts="${timestamp:-$NOW}"
        age=$(( NOW - ts ))
        # Format age: <60s → "42s", <3600 → "5m12s", else "1h23m"
        if   [[ $age -lt 60 ]];   then age_str="${age}s"
        elif [[ $age -lt 3600 ]]; then age_str="$(( age/60 ))m$(( age%60 ))s"
        else                           age_str="$(( age/3600 ))h$(( (age%3600)/60 ))m"
        fi
        display=$(printf "◐  %-12s  waiting %-8s  [%s:%s]" \
            "$agent_name" "$age_str" "$session_name" "$window_name")
        # Sort key: timestamp (smaller = older = higher priority)
        waiting_rows+=("${ts}|${display}"$'\t'"${switch_target}")
        ;;
      running)
        display=$(printf "●  %-12s  running           [%s:%s]" \
            "$agent_name" "$session_name" "$window_name")
        # Sort key: pane number (creation order)
        running_rows+=("${pane_num}|${display}"$'\t'"${switch_target}")
        ;;
    esac
done < "$STATE_FILE"

if [[ ${#waiting_rows[@]} -eq 0 && ${#running_rows[@]} -eq 0 ]]; then
    echo "No AI agents currently tracked."
    sleep 1
    exit 0
fi

# ── Sort each bucket ──────────────────────────────────────────────────────────
IFS=$'\n'
sorted_waiting=($(printf '%s\n' "${waiting_rows[@]}" | sort -t'|' -k1,1n))
sorted_running=($(printf '%s\n' "${running_rows[@]}" | sort -t'|' -k1,1n))
unset IFS

# ── Build final item list (strip the sort key prefix) ────────────────────────
items=""
count=0
highlight_pos=0

current_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "")
current_switch="${current_pane}"  # we'll match on switch_target heuristic below

append_row() {
    local raw="$1"
    # raw format: "sortkey|display_text\tswitch_target"
    # strip sortkey prefix (up to first |)
    local without_key="${raw#*|}"
    # without_key = "display_text\tswitch_target"
    local display switch_target
    display=$(echo "$without_key" | cut -f1)
    switch_target=$(echo "$without_key" | cut -f2)

    count=$(( count + 1 ))
    local line
    line=$(printf "%2d  %s\t%s" "$count" "$display" "$switch_target")
    if [[ -z "$items" ]]; then
        items="$line"
    else
        items="${items}"$'\n'"$line"
    fi
}

# Waiting section header (only if there are waiting agents)
if [[ ${#sorted_waiting[@]} -gt 0 ]]; then
    for row in "${sorted_waiting[@]}"; do
        append_row "$row"
    done
fi

for row in "${sorted_running[@]}"; do
    append_row "$row"
done

# ── fzf ───────────────────────────────────────────────────────────────────────
waiting_count=${#sorted_waiting[@]}
running_count=${#sorted_running[@]}
header_text="  ${waiting_count} waiting  ${running_count} running   Enter=switch  Esc=close"

fzf_args=(
    --prompt="  ❯ "
    --reverse
    --no-info
    --no-preview
    --with-nth=1
    --delimiter=$'\t'
    --header="$header_text"
    --header-first
    --color="hl:214,hl+:214"   # highlight waiting colour (orange)
)

selected=$(echo "$items" | fzf "${fzf_args[@]}")

if [[ -n "$selected" ]]; then
    target=$(echo "$selected" | cut -f3)
    [[ -n "$target" ]] && tmux switch-client -t "$target"
fi
