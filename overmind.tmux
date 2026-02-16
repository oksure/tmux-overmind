#!/usr/bin/env bash

# tmux-overmind — AI agent monitor for tmux
# Entry point: starts monitor daemon, sets key bindings, integrates status bar.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
PID_FILE="${TMPDIR:-/tmp}/tmux-overmind.pid"

# ─── Monitor daemon lifecycle ────────────────────────────────────────────────

stop_monitor() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 0.3
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
}

start_monitor() {
    stop_monitor

    # Launch daemon in background, detached from this shell
    nohup bash "${CURRENT_DIR}/scripts/monitor.sh" >/dev/null 2>&1 &
    disown
}

# ─── Status bar integration ──────────────────────────────────────────────────

integrate_status_bar() {
    local status_script="${CURRENT_DIR}/scripts/status.sh"
    local overmind_indicator="#(${status_script})"

    # User preference: prepend (default), append, or none
    local position
    position=$(tmux show-option -gqv "@overmind_status_position" 2>/dev/null)
    position="${position:-prepend}"

    [[ "$position" == "none" ]] && return 0

    # Already integrated? (avoid duplicates on source-file / reload)
    local current_status_right
    current_status_right=$(tmux show-option -gqv "status-right" 2>/dev/null)
    if [[ "$current_status_right" == *"status.sh"* && "$current_status_right" == *"overmind"* ]]; then
        return 0
    fi

    # ── Check for tmux-powerkit ──
    local powerkit_theme
    powerkit_theme=$(tmux show-option -gqv "@powerkit_theme" 2>/dev/null)

    if [[ -n "$powerkit_theme" ]]; then
        # PowerKit detected — add overmind as an external plugin
        local current_plugins
        current_plugins=$(tmux show-option -gqv "@powerkit_plugins" 2>/dev/null)

        # Already integrated?
        [[ "$current_plugins" == *"overmind"* || "$current_plugins" == *"$status_script"* ]] && return 0

        # Build external plugin spec
        # Format: external("icon"|"content"|"accent"|"accent_icon"|"ttl")
        local overmind_ext="external(\"\"|\"#(${status_script})\"|\"ok-base\"|\"ok-base-lighter\"|\"2\")"

        # If user hasn't customized plugins, seed with powerkit defaults
        if [[ -z "$current_plugins" ]]; then
            current_plugins="datetime,battery,cpu,memory,hostname,git"
        fi

        if [[ "$position" == "prepend" ]]; then
            tmux set-option -g "@powerkit_plugins" "${overmind_ext}, ${current_plugins}"
        else
            tmux set-option -g "@powerkit_plugins" "${current_plugins}, ${overmind_ext}"
        fi

        # Bust powerkit render cache so it picks up the new plugin
        local cache_dir="${TMPDIR:-/tmp}/tmux-powerkit-cache-$(whoami)"
        rm -f "$cache_dir"/rendered_* 2>/dev/null || true

        return 0
    fi

    # ── Vanilla tmux / other plugins — modify status-right directly ──
    if [[ -z "$current_status_right" ]]; then
        tmux set-option -g "status-right" "${overmind_indicator} %H:%M"
    elif [[ "$position" == "prepend" ]]; then
        tmux set-option -g "status-right" "${overmind_indicator} ${current_status_right}"
    else
        tmux set-option -g "status-right" "${current_status_right} ${overmind_indicator}"
    fi

    # Ensure status bar refreshes often enough (2s)
    local interval
    interval=$(tmux show-option -gqv "status-interval" 2>/dev/null)
    if [[ -z "$interval" ]] || [[ "$interval" -gt 2 ]]; then
        tmux set-option -g "status-interval" 2
    fi
}

# ─── Initialize ──────────────────────────────────────────────────────────────

# Ensure scripts are executable
chmod +x "${CURRENT_DIR}/scripts/"*.sh 2>/dev/null || true

# Start monitor daemon
start_monitor

# Integrate status indicator
integrate_status_bar

# Key bindings
# prefix + O : Dashboard — floating popup with fzf (doesn't resize panes)
# prefix + J : Jump to oldest waiting agent (non-interactive, run-shell is fine)
tmux bind-key O display-popup -E -w 60% -h 40% -T " Overmind " "${CURRENT_DIR}/scripts/dashboard.sh"
tmux bind-key J run-shell "${CURRENT_DIR}/scripts/quick_jump.sh"
