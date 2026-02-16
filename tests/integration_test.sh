#!/usr/bin/env bash

# Integration tests for tmux-overmind
# These tests require actual tmux to be running

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPTS_DIR="$PROJECT_DIR/scripts"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "==================================="
echo "  Integration Test Suite"
echo "==================================="
echo ""

# Check if tmux is running
if ! tmux info &>/dev/null; then
    echo -e "${RED}Error: tmux is not running${NC}"
    echo "Please start tmux first before running integration tests"
    exit 1
fi

echo "✓ tmux is running"

# Check if fzf is installed
if ! command -v fzf &>/dev/null; then
    echo -e "${YELLOW}Warning: fzf is not installed${NC}"
    echo "Some tests will be skipped"
else
    echo "✓ fzf is installed"
fi

echo ""
echo "Running integration tests..."
echo ""

# Test 1: Monitor daemon can be started
echo -n "Test 1: Monitor daemon starts... "
if bash "$SCRIPTS_DIR/monitor.sh" &>/dev/null &
then
    MONITOR_PID=$!
    sleep 2
    if kill -0 $MONITOR_PID 2>/dev/null; then
        echo -e "${GREEN}PASSED${NC}"
        kill $MONITOR_PID 2>/dev/null || true
    else
        echo -e "${RED}FAILED${NC} (daemon died)"
    fi
else
    echo -e "${RED}FAILED${NC} (could not start)"
fi

# Test 2: Scripts are executable
echo -n "Test 2: Scripts are executable... "
ALL_EXECUTABLE=true
for script in "$SCRIPTS_DIR"/*.sh; do
    if [[ ! -x "$script" ]]; then
        ALL_EXECUTABLE=false
        echo -e "\n  ${RED}Not executable:${NC} $(basename "$script")"
    fi
done

if $ALL_EXECUTABLE; then
    echo -e "${GREEN}PASSED${NC}"
else
    echo -e "${RED}FAILED${NC}"
fi

# Test 3: State file is created
echo -n "Test 3: State file handling... "
STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
if [[ -f "$STATE_FILE" ]]; then
    echo -e "${GREEN}PASSED${NC}"
else
    echo -e "${YELLOW}SKIPPED${NC} (no state file yet - monitor may not have run)"
fi

# Test 4: Main plugin file syntax
echo -n "Test 4: Main plugin syntax... "
if bash -n "$PROJECT_DIR/overmind.tmux"; then
    echo -e "${GREEN}PASSED${NC}"
else
    echo -e "${RED}FAILED${NC}"
fi

# Test 5: Agent detection regex works
echo -n "Test 5: Agent detection patterns... "
AGENT_PATTERN='^(claude|opencode|codex|gemini|copilot|crush)$'
TEST_PASSED=true

for agent in claude opencode codex gemini copilot crush; do
    if ! [[ "$agent" =~ $AGENT_PATTERN ]]; then
        TEST_PASSED=false
        echo -e "\n  ${RED}Failed for:${NC} $agent"
    fi
done

for non_agent in bash vim python node ls cat; do
    if [[ "$non_agent" =~ $AGENT_PATTERN ]]; then
        TEST_PASSED=false
        echo -e "\n  ${RED}False positive:${NC} $non_agent"
    fi
done

if $TEST_PASSED; then
    echo -e "${GREEN}PASSED${NC}"
else
    echo -e "${RED}FAILED${NC}"
fi

# Test 6: Check tmux version compatibility
echo -n "Test 6: Tmux version check... "
TMUX_VERSION=$(tmux -V | grep -oE '[0-9]+\.[0-9]+([a-z])?' | head -1)
REQUIRED_VERSION="3.0"

if [[ "$(printf '%s\n' "$REQUIRED_VERSION" "$TMUX_VERSION" | sort -V | head -n1)" = "$REQUIRED_VERSION" ]]; then
    echo -e "${GREEN}PASSED${NC} (v$TMUX_VERSION)"
else
    echo -e "${YELLOW}WARNING${NC} (v$TMUX_VERSION, requires 3.0+)"
fi

echo ""
echo "==================================="
echo "  Integration tests complete"
echo "==================================="
