#!/usr/bin/env bash
# Contract-test runner for the v4 batch-runner family.
#
# Usage:
#   bash tests/run_contract_tests.sh [name_filter ...]
#
# Environment:
#   KEEP_WORKSPACES=1   Keep the temporary run directory for inspection.
#
# The runner executes every scenario in tests/cases in its own process and its
# own temporary workspace. The runner fails when any scenario fails.

set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/.." && pwd -P)"
CASES_DIR="${TESTS_DIR}/cases"

CONTRACT_TEST_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ucfd-contract-tests.XXXXXXXX")"
export CONTRACT_TEST_RUN_DIR

cleanup() {
    if [[ "${KEEP_WORKSPACES:-0}" == "1" ]]; then
        printf 'Kept test workspace: %s\n' "$CONTRACT_TEST_RUN_DIR"
        return 0
    fi
    # Cleanup targets only the temporary run directory created above.
    case "$CONTRACT_TEST_RUN_DIR" in
        /tmp/*|/var/tmp/*|"${TMPDIR:-/tmp}"/*)
            rm -rf -- "$CONTRACT_TEST_RUN_DIR"
            ;;
        *)
            printf 'Refusing to remove unexpected run directory: %s\n' \
                "$CONTRACT_TEST_RUN_DIR" >&2
            ;;
    esac
}
trap cleanup EXIT

# ---- repository cleanliness snapshot ----------------------------------------

tree_state() {
    git -C "$REPO_ROOT" status --porcelain 2>/dev/null || printf 'git-unavailable\n'
}

TREE_BEFORE="$(tree_state)"

# ---- case selection ----------------------------------------------------------

mapfile -t CASE_FILES < <(find "$CASES_DIR" -maxdepth 1 -type f -name '*.sh' | sort)

if (( $# > 0 )); then
    SELECTED=()
    for case_file in "${CASE_FILES[@]}"; do
        for filter in "$@"; do
            if [[ "$(basename -- "$case_file")" == *"$filter"* ]]; then
                SELECTED+=("$case_file")
                break
            fi
        done
    done
    CASE_FILES=("${SELECTED[@]}")
fi

(( ${#CASE_FILES[@]} > 0 )) || {
    printf 'No contract-test cases selected.\n' >&2
    exit 1
}

# ---- execution ---------------------------------------------------------------

PASSED=0
FAILED=0
FAILED_NAMES=()

printf '== v4 batch-runner contract tests ==\n'
printf 'Repository : %s\n' "$REPO_ROOT"
printf 'Workspace  : %s\n' "$CONTRACT_TEST_RUN_DIR"
printf 'Scenarios  : %s\n\n' "${#CASE_FILES[@]}"

for case_file in "${CASE_FILES[@]}"; do
    case_name="$(basename -- "$case_file" .sh)"
    log_file="${CONTRACT_TEST_RUN_DIR}/${case_name}.log"

    printf '%-46s ' "$case_name"

    if env \
        CONTRACT_TEST_RUN_DIR="$CONTRACT_TEST_RUN_DIR" \
        CONTRACT_TEST_NAME="$case_name" \
        bash "$case_file" > "$log_file" 2>&1
    then
        printf 'PASS\n'
        PASSED=$(( PASSED + 1 ))
    else
        printf 'FAIL\n'
        FAILED=$(( FAILED + 1 ))
        FAILED_NAMES+=("$case_name")
        printf -- '---- %s output ----\n' "$case_name"
        sed -e 's/^/    /' "$log_file"
        printf -- '---- end %s ----\n' "$case_name"
    fi
done

# ---- repository cleanliness check -------------------------------------------

TREE_AFTER="$(tree_state)"
TREE_CLEAN=1
if [[ "$TREE_BEFORE" != "$TREE_AFTER" ]]; then
    TREE_CLEAN=0
    printf '\nRepository working tree changed during the suite.\n' >&2
    printf 'Before:\n%s\n' "$TREE_BEFORE" >&2
    printf 'After:\n%s\n' "$TREE_AFTER" >&2
fi

printf '\nPassed: %s\nFailed: %s\n' "$PASSED" "$FAILED"

if (( FAILED > 0 )); then
    printf 'Failed scenarios: %s\n' "${FAILED_NAMES[*]}" >&2
    exit 1
fi

(( TREE_CLEAN == 1 )) || exit 1

printf 'All contract scenarios passed.\n'
