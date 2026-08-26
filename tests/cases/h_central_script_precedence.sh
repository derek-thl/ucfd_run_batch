#!/usr/bin/env bash
# Section 23.H - the master stage script wins over a batch-local copy.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

workspace="$(new_workspace precedence)"
use_stub_records "$workspace"

master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
mkdir -p "${output}/batch_1"

make_csv "${output}/batch_1/output_batch_1.csv" 0
cp "${output}/batch_1/output_batch_1.csv" "${workspace}/output_batch_1.csv"

# A stale batch-local copy of the transport stage script.
make_stub_script "${output}/batch_1/run_transport_cases.sh" batch

out="$(bash "$RUN_BATCH" --stage transport -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "transport-only mode must succeed: $out"
stub_ran transport 1 || _fail "the transport stage ran"
assert_eq "master" "$(stub_origin transport 1)" \
    "the master transport script executes, not the batch-local copy"
assert_contains "$out" "Stage source  : ${master}/run_transport_cases.sh" \
    "the run reports the master stage-script source"

# The fallback still works when the master directory has no transport script.
workspace="$(new_workspace fallback)"
use_stub_records "$workspace"
master="${workspace}/master_batch"
output="${workspace}/out"
mkdir -p "$master" "${output}/batch_1"
make_csv "${output}/batch_1/output_batch_1.csv" 0
cp "${output}/batch_1/output_batch_1.csv" "${workspace}/output_batch_1.csv"
make_stub_script "${output}/batch_1/run_transport_cases.sh" batch

out="$(bash "$RUN_BATCH" --stage transport -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "batch-local fallback must succeed: $out"
assert_eq "batch" "$(stub_origin transport 1)" \
    "the batch-local script runs when the master copy is absent"
