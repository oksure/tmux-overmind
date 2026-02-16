#!/usr/bin/env bash

# Test suite for tmux-overmind
# Tests core detection logic, status output, and CSV handling.
# Does NOT require a running tmux server.

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

# Assert that actual CONTAINS expected substring
assert_contains() {
    local test_name="$1" expected="$2" actual="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$actual" == *"$expected"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "  ${GREEN}PASS${NC} %s\n" "$test_name"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf "  ${RED}FAIL${NC} %s\n" "$test_name"
        printf "       expected to contain: '%s'\n" "$expected"
        printf "       actual: '%s'\n" "$actual"
    fi
}

setup() {
    cp "$STATE_FILE" "${STATE_FILE}.test-bak" 2>/dev/null || true
}

teardown() {
    mv "${STATE_FILE}.test-bak" "$STATE_FILE" 2>/dev/null || : > "$STATE_FILE"
}

# Source monitor.sh functions without running the daemon
source_monitor_functions() {
    eval "$(sed -n '1,/^# Go$/p' "$SCRIPTS_DIR/monitor.sh" | grep -v '^monitor_loop$' | grep -v '^echo \$\$ >' | grep -v '^touch ' | grep -v '^trap ')"
}

# ─── Status indicator tests ──────────────────────────────────────────────────
# status.sh now outputs tmux color codes and empty string when no agents

test_status_indicator() {
    printf "\n${YELLOW}Status Indicator Tests${NC}\n"
    setup

    # Empty file → empty output (hidden)
    : > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Empty state file → hidden" "" "$result"

    # No file → empty output (hidden)
    rm -f "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_eq "Missing state file → hidden" "" "$result"
    touch "$STATE_FILE"

    # Only running → contains ●
    echo '%1,sess,win,0,running,,claude' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_contains "Running agents → ●" "●" "$result"

    # Multiple running → contains ●
    printf '%%1,s1,w1,0,running,,claude\n%%2,s2,w2,1,running,,opencode\n' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_contains "Multiple running → ●" "●" "$result"

    # Has waiting → contains ◐
    printf '%%1,s1,w1,0,running,,claude\n%%2,s2,w2,1,waiting,1700000000,opencode\n' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_contains "Running + waiting → ◐" "◐" "$result"

    # Only waiting → contains ◐
    echo '%1,sess,win,0,waiting,1700000000,claude' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_contains "Only waiting → ◐" "◐" "$result"

    # Waiting takes priority over running
    printf '%%1,s1,w1,0,running,,claude\n%%2,s2,w2,1,waiting,1700000000,opencode\n%%3,s3,w3,2,running,,gemini\n' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_contains "Waiting wins over running → ◐" "◐" "$result"

    teardown
}

# ─── Busy detection tests ────────────────────────────────────────────────────

test_busy_detection() {
    printf "\n${YELLOW}Busy Detection Tests${NC}\n"
    source_monitor_functions 2>/dev/null || true

    is_pane_busy "⠋ Processing..." && r=0 || r=1
    assert_eq "Braille spinner ⠋ → busy" "0" "$r"

    is_pane_busy "⠸ Loading data" && r=0 || r=1
    assert_eq "Braille spinner ⠸ → busy" "0" "$r"

    is_pane_busy "✳ thinking… (3s · ↑↓ 500 tokens)" && r=0 || r=1
    assert_eq "Asterisk spinner ✳ with context → busy" "0" "$r"

    is_pane_busy "Press ctrl+c to interrupt" && r=0 || r=1
    assert_eq "'ctrl+c to interrupt' → busy" "0" "$r"

    is_pane_busy "Press esc to interrupt" && r=0 || r=1
    assert_eq "'esc to interrupt' → busy" "0" "$r"

    is_pane_busy "✳ pondering… (3s · ↑↓ 500 tokens)" && r=0 || r=1
    assert_eq "Whimsical 'pondering…' → busy" "0" "$r"

    is_pane_busy "✶ clauding… (1s · ↑↓ 200 tokens)" && r=0 || r=1
    assert_eq "Whimsical 'clauding…' → busy" "0" "$r"

    is_pane_busy "working… 500 tokens" && r=0 || r=1
    assert_eq "Token counter with … → busy" "0" "$r"

    is_pane_busy "esc interrupt" && r=0 || r=1
    assert_eq "OpenCode 'esc interrupt' → busy" "0" "$r"

    is_pane_busy "esc to cancel" && r=0 || r=1
    assert_eq "Gemini 'esc to cancel' → busy" "0" "$r"

    is_pane_busy "Hello world" && r=0 || r=1
    assert_eq "Plain text → not busy" "1" "$r"

    is_pane_busy "" && r=0 || r=1
    assert_eq "Empty text → not busy" "1" "$r"
}

# ─── Title spinner detection tests ───────────────────────────────────────────

test_title_detection() {
    printf "\n${YELLOW}Title Spinner Detection Tests${NC}\n"
    source_monitor_functions 2>/dev/null || true

    title_has_braille_spinner "⠐ Claude Code" && r=0 || r=1
    assert_eq "Title '⠐ Claude Code' → spinner" "0" "$r"

    title_has_braille_spinner "⠋ Claude Code" && r=0 || r=1
    assert_eq "Title '⠋ Claude Code' → spinner" "0" "$r"

    title_has_braille_spinner "Claude Code" && r=0 || r=1
    assert_eq "Title 'Claude Code' (no spinner) → no spinner" "1" "$r"

    title_has_braille_spinner "OpenCode" && r=0 || r=1
    assert_eq "Title 'OpenCode' → no spinner" "1" "$r"

    title_has_braille_spinner "" && r=0 || r=1
    assert_eq "Empty title → no spinner" "1" "$r"
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

    # No waiting agents → empty
    echo '%1,sess,win,0,running,,claude' > "$STATE_FILE"
    oldest=$(while IFS=',' read -r p s w wi st ts ag || [[ -n "$p" ]]; do
        if [[ "$st" == "waiting" ]]; then echo "$ts $s:$wi"; fi
    done < "$STATE_FILE" | sort -n | head -1 | cut -d' ' -f2)
    assert_eq "No waiting → empty target" "" "$oldest"

    # One waiting
    printf '%%1,s1,w1,0,running,,claude\n%%2,s2,w2,1,waiting,1700000010,opencode\n' > "$STATE_FILE"
    oldest=$(while IFS=',' read -r p s w wi st ts ag || [[ -n "$p" ]]; do
        if [[ "$st" == "waiting" ]]; then echo "$ts $s:$wi"; fi
    done < "$STATE_FILE" | sort -n | head -1 | cut -d' ' -f2)
    assert_eq "One waiting → s2:1" "s2:1" "$oldest"

    # Multiple waiting → oldest timestamp wins
    printf '%%1,s1,w1,0,waiting,1700000020,claude\n%%2,s2,w2,1,waiting,1700000010,opencode\n%%3,s3,w3,2,waiting,1700000030,gemini\n' > "$STATE_FILE"
    oldest=$(while IFS=',' read -r p s w wi st ts ag || [[ -n "$p" ]]; do
        if [[ "$st" == "waiting" ]]; then echo "$ts $s:$wi"; fi
    done < "$STATE_FILE" | sort -n | head -1 | cut -d' ' -f2)
    assert_eq "Oldest waiting → s2:1 (ts 1700000010)" "s2:1" "$oldest"

    teardown
}

# ─── Agent detection tests ───────────────────────────────────────────────────

test_agent_detection() {
    printf "\n${YELLOW}Agent Detection Tests${NC}\n"
    source_monitor_functions 2>/dev/null || true

    # Strategy 1: command match
    for cmd in claude opencode codex gemini copilot crush; do
        result=$(detect_agent "$cmd" "" "")
        assert_eq "cmd '$cmd' → detected as '$cmd'" "$cmd" "$result"
    done

    # Non-agents
    for cmd in bash zsh vim python node dodo; do
        detect_agent "$cmd" "" "" >/dev/null 2>&1 && r=0 || r=1
        assert_eq "cmd '$cmd' → not detected" "1" "$r"
    done

    # Strategy 2: title-based
    result=$(detect_agent "2.1.41" "⠐ Claude Code" "")
    assert_eq "cmd='2.1.41' title='Claude Code' → claude" "claude" "$result"

    result=$(detect_agent "node" "codex" "")
    assert_eq "cmd='node' title='codex' → codex" "codex" "$result"

    result=$(detect_agent "copilot" "GitHub Copilot" "")
    assert_eq "cmd='copilot' title='GitHub Copilot' → copilot" "copilot" "$result"

    # Strategy 3: content-based
    result=$(detect_agent "node" "some title" "Authenticated with gemini-api-key")
    assert_eq "cmd='node' content has 'gemini' → gemini" "gemini" "$result"

    # Non-match
    detect_agent "node" "some title" "hello world" >/dev/null 2>&1 && r=0 || r=1
    assert_eq "cmd='node' no keywords → not detected" "1" "$r"
}

# ─── Dashboard list building tests ──────────────────────────────────────────

test_dashboard_list() {
    printf "\n${YELLOW}Dashboard List Building Tests${NC}\n"
    setup

    printf '%%1,mysess,mywin,0,running,,claude\n%%2,dev,code,1,waiting,1700000000,opencode\n' > "$STATE_FILE"

    items=""
    while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name || [[ -n "$pane_id" ]]; do
        [[ -z "$pane_id" ]] && continue
        case "$state" in
            running) icon="●" ;; waiting) icon="◐" ;; *) icon="●" ;;
        esac
        line=$(printf "[%s:%s] %s - %s %s" "$session_name" "$window_name" "$agent_name" "$icon" "$state")
        items="${items}${line}\n"
    done < "$STATE_FILE"

    echo -e "$items" | grep -q "\[mysess:mywin\] claude - ● running" && r=0 || r=1
    assert_eq "Dashboard shows running agent" "0" "$r"

    echo -e "$items" | grep -q "\[dev:code\] opencode - ◐ waiting" && r=0 || r=1
    assert_eq "Dashboard shows waiting agent" "0" "$r"

    teardown
}

# ─── Edge case tests ─────────────────────────────────────────────────────────

test_edge_cases() {
    printf "\n${YELLOW}Edge Case Tests${NC}\n"
    setup

    # Special characters in names
    echo '%1,my-sess_2,win.name,0,running,,claude' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_contains "Special chars in names → ●" "●" "$result"

    # Very long window name
    long_name=$(printf 'a%.0s' {1..200})
    echo "%1,sess,$long_name,0,waiting,1700000000,claude" > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_contains "Long window name → ◐" "◐" "$result"

    # Empty fields in CSV
    echo '%1,sess,win,0,running,,claude' > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_contains "Empty fields in CSV → ●" "●" "$result"

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
test_title_detection
test_ansi_stripping
test_quick_jump_logic
test_agent_detection
test_dashboard_list
test_edge_cases

printf "\n${YELLOW}═══════════════════════════════════════${NC}\n"
printf "  Total: %d  " "$TESTS_RUN"
printf "${GREEN}Passed: %d${NC}  " "$TESTS_PASSED"
printf "${RED}Failed: %d${NC}\n" "$TESTS_FAILED"
printf "${YELLOW}═══════════════════════════════════════${NC}\n"

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
