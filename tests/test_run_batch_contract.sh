#!/usr/bin/env bash
# Focused Issue #5 regression tests for the top-level run_batch.sh contract.
#
# Covered requirements:
#   * v4 Section 7.1  - overwrite removes every existing destination, empty or
#                       non-empty, before template initialization.
#   * v4 Section 19   - successful and failed batches report elapsed time, and
#                       a failure path returns the original failure status.
#   * v4 Section 23.E - overwrite safety.
#   * v4 Section 23.P - sequential and parallel batch failure compatibility.
#
# Usage:
#   bash tests/test_run_batch_contract.sh
set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Standalone run directory. The file reuses the shared harness libraries.
CONTRACT_TEST_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ucfd-run-batch-focus.XXXXXXXX")"
CONTRACT_TEST_NAME="run_batch_focus"
export CONTRACT_TEST_RUN_DIR CONTRACT_TEST_NAME

cleanup() {
    case "$CONTRACT_TEST_RUN_DIR" in
        /tmp/*|/var/tmp/*|"${TMPDIR:-/tmp}"/*) rm -rf -- "$CONTRACT_TEST_RUN_DIR" ;;
    esac
}
trap cleanup EXIT

source "${TESTS_DIR}/lib/harness.sh"
source "${TESTS_DIR}/lib/assert.sh"

set -e

PASS_COUNT=0
report() { PASS_COUNT=$(( PASS_COUNT + 1 )); printf 'PASS %s\n' "$1"; }

# new_fixture <name> - one stub master, one output root, one CSV.
new_fixture() {
    local name="$1"
    workspace="$(new_workspace "$name")"
    use_stub_records "$workspace"
    master="${workspace}/master_batch"
    output="${workspace}/out"
    make_stub_master "$master" master
    mkdir -p "$output"
    make_csv "${workspace}/output_batch_1.csv" 0
}

# ---- 1. empty destination + setup + overwrite -> replaced ---------------------

new_fixture empty_overwrite
mkdir -p "${output}/batch_1"

out="$(bash "$RUN_BATCH" --stage setup --overwrite -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "overwrite over an empty destination must succeed: $out"
assert_contains "$out" "Overwrite enabled: removing ${output}/batch_1" \
    "the empty destination is removed before initialization"
assert_file_exists "${output}/batch_1/setup_cases.sh" \
    "the batch is initialized from the master template"
assert_file_exists "${output}/batch_1/output_batch_1.csv" \
    "the source CSV is copied into the batch"
report "test_empty_destination_overwrite_replaced"

# The removal line must appear before the template-copy line.
removal_line="$(printf '%s\n' "$out" | grep -n "Overwrite enabled: removing" | head -1 | cut -d: -f1)"
copy_line="$(printf '%s\n' "$out" | grep -n "Copy template" | head -1 | cut -d: -f1)"
[[ -n "$removal_line" && -n "$copy_line" && "$removal_line" -lt "$copy_line" ]] ||
    _fail "removal must occur before template initialization" \
        "removal line: $removal_line" "copy line: $copy_line"
report "test_removal_precedes_template_copy"

# ---- 2. non-empty destination + setup + overwrite -> replaced -----------------

new_fixture nonempty_overwrite
mkdir -p "${output}/batch_1"
printf 'stale\n' > "${output}/batch_1/stale.txt"

out="$(bash "$RUN_BATCH" --stage setup --overwrite -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "overwrite over a non-empty destination must succeed: $out"
assert_file_missing "${output}/batch_1/stale.txt" "the stale payload is removed"
report "test_nonempty_destination_overwrite_replaced"

# ---- 3. non-empty destination + setup without overwrite -> fail ---------------

new_fixture nonempty_reject
mkdir -p "${output}/batch_1"
printf 'keep\n' > "${output}/batch_1/keep.txt"

out="$(bash "$RUN_BATCH" --stage setup -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_failure "$status" "setup into a non-empty destination without overwrite must fail"
assert_file_exists "${output}/batch_1/keep.txt" "the existing payload is kept"
report "test_nonempty_destination_without_overwrite_fails"

# ---- 4. no-setup mode + overwrite -> fail --------------------------------------

new_fixture nosetup_overwrite
mkdir -p "${output}/batch_1"
cp "${workspace}/output_batch_1.csv" "${output}/batch_1/output_batch_1.csv"

out="$(bash "$RUN_BATCH" --stage mesh --overwrite -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_failure "$status" "no-setup mode must reject --overwrite"
assert_contains "$out" "--overwrite cannot be used when setup is not selected" \
    "the rejection explains the no-setup overwrite rule"
report "test_no_setup_overwrite_rejected"

# ---- 5. successful batch reports elapsed time ---------------------------------

new_fixture success_elapsed

out="$(bash "$RUN_BATCH" --stage setup -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "the successful batch must succeed: $out"
printf '%s\n' "$out" |
    grep -Eq 'Batch finished  : batch_1 \([0-9]{2}:[0-9]{2}:[0-9]{2}\)' ||
    _fail "a successful batch reports elapsed time" "output:" "$out"
report "test_success_elapsed_time_logged"

# ---- 6. failed batch reports elapsed time and the original status -------------

new_fixture failure_elapsed

out="$(STUB_FAIL_STAGES="mesh" bash "$RUN_BATCH" --stage setup,mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

# The stage stub exits 3. The original status must survive to the caller.
assert_status 3 "$status" "the original stage failure status is preserved"
printf '%s\n' "$out" |
    grep -Eq 'Batch failed    : batch_1 \(exit=3, elapsed=[0-9]{2}:[0-9]{2}:[0-9]{2}\)' ||
    _fail "a failed batch reports elapsed time and the original exit code" \
        "output:" "$out"
report "test_failure_elapsed_time_and_status_logged"

# ---- 7. sequential and parallel failure behavior stays compatible -------------

new_fixture sequential_failure
make_csv "${workspace}/output_batch_2.csv" 0

out="$(STUB_FAIL_STAGES="mesh:1" bash "$RUN_BATCH" --stage setup,mesh \
        -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a sequential run must stop after the first failed batch"
assert_contains "$out" "Stop after first failed batch" \
    "the sequential stop message is kept"
if stub_ran setup 2; then
    _fail "batch_2 must not start after a sequential failure without --keep-going"
fi
report "test_sequential_failure_compatible"

new_fixture parallel_failure
make_csv "${workspace}/output_batch_2.csv" 0

out="$(STUB_FAIL_STAGES="mesh:1" bash "$RUN_BATCH" --stage setup,mesh \
        --keep-going -B 2 -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a parallel run with one failed batch must stay non-zero"
stub_ran mesh 2 || _fail "--keep-going in parallel mode attempts batch_2"
printf '%s\n' "$out" |
    grep -Eq 'Batch failed    : batch_1 \(exit=3, elapsed=[0-9]{2}:[0-9]{2}:[0-9]{2}\)' ||
    _fail "the parallel failed batch reports elapsed time and exit code" \
        "output:" "$out"
report "test_parallel_failure_compatible"

printf '\nAll %s focused run_batch contract tests passed.\n' "$PASS_COUNT"
