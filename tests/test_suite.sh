#!/usr/bin/env bash

# Test suite for tmux-overmind
# Tests core detection logic, status output, and CSV handling
# Does NOT require a running tmux server (unit-level tests).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPTS_DIR="$PROJECT_DIR/scripts"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"

# ─── Helpers ──────────────────────────────────────────────────────────────────

assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "  ${GREEN}PASS${NC} %s\n" "$test_name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "  ${RED}FAIL${NC} %s\n" "$test_name"
        printf "       expected: '%s'\n" "$expected"
        printf "       actual:   '%s'\n" "$actual"
    fi
}

setup() {
    cp "$STATE_FILE" "${STATE_FILE}.test-bak" 2>/dev/null || true
}

teardown() {
    mv "${STATE_FILE}.test-bak" "$STATE_FILE" 2>/dev/null || : > "$STATE_FILE"
}

# Source monitor.sh functions (but not the main loop)
source_monitor_functions() {
    # Extract functions from monitor.sh without running the main code
    # We source only the function definitions by stopping before monitor_loop call
    eval "$(sed -n '1,/^# Go$/p' "$SCRIPTS_DIR/monitor.sh" | grep -v '^monitor_loop$' | grep -v '^echo \$\$ >' | grep -v '^touch ' | grep -v '^trap ')"
}

# ─── Status indicator tests ──────────────────────────────────────────────────

test_status_indicator() {
    printf "\n${YELLOW}Status Indicator Tests${NC}\n"
    setup

    # Empty file → ○
    : > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Empty state file → ○" "○" "$result"

    # No file → ○
    rm -f "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Missing state file → ○" "○" "$result"
    touch "$STATE_FILE"

    # Only running agents → ●
    echo '%1,sess,win,0,running,,claude,' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Running agents only → ●" "●" "$result"

    # Multiple running → ●
    printf '%%1,s1,w1,0,running,,claude,\n%%2,s2,w2,1,running,,opencode,\n' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Multiple running → ●" "●" "$result"

    # Has waiting → ◐
    printf '%%1,s1,w1,0,running,,claude,\n%%2,s2,w2,1,waiting,1700000000,opencode,0\n' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Running + waiting → ◐" "◐" "$result"

    # Only waiting → ◐
    echo '%1,sess,win,0,waiting,1700000000,claude,0' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Only waiting → ◐" "◐" "$result"

    # All idle → ○
    echo '%1,sess,win,0,idle,1700000000,claude,1' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "All idle → ○" "○" "$result"

    # Running + idle (no waiting) → ●
    printf '%%1,s1,w1,0,running,,claude,\n%%2,s2,w2,1,idle,1700000000,opencode,1\n' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Running + idle → ●" "●" "$result"

    # Mixed: running + waiting + idle → ◐
    printf '%%1,s1,w1,0,running,,claude,\n%%2,s2,w2,1,waiting,1700000000,opencode,0\n%%3,s3,w3,2,idle,1700000000,gemini,1\n' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Running + waiting + idle → ◐" "◐" "$result"

    teardown
}

# ─── Busy detection tests ────────────────────────────────────────────────────

test_busy_detection() {
    printf "\n${YELLOW}Busy Detection Tests${NC}\n"
    source_monitor_functions 2>/dev/null || true

    # Braille spinners
    is_pane_busy "⠋ Processing..." && r=0 || r=1
    assert_eq "Braille spinner ⠋ → busy" "0" "$r"

    is_pane_busy "⠸ Loading data" && r=0 || r=1
    assert_eq "Braille spinner ⠸ → busy" "0" "$r"

    # Asterisk spinners (require ellipsis context per agent-deck: bare ✳ can be a done marker)
    is_pane_busy "✳ thinking… (3s · ↑↓ 500 tokens)" && r=0 || r=1
    assert_eq "Asterisk spinner ✳ with context → busy" "0" "$r"

    # "to interrupt" text
    is_pane_busy "Press ctrl+c to interrupt" && r=0 || r=1
    assert_eq "'ctrl+c to interrupt' → busy" "0" "$r"

    is_pane_busy "Press esc to interrupt" && r=0 || r=1
    assert_eq "'esc to interrupt' → busy" "0" "$r"

    # Whimsical thinking words
    is_pane_busy "✳ pondering… (3s · ↑↓ 500 tokens)" && r=0 || r=1
    assert_eq "Whimsical 'pondering…' → busy" "0" "$r"

    is_pane_busy "✶ clauding… (1s · ↑↓ 200 tokens)" && r=0 || r=1
    assert_eq "Whimsical 'clauding…' → busy" "0" "$r"

    # Token counter with ellipsis
    is_pane_busy "working… 500 tokens" && r=0 || r=1
    assert_eq "Token counter with … → busy" "0" "$r"

    # OpenCode busy
    is_pane_busy "esc interrupt" && r=0 || r=1
    assert_eq "OpenCode 'esc interrupt' → busy" "0" "$r"

    # Gemini busy
    is_pane_busy "esc to cancel" && r=0 || r=1
    assert_eq "Gemini 'esc to cancel' → busy" "0" "$r"

    # Plain text (not busy)
    is_pane_busy "Hello world" && r=0 || r=1
    assert_eq "Plain text → not busy" "1" "$r"

    is_pane_busy "" && r=0 || r=1
    assert_eq "Empty text → not busy" "1" "$r"
}

# ─── Prompt/waiting detection tests ──────────────────────────────────────────

test_waiting_detection() {
    printf "\n${YELLOW}Waiting/Prompt Detection Tests${NC}\n"
    source_monitor_functions 2>/dev/null || true

    # Bare prompts (last line)
    is_pane_waiting "" ">" && r=0 || r=1
    assert_eq "Last line '>' → waiting" "0" "$r"

    is_pane_waiting "" "> " && r=0 || r=1
    assert_eq "Last line '> ' → waiting" "0" "$r"

    is_pane_waiting "" "❯" && r=0 || r=1
    assert_eq "Last line '❯' → waiting" "0" "$r"

    is_pane_waiting "" "> hello" && r=0 || r=1
    assert_eq "Last line '> hello' → waiting" "0" "$r"

    # OpenCode prompt
    is_pane_waiting "" "⬝" && r=0 || r=1
    assert_eq "Last line '⬝' (OpenCode) → waiting" "0" "$r"

    # Gemini prompt
    is_pane_waiting "" "gemini>" && r=0 || r=1
    assert_eq "Last line 'gemini>' → waiting" "0" "$r"

    # Codex prompt
    is_pane_waiting "" "codex>" && r=0 || r=1
    assert_eq "Last line 'codex>' → waiting" "0" "$r"

    # Permission dialogs (in full text)
    is_pane_waiting "Yes, allow once" "?" && r=0 || r=1
    assert_eq "'Yes, allow once' in text → waiting" "0" "$r"

    is_pane_waiting "No, and tell Claude what to do" "?" && r=0 || r=1
    assert_eq "'No, and tell Claude' → waiting" "0" "$r"

    # Y/n prompts
    is_pane_waiting "Proceed? (Y/n)" "?" && r=0 || r=1
    assert_eq "'(Y/n)' → waiting" "0" "$r"

    is_pane_waiting "Continue? [y/N]" "?" && r=0 || r=1
    assert_eq "'[y/N]' → waiting" "0" "$r"

    # Continue/Proceed
    is_pane_waiting "Continue?" "?" && r=0 || r=1
    assert_eq "'Continue?' → waiting" "0" "$r"

    # Completion indicators
    is_pane_waiting "What would you like to do next?" ">" && r=0 || r=1
    assert_eq "'What would you like' → waiting" "0" "$r"

    # OpenCode specific
    is_pane_waiting "Ask anything about your code" "⬝" && r=0 || r=1
    assert_eq "'Ask anything' → waiting" "0" "$r"

    # Not waiting
    is_pane_waiting "Processing data..." "Processing data..." && r=0 || r=1
    assert_eq "'Processing data...' → not waiting" "1" "$r"
}

# ─── ANSI stripping tests ────────────────────────────────────────────────────

test_ansi_stripping() {
    printf "\n${YELLOW}ANSI Stripping Tests${NC}\n"
    source_monitor_functions 2>/dev/null || true

    result=$(echo $'\x1b[32mgreen text\x1b[0m' | strip_ansi)
    assert_eq "Strip color codes" "green text" "$result"

    result=$(echo $'\x1b[1;31;42mbold red on green\x1b[0m' | strip_ansi)
    assert_eq "Strip complex color codes" "bold red on green" "$result"

    result=$(echo "plain text" | strip_ansi)
    assert_eq "Plain text unchanged" "plain text" "$result"

    result=$(echo $'\x1b[?25hvisible cursor\x1b[?25l' | strip_ansi)
    assert_eq "Strip DEC private modes" "visible cursor" "$result"
}

# ─── Quick jump logic tests ─────────────────────────────────────────────────

test_quick_jump_logic() {
    printf "\n${YELLOW}Quick Jump Logic Tests${NC}\n"
    setup

    # No waiting agents → no output
    echo '%1,sess,win,0,running,,claude,' > "$STATE_FILE"
    # quick_jump.sh calls tmux switch-client which we can't test outside tmux
    # Instead test the CSV parsing logic
    oldest=$(while IFS=',' read -r p s w wi st ts ag vf || [[ -n "$p" ]]; do
        if [[ "$st" == "waiting" ]]; then echo "$ts $s:$wi"; fi
    done < "$STATE_FILE" | sort -n | head -1 | cut -d' ' -f2)
    assert_eq "No waiting → empty target" "" "$oldest"

    # One waiting agent → that one
    printf '%%1,s1,w1,0,running,,claude,\n%%2,s2,w2,1,waiting,1700000010,opencode,0\n' > "$STATE_FILE"
    oldest=$(while IFS=',' read -r p s w wi st ts ag vf || [[ -n "$p" ]]; do
        if [[ "$st" == "waiting" ]]; then echo "$ts $s:$wi"; fi
    done < "$STATE_FILE" | sort -n | head -1 | cut -d' ' -f2)
    assert_eq "One waiting → s2:1" "s2:1" "$oldest"

    # Multiple waiting → oldest timestamp wins
    printf '%%1,s1,w1,0,waiting,1700000020,claude,0\n%%2,s2,w2,1,waiting,1700000010,opencode,0\n%%3,s3,w3,2,waiting,1700000030,gemini,0\n' > "$STATE_FILE"
    oldest=$(while IFS=',' read -r p s w wi st ts ag vf || [[ -n "$p" ]]; do
        if [[ "$st" == "waiting" ]]; then echo "$ts $s:$wi"; fi
    done < "$STATE_FILE" | sort -n | head -1 | cut -d' ' -f2)
    assert_eq "Oldest waiting → s2:1 (ts 1700000010)" "s2:1" "$oldest"

    # Idle agents NOT selected (already viewed)
    printf '%%1,s1,w1,0,idle,1700000010,claude,1\n%%2,s2,w2,1,waiting,1700000020,opencode,0\n' > "$STATE_FILE"
    oldest=$(while IFS=',' read -r p s w wi st ts ag vf || [[ -n "$p" ]]; do
        if [[ "$st" == "waiting" ]]; then echo "$ts $s:$wi"; fi
    done < "$STATE_FILE" | sort -n | head -1 | cut -d' ' -f2)
    assert_eq "Idle skipped, waiting selected → s2:1" "s2:1" "$oldest"

    teardown
}

# ─── Agent pattern matching tests ────────────────────────────────────────────

test_agent_pattern() {
    printf "\n${YELLOW}Agent Pattern Matching Tests${NC}\n"

    AGENT_PATTERN='^(claude|opencode|codex|gemini|copilot|crush)$'

    for cmd in claude opencode codex gemini copilot crush; do
        [[ "$cmd" =~ $AGENT_PATTERN ]] && r=0 || r=1
        assert_eq "'$cmd' matches agent pattern" "0" "$r"
    done

    for cmd in bash zsh vim python node; do
        [[ "$cmd" =~ $AGENT_PATTERN ]] && r=0 || r=1
        assert_eq "'$cmd' does NOT match agent pattern" "1" "$r"
    done

    # Edge: partial matches should fail
    for cmd in claude-code opencode2 mycodex; do
        [[ "$cmd" =~ $AGENT_PATTERN ]] && r=0 || r=1
        assert_eq "'$cmd' does NOT match (anchored)" "1" "$r"
    done
}

# ─── Dashboard list building tests ──────────────────────────────────────────

test_dashboard_list() {
    printf "\n${YELLOW}Dashboard List Building Tests${NC}\n"
    setup

    printf '%%1,mysess,mywin,0,running,,claude,\n%%2,dev,code,1,waiting,1700000000,opencode,0\n%%3,test,debug,2,idle,1700000000,gemini,1\n' > "$STATE_FILE"

    # Simulate dashboard list building
    items=""
    while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name viewed_flag || [[ -n "$pane_id" ]]; do
        [[ -z "$pane_id" ]] && continue
        case "$state" in
            running) icon="●"; text="Running"  ;;
            waiting) icon="◐"; text="Waiting"  ;;
            idle)    icon="○"; text="Idle"     ;;
            *)       icon="●"; text="Running"  ;;
        esac
        line=$(printf "[%s:%s] %s - %s %s" "$session_name" "$window_name" "$agent_name" "$icon" "$text")
        items="${items}${line}\n"
    done < "$STATE_FILE"

    echo -e "$items" | grep -q "\[mysess:mywin\] claude - ● Running" && r=0 || r=1
    assert_eq "Dashboard shows running agent" "0" "$r"

    echo -e "$items" | grep -q "\[dev:code\] opencode - ◐ Waiting" && r=0 || r=1
    assert_eq "Dashboard shows waiting agent" "0" "$r"

    echo -e "$items" | grep -q "\[test:debug\] gemini - ○ Idle" && r=0 || r=1
    assert_eq "Dashboard shows idle agent" "0" "$r"

    teardown
}

# ─── Edge case tests ─────────────────────────────────────────────────────────

test_edge_cases() {
    printf "\n${YELLOW}Edge Case Tests${NC}\n"
    setup

    # Special characters in session/window names
    echo '%1,my-sess_2,win.name,0,running,,claude,' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Special chars in names → ●" "●" "$result"

    # Very long window name
    long_name=$(printf 'a%.0s' {1..200})
    echo "%1,sess,$long_name,0,waiting,1700000000,claude,0" > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Long window name → ◐" "◐" "$result"

    # Multiple commas / edge CSV parsing
    echo '%1,sess,win,0,running,,claude,' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Empty fields in CSV → ●" "●" "$result"

    teardown
}

# ─── Syntax validation ──────────────────────────────────────────────────────

test_syntax() {
    printf "\n${YELLOW}Script Syntax Tests${NC}\n"

    for script in overmind.tmux scripts/monitor.sh scripts/status.sh scripts/dashboard.sh scripts/quick_jump.sh; do
        bash -n "$PROJECT_DIR/$script" 2>/dev/null && r=0 || r=1
        assert_eq "$script passes bash -n" "0" "$r"
    done
}

# ─── Executable permissions ──────────────────────────────────────────────────

test_permissions() {
    printf "\n${YELLOW}File Permission Tests${NC}\n"

    for script in overmind.tmux scripts/monitor.sh scripts/status.sh scripts/dashboard.sh scripts/quick_jump.sh; do
        [[ -x "$PROJECT_DIR/$script" ]] && r=0 || r=1
        assert_eq "$script is executable" "0" "$r"
    done
}

# ─── Run all tests ───────────────────────────────────────────────────────────

printf "\n${YELLOW}═══════════════════════════════════════${NC}\n"
printf "${YELLOW}  tmux-overmind test suite${NC}\n"
printf "${YELLOW}═══════════════════════════════════════${NC}\n"

test_syntax
test_permissions
test_status_indicator
test_busy_detection
test_waiting_detection
test_ansi_stripping
test_quick_jump_logic
test_agent_pattern
test_dashboard_list
test_edge_cases

printf "\n${YELLOW}═══════════════════════════════════════${NC}\n"
printf "  Total: %d  " "$TESTS_RUN"
printf "${GREEN}Passed: %d${NC}  " "$TESTS_PASSED"
printf "${RED}Failed: %d${NC}\n" "$TESTS_FAILED"
printf "${YELLOW}═══════════════════════════════════════${NC}\n"

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
