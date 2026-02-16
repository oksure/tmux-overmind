#!/usr/bin/env bash

# tmux-overmind monitor daemon
# Loops every 2 seconds, scrapes tmux panes, detects AI agent states.
#
# State model:
#   running  — agent is actively working
#   waiting  — agent is waiting for input
#
# Core principle: "Prove you're RUNNING, otherwise you're WAITING."
#
# An agent is RUNNING only if we find positive evidence:
#   1. Braille spinner in pane_title             (Claude sets this while working)
#   2. window_activity changed since last poll    (terminal is producing output)
#   3. Busy indicators in pane content            (spinners, "to interrupt", etc.)
#   4. Within 6s grace period after any of above  (covers tool-call transitions)
#
# If none of those are true, the agent is WAITING.
# This eliminates false "running" states for tools we don't have patterns for.

STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
TEMP_STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.tmp"
PID_FILE="${TMPDIR:-/tmp}/tmux-overmind.pid"

# ─── Agent detection ─────────────────────────────────────────────────────────
# 3-strategy: command name → pane title → pane content
#
# Real macOS pane metadata:
#   claude  → cmd='2.1.41'   title='⠐ Claude Code'
#   crush   → cmd='crush'    title='crush ~/path'
#   opencode→ cmd='opencode'  title='OpenCode'
#   gemini  → cmd='node'      title='◇  Ready (tmux)'
#   copilot → cmd='copilot'   title='GitHub Copilot'
#   codex   → cmd='node'      title='codex'

AGENT_CMD_PATTERN='^(claude|opencode|codex|gemini|copilot|crush)$'

detect_agent() {
    local cmd="$1" title="$2" content="$3"

    # Strategy 1: direct command match
    if [[ "$cmd" =~ $AGENT_CMD_PATTERN ]]; then
        echo "$cmd"; return 0
    fi

    # Strategy 2: title keywords
    local tl
    tl=$(echo "$title" | tr '[:upper:]' '[:lower:]')
    if [[ "$tl" == *"claude code"* ]] || [[ "$tl" == *"claude"* ]]; then echo "claude"; return 0; fi
    if [[ "$tl" == *"opencode"* ]] || [[ "$tl" == *"open code"* ]]; then echo "opencode"; return 0; fi
    if [[ "$tl" == *"codex"* ]]; then echo "codex"; return 0; fi
    if [[ "$tl" == *"gemini"* ]]; then echo "gemini"; return 0; fi
    if [[ "$tl" == *"copilot"* ]]; then echo "copilot"; return 0; fi
    if [[ "$tl" == *"crush"* ]]; then echo "crush"; return 0; fi

    # Strategy 3: content keywords (for cmd=node with generic title)
    if [[ "$cmd" == "node" || "$cmd" == "python" || "$cmd" == "python3" || \
          "$cmd" == "deno" || "$cmd" == "bun" ]] && [[ -n "$content" ]]; then
        if echo "$content" | grep -qiF 'gemini'; then echo "gemini"; return 0; fi
        if echo "$content" | grep -qF 'codex>'; then echo "codex"; return 0; fi
        if echo "$content" | grep -qF 'How can I help'; then echo "codex"; return 0; fi
        if echo "$content" | grep -qiF 'anthropic'; then echo "claude"; return 0; fi
    fi

    return 1
}

# ─── ANSI stripping ──────────────────────────────────────────────────────────

strip_ansi() {
    sed \
        -e $'s/\x1b\[\?[0-9;]*[a-zA-Z]//g' \
        -e $'s/\x1b\[[0-9;]*[a-zA-Z]//g' \
        -e $'s/\x1b\][^\x07]*\x07//g' \
        -e $'s/\x1b\][^\x1b]*\x1b\\\\//g' \
        -e $'s/\x1b(B//g' \
        -e $'s/\x1b[()][0-9A-B]//g' \
        -e $'s/\x0f//g' \
        -e $'s/\x0e//g'
}

# ─── Title analysis (from agent-deck) ────────────────────────────────────────

title_has_braille_spinner() {
    local title="$1"
    case "$title" in
        *⠋*|*⠙*|*⠹*|*⠸*|*⠼*|*⠴*|*⠦*|*⠧*|*⠇*|*⠏*) return 0 ;;
        *⠐*|*⠂*|*⠈*|*⠁*|*⠑*|*⠃*|*⠊*|*⠘*|*⠰*|*⠤*) return 0 ;;
        *⠆*|*⠒*|*⠖*|*⠚*|*⠲*|*⠶*|*⠾*|*⠿*) return 0 ;;
        *⡀*|*⣀*|*⣄*|*⣤*|*⣦*|*⣶*|*⣷*|*⣿*) return 0 ;;
    esac
    return 1
}

# ─── Content busy indicators ─────────────────────────────────────────────────
# These are POSITIVE EVIDENCE of active work. If we find any → RUNNING.

is_pane_busy() {
    local text="$1"

    # Braille spinners in content
    if echo "$text" | grep -qF '⠋' || echo "$text" | grep -qF '⠙' || \
       echo "$text" | grep -qF '⠹' || echo "$text" | grep -qF '⠸' || \
       echo "$text" | grep -qF '⠼' || echo "$text" | grep -qF '⠴' || \
       echo "$text" | grep -qF '⠦' || echo "$text" | grep -qF '⠧' || \
       echo "$text" | grep -qF '⠇' || echo "$text" | grep -qF '⠏'; then
        return 0
    fi

    # Asterisk spinner + ellipsis (Claude 2.1.25+)
    if echo "$text" | grep -qE '[✳✽✶✢].*…'; then return 0; fi

    # "ctrl+c/esc to interrupt"
    if echo "$text" | grep -qi 'to interrupt'; then return 0; fi

    # Token counter with ellipsis (streaming/thinking)
    if echo "$text" | grep -qE '….*tokens'; then return 0; fi

    # OpenCode busy
    if echo "$text" | grep -qF 'esc interrupt'; then return 0; fi

    # Gemini busy
    if echo "$text" | grep -qi 'esc to cancel'; then return 0; fi

    return 1
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

get_last_nonempty_line() {
    echo "$1" | sed '/^[[:space:]]*$/d' | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# ─── Main monitoring loop ────────────────────────────────────────────────────

monitor_loop() {
    declare -A LAST_BUSY_TIME     # pane_id → epoch when last positively "running"
    declare -A LAST_ACTIVITY      # pane_id → previous window_activity timestamp
    declare -A FIRST_SEEN         # pane_id → epoch when pane was first detected
    local GRACE_PERIOD=3          # seconds to stay "running" after last busy signal
    local STARTUP_PERIOD=3        # seconds to assume "running" for newly-detected panes

    while true; do
        tmux list-sessions >/dev/null 2>&1 || { sleep 5; continue; }

        local CURRENT_TIME
        CURRENT_TIME=$(date +%s)

        : > "$TEMP_STATE_FILE"

        local pane_data
        pane_data=$(tmux list-panes -a -F "#{pane_id}|#{pane_current_command}|#{session_name}|#{window_name}|#{window_index}|#{pane_index}|#{cursor_y}|#{pane_title}|#{window_activity}" 2>/dev/null) || true

        while IFS='|' read -r pane_id pane_cmd session_name window_name window_index pane_index cursor_y pane_title win_activity; do
            [[ -z "$pane_id" ]] && continue

            # Screen scrape
            local captured=""
            captured=$(tmux capture-pane -p -t "$pane_id" -S -15 2>/dev/null) || true
            if [[ -n "$cursor_y" ]]; then
                local cursor_line
                cursor_line=$(tmux capture-pane -p -t "$pane_id" -S "$cursor_y" -E "$cursor_y" 2>/dev/null) || true
                captured="${captured}
${cursor_line}"
            fi
            local clean_text
            clean_text=$(echo "$captured" | strip_ansi)

            # Agent detection
            local agent_name
            agent_name=$(detect_agent "$pane_cmd" "$pane_title" "$clean_text") || continue

            # ── Track first-seen time (new panes get a startup grace period) ──
            if [[ -z "${FIRST_SEEN[$pane_id]:-}" ]]; then
                FIRST_SEEN["$pane_id"]=$CURRENT_TIME
            fi

            # ── Determine: is this pane PROVABLY running? ──
            local is_running=false

            # Signal 1: Braille spinner in pane title (Claude-specific, authoritative)
            if title_has_braille_spinner "$pane_title"; then
                is_running=true
                LAST_BUSY_TIME["$pane_id"]=$CURRENT_TIME
            fi

            # Signal 2: window_activity changed since last poll (terminal producing output)
            if [[ -n "${LAST_ACTIVITY[$pane_id]:-}" ]] && \
               [[ "$win_activity" != "${LAST_ACTIVITY[$pane_id]}" ]]; then
                is_running=true
                LAST_BUSY_TIME["$pane_id"]=$CURRENT_TIME
            fi
            LAST_ACTIVITY["$pane_id"]=$win_activity

            # Signal 3: Busy indicators in captured content
            if ! $is_running && is_pane_busy "$clean_text"; then
                is_running=true
                LAST_BUSY_TIME["$pane_id"]=$CURRENT_TIME
            fi

            # Signal 4: Grace period (6s after last confirmed running)
            if ! $is_running && [[ -n "${LAST_BUSY_TIME[$pane_id]:-}" ]] && \
               [[ $((CURRENT_TIME - LAST_BUSY_TIME[$pane_id])) -lt $GRACE_PERIOD ]]; then
                is_running=true
            fi

            # Signal 5: Startup period (first 4s after detecting a new pane)
            if ! $is_running && \
               [[ $((CURRENT_TIME - FIRST_SEEN[$pane_id])) -lt $STARTUP_PERIOD ]]; then
                is_running=true
            fi

            # ── State ──
            local state
            if $is_running; then
                state="running"
            else
                state="waiting"
            fi

            # ── Timestamp (for FIFO quick-jump ordering) ──
            local timestamp=""
            if [[ "$state" == "waiting" ]]; then
                local existing_state existing_timestamp
                existing_state=$(grep "^${pane_id}," "$STATE_FILE" 2>/dev/null | head -1 | cut -d',' -f5)
                existing_timestamp=$(grep "^${pane_id}," "$STATE_FILE" 2>/dev/null | head -1 | cut -d',' -f6)

                if [[ "$existing_state" == "waiting" ]] && [[ -n "$existing_timestamp" ]]; then
                    timestamp="$existing_timestamp"
                else
                    timestamp="$CURRENT_TIME"
                fi
            fi

            echo "${pane_id},${session_name},${window_name},${window_index},${state},${timestamp},${agent_name}" >> "$TEMP_STATE_FILE"
        done <<< "$pane_data"

        mv -f "$TEMP_STATE_FILE" "$STATE_FILE"
        sleep 1
    done
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
    rm -f "$TEMP_STATE_FILE" "$PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP

# ─── Single-instance enforcement ─────────────────────────────────────────────
if [[ -f "$PID_FILE" ]]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null)
    if [[ -n "$old_pid" ]] && [[ "$old_pid" != "$$" ]] && kill -0 "$old_pid" 2>/dev/null; then
        kill "$old_pid" 2>/dev/null || true
        sleep 0.3
        kill -0 "$old_pid" 2>/dev/null && kill -9 "$old_pid" 2>/dev/null || true
    fi
fi

echo $$ > "$PID_FILE"
touch "$STATE_FILE"
monitor_loop
