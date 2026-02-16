#!/usr/bin/env bash

# tmux-overmind - Overarching monitor for AI CLI agents in tmux
# Entry point: Sets up key bindings and starts the monitor daemon

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# State file location
STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
PID_FILE="${TMPDIR:-/tmp}/tmux-overmind.pid"

# Ensure state file exists
touch "$STATE_FILE"

# Function to start the monitor daemon
start_monitor() {
    # Check if monitor is already running
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            # Monitor is already running
            return 0
        fi
    fi
    
    # Start the monitor daemon in background
    nohup bash "${CURRENT_DIR}/scripts/monitor.sh" >/dev/null 2>&1 &
    echo $! > "$PID_FILE"
}

# Function to integrate with existing status bar setup
integrate_status_bar() {
    local status_script="${CURRENT_DIR}/scripts/status.sh"
    local overmind_indicator="#($status_script)"
    
    # Check user's preferred position (default: prepend to right side)
    local position
    position=$(tmux show-option -gqv "@overmind_status_position")
    position="${position:-prepend}"  # prepend, append, or none
    
    # If user explicitly disabled status integration, skip
    if [[ "$position" == "none" ]]; then
        return 0
    fi
    
    # Get current status-right
    local current_status_right
    current_status_right=$(tmux show-option -gqv "status-right")
    
    # Check if we already integrated (avoid duplicates)
    if [[ "$current_status_right" == *"$status_script"* ]]; then
        return 0
    fi
    
    # Check for known status bar plugins
    local powerkit_theme
    powerkit_theme=$(tmux show-option -gqv "@powerkit_theme")
    
    if [[ -n "$powerkit_theme" ]]; then
        # tmux-powerkit detected - add overmind as an external plugin
        # PowerKit uses @powerkit_plugins to define plugins
        local current_plugins
        current_plugins=$(tmux show-option -gqv "@powerkit_plugins")
        
        # Check if already integrated
        if [[ "$current_plugins" == *"overmind"* ]]; then
            return 0
        fi
        
        # Build external plugin spec for powerkit
        # Format: external("icon"|"content"|"accent"|"accent_icon"|"ttl")
        # Empty icon for compact display - just show the status character
        local overmind_plugin="external(\"\"|\"#($status_script)\"|\"ok-base\"|\"ok-base-lighter\"|\"2\")"
        
        # Add overmind to plugins list
        # If no custom plugins set (or only overmind set), use powerkit defaults
        local powerkit_defaults="datetime,battery,cpu,memory,hostname,git"
        local plugins_list
        if [[ -z "$current_plugins" ]] || [[ "$current_plugins" == "$overmind_plugin" ]]; then
            plugins_list="$powerkit_defaults"
        else
            plugins_list="$current_plugins"
        fi
        
        if [[ "$position" == "prepend" ]]; then
            tmux set-option -g "@powerkit_plugins" "$overmind_plugin, $plugins_list"
        else
            tmux set-option -g "@powerkit_plugins" "$plugins_list, $overmind_plugin"
        fi
        
        # Clear powerkit's render cache so it picks up the change
        if [[ -d "$HOME/.tmux/plugins/tmux-powerkit" ]]; then
            local cache_dir="${TMPDIR:-/tmp}/tmux-powerkit-cache-$(whoami)"
            rm -f "$cache_dir"/rendered_* 2>/dev/null
        fi
        
        # Trigger powerkit refresh if available
        if [[ -f "$HOME/.tmux/plugins/tmux-powerkit/src/helpers/reload_theme.sh" ]]; then
            POWERKIT_ROOT="$HOME/.tmux/plugins/tmux-powerkit" bash "$HOME/.tmux/plugins/tmux-powerkit/src/helpers/reload_theme.sh" 2>/dev/null || true
        fi
    else
        # Vanilla tmux or other plugins - directly modify status-right
        if [[ -z "$current_status_right" ]]; then
            # No existing status-right, set default
            tmux set-option -g "status-right" "$overmind_indicator %H:%M"
        else
            # Append/prepend to existing status-right
            if [[ "$position" == "prepend" ]]; then
                tmux set-option -g "status-right" "$overmind_indicator $current_status_right"
            else
                tmux set-option -g "status-right" "$current_status_right $overmind_indicator"
            fi
        fi
    fi
    
    # Set status interval to update the indicator
    local current_interval
    current_interval=$(tmux show-option -gqv "status-interval")
    if [[ -z "$current_interval" ]] || [[ "$current_interval" -gt 2 ]]; then
        tmux set-option -g "status-interval" 2
    fi
}

# Start the monitor daemon
start_monitor

# Integrate with status bar
integrate_status_bar

# Set up key bindings
# prefix + O: Open dashboard (Overmind)
# prefix + J: Jump to oldest waiting agent
tmux bind-key O run-shell "${CURRENT_DIR}/scripts/dashboard.sh"
tmux bind-key J run-shell "${CURRENT_DIR}/scripts/quick_jump.sh"
