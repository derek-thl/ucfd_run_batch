#!/usr/bin/env bash
# Section 23.E - overwrite safety.
#
# Scope note: the existing-empty-destination removal requirement of
# Specification #3 belongs to Issue #5. This scenario asserts only the
# currently conforming non-empty and no-setup rules.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# new_case <name> - build one isolated overwrite fixture.
# The function sets the global `workspace` so that the exported stub record
# directory stays visible to the assertions in this process.
new_case() {
    local name="$1"
    workspace="$(new_workspace "$name")"
    use_stub_records "$workspace"
    make_stub_master "${workspace}/master_batch" master
    mkdir -p "${workspace}/out"
    make_csv "${workspace}/output_batch_1.csv" 0
}

# 1. Existing non-empty batch + setup + no overwrite -> fail.
new_case reject
mkdir -p "${workspace}/out/batch_1"
printf 'existing payload\n' > "${workspace}/out/batch_1/keep.txt"

out="$(bash "$RUN_BATCH" --stage setup -m "${workspace}/master_batch" \
        -o "${workspace}/out" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "setup into an existing non-empty batch must fail"
assert_contains "$out" "already exists and is not empty" \
    "the failure names the non-empty batch directory"
assert_file_exists "${workspace}/out/batch_1/keep.txt" \
    "a rejected run keeps the existing payload"
assert_file_missing "${STUB_RECORD_DIR}/stubs.log" \
    "no stage runs after an overwrite-safety rejection"

# 2. Existing non-empty batch + setup + --overwrite -> allowed.
new_case allow
mkdir -p "${workspace}/out/batch_1"
printf 'stale payload\n' > "${workspace}/out/batch_1/stale.txt"

out="$(bash "$RUN_BATCH" --stage setup --overwrite -m "${workspace}/master_batch" \
        -o "${workspace}/out" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "--overwrite must replace a non-empty batch: $out"
assert_contains "$out" "Overwrite enabled: removing" \
    "the run reports the overwrite removal"
assert_file_missing "${workspace}/out/batch_1/stale.txt" \
    "overwrite removes the stale payload"
assert_file_exists "${workspace}/out/batch_1/output_batch_1.csv" \
    "overwrite copies the source CSV into the batch"
assert_file_exists "${workspace}/out/batch_1/setup_cases.sh" \
    "overwrite initializes the batch from the master template"
stub_ran setup 1 || _fail "the setup stage runs after a permitted overwrite"

# 3. No setup + --overwrite -> fail.
new_case nosetup
mkdir -p "${workspace}/out/batch_1"
printf 'payload\n' > "${workspace}/out/batch_1/keep.txt"

out="$(bash "$RUN_BATCH" --stage mesh --overwrite -m "${workspace}/master_batch" \
        -o "${workspace}/out" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "--overwrite without setup must fail"
assert_contains "$out" "--overwrite cannot be used when setup is not selected" \
    "the failure explains the no-setup overwrite rule"
assert_file_exists "${workspace}/out/batch_1/keep.txt" \
    "a rejected overwrite keeps the existing batch"

# 4. RUN_BATCH_OVERWRITE=1 is the documented environment equivalent.
new_case envform
mkdir -p "${workspace}/out/batch_1"
printf 'stale payload\n' > "${workspace}/out/batch_1/stale.txt"

out="$(RUN_BATCH_OVERWRITE=1 bash "$RUN_BATCH" --stage setup \
        -m "${workspace}/master_batch" -o "${workspace}/out" \
        "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "RUN_BATCH_OVERWRITE=1 must replace a non-empty batch: $out"
assert_file_missing "${workspace}/out/batch_1/stale.txt" \
    "the environment form removes the stale payload"
