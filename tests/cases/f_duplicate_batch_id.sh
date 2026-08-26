#!/usr/bin/env bash
# Section 23.F - two inputs that resolve to one batch ID.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

workspace="$(new_workspace duplicate)"
use_stub_records "$workspace"
make_stub_master "${workspace}/master_batch" master
mkdir -p "${workspace}/out"

# Both filenames resolve to batch ID 1.
make_csv "${workspace}/output_batch_1.csv" 0
make_csv "${workspace}/scenario_batch-1.csv" 0

out="$(bash "$RUN_BATCH" --stage setup -m "${workspace}/master_batch" \
        -o "${workspace}/out" \
        "${workspace}/output_batch_1.csv" "${workspace}/scenario_batch-1.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a duplicate batch ID must fail"
assert_contains "$out" "Duplicate batch destination detected" \
    "the failure names the duplicate destination"

# The rejection must happen during preflight, before any stage starts.
assert_not_contains "$out" "Stage start" "no stage starts before the rejection"
assert_file_missing "${STUB_RECORD_DIR}/stubs.log" "no stage script runs"
assert_dir_missing "${workspace}/out/batch_1" "no batch workspace is created"
