# implement-issue-orchestrator Tests

BATS (Bash Automated Testing System) test suite for `implement-issue-orchestrator.sh`.

## Prerequisites

```bash
# macOS
brew install bats-core jq

# Ubuntu/Debian
sudo apt install bats jq

# Or via npm (bats only)
npm install -g bats
```

## Running Tests

```bash
# Run all tests
./run-tests.sh

# Run specific test file
./run-tests.sh test-argument-parsing.bats

# Verbose output
./run-tests.sh --verbose

# TAP format output
./run-tests.sh --tap
```

## Test Files

| File | Description |
|------|-------------|
| `test-argument-parsing.bats` | CLI argument validation (--issue, --branch, --agent, etc.) |
| `test-status-functions.bats` | Status file management (init, update, stages, tasks) |
| `test-rate-limit.bats` | Rate limit detection and wait time extraction |
| `test-stage-runner.bats` | Stage execution, schema validation, logging |
| `test-quality-loop.bats` | Quality loop iteration and flow control |
| `test-constants.bats` | Configuration constants and defaults |
| `test-integration.bats` | Full workflow structure verification |

## Directory Structure

```
implement-issue-test/
├── README.md                    # This file
├── run-tests.sh                 # Test runner script
├── helpers/
│   └── test-helper.bash         # Common setup/teardown/assertions
├── fixtures/
│   ├── setup-success.json       # Mock Claude responses
│   ├── setup-error.json
│   ├── implement-success.json
│   ├── test-passed.json
│   ├── test-failed.json
│   ├── review-approved.json
│   ├── review-changes-requested.json
│   ├── task-review-passed.json
│   ├── task-review-improvements.json
│   ├── pr-success.json
│   └── rate-limit.json
└── test-*.bats                  # Test files
```

## Writing New Tests

### Basic Test Structure

```bash
#!/usr/bin/env bats

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    # Additional setup...
}

teardown() {
    teardown_test_env
}

@test "description of what is being tested" {
    # Arrange
    local input="test value"

    # Act
    run some_function "$input"

    # Assert
    [ "$status" -eq 0 ]
    [[ "$output" == *"expected"* ]]
}
```

### Available Helpers

**Setup/Teardown:**
- `setup_test_env` - Create isolated temp directory
- `teardown_test_env` - Clean up temp directory
- `install_mocks` - Install mock `claude` and `gh` binaries
- `source_orchestrator_functions` - Load functions without running main

**Assertions:**
- `assert_file_exists <file>`
- `assert_dir_exists <dir>`
- `assert_file_contains <file> <pattern>`
- `assert_json_field <file> <jq-path> <expected>`
- `assert_exit_code <actual> <expected>`
- `assert_equals <actual> <expected>`
- `assert_contains <haystack> <needle>`
- `assert_not_empty <value>`

### Using Fixtures

```bash
@test "handles successful setup response" {
    export MOCK_CLAUDE_RESPONSE="$TEST_DIR/fixtures/setup-success.json"
    run run_stage "setup" "prompt" "implement-issue-setup.json"
    # Assertions...
}
```

## Test Coverage

The test suite covers:

- **Argument Parsing**: Required/optional args, validation, help text
- **Status Management**: Init, stage updates, task tracking, iteration counters
- **Rate Limiting**: Detection patterns, wait time extraction
- **Stage Execution**: Schema loading, output extraction, timeout handling
- **Quality Loop**: Iteration tracking, test/review flow, max iterations
- **Integration**: Stage sequence, agent selection, error handling

## CI Integration

```yaml
# GitHub Actions example
- name: Run orchestrator tests
  run: |
    cd .claude/scripts/implement-issue-test
    ./run-tests.sh --tap
```
