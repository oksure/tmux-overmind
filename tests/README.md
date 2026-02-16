# tmux-overmind Test Suite

Comprehensive test suite for tmux-overmind plugin.

## Test Files

### 1. `test_suite.sh` - Unit Tests (20 tests)
Core functionality tests that don't require tmux to be running:

- **Status indicator tests**: ○, ●, ◐ for various states
- **Prompt pattern tests**: Detection of >, ?, ❯, ⬝, (Y/n), etc.
- **State file format validation**
- **Quick jump logic tests**
- **Agent pattern matching**
- **Dashboard list building**
- **Empty/malformed file handling**
- **Special characters and edge cases**
- **State transitions**

### 2. `integration_test.sh` - Integration Tests (6 tests)
Tests that require actual tmux to be running:

- Monitor daemon startup
- Script executability
- State file handling
- Main plugin syntax
- Agent detection patterns
- Tmux version compatibility

### 3. `edge_cases.sh` - Edge Case Tests (12 tests)
Stress tests for unusual scenarios:

- Very long window names (500+ chars)
- Unicode in session/window names
- Empty fields in CSV
- Special regex characters
- Old/future timestamps
- CRLF line endings
- Many agents (100+)
- Files without trailing newlines

## Running Tests

### Run all tests:
```bash
cd tests
./test_suite.sh && ./integration_test.sh && ./edge_cases.sh
```

### Run individual suites:
```bash
# Unit tests only
./test_suite.sh

# Integration tests (requires tmux)
./integration_test.sh

# Edge cases
./edge_cases.sh
```

### Check syntax:
```bash
bash -n ../scripts/*.sh
bash -n ../overmind.tmux
```

## CI/CD

GitHub Actions workflow (`.github/workflows/tests.yml`) runs:
1. Unit test suite
2. ShellCheck static analysis
3. Syntax validation

## Adding New Tests

### Unit test template:
```bash
test_your_feature() {
    # Setup
    cat > "$ORIG_STATE_FILE" << 'EOF'
%1,session1,window1,1,waiting,1234567890,opencode
EOF
    
    # Execute
    local result
    result=$(bash "$SCRIPTS_DIR/status.sh")
    
    # Assert
    assert_equals "◐" "$result" "Expected half-circle"
}

# Register test
run_test "Your feature name" test_your_feature
```

### Edge case template:
```bash
run_test "Test description" '
    STATE_FILE="${TMPDIR:-/tmp}/tmux-overmind-state.csv"
    # setup
    echo "data" > "$STATE_FILE"
    # test
    result=$(bash "$SCRIPTS_DIR/status.sh")
    [[ "$result" == "◐" ]]
'
```

## Test Results Summary

- **Total tests**: 38
- **Unit tests**: 20
- **Integration tests**: 6  
- **Edge cases**: 12
- **Expected pass rate**: 100%

## Troubleshooting

### Tests fail with "state file not found"
The tests create a temporary state file. Make sure you have write permissions to `$TMPDIR` (usually `/tmp`).

### Integration tests fail
Integration tests require:
- tmux to be running
- fzf to be installed (for some tests)

### Color output issues
If colors aren't displaying correctly, check that your terminal supports ANSI color codes.
