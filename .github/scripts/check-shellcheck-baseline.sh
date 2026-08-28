#!/usr/bin/env bash
#
# Baseline-aware ShellCheck gate for the run-batch package (Issue #19, I-A).
#
# The gate does not fix or suppress an existing ShellCheck finding. The gate
# compares the current normalized diagnostics with a committed baseline and
# fails when the two differ. A new, removed, moved, or changed diagnostic
# fails the comparison.
#
# The gate checks the six batch-runner scripts only. A scope change or a
# ShellCheck version change requires a separate bounded Issue.

set -Eeuo pipefail
export LC_ALL=C

REQUIRED_VERSION="0.9.0"

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BASELINE_FILE="${REPO_ROOT}/.github/shellcheck-baseline.gcc"

CHECKED_FILES=(
    "src/run_batch.sh"
    "src/master_batch/setup_cases.sh"
    "src/master_batch/run_mesh_cases.sh"
    "src/master_batch/run_flow_cases.sh"
    "src/master_batch/run_transport_cases.sh"
    "src/master_batch/run_post_processing_cases.sh"
)

die() {
    printf 'shellcheck-baseline: ERROR: %s\n' "$*" >&2
    exit 1
}

CURRENT_FILE=""

# The EXIT trap keeps the command status when cleanup succeeds. A failed
# removal of the temporary diagnostic file makes the final status non-zero
# (Issue #19 failure behavior).
cleanup() {
    local status=$?
    if [[ -n "$CURRENT_FILE" && -f "$CURRENT_FILE" ]]; then
        if ! rm -f -- "$CURRENT_FILE"; then
            printf 'shellcheck-baseline: ERROR: could not remove the temporary diagnostic file %s\n' \
                "$CURRENT_FILE" >&2
            if (( status == 0 )); then
                status=1
            fi
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

# ---- ShellCheck availability and exact version ------------------------------

command -v shellcheck >/dev/null 2>&1 ||
    die "shellcheck is not installed or is not in PATH."

version_output=""
version_output="$(shellcheck --version 2>&1)" ||
    die "'shellcheck --version' failed."

actual_version="$(
    printf '%s\n' "$version_output" |
        awk '$1 == "version:" { print $2; exit }'
)"

[[ -n "$actual_version" ]] ||
    die "Could not read a version from 'shellcheck --version'."

if [[ "$actual_version" != "$REQUIRED_VERSION" ]]; then
    die "ShellCheck version must be ${REQUIRED_VERSION}; found ${actual_version}. A version change requires a separate bounded Issue that regenerates and reviews the baseline."
fi

printf 'shellcheck-baseline: ShellCheck version %s\n' "$actual_version"

# ---- Complete file scope ----------------------------------------------------

missing=()
for checked in "${CHECKED_FILES[@]}"; do
    [[ -f "${REPO_ROOT}/${checked}" ]] || missing+=("$checked")
done

if (( ${#missing[@]} > 0 )); then
    die "ShellCheck cannot analyze the complete file scope. Missing: ${missing[*]}"
fi

[[ -f "$BASELINE_FILE" ]] ||
    die "Baseline file not found: ${BASELINE_FILE#"${REPO_ROOT}/"}"

# ---- Analysis ---------------------------------------------------------------

CURRENT_FILE="$(mktemp)" ||
    die "Could not create the temporary diagnostic file."

cd -- "$REPO_ROOT" ||
    die "Could not enter the repository root: $REPO_ROOT"

# ShellCheck exit 0 means no diagnostic. Exit 1 means it reported diagnostics.
# Both are valid analysis results. Any other status is an execution error.
shellcheck_status=0
shellcheck --format=gcc "${CHECKED_FILES[@]}" > "$CURRENT_FILE" ||
    shellcheck_status=$?

if (( shellcheck_status != 0 && shellcheck_status != 1 )); then
    printf 'shellcheck-baseline: shellcheck output before the error:\n' >&2
    cat -- "$CURRENT_FILE" >&2 || true
    die "ShellCheck returned execution-error status ${shellcheck_status}."
fi

sort -o "$CURRENT_FILE" "$CURRENT_FILE" ||
    die "Could not normalize the ShellCheck diagnostics."

current_count="$(wc -l < "$CURRENT_FILE")"
baseline_count="$(wc -l < "$BASELINE_FILE")"

printf 'shellcheck-baseline: current diagnostics (%s):\n' "$current_count"
cat -- "$CURRENT_FILE"
printf '\n'

# ---- Exact comparison -------------------------------------------------------

if ! diff -u "$BASELINE_FILE" "$CURRENT_FILE" \
        --label "baseline (${baseline_count})" \
        --label "current (${current_count})"; then
    printf '\n' >&2
    die "The current ShellCheck diagnostics differ from the committed baseline. Do not suppress a finding. An authorized finding correction must update .github/shellcheck-baseline.gcc in the same bounded change."
fi

printf 'shellcheck-baseline: OK. %s accepted baseline diagnostics. No new finding.\n' \
    "$current_count"
