# tmux-overmind Tests

## Running

```bash
bash tests/test_suite.sh
```

## Coverage

74 unit tests covering:

- **Script syntax** (bash -n) for all 5 scripts
- **File permissions** (executable bit)
- **Status indicator** (9 scenarios: empty, running, waiting, idle, mixed)
- **Busy detection** (12 patterns: spinners, interrupt text, whimsical words, tool-specific)
- **Waiting/prompt detection** (15 patterns: bare prompts, permission dialogs, Y/n, tool-specific)
- **ANSI stripping** (4 cases: color codes, complex codes, DEC private modes, plain text)
- **Quick jump logic** (4 scenarios: FIFO ordering, idle exclusion)
- **Agent pattern matching** (14 cases: valid agents, non-agents, partial matches)
- **Dashboard list building** (3 format checks)
- **Edge cases** (3: special chars, long names, empty CSV fields)

No tmux server required.
