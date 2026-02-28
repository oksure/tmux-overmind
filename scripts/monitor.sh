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
#   1. Braille spinner in pane_title                 (Claude sets this while working)
#   2. window_activity changed since last poll        (terminal is producing output)
#      → SUPPRESSED when content positively shows a waiting prompt
#   3. Busy indicators in pane content               (spinners, "to interrupt", etc.)
#   4. Within 3s grace period after any of above     (covers tool-call transitions)
#      → SUPPRESSED when content positively shows a waiting prompt
#
# If none of those are true, the agent is WAITING.
# Crucially: is_pane_waiting() provides a positive "waiting" signal that overrides
# the noisy window_activity signal — agents often redraw their prompt, which fires
# window_activity even when sitting idle at a prompt.

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

# ─── Content waiting indicators ──────────────────────────────────────────────
# POSITIVE EVIDENCE of a waiting/idle state. When found, suppresses the noisy
# window_activity signal so prompt redraws don't keep an agent stuck at "running".

is_pane_waiting() {
    local text="$1"
    local last_line
    last_line=$(get_last_nonempty_line "$text")

    # Claude Code / generic CLI: last visible line is just the prompt glyph
    case "$last_line" in
        ">"*|"❯"*|"$ "*) return 0 ;;
    esac

    # OpenCode explicit waiting indicators
    if echo "$text" | grep -qiF 'press enter to send'; then return 0; fi
    if echo "$text" | grep -qiF 'Ask anything';        then return 0; fi

    # Gemini CLI waiting
    if echo "$text" | grep -qE 'gemini[>❯]|Type your message'; then return 0; fi

    # Codex waiting
    if echo "$text" | grep -qF 'codex>'; then return 0; fi

    # Permission / confirmation dialogs (all agents)
    if echo "$text" | grep -qF 'Yes, allow once';    then return 0; fi
    if echo "$text" | grep -qF 'Yes, allow always';  then return 0; fi
    if echo "$text" | grep -qF '(Y/n)';              then return 0; fi
    if echo "$text" | grep -qF '(y/N)';              then return 0; fi
    if echo "$text" | grep -qF '[Y/n]';              then return 0; fi
    if echo "$text" | grep -qF '[y/N]';              then return 0; fi
    if echo "$text" | grep -qiF 'Do you want to';    then return 0; fi
    if echo "$text" | grep -qiF 'Run this command';  then return 0; fi
    if echo "$text" | grep -qiF 'Would you like';    then return 0; fi
    if echo "$text" | grep -qiF 'Allow this MCP';    then return 0; fi

    # Completion / handoff phrases (agent finished, ball in user's court)
    if echo "$text" | grep -qiE '(What would you like|What else|Anything else|Let me know if|How can I help)'; then return 0; fi

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

            # ── Does content positively indicate WAITING? ──
            # Evaluated first so it can gatekeep noisy signals below.
            local positively_waiting=false
            if is_pane_waiting "$clean_text"; then
                positively_waiting=true
            fi

            # ── Determine: is this pane PROVABLY running? ──
            local is_running=false

            # Signal 1: Braille spinner in pane title (Claude-specific, authoritative).
            # Not suppressed — a spinner in the title overrides content heuristics.
            if title_has_braille_spinner "$pane_title"; then
                is_running=true
                LAST_BUSY_TIME["$pane_id"]=$CURRENT_TIME
            fi

            # Signal 2: window_activity changed since last poll.
            # SUPPRESSED when we positively see a waiting prompt — agents redraw
            # their prompt on cursor blinks / scrollback, firing this spuriously.
            if ! $positively_waiting && \
               [[ -n "${LAST_ACTIVITY[$pane_id]:-}" ]] && \
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

            # Signal 4: Grace period (3s after last confirmed running).
            # SUPPRESSED when content explicitly shows a waiting prompt — otherwise
            # a single prompt redraw would extend the grace period indefinitely.
            if ! $is_running && ! $positively_waiting && \
               [[ -n "${LAST_BUSY_TIME[$pane_id]:-}" ]] && \
               [[ $((CURRENT_TIME - LAST_BUSY_TIME[$pane_id])) -lt $GRACE_PERIOD ]]; then
                is_running=true
            fi

            # Signal 5: Startup period (first N seconds after first detection).
            # SUPPRESSED if content already shows waiting — some agents open
            # immediately to a prompt with no work to do.
            if ! $is_running && ! $positively_waiting && \
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
