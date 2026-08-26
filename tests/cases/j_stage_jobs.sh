#!/usr/bin/env bash
# Section 23.J - stage-specific job counts override the default.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

workspace="$(new_workspace jobs)"
use_stub_records "$workspace"

master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
mkdir -p "$output"
make_csv "${workspace}/output_batch_1.csv" 0

out="$(bash "$RUN_BATCH" -j 4 --mesh-jobs 3 --post-jobs 6 \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the full pipeline with job overrides must succeed: $out"

assert_eq "4" "$(stub_arg_after setup 1 -j)"     "setup uses the default -j 4"
assert_eq "3" "$(stub_arg_after mesh 1 -j)"      "mesh uses the --mesh-jobs override"
assert_eq "4" "$(stub_arg_after flow 1 -j)"      "flow uses the default -j 4"
assert_eq "4" "$(stub_arg_after transport 1 -j)" "transport uses the default -j 4"
assert_eq "6" "$(stub_arg_after post 1 -j)"      "post uses the --post-jobs override"

# Without -j the wrapper forwards no job option and each stage keeps its default.
workspace="$(new_workspace nodefault)"
use_stub_records "$workspace"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
mkdir -p "$output"
make_csv "${workspace}/output_batch_1.csv" 0

out="$(bash "$RUN_BATCH" --stage mesh,flow --setup-jobs 2 \
        -m "$master" -o "$output" --stage setup "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?
assert_status 0 "$status" "a run without -j must succeed: $out"
assert_eq "2" "$(stub_arg_after setup 1 -j)" "setup uses --setup-jobs 2"
assert_not_contains "$(stub_argv_joined mesh 1)" "-j" \
    "mesh receives no job option when neither -j nor --mesh-jobs is set"

# A job count below 1 is rejected.
out="$(bash "$RUN_BATCH" -j 0 -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?
assert_failure "$status" "-j 0 must be rejected"
assert_contains "$out" "--jobs must be an integer >= 1" \
    "the failure explains the job-count rule"
