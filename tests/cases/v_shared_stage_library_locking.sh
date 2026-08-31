#!/usr/bin/env bash
# Section 23.V - shared Stage library locking characterization (Issue #39).
#
# This scenario characterizes the current Stage Runner mutual-exclusion
# behavior. The assertions pass before and after the I-G1 extraction.
#
# Every assertion uses a public Stage Runner CLI, the process status, the
# console output, and the Batch Workspace file tree. No assertion sources
# lib_batch_stage.sh and no assertion calls a shared helper.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# Every Stage Runner invocation has a finite timeout. A lock regression must
# fail the scenario instead of waiting without a limit.
STAGE_TIMEOUT=120

# ---- helpers -----------------------------------------------------------------

# assert_summary_shape <summary> <columns> <data_rows> <label>
# A merged row or a partial row changes the field count of a line, so the field
# count proves that concurrent writes stayed complete and parseable.
assert_summary_shape() {
    local path="$1" columns="$2" rows="$3" label="$4" bad

    assert_file_exists "$path" "${label}: the summary exists"

    assert_eq "$rows" \
        "$(awk -F, 'NR > 1 && NF > 0 { count++ } END { print count + 0 }' "$path")" \
        "${label}: the summary holds every data row"

    bad="$(awk -F, -v want="$columns" 'NF != want { printf "line %d has %d fields; ", NR, NF }' "$path")"
    assert_eq "" "$bad" "${label}: every summary line has ${columns} fields"
}

# assert_no_lock_dir <workspace> <label>
assert_no_lock_dir() {
    local found
    found="$(find "$1" -name '*.lockdir' 2>/dev/null | sort | tr '\n' ' ')"
    assert_eq "" "$found" "${2}: no lock directory survives"
}

# summary_status_values <summary> <status_field> - the sorted status values.
summary_status_values() {
    awk -F, -v field="$2" 'NR > 1 && NF > 0 {
            value = $field
            gsub(/"/, "", value)
            print value
        }' "$1" | sort -u | tr '\n' ' '
}

# make_flow_batch <name> <count> - one workspace with <count> meshed flow Cases.
make_flow_batch() {
    local name="$1" count="$2" index
    workspace="$(new_workspace "$name")"
    install_fakes "$workspace"
    assert_fakes_active
    case_ids=()
    for (( index = 0; index < count; index++ )); do
        case_ids+=("$index")
    done
    make_csv "${workspace}/output_batch_1.csv" "${case_ids[@]}"
    for (( index = 0; index < count; index++ )); do
        make_flow_case "${workspace}/case_${index}/flow" 2
    done
}

CASE_COUNT=4

# ---- setup: concurrent summary writes keep the 10-column schema -------------

workspace="$(new_workspace setup_concurrent)"
mkdir -p "${workspace}/simpleFoam_files" "${workspace}/scalarTransportDeffFoam_files"
make_csv "${workspace}/output_batch_1.csv" 0 1 2 3

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$SETUP_SCRIPT" \
        -i output_batch_1.csv -O . -j 4 --dry-run 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "the concurrent setup dry-run keeps exit status 0"
# One flow record and one transport record for each Case.
assert_summary_shape "${workspace}/setup_cases_summary.csv" 10 \
    $(( CASE_COUNT * 2 )) "setup"
assert_eq "dry_run " "$(summary_status_values "${workspace}/setup_cases_summary.csv" 9)" \
    "setup keeps its current status values"
assert_no_lock_dir "$workspace" "setup success"

# ---- mesh: summary writes keep the 7-column schema -------------------------
#
# This scenario runs the mesh Stage Runner with one Case at a time. A mesh run
# with more than one concurrent Case cannot be characterized here, because
# `show_running_cases` in run_mesh_cases.sh globs `_mesh_state/*.state` and then
# reads each file with `awk`. A Case that finishes between the glob and the
# `awk` makes the following `read` reach end of file, and `set -e` stops the
# Stage Runner. That race loses a summary row and gives status 1 even when every
# Case succeeds. The race is not a locking defect, and Issue #39 prohibits a
# pre-existing behavior fix. The Implementer published a blocker for the mesh
# concurrency requirement of Issue #39.

make_flow_batch mesh_sequential 1

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$MESH_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "the mesh run keeps exit status 0"
assert_summary_shape "${workspace}/run_mesh_cases_summary.csv" 7 1 "mesh"
assert_eq "meshed " "$(summary_status_values "${workspace}/run_mesh_cases_summary.csv" 6)" \
    "mesh keeps its current status values"
assert_no_lock_dir "$workspace" "mesh success"

# ---- flow: concurrent summary writes keep the 7-column schema -------------

make_flow_batch flow_concurrent "$CASE_COUNT"
for index in 0 1 2 3; do
    make_flow_mesh "${workspace}/case_${index}/flow"
    printf 'FoamFile { object wallDistance; }\n' \
        > "${workspace}/case_${index}/flow/0/wallDistance"
done

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$FLOW_SCRIPT" \
        -i output_batch_1.csv -O . -j 4 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "the concurrent flow run keeps exit status 0"
assert_summary_shape "${workspace}/run_flow_cases_summary.csv" 7 "$CASE_COUNT" "flow"
assert_eq "solved " "$(summary_status_values "${workspace}/run_flow_cases_summary.csv" 6)" \
    "flow keeps its current status values"
assert_no_lock_dir "$workspace" "flow success"

# ---- transport: concurrent summary writes keep the 7-column schema --------

make_flow_batch transport_concurrent "$CASE_COUNT"
for index in 0 1 2 3; do
    make_flow_mesh "${workspace}/case_${index}/flow"
    make_flow_result "${workspace}/case_${index}/flow" 3000
    make_transport_case "${workspace}/case_${index}/trd" 2 T 300
    printf 'flow-U-at-3000\n' > "${workspace}/case_${index}/flow/3000/U"
    printf 'flow-nut-at-3000\n' > "${workspace}/case_${index}/flow/3000/nut"
    printf 'flow-phi-at-3000\n' > "${workspace}/case_${index}/flow/3000/phi"
done

# The fake solver writes the controlDict endTime only, so the scenario requests
# that one save time.
out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$TRANSPORT_SCRIPT" \
        -i output_batch_1.csv -O . -j 4 --save-times "300" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the concurrent transport run keeps exit status 0"
assert_summary_shape "${workspace}/run_transport_cases_summary.csv" 7 "$CASE_COUNT" "transport"
assert_eq "solved " "$(summary_status_values "${workspace}/run_transport_cases_summary.csv" 6)" \
    "transport keeps its current status values"
assert_no_lock_dir "$workspace" "transport success"

# ---- post-processing: concurrent writes keep the 4-column schema ----------

make_flow_batch post_concurrent "$CASE_COUNT"
for index in 0 1 2 3; do
    make_flow_result "${workspace}/case_${index}/flow" 3000
    make_transport_case "${workspace}/case_${index}/trd" 2 T 300
    mkdir -p "${workspace}/case_${index}/trd/300"
    printf 'FoamFile { object T; }\n' > "${workspace}/case_${index}/trd/300/T"
done

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$POST_SCRIPT" \
        -i output_batch_1.csv -O . -j 4 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "the concurrent post-processing run keeps exit status 0"
assert_summary_shape "${workspace}/run_post_processing_cases_summary.csv" 4 \
    "$CASE_COUNT" "post-processing"
assert_eq "completed " \
    "$(summary_status_values "${workspace}/run_post_processing_cases_summary.csv" 3)" \
    "post-processing keeps its current status values"
assert_no_lock_dir "$workspace" "post-processing success"

# ---- a held summary lock makes each Stage Runner wait ----------------------

# summary_rows <summary>
summary_rows() {
    [[ -f "$1" ]] || { printf '0\n'; return 0; }
    awk -F, 'NR > 1 && NF > 0 { count++ } END { print count + 0 }' "$1"
}

# assert_waits_for_lock <label> <summary_name> <expected_rows> <command...>
# The scenario holds the exact `${SUMMARY_CSV}.lockdir` path. A Stage Runner
# that uses another lock path would not wait, so this also proves the path.
assert_waits_for_lock() {
    local label="$1" summary_name="$2" expected_rows="$3"
    shift 3
    local summary="${workspace}/${summary_name}"
    local lock="${workspace}/${summary_name}.lockdir"
    local runner_pid wait_status=0 attempt

    mkdir -p "$lock"

    ( cd "$workspace" && timeout "$STAGE_TIMEOUT" "$@" ) \
        > "${workspace}/${label}_wait.log" 2>&1 &
    runner_pid=$!

    for attempt in $(seq 1 400); do
        [[ -f "$summary" ]] && break
        sleep 0.05
    done

    assert_file_exists "$summary" "${label}: the Stage Runner writes the summary header"
    sleep 0.5
    assert_eq 0 "$(summary_rows "$summary")" \
        "${label}: the Stage Runner waits while the summary lock is held"

    rmdir "$lock"
    wait "$runner_pid" && wait_status=0 || wait_status=$?

    assert_status 0 "$wait_status" \
        "${label}: the Stage Runner completes after the lock is released"
    assert_eq "$expected_rows" "$(summary_rows "$summary")" \
        "${label}: every row is written after the lock is released"
    assert_no_lock_dir "$workspace" "${label} lock wait"
}

workspace="$(new_workspace setup_lock_wait)"
mkdir -p "${workspace}/simpleFoam_files" "${workspace}/scalarTransportDeffFoam_files"
make_csv "${workspace}/output_batch_1.csv" 0
assert_waits_for_lock setup setup_cases_summary.csv 2 \
    bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run

make_flow_batch mesh_lock_wait 1
assert_waits_for_lock mesh run_mesh_cases_summary.csv 1 \
    bash "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1

make_flow_batch flow_lock_wait 1
make_flow_mesh "${workspace}/case_0/flow"
printf 'FoamFile { object wallDistance; }\n' > "${workspace}/case_0/flow/0/wallDistance"
assert_waits_for_lock flow run_flow_cases_summary.csv 1 \
    bash "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1

make_flow_batch transport_lock_wait 1
make_flow_mesh "${workspace}/case_0/flow"
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300
for field in U nut phi; do
    printf 'flow-%s-at-3000\n' "$field" > "${workspace}/case_0/flow/3000/${field}"
done
assert_waits_for_lock transport run_transport_cases_summary.csv 1 \
    bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 --save-times 300

make_flow_batch post_lock_wait 1
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300
mkdir -p "${workspace}/case_0/trd/300"
printf 'FoamFile { object T; }\n' > "${workspace}/case_0/trd/300/T"
assert_waits_for_lock post run_post_processing_cases_summary.csv 1 \
    bash "$POST_SCRIPT" -i output_batch_1.csv -O . -j 1

# ---- forced Case failures keep their current behavior ----------------------

# setup: an invalid WS row keeps its failed row and non-zero status.
workspace="$(new_workspace setup_failure)"
mkdir -p "${workspace}/simpleFoam_files" "${workspace}/scalarTransportDeffFoam_files"
printf 'Case,WS,WD\ngood_0,3.5,270.0\nbad_0,not_a_number,270.0\n' \
    > "${workspace}/output_batch_1.csv"

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$SETUP_SCRIPT" \
        -i output_batch_1.csv -O . -j 2 --dry-run 2>&1)" && status=0 || status=$?

assert_failure "$status" "a failed setup row keeps the current non-zero status"
assert_eq 1 "$(summary_status_count "${workspace}/setup_cases_summary.csv" failed 9)" \
    "setup keeps its failed summary row"
assert_contains "$(cat "${workspace}/.setup_cases_failed")" "output_batch_1.csv,3" \
    "setup keeps its Failure Artifact record"
assert_no_lock_dir "$workspace" "setup failure"

# mesh, flow, transport, and post-processing forced Case failures.
make_flow_batch mesh_failure 1
out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="blockMesh" timeout "$STAGE_TIMEOUT" \
        bash "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_failure "$status" "a failed mesh command keeps the current non-zero status"
assert_eq 1 "$(summary_status_count "${workspace}/run_mesh_cases_summary.csv" failed)" \
    "mesh keeps its failed summary row"
assert_contains "$(cat "${workspace}/.run_mesh_cases_failed")" "case_0/flow" \
    "mesh keeps its Failure Artifact record"
assert_file_missing "${workspace}/case_0/flow/restart.marker" \
    "mesh writes no restart marker after a failure"
assert_no_lock_dir "$workspace" "mesh failure"

make_flow_batch flow_failure 1
make_flow_mesh "${workspace}/case_0/flow"
printf 'FoamFile { object wallDistance; }\n' > "${workspace}/case_0/flow/0/wallDistance"
out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="simpleFoam" timeout "$STAGE_TIMEOUT" \
        bash "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_failure "$status" "a failed flow command keeps the current non-zero status"
assert_eq 1 "$(summary_status_count "${workspace}/run_flow_cases_summary.csv" failed)" \
    "flow keeps its failed summary row"
assert_contains "$(cat "${workspace}/.run_flow_cases_failed")" "case_0/flow" \
    "flow keeps its Failure Artifact record"
assert_file_missing "${workspace}/case_0/flow/flow.marker" \
    "flow writes no marker after a failure"
assert_no_lock_dir "$workspace" "flow failure"

make_flow_batch transport_failure 1
make_flow_mesh "${workspace}/case_0/flow"
make_flow_result "${workspace}/case_0/flow" 3000
# endTime 100 cannot cover the requested save time 300.
make_transport_case "${workspace}/case_0/trd" 2 T 100
out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$TRANSPORT_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 --save-times "60,120,300" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a transport precondition failure keeps the current status"
assert_eq 1 "$(summary_status_count "${workspace}/run_transport_cases_summary.csv" failed)" \
    "transport keeps its failed summary row"
assert_no_lock_dir "$workspace" "transport failure"

make_flow_batch post_failure 1
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300
mkdir -p "${workspace}/case_0/trd/300"
printf 'FoamFile { object T; }\n' > "${workspace}/case_0/trd/300/T"
out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="foamToVTK" timeout "$STAGE_TIMEOUT" \
        bash "$POST_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_failure "$status" "a failed conversion keeps the current post-processing status"
assert_eq 1 "$(summary_status_count "${workspace}/run_post_processing_cases_summary.csv" failed 3)" \
    "post-processing keeps its failed summary row"
assert_no_lock_dir "$workspace" "post-processing failure"

# ---- a transport Failure Artifact on /dev/full keeps Stage completion --------
#
# A Failure Artifact on /dev/full is a character device. The transport progress
# line counted Failure Artifact lines without a regular-file test, so the
# progress read took an endless stream and the Stage Runner never completed
# (Issue #42). Both observations below must complete without an external kill.
# The 120-second STAGE_TIMEOUT is only a test safety limit, so status 124 is a
# test failure and never an accepted Stage result.

# assert_no_case_state <workspace> <label>
assert_no_case_state() {
    local found
    found="$(find "$1" -name '*.state' 2>/dev/null | sort | tr '\n' ' ')"
    assert_eq "" "$found" "${2}: no Case state file survives"
}

# assert_exact_summary <summary> <label> <expected_data_row>
# The helper proves the exact seven-column header, exactly one data row, and the
# expected value of every field in that row.
assert_exact_summary() {
    local path="$1" label="$2" expected_row="$3"

    assert_file_exists "$path" "${label}: the summary exists"
    assert_eq 'csv_file,row_number,case_id,flow_case_transport_case,transport_case_dir,status,message' \
        "$(sed -n '1p' "$path")" \
        "${label}: the summary keeps the exact seven-column header"
    assert_eq 1 \
        "$(awk 'NR > 1 && NF > 0 { count++ } END { print count + 0 }' "$path")" \
        "${label}: the summary holds exactly one data row"
    assert_eq "$expected_row" "$(sed -n '2p' "$path")" \
        "${label}: every summary field holds its expected value"
}

# A successful transport Stage must still finish while the Failure Artifact is a
# character device. endTime 300 covers the requested save time 300.
make_flow_batch transport_devfull_solved 1
make_flow_mesh "${workspace}/case_0/flow"
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300
ln -s /dev/full "${workspace}/.run_transport_cases_failed"

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$TRANSPORT_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 --save-times "300" 2>&1)" \
    && status=0 || status=$?

assert_ne 124 "$status" \
    "a solved transport Stage on /dev/full completes without an external kill"
assert_status 0 "$status" "a solved transport Stage on /dev/full keeps status 0"
expected_row="$(printf \
    '"%s/output_batch_1.csv","2","case_0","case_0/flow|case_0/trd","%s/case_0/trd","solved","OK"' \
    "$workspace" "$workspace")"
assert_exact_summary "${workspace}/run_transport_cases_summary.csv" \
    "transport /dev/full solved" "$expected_row"
assert_contains "$out" "All transport jobs finished." \
    "the solved /dev/full run reports Stage success"
assert_file_exists "${workspace}/case_0/trd/transport.marker" \
    "the solved /dev/full run writes the transport marker"
assert_no_lock_dir "$workspace" "transport /dev/full solved"
assert_no_case_state "$workspace" "transport /dev/full solved"

# A failed transport Stage must complete and report failure. endTime 100 cannot
# cover the requested save time 300, so the Case fails and the Stage Runner
# appends the Case name to the Failure Artifact. That append fails on
# /dev/full. The Stage Runner must not hide the write error and must not turn a
# failed Failure Artifact append into Stage success.
make_flow_batch transport_devfull_failed 1
make_flow_mesh "${workspace}/case_0/flow"
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 100
ln -s /dev/full "${workspace}/.run_transport_cases_failed"

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$TRANSPORT_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 --save-times "300" 2>&1)" \
    && status=0 || status=$?

assert_ne 124 "$status" \
    "a failed transport Stage on /dev/full completes without an external kill"
assert_ne 0 "$status" \
    "a transport Failure Artifact on /dev/full does not report Stage success"
expected_row="$(printf \
    '"%s/output_batch_1.csv","2","case_0","case_0/flow|case_0/trd","%s/case_0/trd","failed","see log: %s/_transport_logs/case_0_trd.log"' \
    "$workspace" "$workspace" "$workspace")"
assert_exact_summary "${workspace}/run_transport_cases_summary.csv" \
    "transport /dev/full failed" "$expected_row"
assert_contains "$out" "write error: No space left on device" \
    "the failed /dev/full run keeps the Failure Artifact write error"
# The failed append status ends the Case job before the per-Case line. This
# scenario keeps that current behavior.
assert_not_contains "$out" "TRANSPORT FAILED:" \
    "the failed /dev/full run keeps the current absence of the per-Case line"
assert_contains "$out" "One or more transport jobs failed." \
    "the failed /dev/full run reports Stage failure"
assert_not_contains "$out" "All transport jobs finished." \
    "the failed /dev/full run does not report Stage success"
assert_file_missing "${workspace}/case_0/trd/transport.marker" \
    "the failed /dev/full run writes no transport marker"
assert_no_lock_dir "$workspace" "transport /dev/full failed"
assert_no_case_state "$workspace" "transport /dev/full failed"

# A readable regular Failure Artifact must keep the current progress behavior.
# The Issue #42 guard must read that file, so a constant failed count must fail
# this observation. Two Cases fail, so the progress line must report failed=2.
make_flow_batch transport_regular_artifact 2
for case_index in 0 1; do
    make_flow_mesh "${workspace}/case_${case_index}/flow"
    make_flow_result "${workspace}/case_${case_index}/flow" 3000
    make_transport_case "${workspace}/case_${case_index}/trd" 2 T 100
done

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$TRANSPORT_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 --save-times "300" 2>&1)" \
    && status=0 || status=$?

assert_ne 124 "$status" \
    "a readable regular Failure Artifact completes without an external kill"
assert_ne 0 "$status" \
    "two failed Cases keep a non-zero transport Stage status"
assert_file_exists "${workspace}/.run_transport_cases_failed" \
    "the readable regular Failure Artifact stays a regular file"
assert_eq 2 "$(wc -l < "${workspace}/.run_transport_cases_failed")" \
    "the readable regular Failure Artifact records both failed Cases"
assert_eq 2 "$(summary_status_count "${workspace}/run_transport_cases_summary.csv" failed)" \
    "the readable regular Failure Artifact run keeps both failed summary rows"
# The exact progress line proves the field set, the field order, and the exact
# failed count that the Stage Runner read from the Failure Artifact.
assert_contains "$out" \
    "Transport progress: total=2, launched=2, running=0/1, pending=0, solved=0, continued=0, skipped=0, failed=2" \
    "a readable regular Failure Artifact keeps the progress field set and the exact failed count"
assert_no_lock_dir "$workspace" "transport regular Failure Artifact"
assert_no_case_state "$workspace" "transport regular Failure Artifact"

# ---- a lock path with spaces and shell metacharacters stays one argument ----

workspace="$(new_workspace odd_lock_path)"
output="${workspace}/out dir & meta;\$x"
mkdir -p "$output" "${workspace}/simpleFoam_files" \
    "${workspace}/scalarTransportDeffFoam_files"
make_csv "${workspace}/output_batch_1.csv" 0 1

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$SETUP_SCRIPT" \
        -i output_batch_1.csv -O "$output" -j 2 --dry-run 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "an unusual lock path keeps exit status 0"
assert_summary_shape "${output}/setup_cases_summary.csv" 10 4 "unusual lock path"
assert_no_lock_dir "$workspace" "unusual lock path"
