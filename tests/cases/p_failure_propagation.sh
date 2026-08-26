#!/usr/bin/env bash
# Section 23.P - failure propagation.
#
# Scope note: this scenario covers the currently conforming failure paths.
# Two Section 23.P sub-cases are excluded because the production scripts do not
# satisfy them yet:
#   * a failed OpenFOAM command inside the mesh or flow stage is not propagated;
#     Issue #9 owns that gap. See tests/README.md, "Known contract gaps".
#   * post-processing and transport missing-case handling belongs to Issue #6.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# ---- top level: a failed stage fails the batch -------------------------------

build_two_batches() {
    workspace="$(new_workspace "$1")"
    use_stub_records "$workspace"
    master="${workspace}/master_batch"
    output="${workspace}/out"
    make_stub_master "$master" master
    mkdir -p "$output"
    make_csv "${workspace}/output_batch_1.csv" 0
    make_csv "${workspace}/output_batch_2.csv" 0
}

build_two_batches stopfirst

out="$(STUB_FAIL_STAGES="mesh:1" bash "$RUN_BATCH" --stage setup,mesh \
        -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a failed stage must fail the run"
assert_contains "$out" "Stage failed  : run_mesh_cases.sh" "the failed stage is named"
assert_contains "$out" "Batch failed: batch_1" "the batch is marked failed"
assert_contains "$out" "Stop after first failed batch" \
    "the run stops before launching more batches"

# The child exit status is preserved through the stage report.
assert_contains "$out" "exit=3" "the original stage exit status is preserved"

stub_ran mesh 1 || _fail "the mesh stage ran for batch_1"
if stub_ran setup 2; then
    _fail "batch_2 must not start without --keep-going"
fi

# ---- --keep-going attempts the other batches ---------------------------------

build_two_batches keepgoing

out="$(STUB_FAIL_STAGES="mesh:1" bash "$RUN_BATCH" --stage setup,mesh --keep-going \
        -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "--keep-going must still report a final failure"
assert_contains "$out" "1 batch(es) failed." "the final report counts the failure"
stub_ran mesh 2 || _fail "--keep-going attempts batch_2"
assert_not_contains "$out" "All requested batches and stages finished successfully." \
    "a failed batch must not report overall success"

# ---- a stage-script failure in any selected stage stops the batch ------------

build_two_batches poststage

out="$(STUB_FAIL_STAGES="post" bash "$RUN_BATCH" \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a failed post stage must fail the run"
assert_contains "$out" "Stage failed  : run_post_processing_cases.sh" \
    "the failed post stage is named"
stub_ran transport 1 || _fail "the earlier stages ran before the post failure"

# ---- stage level: post-processing conversion failure -------------------------

workspace="$(new_workspace postcase)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300
mkdir -p "${workspace}/case_0/trd/300"
printf 'FoamFile { object T; }\n' > "${workspace}/case_0/trd/300/T"

out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="foamToVTK" \
        bash "$POST_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a failed conversion must fail the post stage"
assert_eq 1 "$(summary_status_count "${workspace}/run_post_processing_cases_summary.csv" failed 3)" \
    "the post summary records the failed case"
assert_contains "$out" "One or more post-processing jobs failed" \
    "the post stage reports the failure"

# ---- stage level: transport precondition failure -----------------------------

workspace="$(new_workspace transportcase)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_mesh "${workspace}/case_0/flow"
make_flow_result "${workspace}/case_0/flow" 3000
# endTime 100 cannot cover the requested save time 300.
make_transport_case "${workspace}/case_0/trd" 2 T 100

out="$(cd "$workspace" && bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --save-times "60,120,300" 2>&1)" && status=0 || status=$?

assert_failure "$status" "a transport precondition failure must fail the stage"
assert_eq 1 "$(summary_status_count "${workspace}/run_transport_cases_summary.csv" failed)" \
    "the transport summary records the failed case"
assert_contains "$out" "One or more transport jobs failed" \
    "the transport stage reports the failure"
