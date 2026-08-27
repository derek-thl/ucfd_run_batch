#!/usr/bin/env bash
# Section 23.P - failure propagation.
#
# Includes the Issue #9 restorations: a failed required OpenFOAM command
# inside the mesh or flow stage fails the case and the stage (v4 Sections
# 15.5, 16.6, and 23.P).
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

# ---- stage level: every required fresh-mesh command failure (Issue #9) -----------

# make_mesh_fixture <name> - one unmeshed flow case ready for a fresh mesh run.
make_mesh_fixture() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" 0
    make_flow_case "${workspace}/case_0/flow" 2
}

for failing_command in surfaceFeatureExtract blockMesh decomposePar \
                       snappyHexMesh reconstructParMesh checkMesh; do
    make_mesh_fixture "meshfail_${failing_command}"

    out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="$failing_command" \
            bash "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
        && status=0 || status=$?

    assert_failure "$status" \
        "a failed ${failing_command} must make the mesh stage non-zero"
    summary="${workspace}/run_mesh_cases_summary.csv"
    assert_eq 1 "$(summary_status_count "$summary" failed)" \
        "a failed ${failing_command} produces a failed mesh summary row"
    assert_eq 0 "$(summary_status_count "$summary" meshed)" \
        "no success summary state is written after a failed ${failing_command}"
    assert_contains "$(cat "${workspace}/.run_mesh_cases_failed")" "case_0/flow" \
        "the mesh failure artifact identifies the affected case"
    assert_file_missing "${workspace}/case_0/flow/restart.marker" \
        "no restart marker is written after a failed ${failing_command}"
    assert_contains "$(case_log "$workspace" _mesh_logs case_0_flow)" \
        "Required mesh command failed" \
        "the case log names the failed required command (${failing_command})"
done

# ---- stage level: every required fresh-flow command failure (Issue #9) -----------

# make_flow_fixture <name> <with_walldistance> - one meshed flow case.
make_flow_fixture() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" 0
    make_flow_case "${workspace}/case_0/flow" 2
    make_flow_mesh "${workspace}/case_0/flow"
    if [[ "$2" == "yes" ]]; then
        printf 'FoamFile { object wallDistance; }\n' \
            > "${workspace}/case_0/flow/0/wallDistance"
    fi
}

# RECONSTRUCT_MODE stays at the default (latest), so reconstructPar is a
# required command. checkMesh is required only on the wallDistance-fallback
# path, so that scenario starts without 0/wallDistance.
for failing_command in decomposePar renumberMesh simpleFoam reconstructPar checkMesh; do
    with_walldistance="yes"
    [[ "$failing_command" == "checkMesh" ]] && with_walldistance="no"
    make_flow_fixture "flowfail_${failing_command}" "$with_walldistance"

    out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="$failing_command" \
            bash "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
        && status=0 || status=$?

    assert_failure "$status" \
        "a failed ${failing_command} must make the flow stage non-zero"
    summary="${workspace}/run_flow_cases_summary.csv"
    assert_eq 1 "$(summary_status_count "$summary" failed)" \
        "a failed ${failing_command} produces a failed flow summary row"
    assert_eq 0 "$(summary_status_count "$summary" solved)" \
        "no success summary state is written after a failed ${failing_command}"
    assert_contains "$(cat "${workspace}/.run_flow_cases_failed")" "case_0/flow" \
        "the flow failure artifact identifies the affected case"
    assert_file_missing "${workspace}/case_0/flow/flow.marker" \
        "no flow marker is written after a failed ${failing_command}"
    assert_contains "$(case_log "$workspace" _flow_logs case_0_flow)" \
        "Required flow command failed" \
        "the case log names the failed required command (${failing_command})"
done

# ---- top level: a mesh command failure marks the batch failed (Issue #9) ---------

workspace="$(new_workspace meshfail_top)"
install_fakes "$workspace"
assert_fakes_active
output="${workspace}/out"
mkdir -p "${output}/batch_1"
make_csv "${output}/batch_1/output_batch_1.csv" 0
cp "${output}/batch_1/output_batch_1.csv" "${workspace}/output_batch_1.csv"
make_flow_case "${output}/batch_1/case_0/flow" 2

out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="snappyHexMesh" \
        bash "$RUN_BATCH" --stage mesh -m "$MASTER_SRC_DIR" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_failure "$status" "a mesh command failure must fail the top-level run"
assert_contains "$out" "Stage failed  : run_mesh_cases.sh" \
    "the top level names the failed mesh stage"
assert_contains "$out" "Batch failed: batch_1" "the batch is marked failed"
