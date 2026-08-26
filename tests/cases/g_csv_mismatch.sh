#!/usr/bin/env bash
# Section 23.G - an external CSV with the same name but different content.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

workspace="$(new_workspace mismatch)"
use_stub_records "$workspace"
make_stub_master "${workspace}/master_batch" master
mkdir -p "${workspace}/out/batch_1" "${workspace}/external"

# The batch was created from this CSV.
make_csv "${workspace}/out/batch_1/output_batch_1.csv" 0 1

# A different external CSV uses the same file name.
make_csv "${workspace}/external/output_batch_1.csv" 7 8

out="$(bash "$RUN_BATCH" --stage mesh -m "${workspace}/master_batch" \
        -o "${workspace}/out" "${workspace}/external/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a CSV mismatch must fail"
assert_contains "$out" "CSV mismatch for existing batch_1" \
    "the failure names the mismatched batch"
assert_not_contains "$out" "Stage start" "no stage starts before the rejection"
assert_file_missing "${STUB_RECORD_DIR}/stubs.log" "no stage script runs"

# An identical external copy must pass the same guard.
cp "${workspace}/out/batch_1/output_batch_1.csv" \
   "${workspace}/external/output_batch_1.csv"

out="$(bash "$RUN_BATCH" --dry-run --stage mesh -m "${workspace}/master_batch" \
        -o "${workspace}/out" "${workspace}/external/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "an identical external CSV must pass: $out"
