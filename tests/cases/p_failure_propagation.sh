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

# ---- stage level: a failed setup row fails the setup stage (Issue #24) -----------

# make_setup_workspace <name> - a workspace with both setup base folders.
make_setup_workspace() {
    workspace="$(new_workspace "$1")"
    mkdir -p "${workspace}/simpleFoam_files" "${workspace}/scalarTransportDeffFoam_files"
}

# write_setup_csv <path> [<row> ...] - a DOE Batch CSV with explicit row text.
write_setup_csv() {
    local path="$1" row
    shift
    printf 'Case,WS,WD\n' > "$path"
    for row in "$@"; do
        printf '%s\n' "$row" >> "$path"
    done
}

make_setup_workspace setup_mixed
write_setup_csv "${workspace}/output_batch_1.csv" \
    "good_1,3.5,270.0" \
    "bad_1,not_a_number,270.0"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run 2>&1)" \
    && status=0 || status=$?

summary="${workspace}/setup_cases_summary.csv"

assert_failure "$status" "a failed setup row must make the setup stage non-zero"
assert_eq 1 "$(summary_status_count "$summary" failed 9)" \
    "the setup summary records the failed row"
assert_eq 2 "$(summary_status_count "$summary" dry_run 9)" \
    "the successful row keeps its flow and transport summary records"
assert_contains "$(cat "${workspace}/.setup_cases_failed")" "output_batch_1.csv,3" \
    "the setup failure artifact identifies the failed row"
assert_contains "$out" "Some rows failed. Check:" "the setup stage prints the warning"
assert_contains "$out" "Summary: ${workspace}/setup_cases_summary.csv" \
    "the setup stage prints the summary path before the non-zero return"

# A setup invocation without a failed row keeps the current success behavior.

make_setup_workspace setup_allgood
write_setup_csv "${workspace}/output_batch_1.csv" \
    "good_1,3.5,270.0" \
    "good_2,4.5,90.0"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a setup dry-run with valid rows must exit 0"
assert_eq 0 "$(summary_status_count "${workspace}/setup_cases_summary.csv" failed 9)" \
    "a valid setup dry-run records no failed row"
assert_contains "$out" "Done." "the setup stage keeps the success diagnostic"

# An empty DOE Batch CSV with a valid header must not create a false failure.

make_setup_workspace setup_empty
write_setup_csv "${workspace}/output_batch_1.csv"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "an empty DOE Batch CSV must exit 0"
assert_eq 0 "$(summary_status_count "${workspace}/setup_cases_summary.csv" failed 9)" \
    "an empty DOE Batch CSV records no failed row"

# A skipped row must not make the setup stage non-zero.

make_setup_workspace setup_skipped
write_setup_csv "${workspace}/output_batch_1.csv" \
    "zero_1,0,270.0" \
    "good_1,3.5,90.0"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --zero-ws-mode skip --dry-run 2>&1)" && status=0 || status=$?

summary="${workspace}/setup_cases_summary.csv"

assert_status 0 "$status" "a skipped row must not make the setup stage non-zero"
assert_eq 1 "$(summary_status_count "$summary" skipped 9)" \
    "the skipped row keeps the skipped summary state"
assert_eq 0 "$(summary_status_count "$summary" failed 9)" \
    "a skipped row is not a failed row"

# An invalid WS row and an invalid WD row produce the same failure signals.

for bad_row in "bad_ws,not_a_number,270.0" "bad_wd,3.5,not_a_number"; do
    make_setup_workspace "setup_${bad_row%%,*}"
    write_setup_csv "${workspace}/output_batch_1.csv" "$bad_row"

    out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 \
            --dry-run 2>&1)" && status=0 || status=$?

    assert_failure "$status" "row '${bad_row}' must make the setup stage non-zero"
    assert_eq 1 "$(summary_status_count "${workspace}/setup_cases_summary.csv" failed 9)" \
        "row '${bad_row}' produces a failed summary row"
    assert_contains "$(cat "${workspace}/.setup_cases_failed")" "output_batch_1.csv,2" \
        "row '${bad_row}' is identified in the setup failure artifact"
    assert_contains "$out" "Some rows failed. Check:" \
        "row '${bad_row}' keeps the existing warning"
done

# Concurrent failed rows aggregate into one non-zero setup status.

make_setup_workspace setup_concurrent
write_setup_csv "${workspace}/output_batch_1.csv" \
    "bad_1,not_a_number,270.0" \
    "bad_2,also_not_a_number,90.0" \
    "good_1,3.5,180.0"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 2 --dry-run 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "two concurrent failed rows must make the setup stage non-zero"
assert_eq 2 "$(summary_status_count "${workspace}/setup_cases_summary.csv" failed 9)" \
    "both concurrent failures reach the setup summary"
assert_eq 2 "$(grep -c . "${workspace}/.setup_cases_failed")" \
    "both concurrent failures reach the setup failure artifact"
assert_eq 2 "$(summary_status_count "${workspace}/setup_cases_summary.csv" dry_run 9)" \
    "the successful row of a concurrent invocation keeps its summary records"

# A failure-artifact write failure must not produce setup success.

make_setup_workspace setup_failfile
write_setup_csv "${workspace}/output_batch_1.csv" "good_1,3.5,270.0"
mkdir -p "${workspace}/.setup_cases_failed"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "an unwritable failure artifact must make the setup stage non-zero"

# A missing required CSV column stays a fatal validation failure.

make_setup_workspace setup_missingcolumn
printf 'Case,WD\ngood_1,270.0\n' > "${workspace}/output_batch_1.csv"

out="$(cd "$workspace" && bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a missing required CSV column must stay non-zero"
assert_contains "$out" "Required column not found" "the missing column is named"

# A missing required command stays a fatal command-validation failure.

make_setup_workspace setup_missingcommand
write_setup_csv "${workspace}/output_batch_1.csv" "good_1,3.5,270.0"
mkdir -p "${workspace}/_setup_bin"
for command_name in surfaceTransformPoints foamDictionary; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${workspace}/_setup_bin/${command_name}"
    chmod +x "${workspace}/_setup_bin/${command_name}"
done

# surfaceCheck is intentionally absent. Prove that the scenario is not vacuous.
setup_path="${workspace}/_setup_bin:/usr/bin:/bin"
if ( PATH="$setup_path"; command -v surfaceCheck >/dev/null 2>&1 ); then
    _fail "the missing-command scenario needs a PATH without surfaceCheck"
fi

out="$(cd "$workspace" && PATH="$setup_path" bash "$SETUP_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_failure "$status" "a missing required command must stay non-zero"
assert_contains "$out" "'surfaceCheck' not found in PATH" "the missing command is named"

# ---- top level: a failed setup row marks the batch failed (Issue #24) ------------

# build_setup_batches <name> - two batches that use the real setup stage runner
# and a mesh stage stub. Batch 1 holds one invalid row. Batch 2 is empty.
build_setup_batches() {
    workspace="$(new_workspace "$1")"
    use_stub_records "$workspace"
    master="${workspace}/master_batch"
    output="${workspace}/out"
    make_stub_master "$master" master
    cp -f -- "$SETUP_SCRIPT" "${master}/setup_cases.sh"
    mkdir -p "${master}/simpleFoam_files" "${master}/scalarTransportDeffFoam_files"
    mkdir -p "$output" "${workspace}/_setup_bin"

    local command_name
    for command_name in surfaceCheck surfaceTransformPoints foamDictionary; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "${workspace}/_setup_bin/${command_name}"
        chmod +x "${workspace}/_setup_bin/${command_name}"
    done
    setup_path="${workspace}/_setup_bin:${PATH}"

    write_setup_csv "${workspace}/output_batch_1.csv" "bad_1,not_a_number,270.0"
    write_setup_csv "${workspace}/output_batch_2.csv"
}

build_setup_batches setupfail_stopfirst

out="$(cd "$workspace" && PATH="$setup_path" bash "$RUN_BATCH" --stage setup,mesh \
        -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a failed setup row must fail the top-level run"
assert_contains "$out" "Stage failed  : setup_cases.sh" "the failed setup stage is named"
assert_contains "$out" "Batch failed: batch_1" "the batch is marked failed"
assert_contains "$out" "Stop after first failed batch" \
    "the run stops before launching more batches"
assert_file_exists "${output}/batch_1/.setup_cases_failed" \
    "the batch workspace keeps the setup failure artifact"

if stub_ran mesh 1; then
    _fail "mesh must not start after a failed setup stage in the same batch"
fi
if stub_ran mesh 2; then
    _fail "batch_2 must not start without --keep-going"
fi

# --keep-going attempts the later batch and keeps the final status non-zero.

build_setup_batches setupfail_keepgoing

out="$(cd "$workspace" && PATH="$setup_path" bash "$RUN_BATCH" --stage setup,mesh \
        --keep-going -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "--keep-going must still report a final failure"
assert_contains "$out" "1 batch(es) failed." "the final report counts the setup failure"
stub_ran mesh 2 || _fail "--keep-going attempts batch_2 after a failed setup batch"
assert_not_contains "$out" "All requested batches and stages finished successfully." \
    "a failed setup batch must not report overall success"

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
