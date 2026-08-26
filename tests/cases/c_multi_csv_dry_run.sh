#!/usr/bin/env bash
# Section 23.C - top-level multi-CSV dry-run.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

workspace="$(new_workspace dryrun)"
use_stub_records "$workspace"

master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
mkdir -p "$output"

make_csv "${workspace}/output_batch_1.csv" 0 1
make_csv "${workspace}/output_batch_2.csv" 0 1

out="$(bash "$RUN_BATCH" --dry-run -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "multi-CSV dry-run must succeed: $out"

# Two unique batches.
assert_contains "$out" "Batch count     : 2" "dry-run reports two batches"
assert_contains "$out" "DRY-RUN batch_1" "dry-run plans batch_1"
assert_contains "$out" "DRY-RUN batch_2" "dry-run plans batch_2"

# Canonical stage order for the default pipeline.
assert_contains "$out" \
    "Selected stages : setup -> mesh -> flow -> transport -> post-processing" \
    "dry-run prints the canonical stage order"

# No CFD stage execution.
assert_contains "$out" "DRY-RUN complete. No simulations were run." \
    "dry-run states that no simulation ran"
assert_file_missing "${STUB_RECORD_DIR}/stubs.log" \
    "no stage script runs during a dry-run"

# A dry-run must not create the destination workspaces.
assert_dir_missing "${output}/batch_1" "dry-run does not create batch_1"
assert_dir_missing "${output}/batch_2" "dry-run does not create batch_2"
