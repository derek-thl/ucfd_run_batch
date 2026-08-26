#!/usr/bin/env bash
# Section 23.D - input order must not control execution order.
#
# The reuse workspace must exist and must not be empty before the stage-order
# preflight runs, because setup is not selected.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

workspace="$(new_workspace ordering)"
use_stub_records "$workspace"

master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
mkdir -p "$output"

make_csv "${workspace}/output_batch_1.csv" 0 1

# Required non-empty reuse workspace.
mkdir -p "${output}/batch_1"
cp "${workspace}/output_batch_1.csv" "${output}/batch_1/output_batch_1.csv"
assert_file_exists "${output}/batch_1/output_batch_1.csv" \
    "the reuse workspace is not empty before preflight"

out="$(bash "$RUN_BATCH" --dry-run --stage transport,mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "stage-order dry-run must succeed: $out"
assert_contains "$out" "Selected stages : mesh -> transport" \
    "canonical order is mesh -> transport"
assert_not_contains "$out" "transport -> mesh" \
    "input order must not control execution order"
assert_contains "$out" "Workspace mode  : reuse existing batch directories" \
    "a run without setup reuses the existing batch directory"

# The repeated --stage form must produce the same canonical order.
out_repeated="$(bash "$RUN_BATCH" --dry-run --stage transport --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?
assert_status 0 "$status" "repeated --stage dry-run must succeed: $out_repeated"
assert_contains "$out_repeated" "Selected stages : mesh -> transport" \
    "repeated --stage keeps the canonical order"
