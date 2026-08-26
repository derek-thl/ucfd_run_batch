#!/usr/bin/env bash
# Assertion helpers for the v4 batch-runner contract tests.
#
# Every assertion prints a diagnostic and returns 1 on failure. A test case
# stops at the first failure because the case runner uses `set -e`.

# Unit separator used to join an argument vector into one greppable line.
US=$'\x1f'

_fail() {
    printf 'ASSERT FAIL: %s\n' "$1" >&2
    shift
    local line
    for line in "$@"; do
        printf '  %s\n' "$line" >&2
    done
    return 1
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    [[ "$expected" == "$actual" ]] && return 0
    _fail "$message" "expected: [$expected]" "actual:   [$actual]"
}

assert_ne() {
    local unexpected="$1" actual="$2" message="$3"
    [[ "$unexpected" != "$actual" ]] && return 0
    _fail "$message" "value must differ from: [$unexpected]"
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    [[ "$haystack" == *"$needle"* ]] && return 0
    _fail "$message" "missing substring: [$needle]" "actual text:" "$haystack"
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    [[ "$haystack" != *"$needle"* ]] && return 0
    _fail "$message" "forbidden substring present: [$needle]" "actual text:" "$haystack"
}

assert_file_exists() {
    local path="$1" message="$2"
    [[ -f "$path" ]] && return 0
    _fail "$message" "missing file: $path"
}

assert_file_missing() {
    local path="$1" message="$2"
    [[ ! -e "$path" ]] && return 0
    _fail "$message" "file must not exist: $path"
}

assert_dir_exists() {
    local path="$1" message="$2"
    [[ -d "$path" ]] && return 0
    _fail "$message" "missing directory: $path"
}

assert_dir_missing() {
    local path="$1" message="$2"
    [[ ! -e "$path" ]] && return 0
    _fail "$message" "directory must not exist: $path"
}

# assert_status <expected> <actual> <message>
assert_status() {
    local expected="$1" actual="$2" message="$3"
    [[ "$expected" == "$actual" ]] && return 0
    _fail "$message" "expected exit status: $expected" "actual exit status:   $actual"
}

# assert_failure <actual> <message> - any non-zero status.
assert_failure() {
    local actual="$1" message="$2"
    (( actual != 0 )) && return 0
    _fail "$message" "expected a non-zero exit status; got 0"
}

# assert_help_option <help_text> <option> <message>
# Token-aware option check for help output. A longer option token cannot
# satisfy a shorter option assertion. The option must appear delimited by
# line start, whitespace, or a comma before it, and by whitespace, a comma,
# '=', '<', or line end after it.
assert_help_option() {
    local help_text="$1" option="$2" message="$3"
    if printf '%s\n' "$help_text" |
        grep -Eq "(^|[[:space:]]|,)${option}([[:space:]]|,|=|<|$)"; then
        return 0
    fi
    _fail "$message" "option token not found in help output: [$option]"
}
