#!/usr/bin/env bash
# Focused Issue #6 regression tests for stage failure propagation.
#
# Covered requirements:
#   * v4 Section 18.5 - a requested post-processing case with no case
#                       directory is a failed case and a failed stage.
#   * v4 Section 17.4 - a requested transport case with no required flow
#                       case is a failed case and a failed stage.
#   * v4 Section 23.P - the top level receives the non-zero stage result with
#                       and without --keep-going.
#
# Usage:
#   bash tests/test_stage_failure_contract.sh
set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

CONTRACT_TEST_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ucfd-stage-failure-focus.XXXXXXXX")"
CONTRACT_TEST_NAME="stage_failure_focus"
export CONTRACT_TEST_RUN_DIR CONTRACT_TEST_NAME

cleanup() {
    case "$CONTRACT_TEST_RUN_DIR" in
        /tmp/*|/var/tmp/*|"${TMPDIR:-/tmp}"/*) rm -rf -- "$CONTRACT_TEST_RUN_DIR" ;;
    esac
}
trap cleanup EXIT

source "${TESTS_DIR}/lib/harness.sh"
source "${TESTS_DIR}/lib/assert.sh"

set -e

PASS_COUNT=0
report() { PASS_COUNT=$(( PASS_COUNT + 1 )); printf 'PASS %s\n' "$1"; }

# ---- 1. missing requested post-processing case ---------------------------------

workspace="$(new_workspace post_missing)"
install_fakes "$workspace"
assert_fakes_active

# Row case_0 has a complete case. Row case_9 has no case directory.
make_csv "${workspace}/output_batch_1.csv" 0 9
make_flow_case "${workspace}/case_0/flow" 2
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300
mkdir -p "${workspace}/case_0/trd/300"
printf 'FoamFile { object T; }\n' > "${workspace}/case_0/trd/300/T"

out="$(cd "$workspace" && bash "$POST_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a missing requested post case must fail the stage"
summary="${workspace}/run_post_processing_cases_summary.csv"
assert_eq 1 "$(summary_status_count "$summary" failed 3)" \
    "the post summary records the missing case as failed"
assert_eq 1 "$(summary_status_count "$summary" completed 3)" \
    "the complete case still completes"
assert_file_exists "${workspace}/.run_post_processing_cases_failed" \
    "the documented post failure artifact exists"
assert_contains "$(cat "${workspace}/.run_post_processing_cases_failed")" "case_9" \
    "the failure artifact names the missing case"
report "test_post_missing_case_fails_stage"

# ---- 2. missing transport flow prerequisite ------------------------------------

workspace="$(new_workspace transport_missing)"
install_fakes "$workspace"
assert_fakes_active

# Row case_0 is complete. Row case_9 has a transport case but no flow case.
make_csv "${workspace}/output_batch_1.csv" 0 9
make_flow_case "${workspace}/case_0/flow" 2
make_flow_mesh "${workspace}/case_0/flow"
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300
make_transport_case "${workspace}/case_9/trd" 2 T 300

out="$(cd "$workspace" && FAKE_SOLVER_TIMES="60 120 300" \
        bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --save-times "60,120,300" 2>&1)" && status=0 || status=$?

assert_failure "$status" "a missing flow prerequisite must fail the transport stage"
summary="${workspace}/run_transport_cases_summary.csv"
assert_eq 1 "$(summary_status_count "$summary" failed)" \
    "the transport summary records the missing prerequisite as failed"
assert_eq 1 "$(summary_status_count "$summary" solved)" \
    "the complete case still solves"
assert_file_exists "${workspace}/.run_transport_cases_failed" \
    "the documented transport failure artifact exists"
assert_contains "$(cat "${workspace}/.run_transport_cases_failed")" "case_9/trd" \
    "the failure artifact names the failed transport case"
assert_contains "$out" "One or more transport jobs failed" \
    "the transport stage reports the failure"
report "test_transport_missing_flow_fails_stage"

# ---- 3. unrelated skip behavior stays compatible --------------------------------

# A duplicate case id stays a skip, not a failure.
workspace="$(new_workspace duplicate_skip)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 0 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_mesh "${workspace}/case_0/flow"
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300

out="$(cd "$workspace" && FAKE_SOLVER_TIMES="60 120 300" \
        bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --save-times "60,120,300" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "a duplicate case id must stay a skip: $out"
summary="${workspace}/run_transport_cases_summary.csv"
assert_eq 1 "$(summary_status_count "$summary" skipped)" \
    "the duplicate row stays skipped"
assert_eq 0 "$(summary_status_count "$summary" failed)" \
    "the duplicate row is not a failure"
report "test_duplicate_case_stays_skipped"

# ---- 4. top-level propagation without --keep-going -------------------------------

top_fixture() {
    local name="$1"
    workspace="$(new_workspace "$name")"
    install_fakes "$workspace"
    assert_fakes_active
    output="${workspace}/out"

    # batch_1 has a transport case without its flow case -> transport fails.
    mkdir -p "${output}/batch_1"
    make_csv "${output}/batch_1/output_batch_1.csv" 0
    cp "${output}/batch_1/output_batch_1.csv" "${workspace}/output_batch_1.csv"
    make_transport_case "${output}/batch_1/case_0/trd" 2 T 300

    # batch_2 is complete -> transport succeeds.
    mkdir -p "${output}/batch_2"
    make_csv "${output}/batch_2/output_batch_2.csv" 0
    cp "${output}/batch_2/output_batch_2.csv" "${workspace}/output_batch_2.csv"
    make_flow_case "${output}/batch_2/case_0/flow" 2
    make_flow_mesh "${output}/batch_2/case_0/flow"
    make_flow_result "${output}/batch_2/case_0/flow" 3000
    make_transport_case "${output}/batch_2/case_0/trd" 2 T 300
}

top_fixture stop_first

out="$(cd "$workspace" && FAKE_SOLVER_TIMES="60 120 300" \
        bash "$RUN_BATCH" --stage transport --save-times "60,120,300" \
        -m "$MASTER_SRC_DIR" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "the top level must fail when the transport stage fails"
assert_contains "$out" "Stage failed  : run_transport_cases.sh" \
    "the top level names the failed transport stage"
assert_contains "$out" "Stop after first failed batch" \
    "the run stops before batch_2 without --keep-going"
assert_not_contains "$out" "Batch 2/2" \
    "batch_2 does not start without --keep-going"
report "test_top_level_stops_without_keep_going"

# ---- 5. top-level propagation with --keep-going -----------------------------------

top_fixture keep_going

out="$(cd "$workspace" && FAKE_SOLVER_TIMES="60 120 300" \
        bash "$RUN_BATCH" --stage transport --save-times "60,120,300" --keep-going \
        -m "$MASTER_SRC_DIR" -o "$output" \
        "${workspace}/output_batch_1.csv" "${workspace}/output_batch_2.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "--keep-going must still report the final failure"
assert_contains "$out" "1 batch(es) failed." "the final report counts one failed batch"
assert_contains "$out" "Batch 2/2" "--keep-going attempts batch_2"
summary2="${output}/batch_2/run_transport_cases_summary.csv"
assert_eq 1 "$(summary_status_count "$summary2" solved)" \
    "batch_2 transport succeeds under --keep-going"
report "test_top_level_continues_with_keep_going"

# ---- 6. post failure-artifact write error must not produce success --------------

# /dev/full accepts open and truncate and fails every write with ENOSPC. A
# failure-artifact symlink to /dev/full makes the artifact append fail while
# stage setup still succeeds.
[[ -c /dev/full ]] || _fail "/dev/full is required for the write-error scenarios"

workspace="$(new_workspace post_artifact_error)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 9
ln -s /dev/full "${workspace}/.run_post_processing_cases_failed"

out="$(cd "$workspace" && timeout 120 \
        bash "$POST_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a post failure-artifact write error must not produce success"
assert_contains "$out" "One or more post-processing jobs failed" \
    "the stage reports the failure although the artifact append failed"
summary="${workspace}/run_post_processing_cases_summary.csv"
assert_eq 1 "$(summary_status_count "$summary" failed 3)" \
    "the missing case is still summarized as failed"
[[ ! -s "${workspace}/.run_post_processing_cases_failed" ]] ||
    _fail "the scenario requires an empty failure artifact to prove the gate"
report "test_post_failure_artifact_write_error_fails_stage"

# ---- 7. transport failure-artifact write error must not produce success ----------

# PROGRESS_INTERVAL is set very high so that show_progress never reads the
# device-backed failure artifact during this scenario.
workspace="$(new_workspace transport_artifact_error)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 9
make_transport_case "${workspace}/case_9/trd" 2 T 300
ln -s /dev/full "${workspace}/.run_transport_cases_failed"

out="$(cd "$workspace" && env PROGRESS_INTERVAL=9999999999 timeout 120 \
        bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 \
        --save-times "60,120,300" 2>&1)" && status=0 || status=$?

assert_failure "$status" "a transport failure-artifact write error must not produce success"
assert_contains "$out" "One or more transport jobs failed" \
    "the stage reports the failure although the artifact append failed"
summary="${workspace}/run_transport_cases_summary.csv"
assert_eq 1 "$(summary_status_count "$summary" failed)" \
    "the missing-flow case is still summarized as failed"
[[ ! -s "${workspace}/.run_transport_cases_failed" ]] ||
    _fail "the scenario requires an empty failure artifact to prove the gate"
report "test_transport_failure_artifact_write_error_fails_stage"

printf '\nAll %s focused stage-failure contract tests passed.\n' "$PASS_COUNT"
