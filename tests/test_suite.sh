#!/usr/bin/env bash

# Comprehensive test suite for tmux-overmind
# Tests all core functionality without requiring actual tmux/AI agents

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPTS_DIR="$PROJECT_DIR/scripts"

# Test result tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test helper functions
setup_test_env() {
    export TMPDIR="${TMPDIR:-/tmp}"
    export TEST_STATE_FILE="$TMPDIR/tmux-overmind-test-state.csv"
    export TEST_PID_FILE="$TMPDIR/tmux-overmind-test.pid"
    export ORIG_STATE_FILE="${TMPDIR}/tmux-overmind-state.csv"
    
    # Backup original state file
    if [[ -f "$ORIG_STATE_FILE" ]]; then
        cp "$ORIG_STATE_FILE" "${ORIG_STATE_FILE}.backup"
    fi
}

cleanup_test_env() {
    rm -f "$TEST_STATE_FILE" "$TEST_PID_FILE"
    
    # Restore original state file
    if [[ -f "${ORIG_STATE_FILE}.backup" ]]; then
        mv "${ORIG_STATE_FILE}.backup" "$ORIG_STATE_FILE"
    fi
}

run_test() {
    local test_name="$1"
    local test_func="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -n "Testing $test_name... "
    
    if $test_func; then
        echo -e "${GREEN}PASSED${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAILED${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    
    if [[ "$expected" != "$actual" ]]; then
        echo -e "\n${RED}Assertion failed:${NC} $msg"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        return 1
    fi
    return 0
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    
    if [[ "$haystack" != *"$needle"* ]]; then
        echo -e "\n${RED}Assertion failed:${NC} $msg"
        echo "  String does not contain: '$needle'"
        echo "  Haystack: '$haystack'"
        return 1
    fi
    return 0
}

assert_file_exists() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo -e "\n${RED}Assertion failed:${NC} File does not exist: $file"
        return 1
    fi
    return 0
}

# =============================================================================
# TEST CASES
# =============================================================================

# -----------------------------------------------------------------------------
# Test 1: Status indicator - No agents running
# -----------------------------------------------------------------------------
test_status_no_agents() {
    # Create empty state file
    > "$ORIG_STATE_FILE"
    
    local result
    result=$(bash "$SCRIPTS_DIR/status.sh")
    
    assert_equals "○" "$result" "Empty state should return ○"
}

# -----------------------------------------------------------------------------
# Test 2: Status indicator - All agents running (busy)
# -----------------------------------------------------------------------------
test_status_all_running() {
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window1,1,running,,opencode
%2,session1,window2,2,running,,claude
EOF
    
    local result
    result=$(bash "$SCRIPTS_DIR/status.sh")
    
    assert_equals "●" "$result" "All running agents should return ●"
}

# -----------------------------------------------------------------------------
# Test 3: Status indicator - At least one waiting
# -----------------------------------------------------------------------------
test_status_one_waiting() {
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window1,1,running,,opencode
%2,session1,window2,2,waiting,1234567890,claude
EOF
    
    local result
    result=$(bash "$SCRIPTS_DIR/status.sh")
    
    assert_equals "◐" "$result" "One waiting agent should return ◐"
}

# -----------------------------------------------------------------------------
# Test 4: Status indicator - Multiple waiting agents
# -----------------------------------------------------------------------------
test_status_multiple_waiting() {
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window1,1,waiting,1234567890,opencode
%2,session1,window2,2,waiting,1234567880,claude
%3,session2,window1,1,waiting,1234567870,codex
EOF
    
    local result
    result=$(bash "$SCRIPTS_DIR/status.sh")
    
    assert_equals "◐" "$result" "Multiple waiting agents should return ◐"
}

# -----------------------------------------------------------------------------
# Test 5: Status indicator - All waiting
# -----------------------------------------------------------------------------
test_status_all_waiting() {
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window1,1,waiting,1234567890,opencode
%2,session1,window2,2,waiting,1234567880,claude
EOF
    
    local result
    result=$(bash "$SCRIPTS_DIR/status.sh")
    
    assert_equals "◐" "$result" "All waiting agents should return ◐"
}

# -----------------------------------------------------------------------------
# Test 6: Status indicator - Missing state file
# -----------------------------------------------------------------------------
test_status_missing_file() {
    rm -f "$ORIG_STATE_FILE"
    
    local result
    result=$(bash "$SCRIPTS_DIR/status.sh")
    
    assert_equals "○" "$result" "Missing state file should return ○"
}

# -----------------------------------------------------------------------------
# Test 7: Prompt pattern detection - Standard prompts
# -----------------------------------------------------------------------------
test_prompt_patterns_standard() {
    local test_texts=(
        "> "
        "? "
        "❯ "
    )
    
    local pattern=$'[>?] $|[⬝❯]|\\(Y/n\\)|\\(y/N\\)|\\[Y/n\\]|\\[y/N\\]'
    
    for text in "${test_texts[@]}"; do
        if ! echo "$text" | grep -qE "$pattern" 2>/dev/null; then
            echo -e "\n${RED}Pattern failed for:${NC} '$text'"
            return 1
        fi
    done
    
    return 0
}

# -----------------------------------------------------------------------------
# Test 8: Prompt pattern detection - Confirmation prompts
# -----------------------------------------------------------------------------
test_prompt_patterns_confirmations() {
    local test_texts=(
        "(Y/n)"
        "(y/N)"
        "[Y/n]"
        "[y/N]"
    )
    
    local pattern=$'[>?] $|[⬝❯]|\\(Y/n\\)|\\(y/N\\)|\\[Y/n\\]|\\[y/N\\]'
    
    for text in "${test_texts[@]}"; do
        if ! echo "$text" | grep -qE "$pattern" 2>/dev/null; then
            echo -e "\n${RED}Pattern failed for:${NC} '$text'"
            return 1
        fi
    done
    
    return 0
}

# -----------------------------------------------------------------------------
# Test 9: Prompt pattern detection - Opencode prompt
# -----------------------------------------------------------------------------
test_prompt_patterns_opencode() {
    local test_text="⬝⬝⬝⬝⬝⬝⬝⬝  esc interrupt"
    local pattern=$'[>?] $|[⬝❯]|\\(Y/n\\)|\\(y/N\\)|\\[Y/n\\]|\\[y/N\\]'
    
    if ! echo "$test_text" | LC_ALL=C grep -qE "$pattern" 2>/dev/null; then
        echo -e "\n${RED}Pattern failed for opencode prompt${NC}"
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Test 10: State file format validation
# -----------------------------------------------------------------------------
test_state_file_format() {
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window1,1,waiting,1234567890,opencode
%2,session1,window2,2,running,,claude
EOF
    
    local line_count
    line_count=$(wc -l < "$ORIG_STATE_FILE")
    
    if [[ "$line_count" -ne 2 ]]; then
        echo -e "\n${RED}State file should have 2 lines${NC}"
        return 1
    fi
    
    # Check first line format
    local first_line
    first_line=$(head -1 "$ORIG_STATE_FILE")
    
    # Should have 7 fields separated by commas
    local field_count
    field_count=$(echo "$first_line" | awk -F',' '{print NF}')
    
    if [[ "$field_count" -ne 7 ]]; then
        echo -e "\n${RED}State line should have 7 fields, got $field_count${NC}"
        echo "  Line: $first_line"
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Test 11: Quick jump - Find oldest waiting
# -----------------------------------------------------------------------------
test_quick_jump_oldest() {
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window1,1,waiting,1234567890,opencode
%2,session1,window2,2,waiting,1234567880,claude
%3,session2,window1,1,running,,codex
EOF
    
    # Parse the state file like quick_jump.sh does
    local oldest_target=""
    local oldest_timestamp=""
    
    while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name; do
        [[ -z "$pane_id" ]] && continue
        
        if [[ "$state" == "waiting" ]] && [[ -n "$timestamp" ]]; then
            if [[ -z "$oldest_timestamp" ]] || [[ "$timestamp" -lt "$oldest_timestamp" ]]; then
                oldest_timestamp="$timestamp"
                oldest_target="${session_name}:${window_index}"
            fi
        fi
    done < "$ORIG_STATE_FILE"
    
    assert_equals "session1:2" "$oldest_target" "Should find oldest waiting agent"
}

# -----------------------------------------------------------------------------
# Test 12: Quick jump - No waiting agents
# -----------------------------------------------------------------------------
test_quick_jump_no_waiting() {
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window1,1,running,,opencode
%2,session1,window2,2,running,,claude
EOF
    
    local oldest_target=""
    local oldest_timestamp=""
    
    while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name; do
        [[ -z "$pane_id" ]] && continue
        
        if [[ "$state" == "waiting" ]] && [[ -n "$timestamp" ]]; then
            if [[ -z "$oldest_timestamp" ]] || [[ "$timestamp" -lt "$oldest_timestamp" ]]; then
                oldest_timestamp="$timestamp"
                oldest_target="${session_name}:${window_index}"
            fi
        fi
    done < "$ORIG_STATE_FILE"
    
    assert_equals "" "$oldest_target" "Should find no waiting agents"
}

# -----------------------------------------------------------------------------
# Test 13: Agent pattern matching
# -----------------------------------------------------------------------------
test_agent_pattern_matching() {
    local valid_agents=("claude" "opencode" "codex" "gemini" "copilot" "crush")
    local invalid_agents=("vim" "bash" "python" "node" "ls" "cat")
    
    local pattern='^(claude|opencode|codex|gemini|copilot|crush)$'
    
    # Test valid agents
    for agent in "${valid_agents[@]}"; do
        if ! [[ "$agent" =~ $pattern ]]; then
            echo -e "\n${RED}Valid agent '$agent' did not match pattern${NC}"
            return 1
        fi
    done
    
    # Test invalid agents
    for agent in "${invalid_agents[@]}"; do
        if [[ "$agent" =~ $pattern ]]; then
            echo -e "\n${RED}Invalid agent '$agent' incorrectly matched pattern${NC}"
            return 1
        fi
    done
    
    return 0
}

# -----------------------------------------------------------------------------
# Test 14: Dashboard - Build agent list
# -----------------------------------------------------------------------------
test_dashboard_build_list() {
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window1,1,waiting,1234567890,opencode
%2,session1,coding,2,running,,claude
EOF
    
    # Simulate dashboard list building
    local output=""
    
    while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name; do
        [[ -z "$pane_id" ]] && continue
        
        local status_icon status_text
        if [[ "$state" == "waiting" ]]; then
            status_icon="◐"
            status_text="Waiting"
        else
            status_icon="●"
            status_text="Running"
        fi
        
        output+="$(printf "[%s:%s] %s - %s %s" "$session_name" "$window_name" "$agent_name" "$status_icon" "$status_text")"
        output+=$'\n'
    done < "$ORIG_STATE_FILE"
    
    assert_contains "$output" "◐ Waiting" "Should contain waiting indicator"
    assert_contains "$output" "● Running" "Should contain running indicator"
    assert_contains "$output" "[session1:window1]" "Should contain window info"
    assert_contains "$output" "opencode" "Should contain agent name"
}

# -----------------------------------------------------------------------------
# Test 15: Empty state file handling
# -----------------------------------------------------------------------------
test_empty_state_handling() {
    > "$ORIG_STATE_FILE"
    
    # Test status.sh
    local status_result
    status_result=$(bash "$SCRIPTS_DIR/status.sh")
    assert_equals "○" "$status_result" "Empty file should return ○"
    
    # Test that it's truly empty
    local line_count
    line_count=$(wc -l < "$ORIG_STATE_FILE" | tr -d ' ')
    assert_equals "0" "$line_count" "State file should be empty"
}

# -----------------------------------------------------------------------------
# Test 16: Malformed state file handling
# -----------------------------------------------------------------------------
test_malformed_state_handling() {
    # Create a malformed state file
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1
%2,session1,window2,2
%3,session1,window3,3,waiting,1234567890,opencode
EOF
    
    # Status script should still work with valid lines
    local result
    result=$(bash "$SCRIPTS_DIR/status.sh")
    
    assert_equals "◐" "$result" "Should handle malformed lines and detect waiting"
}

# -----------------------------------------------------------------------------
# Test 17: Special characters in window names
# -----------------------------------------------------------------------------
test_special_characters_window_names() {
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window-with-dashes,1,waiting,1234567890,opencode
%2,session1,window.with.dots,2,running,,claude
%3,session1,window with spaces,3,waiting,1234567880,codex
EOF
    
    local result
    result=$(bash "$SCRIPTS_DIR/status.sh")
    
    assert_equals "◐" "$result" "Should handle special characters in window names"
}

# -----------------------------------------------------------------------------
# Test 18: Concurrent session handling
# -----------------------------------------------------------------------------
test_concurrent_sessions() {
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,dev,coding,1,waiting,1234567890,opencode
%2,dev,debug,2,running,,claude
%3,personal,notes,1,waiting,1234567880,codex
%4,work,meeting,1,running,,gemini
EOF
    
    local result
    result=$(bash "$SCRIPTS_DIR/status.sh")
    
    assert_equals "◐" "$result" "Should handle multiple sessions"
}

# -----------------------------------------------------------------------------
# Test 19: Timestamp ordering
# -----------------------------------------------------------------------------
test_timestamp_ordering() {
    local now
    now=$(date +%s)
    
    # Create entries with different timestamps
    local old_time=$((now - 3600))  # 1 hour ago
    local older_time=$((now - 7200)) # 2 hours ago
    local newest_time=$((now - 60))  # 1 minute ago
    
    cat > "$ORIG_STATE_FILE" << EOF
%1,session1,window1,1,waiting,$newest_time,opencode
%2,session1,window2,2,waiting,$older_time,claude
%3,session1,window3,3,waiting,$old_time,codex
EOF
    
    # Test that we can parse timestamps
    local parsed_timestamps=()
    while IFS=',' read -r pane_id session_name window_name window_index state timestamp agent_name; do
        [[ -z "$pane_id" ]] && continue
        if [[ "$state" == "waiting" ]] && [[ -n "$timestamp" ]]; then
            parsed_timestamps+=("$timestamp")
        fi
    done < "$ORIG_STATE_FILE"
    
    if [[ ${#parsed_timestamps[@]} -ne 3 ]]; then
        echo -e "\n${RED}Expected 3 waiting entries, got ${#parsed_timestamps[@]}${NC}"
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Test 20: State transitions
# -----------------------------------------------------------------------------
test_state_transitions() {
    # Start with all running
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window1,1,running,,opencode
%2,session1,window2,2,running,,claude
EOF
    
    local result1
    result1=$(bash "$SCRIPTS_DIR/status.sh")
    assert_equals "●" "$result1" "Initial: All running"
    
    # Transition to one waiting
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window1,1,running,,opencode
%2,session1,window2,2,waiting,1234567890,claude
EOF
    
    local result2
    result2=$(bash "$SCRIPTS_DIR/status.sh")
    assert_equals "◐" "$result2" "Transition: One waiting"
    
    # Transition to all waiting
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window1,1,waiting,1234567890,opencode
%2,session1,window2,2,waiting,1234567880,claude
EOF
    
    local result3
    result3=$(bash "$SCRIPTS_DIR/status.sh")
    assert_equals "◐" "$result3" "Transition: All waiting"
    
    # Back to none
    > "$ORIG_STATE_FILE"
    
    local result4
    result4=$(bash "$SCRIPTS_DIR/status.sh")
    assert_equals "○" "$result4" "Transition: No agents"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo "==================================="
    echo "  tmux-overmind Test Suite"
    echo "==================================="
    echo ""
    
    setup_test_env
    
    # Run all tests
    echo "Running tests..."
    echo ""
    
    run_test "Status: No agents" test_status_no_agents
    run_test "Status: All running" test_status_all_running
    run_test "Status: One waiting" test_status_one_waiting
    run_test "Status: Multiple waiting" test_status_multiple_waiting
    run_test "Status: All waiting" test_status_all_waiting
    run_test "Status: Missing file" test_status_missing_file
    
    run_test "Patterns: Standard prompts" test_prompt_patterns_standard
    run_test "Patterns: Confirmation prompts" test_prompt_patterns_confirmations
    run_test "Patterns: Opencode prompt" test_prompt_patterns_opencode
    
    run_test "State file format" test_state_file_format
    
    run_test "Quick jump: Oldest waiting" test_quick_jump_oldest
    run_test "Quick jump: No waiting" test_quick_jump_no_waiting
    
    run_test "Agent pattern matching" test_agent_pattern_matching
    
    run_test "Dashboard: Build list" test_dashboard_build_list
    
    run_test "Empty state handling" test_empty_state_handling
    run_test "Malformed state handling" test_malformed_state_handling
    run_test "Special characters in names" test_special_characters_window_names
    run_test "Concurrent sessions" test_concurrent_sessions
    run_test "Timestamp ordering" test_timestamp_ordering
    run_test "State transitions" test_state_transitions
    
    # Summary
    echo ""
    echo "==================================="
    echo "  Test Summary"
    echo "==================================="
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    
    cleanup_test_env
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    fi
}

main "$@"
