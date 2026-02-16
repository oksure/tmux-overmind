#!/usr/bin/env bash

# tmux-overmind monitor daemon
# Loops every 2 seconds, scrapes tmux panes, detects agent states

STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
TEMP_STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.tmp"
PID_FILE="${TMPDIR:-/tmp}/tmux-overmind.pid"

# Supported AI agent commands (regex pattern)
AGENT_PATTERN='^(claude|opencode|codex|gemini|copilot|crush)$'

# Prompt patterns that indicate "Waiting" state
# Use $'...' syntax for proper UTF-8 hex interpretation
PROMPT_PATTERNS=$'[>?] $|[⬝❯]|⬝⬝|\\(Y/n\\)|\\(y/N\\)|\\[Y/n\\]|\\[y/N\\]|Continue\\?|Yes, allow once|No, and tell'

# Busy indicator patterns (spinners, progress bars, etc.)
BUSY_PATTERNS='⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|✳|✽|✶|✢|ctrl\+c to interrupt|Thinking|Working|Analyzing|Processing|⏎|█|▓|▒|░|Pending|Loading|Waiting for response'

# Tool-specific patterns
CLAUDE_PATTERNS='\(Y/n\)|\(y/N\)|Yes, allow once|No, and tell|interrupt'
OPENCODE_PATTERNS='⬝|esc interrupt|tab agents|ctrl\+p commands'
GEMINI_PATTERNS='Continue\?|thinking|analyzing'

# Function to check if a pane contains an AI agent
is_agent_pane() {
    local pane_id="$1"
    local current_cmd
    current_cmd=$(tmux display-message -p -t "$pane_id" -F "#{pane_current_command}" 2>/dev/null)
    [[ -n "$current_cmd" ]] && [[ "$current_cmd" =~ $AGENT_PATTERN ]]
}

# Function to get agent name from pane
get_agent_name() {
    local pane_id="$1"
    tmux display-message -p -t "$pane_id" -F "#{pane_current_command}" 2>/dev/null
}

# Function to strip ANSI escape codes from text
strip_ansi() {
    local text="$1"
    # Remove ANSI escape sequences
    echo "$text" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/\x1b\[?[0-9;]*[a-zA-Z]//g'
}

# Function to detect if agent is busy (working)
is_pane_busy() {
    local text="$1"
    # Check for busy indicators first
    if echo "$text" | grep -qE "$BUSY_PATTERNS" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Function to detect if agent is waiting for input
is_pane_waiting() {
    local text="$1"
    # Check for prompt patterns
    if echo "$text" | LC_ALL=C grep -qE "$PROMPT_PATTERNS" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Function to detect state by scraping the pane
get_pane_state() {
    local pane_id="$1"
    local pane_height
    local bottom_text
    local clean_text
    
    # Get pane height to calculate bottom area
    pane_height=$(tmux display-message -p -t "$pane_id" -F "#{pane_height}" 2>/dev/null)
    
    # If we can't get pane height, assume running
    [[ -z "$pane_height" ]] && echo "running" && return
    
    # Capture bottom 5 lines where prompts typically appear (for TUIs like opencode)
    # Use negative index to capture from bottom: -5 means last 5 lines
    bottom_text=$(tmux capture-pane -p -t "$pane_id" -S -5 2>/dev/null)
    
    # Also check cursor line as fallback
    local cursor_y cursor_text
    cursor_y=$(tmux display-message -p -t "$pane_id" -F "#{cursor_y}" 2>/dev/null)
    if [[ -n "$cursor_y" ]]; then
        cursor_text=$(tmux capture-pane -p -t "$pane_id" -S "$cursor_y" -E "$cursor_y" 2>/dev/null)
        bottom_text="${bottom_text}${cursor_text}"
    fi
    
    # Strip ANSI codes for cleaner matching
    clean_text=$(strip_ansi "$bottom_text")
    
    # Priority: Busy indicators > Prompt patterns > Running
    if is_pane_busy "$clean_text"; then
        echo "running"
    elif is_pane_waiting "$clean_text"; then
        echo "waiting"
    else
        echo "running"
    fi
}

# Function to read existing timestamp for a pane
get_existing_timestamp() {
    local pane_id="$1"
    local existing_state
    
    existing_state=$(grep "^${pane_id}," "$STATE_FILE" 2>/dev/null)
    if [[ -n "$existing_state" ]]; then
        # Extract timestamp (6th field)
        echo "$existing_state" | cut -d',' -f6
    fi
}

# Function to read existing state for a pane
get_existing_state() {
    local pane_id="$1"
    local existing_state
    
    existing_state=$(grep "^${pane_id}," "$STATE_FILE" 2>/dev/null)
    if [[ -n "$existing_state" ]]; then
        # Extract state (5th field)
        echo "$existing_state" | cut -d',' -f5
    fi
}

# Function to get window activity timestamp (for tracking seen/unseen)
get_window_activity() {
    local pane_id="$1"
    tmux display-message -p -t "$pane_id" -F "#{window_activity}" 2>/dev/null
}

# Function to check if window has been viewed since waiting
is_window_viewed() {
    local pane_id="$1"
    local waiting_timestamp="$2"
    
    # Get window activity time
    local window_activity
    window_activity=$(get_window_activity "$pane_id")
    
    # If no waiting timestamp, not applicable
    [[ -z "$waiting_timestamp" ]] && return 1
    
    # Convert window activity from tmux format (epoch or relative time)
    # tmux returns epoch time for window_activity
    if [[ -n "$window_activity" ]]; then
        # If window was active after we started waiting, user has seen it
        if [[ "$window_activity" -gt "$waiting_timestamp" ]]; then
            return 0
        fi
    fi
    
    return 1
}

# Main monitoring loop
monitor_loop() {
    # Track last states for spike filtering
    declare -A LAST_STATES
    declare -A STATE_CHANGE_TIMES
    local CURRENT_TIME
    
    while true; do
        CURRENT_TIME=$(date +%s)
        
        # Create temp state file
        > "$TEMP_STATE_FILE"
        
        # Get all pane IDs across all sessions
        local all_panes
        all_panes=$(tmux list-panes -a -F "#{pane_id}" 2>/dev/null)
        
        # Process each pane
        while IFS= read -r pane_id; do
            [[ -z "$pane_id" ]] && continue
            
            # Check if this pane has an AI agent
            if is_agent_pane "$pane_id"; then
                # Get pane info
                local session_name window_name window_index pane_index agent_name state timestamp viewed_flag
                
                session_name=$(tmux display-message -p -t "$pane_id" -F "#{session_name}" 2>/dev/null)
                window_name=$(tmux display-message -p -t "$pane_id" -F "#{window_name}" 2>/dev/null)
                window_index=$(tmux display-message -p -t "$pane_id" -F "#{window_index}" 2>/dev/null)
                pane_index=$(tmux display-message -p -t "$pane_id" -F "#{pane_index}" 2>/dev/null)
                agent_name=$(get_agent_name "$pane_id")
                
                # Get raw state from pane scraping
                local raw_state
                raw_state=$(get_pane_state "$pane_id")
                
                # Spike filtering: require 2+ state changes in 1 second to confirm
                if [[ "${LAST_STATES[$pane_id]}" != "$raw_state" ]]; then
                    local last_change_time="${STATE_CHANGE_TIMES[$pane_id]:-0}"
                    if [[ $((CURRENT_TIME - last_change_time)) -lt 1 ]]; then
                        # Rapid change, might be flickering - keep old state
                        raw_state="${LAST_STATES[$pane_id]}"
                    else
                        # Legitimate state change
                        STATE_CHANGE_TIMES[$pane_id]=$CURRENT_TIME
                        LAST_STATES[$pane_id]=$raw_state
                    fi
                fi
                
                # Check if we need to update timestamp (only when transitioning to waiting)
                local existing_state existing_timestamp
                existing_state=$(get_existing_state "$pane_id")
                existing_timestamp=$(get_existing_timestamp "$pane_id")
                
                if [[ "$raw_state" == "waiting" && "$existing_state" != "waiting" ]]; then
                    # Transitioning from running to waiting - record new timestamp
                    timestamp="$CURRENT_TIME"
                    viewed_flag="0"
                elif [[ "$raw_state" == "waiting" && "$existing_state" == "waiting" && -n "$existing_timestamp" ]]; then
                    # Still waiting - keep existing timestamp
                    timestamp="$existing_timestamp"
                    # Check if window has been viewed
                    if is_window_viewed "$pane_id" "$timestamp"; then
                        viewed_flag="1"
                    else
                        viewed_flag="0"
                    fi
                else
                    # Running or other state - no timestamp needed
                    timestamp=""
                    viewed_flag=""
                fi
                
                # Determine final state: running/waiting/idle
                if [[ "$raw_state" == "waiting" && "$viewed_flag" == "1" ]]; then
                    state="idle"
                else
                    state="$raw_state"
                fi
                
                # Write to temp state file: pane_id,session,window,window_index,state,timestamp,agent_name,viewed
                echo "${pane_id},${session_name},${window_name},${window_index},${state},${timestamp},${agent_name},${viewed_flag}" >> "$TEMP_STATE_FILE"
            fi
        done <<< "$all_panes"
        
        # Atomically replace state file
        mv "$TEMP_STATE_FILE" "$STATE_FILE"
        
        # Sleep for 2 seconds
        sleep 2
    done
}

# Cleanup function for signal handling
cleanup() {
    rm -f "$TEMP_STATE_FILE"
    rm -f "$PID_FILE"
    exit 0
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT

# Write PID to file
echo $$ > "$PID_FILE"

# Ensure state file exists
touch "$STATE_FILE"

# Start monitoring
monitor_loop
