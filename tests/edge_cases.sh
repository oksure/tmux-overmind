#!/usr/bin/env bash

# Edge case tests for tmux-overmind

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPTS_DIR="$PROJECT_DIR/scripts"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local name="$1"
    local cmd="$2"
    echo -n "Testing $name... "
    if eval "$cmd"; then
        echo -e "${GREEN}PASSED${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAILED${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo "==================================="
echo "  Edge Case Tests"
echo "==================================="
echo ""

# Test 1: Very long window names
run_test "Long window names" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    printf "%%1,session1,%s,1,waiting,1234567890,opencode\n" "$(python3 -c "print(\"A\"*500)")" > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'

# Test 2: Unicode in session/window names
run_test "Unicode in names" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    cat > "$STATE_FILE" << EOF
%1,dev-session,🚀-coding,1,waiting,1234567890,opencode
%2,개발-session,テスト-window,2,running,,claude
EOF
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'

# Test 3: Empty fields in CSV
run_test "Empty fields handling" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    cat > "$STATE_FILE" << EOF
%1,,window1,1,waiting,1234567890,opencode
%2,session1,,2,running,,claude
EOF
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'

# Test 4: Special regex characters in names
run_test "Special regex chars" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    cat > "$STATE_FILE" << EOF
%1,session[1],window.*,1,waiting,1234567890,opencode
%2,session(test),window+name,2,running,,claude
EOF
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'

# Test 5: Newline characters in window names (edge case)
run_test "Newline in data" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    printf "%%1,session1,window1,1,waiting,1234567890,opencode\n%%2,session1,window2,2,running,,claude\n" > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'

# Test 6: Very old timestamps
run_test "Old timestamps" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    # Timestamps from 2020
    cat > "$STATE_FILE" << EOF
%1,session1,window1,1,waiting,1577836800,opencode
%2,session1,window2,2,waiting,1577836700,claude
EOF
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'

# Test 7: Future timestamps
run_test "Future timestamps" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    # Timestamp from year 2030
    cat > "$STATE_FILE" << EOF
%1,session1,window1,1,waiting,1893456000,opencode
EOF
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'

# Test 8: Mixed line endings (CRLF)
run_test "CRLF line endings" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    printf "%%1,session1,window1,1,waiting,1234567890,opencode\r\n%%2,session1,window2,2,running,,claude\r\n" > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'

# Test 9: Large number of agents
run_test "Many agents (100)" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    > "$STATE_FILE"
    for i in $(seq 1 100); do
        if [[ $((i % 2)) -eq 0 ]]; then
            echo "%$i,session$((i/10)),window$i,$((i%10)),waiting,$((1234567890+i)),opencode"
        else
            echo "%$i,session$((i/10)),window$i,$((i%10)),running,,claude"
        fi
    done >> "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'

# Test 10: Pane IDs with special characters
run_test "Special pane IDs" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    cat > "$STATE_FILE" << EOF
%1-dev,session1,window1,1,waiting,1234567890,opencode
%2@1,session1,window2,2,running,,claude
EOF
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'

# Test 11: Missing trailing newlines
run_test "No trailing newline" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    printf "%%1,session1,window1,1,waiting,1234567890,opencode" > "$STATE_FILE"
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'

# Test 12: Whitespace-only window names
run_test "Whitespace names" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    cat > "$STATE_FILE" << EOF
%1,session1,   ,1,waiting,1234567890,opencode
EOF
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'

echo ""
echo "==================================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "==================================="

[[ $TESTS_FAILED -eq 0 ]]
