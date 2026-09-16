#!/usr/bin/env bash
# Section 23.AB - MPI launcher oversubscription opt-in (Issue #74).
#
# The scenario proves the public contract of BATCH_STAGE_MPI_OVERSUBSCRIBE. The
# control selects the MPI launcher argument vector. It changes no rank count.
#
# Observations T1 to T15 use the mesh, flow, transport, and post-processing
# Stage Runner CLIs, the process status, the console output, the Batch Workspace
# file tree, and the recorded argument vectors of the fake commands. Two
# observations call the two new public library helpers directly, because the
# helper status and the helper output array are part of the declared API.
#
# Checks S1 to S9 read .github/workflows/openfoam-evidence.yml as text. The
# workflow starts only through workflow_dispatch, so the corrected evidence
# capture needs a static check.
#
# Every observation runs in its own child process, so one failure cannot hide a
# later failure and no observation can see the workspace of another observation.
# The scenario reports every failing observation and then fails.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

STAGE_LIBRARY="${MASTER_SRC_DIR}/lib_batch_stage.sh"
WORKFLOW="${REPO_ROOT}/.github/workflows/openfoam-evidence.yml"

# The rank count of every Case in this scenario. The control must never change
# it, so each assertion uses this one value.
AB_RANKS=8

# The rejected value used by every invalid-value observation.
AB_INVALID_VALUE="yes"

# ---- shared fixtures --------------------------------------------------------

# ab_mesh_fixture <workspace> - one meshable Case with AB_RANKS ranks.
ab_mesh_fixture() {
    local workspace="$1"
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" 0
    make_flow_case "${workspace}/case_0/flow" "$AB_RANKS"
}

# ab_flow_fixture <workspace> - one solvable flow Case with AB_RANKS ranks.
ab_flow_fixture() {
    local workspace="$1"
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" 0
    make_flow_case "${workspace}/case_0/flow" "$AB_RANKS"
    make_flow_mesh "${workspace}/case_0/flow"
    printf 'FoamFile { object wallDistance; }\n' \
        > "${workspace}/case_0/flow/0/wallDistance"
}

# ab_transport_fixture <workspace> - one transport Case with AB_RANKS ranks.
# The transport observation uses the fake commands, so it needs no real custom
# solver.
ab_transport_fixture() {
    local workspace="$1" flow_dir trd_dir
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" 0
    flow_dir="${workspace}/case_0/flow"
    trd_dir="${workspace}/case_0/trd"
    make_flow_case "$flow_dir" "$AB_RANKS"
    make_flow_mesh "$flow_dir"
    make_flow_result "$flow_dir" 3000
    make_transport_case "$trd_dir" "$AB_RANKS" T 300
}

# ab_post_fixture <workspace> - one convertible Case for post-processing.
ab_post_fixture() {
    local workspace="$1" flow_dir trd_dir
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" 0
    flow_dir="${workspace}/case_0/flow"
    trd_dir="${workspace}/case_0/trd"
    make_flow_case "$flow_dir" "$AB_RANKS"
    make_flow_result "$flow_dir" 3000
    make_transport_case "$trd_dir" "$AB_RANKS" T 300
    mkdir -p "${trd_dir}/300"
    printf 'FoamFile { object T; }\n' > "${trd_dir}/300/T"
}

# ab_run_mesh <workspace> <policy-mode> [<value>] - run the mesh Stage Runner.
# policy-mode: unset | value
ab_run_mesh() {
    local workspace="$1" mode="$2" value="${3-}"
    if [[ "$mode" == unset ]]; then
        ( cd "$workspace" && bash "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1 )
    else
        ( cd "$workspace" && BATCH_STAGE_MPI_OVERSUBSCRIBE="$value" \
              bash "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1 )
    fi
}

# ab_expected_off_mesh_vector - the base-behavior mesh launcher vector.
ab_expected_off_mesh_vector() {
    argv_line -np "$AB_RANKS" snappyHexMesh -parallel -overwrite
}

# ab_expected_on_mesh_vector - the opt-in mesh launcher vector.
ab_expected_on_mesh_vector() {
    argv_line --oversubscribe -np "$AB_RANKS" snappyHexMesh -parallel -overwrite
}

# ab_no_openfoam_command <message> - no fake command recorded any call.
ab_no_openfoam_command() {
    local message="$1" command_name
    for command_name in "${FAKE_COMMANDS[@]}"; do
        assert_eq 0 "$(fake_call_count "$command_name")" \
            "${message}: ${command_name} must record no call"
    done
}

# ---- T1 to T4: the four launcher states of the mesh Stage -------------------

t1_mesh_unset_vector() {
    local workspace out status
    workspace="$(new_workspace t1)"
    ab_mesh_fixture "$workspace"

    out="$(ab_run_mesh "$workspace" unset)" && status=0 || status=$?

    assert_status 0 "$status" "T1: an unset control keeps the mesh Stage successful: $out"
    assert_eq 1 "$(fake_call_count mpirun)" "T1: the mesh Stage launches mpirun one time"
    assert_eq "$(ab_expected_off_mesh_vector)" "$(fake_argvs mpirun)" \
        "T1: an unset control gives the exact base launcher vector"
    assert_not_contains "$(fake_argvs mpirun)" "--oversubscribe" \
        "T1: an unset control adds no --oversubscribe"
}

t2_mesh_zero_vector() {
    local workspace out status
    workspace="$(new_workspace t2)"
    ab_mesh_fixture "$workspace"

    out="$(ab_run_mesh "$workspace" value 0)" && status=0 || status=$?

    assert_status 0 "$status" "T2: the value 0 keeps the mesh Stage successful: $out"
    assert_eq "$(ab_expected_off_mesh_vector)" "$(fake_argvs mpirun)" \
        "T2: the value 0 gives the exact T1 vector"
    assert_not_contains "$(fake_argvs mpirun)" "--oversubscribe" \
        "T2: the value 0 adds no --oversubscribe"
}

t3_mesh_empty_vector() {
    local workspace out status
    workspace="$(new_workspace t3)"
    ab_mesh_fixture "$workspace"

    out="$(ab_run_mesh "$workspace" value "")" && status=0 || status=$?

    assert_status 0 "$status" "T3: an empty value keeps the mesh Stage successful: $out"
    assert_eq "$(ab_expected_off_mesh_vector)" "$(fake_argvs mpirun)" \
        "T3: an empty value gives the exact T1 vector"
    assert_not_contains "$(fake_argvs mpirun)" "--oversubscribe" \
        "T3: an empty value adds no --oversubscribe"
}

t4_mesh_on_vector() {
    local workspace out status recorded
    workspace="$(new_workspace t4)"
    ab_mesh_fixture "$workspace"

    out="$(ab_run_mesh "$workspace" value 1)" && status=0 || status=$?

    assert_status 0 "$status" "T4: the value 1 keeps the mesh Stage successful: $out"
    assert_eq 1 "$(fake_call_count mpirun)" "T4: the mesh Stage launches mpirun one time"
    recorded="$(fake_argvs mpirun)"
    assert_eq "$(ab_expected_on_mesh_vector)" "$recorded" \
        "T4: the value 1 puts --oversubscribe directly after the launcher"
    assert_eq 1 "$(printf '%s' "$recorded" | tr "$US" '\n' | grep -c '^--oversubscribe$' || true)" \
        "T4: --oversubscribe occurs exactly one time"
    # The wrapped command keeps every existing argument.
    assert_eq "$(argv_line -parallel -overwrite)" "$(fake_argvs snappyHexMesh)" \
        "T4: snappyHexMesh keeps -parallel -overwrite"
}

# ---- T5: an invalid value and an execution request --------------------------

t5_mesh_invalid_value_execution() {
    local workspace out status
    workspace="$(new_workspace t5)"
    ab_mesh_fixture "$workspace"

    out="$(ab_run_mesh "$workspace" value "$AB_INVALID_VALUE")" && status=0 || status=$?

    assert_status 1 "$status" "T5: an invalid value gives status 1"
    assert_contains "$out" "BATCH_STAGE_MPI_OVERSUBSCRIBE" \
        "T5: the diagnostic names the variable"
    assert_contains "$out" "$AB_INVALID_VALUE" \
        "T5: the diagnostic names the rejected value"
    ab_no_openfoam_command "T5"
    assert_file_missing "${workspace}/run_mesh_cases_summary.csv" \
        "T5: an invalid value writes no Stage summary"
    assert_file_missing "${workspace}/.run_mesh_cases_failed" \
        "T5: an invalid value writes no Failure Artifact"
    assert_dir_missing "${workspace}/_mesh_logs" \
        "T5: an invalid value creates no log directory"
    assert_dir_missing "${workspace}/_mesh_state" \
        "T5: an invalid value creates no state directory"
}

# ---- T6: the flow Stage with the opt-in -------------------------------------

t6_flow_on_vector() {
    local workspace out status
    workspace="$(new_workspace t6)"
    ab_flow_fixture "$workspace"

    out="$(cd "$workspace" && BATCH_STAGE_MPI_OVERSUBSCRIBE=1 \
            bash "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
        && status=0 || status=$?

    assert_status 0 "$status" "T6: the value 1 keeps the flow Stage successful: $out"
    assert_eq 2 "$(fake_call_count mpirun)" "T6: the flow Stage launches mpirun two times"
    assert_eq "$(printf '%s\n%s' \
            "$(argv_line --oversubscribe -np "$AB_RANKS" renumberMesh -parallel -overwrite)" \
            "$(argv_line --oversubscribe -np "$AB_RANKS" simpleFoam -parallel)")" \
        "$(fake_argvs mpirun)" \
        "T6: both flow launches hold --oversubscribe directly after the launcher"
    assert_eq "$(argv_line -parallel)" "$(fake_argvs simpleFoam)" \
        "T6: the flow solver keeps -parallel"
}

# ---- T7: the transport Stage with the opt-in --------------------------------

t7_transport_on_vector() {
    local workspace out status
    workspace="$(new_workspace t7)"
    ab_transport_fixture "$workspace"

    out="$(cd "$workspace" && BATCH_STAGE_MPI_OVERSUBSCRIBE=1 FAKE_SOLVER_TIMES="300" \
            bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
        && status=0 || status=$?

    assert_status 0 "$status" "T7: the value 1 keeps the transport Stage successful: $out"
    assert_eq 2 "$(fake_call_count mpirun)" \
        "T7: the transport Stage launches mpirun two times"
    assert_eq "$(printf '%s\n%s' \
            "$(argv_line --oversubscribe -np "$AB_RANKS" renumberMesh -parallel -overwrite)" \
            "$(argv_line --oversubscribe -np "$AB_RANKS" scalarTransportDeffFoam -parallel)")" \
        "$(fake_argvs mpirun)" \
        "T7: both transport launches hold --oversubscribe directly after the launcher"
    assert_eq "$(argv_line -parallel)" "$(fake_argvs scalarTransportDeffFoam)" \
        "T7: the transport solver keeps -parallel"
}

# ---- T8: the control changes no rank count ----------------------------------

t8_rank_count_unchanged() {
    local workspace out status dict
    workspace="$(new_workspace t8)"
    ab_mesh_fixture "$workspace"
    dict="${workspace}/case_0/flow/system/decomposeParDict"

    out="$(ab_run_mesh "$workspace" value 1)" && status=0 || status=$?

    assert_status 0 "$status" "T8: the value 1 keeps the mesh Stage successful: $out"
    assert_file_exists "$dict" "T8: the Case keeps system/decomposeParDict"
    assert_contains "$(cat "$dict")" "numberOfSubdomains ${AB_RANKS};" \
        "T8: the control keeps numberOfSubdomains at ${AB_RANKS}"
    assert_eq "$AB_RANKS" "$(fake_arg_after mpirun -np)" \
        "T8: the launcher still receives the Case rank count"
}

# ---- T9: the post-processing Stage ignores the control ----------------------

# ab_post_result <workspace> - the workspace-independent post-processing result.
# Each absolute workspace path becomes the token <workspace>, so two runs in two
# workspaces are comparable.
ab_post_result() {
    local workspace="$1"
    {
        echo "== summary =="
        sed -e "s#${workspace}#<workspace>#g" \
            -- "${workspace}/run_post_processing_cases_summary.csv"
        echo "== vtk tree =="
        ( cd "$workspace" && find case_0/vtk -type f | sort )
        echo "== foamToVTK calls =="
        fake_argvs foamToVTK
    }
}

t9_post_result_unchanged() {
    local off_workspace on_workspace off_out on_out off_status on_status
    local off_result on_result off_calls on_calls off_mpi on_mpi

    off_workspace="$(new_workspace t9off)"
    ab_post_fixture "$off_workspace"
    off_out="$(cd "$off_workspace" && bash "$POST_SCRIPT" \
            -i output_batch_1.csv -O . -j 1 2>&1)" && off_status=0 || off_status=$?
    off_result="$(ab_post_result "$off_workspace")"
    off_calls="$(fake_call_count foamToVTK)"
    off_mpi="$(fake_call_count mpirun)"

    on_workspace="$(new_workspace t9on)"
    ab_post_fixture "$on_workspace"
    on_out="$(cd "$on_workspace" && BATCH_STAGE_MPI_OVERSUBSCRIBE=1 bash "$POST_SCRIPT" \
            -i output_batch_1.csv -O . -j 1 2>&1)" && on_status=0 || on_status=$?
    on_result="$(ab_post_result "$on_workspace")"
    on_calls="$(fake_call_count foamToVTK)"
    on_mpi="$(fake_call_count mpirun)"

    assert_status 0 "$off_status" \
        "T9: the post-processing Stage succeeds without the control: $off_out"
    assert_status 0 "$on_status" \
        "T9: the post-processing Stage succeeds with the control: $on_out"
    assert_eq "$off_result" "$on_result" \
        "T9: the control changes no post-processing Stage result"
    assert_eq "$off_calls" "$on_calls" "T9: the control changes no foamToVTK call count"
    assert_eq 0 "$off_mpi" \
        "T9: the post-processing Stage launches no MPI command without the control"
    assert_eq 0 "$on_mpi" \
        "T9: the post-processing Stage launches no MPI command with the control"
}

# ---- T10: flow and transport reject an invalid value ------------------------

t10_flow_transport_invalid_value_execution() {
    local workspace out status

    workspace="$(new_workspace t10flow)"
    ab_flow_fixture "$workspace"
    out="$(cd "$workspace" && BATCH_STAGE_MPI_OVERSUBSCRIBE="$AB_INVALID_VALUE" \
            bash "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
        && status=0 || status=$?
    assert_status 1 "$status" "T10: the flow Stage Runner gives status 1"
    assert_contains "$out" "BATCH_STAGE_MPI_OVERSUBSCRIBE" \
        "T10: the flow diagnostic names the variable"
    assert_contains "$out" "$AB_INVALID_VALUE" \
        "T10: the flow diagnostic names the rejected value"
    ab_no_openfoam_command "T10 flow"
    assert_file_missing "${workspace}/run_flow_cases_summary.csv" \
        "T10: the flow Stage Runner writes no Stage summary"
    assert_file_missing "${workspace}/.run_flow_cases_failed" \
        "T10: the flow Stage Runner writes no Failure Artifact"
    assert_dir_missing "${workspace}/_flow_logs" \
        "T10: the flow Stage Runner creates no log directory"

    workspace="$(new_workspace t10transport)"
    ab_transport_fixture "$workspace"
    out="$(cd "$workspace" && BATCH_STAGE_MPI_OVERSUBSCRIBE="$AB_INVALID_VALUE" \
            bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j 1 2>&1)" \
        && status=0 || status=$?
    assert_status 1 "$status" "T10: the transport Stage Runner gives status 1"
    assert_contains "$out" "BATCH_STAGE_MPI_OVERSUBSCRIBE" \
        "T10: the transport diagnostic names the variable"
    assert_contains "$out" "$AB_INVALID_VALUE" \
        "T10: the transport diagnostic names the rejected value"
    ab_no_openfoam_command "T10 transport"
    assert_file_missing "${workspace}/run_transport_cases_summary.csv" \
        "T10: the transport Stage Runner writes no Stage summary"
    assert_file_missing "${workspace}/.run_transport_cases_failed" \
        "T10: the transport Stage Runner writes no Failure Artifact"
    assert_dir_missing "${workspace}/_transport_logs" \
        "T10: the transport Stage Runner creates no log directory"
    assert_dir_missing "${workspace}/_transport_state" \
        "T10: the transport Stage Runner creates no state directory"
}

# ---- T11 to T13: an invalid value keeps every help request successful -------

# ab_help_observation <label> <script> <summary-name> <fail-name> <option>
ab_help_observation() {
    local label="$1" script="$2" summary="$3" fail_file="$4" option="$5"
    local workspace out status
    workspace="$(new_workspace "${label}${option//-/}")"
    install_fakes "$workspace"
    assert_fakes_active

    out="$(cd "$workspace" && BATCH_STAGE_MPI_OVERSUBSCRIBE="$AB_INVALID_VALUE" \
            bash "$script" "$option" 2>&1)" && status=0 || status=$?

    assert_status 0 "$status" "${label}: ${option} keeps status 0 with an invalid value"
    assert_contains "$out" "Usage:" "${label}: ${option} prints the help text"
    assert_help_option "$out" "-h" "${label}: the help text lists -h"
    # The help text documents the control, so the assertion targets the
    # diagnostic text and not the variable name.
    assert_contains "$out" "BATCH_STAGE_MPI_OVERSUBSCRIBE=1" \
        "${label}: the help text documents the control"
    assert_not_contains "$out" "must be unset, empty, 0, or 1" \
        "${label}: ${option} writes no invalid-policy diagnostic"
    assert_not_contains "$out" "Rejected value" \
        "${label}: ${option} names no rejected value"
    assert_not_contains "$out" "[ERROR]" \
        "${label}: ${option} writes no error diagnostic"
    ab_no_openfoam_command "${label} ${option}"
    assert_file_missing "${workspace}/${summary}" \
        "${label}: ${option} writes no Stage summary"
    assert_file_missing "${workspace}/${fail_file}" \
        "${label}: ${option} writes no Failure Artifact"
}

t11_mesh_help_invalid_value() {
    ab_help_observation T11 "$MESH_SCRIPT" \
        run_mesh_cases_summary.csv .run_mesh_cases_failed -h
    ab_help_observation T11 "$MESH_SCRIPT" \
        run_mesh_cases_summary.csv .run_mesh_cases_failed --help
}

t12_flow_help_invalid_value() {
    ab_help_observation T12 "$FLOW_SCRIPT" \
        run_flow_cases_summary.csv .run_flow_cases_failed -h
    ab_help_observation T12 "$FLOW_SCRIPT" \
        run_flow_cases_summary.csv .run_flow_cases_failed --help
}

t13_transport_help_invalid_value() {
    ab_help_observation T13 "$TRANSPORT_SCRIPT" \
        run_transport_cases_summary.csv .run_transport_cases_failed -h
    ab_help_observation T13 "$TRANSPORT_SCRIPT" \
        run_transport_cases_summary.csv .run_transport_cases_failed --help
}

# ---- T14 and T15: the launcher rejects an invalid argument ------------------

# ab_launcher_probe <workspace> <preset> <rank-count> <policy>
#
# The probe sources the library in a child process, calls the launcher, and
# prints the exact status and the exact array state. preset `sentinel` assigns a
# known array before the call, so an unchanged array is provable. The child
# writes standard error to a file, so the library output rule is provable.
ab_launcher_probe() {
    local workspace="$1" preset="$2" rank_count="$3" policy="$4"
    mkdir -p -- "$workspace"
    bash -c '
        set -uo pipefail
        library="$1"; preset="$2"; rank_count="$3"; policy="$4"
        # shellcheck disable=SC1090
        source "$library"
        if [[ "$preset" == sentinel ]]; then
            BATCH_STAGE_MPI_LAUNCHER=(sentinel-value)
        fi
        batch_stage_mpi_launcher "$rank_count" "$policy"
        printf "status=%s\n" "$?"
        if [[ -n "${BATCH_STAGE_MPI_LAUNCHER+set}" ]]; then
            printf "array=SET\n"
            printf "element=%s\n" "${BATCH_STAGE_MPI_LAUNCHER[@]}"
        else
            printf "array=UNSET\n"
        fi
    ' _ "$STAGE_LIBRARY" "$preset" "$rank_count" "$policy" \
        2> "${workspace}/stderr.txt"
}

t14_launcher_rejects_unvalidated() {
    local workspace out
    workspace="$(new_workspace t14)"

    out="$(ab_launcher_probe "$workspace" none "$AB_RANKS" unvalidated)"

    assert_contains "$out" "status=1" \
        "T14: the launcher returns 1 for the normalized value unvalidated"
    assert_contains "$out" "array=UNSET" \
        "T14: the launcher leaves BATCH_STAGE_MPI_LAUNCHER unset"
    assert_eq "" "$(cat "${workspace}/stderr.txt")" \
        "T14: the library writes no standard-error output"
}

t15_launcher_rejects_bad_rank_count() {
    local workspace out value label

    # A rejected rank count gives status 1, leaves the array unchanged, and
    # writes nothing.
    for value in 0 00 abc 1.5 -1 "+8"; do
        label="${value//[^0-9a-zA-Z]/x}"
        workspace="$(new_workspace "t15_reject_${label}")"
        out="$(ab_launcher_probe "$workspace" sentinel "$value" on)"

        assert_contains "$out" "status=1" \
            "T15: the launcher returns 1 for the rank count '${value}'"
        assert_contains "$out" "element=sentinel-value" \
            "T15: the rank count '${value}' leaves the array unchanged"
        assert_not_contains "$out" "element=mpirun" \
            "T15: the rank count '${value}' writes no launcher vector"
        assert_eq "" "$(cat "${workspace}/stderr.txt")" \
            "T15: the library writes no standard-error output for '${value}'"
    done

    # A leading-zero decimal rank count is valid. Bash reads a leading-zero
    # operand as octal, so an arithmetic test would reject 08 and would write a
    # diagnostic. The launcher validates a decimal string instead, and it keeps
    # the accepted rank-count text unchanged in the vector.
    workspace="$(new_workspace t15_accept_08)"
    out="$(ab_launcher_probe "$workspace" none 08 off)"

    assert_contains "$out" "status=0" \
        "T15: the launcher accepts the decimal rank count 08"
    assert_contains "$out" "element=mpirun" \
        "T15: the rank count 08 writes a launcher vector"
    assert_eq "$(printf 'status=0\narray=SET\nelement=mpirun\nelement=-np\nelement=08')" \
        "$out" \
        "T15: the rank count 08 gives the exact vector mpirun -np 08"
    assert_eq "" "$(cat "${workspace}/stderr.txt")" \
        "T15: the rank count 08 writes no standard-error output"

    # The same rule holds with the on policy and with a longer leading-zero run.
    workspace="$(new_workspace t15_accept_007_on)"
    out="$(ab_launcher_probe "$workspace" none 007 on)"

    assert_eq "$(printf 'status=0\narray=SET\nelement=mpirun\nelement=--oversubscribe\nelement=-np\nelement=007')" \
        "$out" \
        "T15: the rank count 007 keeps its exact text with the on policy"
    assert_eq "" "$(cat "${workspace}/stderr.txt")" \
        "T15: the rank count 007 writes no standard-error output"
}

# ---- workflow static-check helpers -----------------------------------------

# ab_workflow_step_block <step-name> - the exact text of one workflow step.
ab_workflow_step_block() {
    awk -v want="      - name: $1" '
        $0 == want { inside = 1; print; next }
        inside && /^      - name: / { exit }
        inside { print }
    ' "$WORKFLOW"
}

# ab_workflow_job_env_block - the exact text of the job-level env block.
ab_workflow_job_env_block() {
    awk '
        /^    env:[[:space:]]*$/ { inside = 1; next }
        inside {
            if ($0 ~ /^[[:space:]]*$/) { next }
            if ($0 ~ /^      [^[:space:]]/) { print; next }
            exit
        }
    ' "$WORKFLOW"
}

s1_upload_path_is_runner_temp() {
    local block
    assert_file_exists "$WORKFLOW" "S1: the evidence workflow exists"
    block="$(ab_workflow_step_block "Upload the evidence artifacts")"
    assert_contains "$block" 'path: ${{ runner.temp }}/evidence' \
        "S1: the upload path is the runner temporary evidence directory"
    assert_not_contains "$block" "path: evidence/" \
        "S1: the upload path is not the checkout evidence directory"
}

s2_if_no_files_found_is_error() {
    local block
    block="$(ab_workflow_step_block "Upload the evidence artifacts")"
    assert_contains "$block" "if-no-files-found: error" \
        "S2: the upload guard is error"
    assert_not_contains "$block" "if-no-files-found: warn" \
        "S2: the upload guard is not warn"
}

s3_job_env_declares_no_evidence_dir() {
    local block
    block="$(ab_workflow_job_env_block)"
    assert_contains "$block" "OPENFOAM_PACKAGE:" \
        "S3: the job-level env block is readable"
    assert_not_contains "$block" "EVIDENCE_DIR" \
        "S3: the job-level env block declares no EVIDENCE_DIR"
}

s4_first_step_sets_evidence_dir() {
    local block
    block="$(ab_workflow_step_block "Start the evidence clock")"
    assert_contains "$block" 'EVIDENCE_DIR=${RUNNER_TEMP}/evidence' \
        "S4: the first step derives EVIDENCE_DIR from RUNNER_TEMP"
    assert_contains "$block" 'GITHUB_ENV' \
        "S4: the first step publishes EVIDENCE_DIR through GITHUB_ENV"
}

s5_orchestrator_step_sets_the_optin() {
    local block
    block="$(ab_workflow_step_block "Run the Orchestrator")"
    assert_contains "$block" 'BATCH_STAGE_MPI_OVERSUBSCRIBE: "1"' \
        "S5: the Orchestrator step sets the control to 1"
    assert_contains "$block" "env:" \
        "S5: the Orchestrator step uses a step-level env block"
    assert_not_contains "$(ab_workflow_job_env_block)" \
        "BATCH_STAGE_MPI_OVERSUBSCRIBE" \
        "S5: the control is not a job-level environment value"
}

s6_capture_step_names_every_failure_artifact() {
    local block name
    block="$(ab_workflow_step_block "Capture the evidence")"
    for name in .setup_cases_failed .run_mesh_cases_failed .run_flow_cases_failed \
                .run_transport_cases_failed .run_post_processing_cases_failed; do
        assert_contains "$block" "$name" \
            "S6: the capture step names the Failure Artifact ${name}"
    done
}

s7_capture_step_names_every_log_directory() {
    local block name
    block="$(ab_workflow_step_block "Capture the evidence")"
    for name in _setup_logs _mesh_logs _flow_logs _transport_logs; do
        assert_contains "$block" "$name" \
            "S7: the capture step names the per-Case log directory ${name}"
    done
    assert_contains "$block" "vtk/logs" \
        "S7: the capture step names the post-processing conversion log directory"
}

# ab_extract_vtu_extractor - print the production vtu_header_point_data_names
# function from the workflow, de-indented so that it can be sourced. The test
# therefore runs the exact committed code, not a copy of it.
ab_extract_vtu_extractor() {
    awk '
        /^          vtu_header_point_data_names\(\) \{$/ { inside = 1 }
        inside { print }
        inside && /^          \}$/ { exit }
    ' "$WORKFLOW" | sed -e 's/^          //'
}

s8_capture_step_writes_the_vtu_manifest() {
    local block
    block="$(ab_workflow_step_block "Capture the evidence")"
    assert_contains "$block" "vtu-point-data.txt" \
        "S8: the capture step writes the VTU point-data manifest"
    assert_contains "$block" "AppendedData" \
        "S8: the manifest reads only the bytes before the appended payload"
    assert_contains "$block" "VTU_EVIDENCE=UNAVAILABLE" \
        "S8: the manifest records an explicit unavailable result"
    assert_not_contains "$block" "VTU_HEADER_BOUND_BYTES" \
        "S8: the extraction uses no arbitrary header size limit"

    # The extraction must end at the marker. A record separator that ends the
    # marker record only at the next tag-opening byte makes the parser wait for,
    # and hold, the complete appended payload.
    local workspace extractor fixture producer observed status elapsed start end
    workspace="$(new_workspace s8_boundary)"
    extractor="${workspace}/vtu_extractor.sh"
    ab_extract_vtu_extractor > "$extractor"
    bash -n "$extractor" ||
        _fail "S8: the extracted production extractor must parse"
    assert_contains "$(cat "$extractor")" "vtu_header_point_data_names() {" \
        "S8: the production extractor is extracted from the workflow"

    # A producer that publishes the complete header and the marker into a stream
    # that it keeps open, then holds the payload back. A named pipe is used, so
    # the reader cannot reach end of file early: an extractor that waits for the
    # appended payload blocks, and a correct extractor completes at the marker.
    fixture="${workspace}/delayed.vtu"
    mkfifo "$fixture" || _fail "S8: the scenario needs a named pipe"
    (
        printf '<?xml version="1.0"?>\n<VTKFile><UnstructuredGrid><Piece>'
        printf '<PointData><DataArray Name="U"/><DataArray Name="p"/></PointData>'
        printf '<CellData><DataArray Name="S8_CELL_MUST_NOT_APPEAR"/></CellData>'
        printf '</Piece></UnstructuredGrid>\n  <AppendedData encoding="raw">\n'
        sleep 30
        printf '_S8_PAYLOAD_MUST_NOT_APPEAR\n  </AppendedData></VTKFile>\n'
    ) > "$fixture" &
    producer=$!

    start="$(date +%s)"
    observed="$(timeout 10 bash -c 'source "$1"; vtu_header_point_data_names "$2"' _ \
        "$extractor" "$fixture")" && status=0 || status=$?
    end="$(date +%s)"
    elapsed=$(( end - start ))

    kill "$producer" 2>/dev/null || true
    wait "$producer" 2>/dev/null || true

    assert_status 0 "$status" \
        "S8: the extractor completes while the payload is still withheld"
    assert_eq "U p" "$observed" \
        "S8: the extractor reads the complete header before the marker"
    assert_not_contains "$observed" "S8_CELL_MUST_NOT_APPEAR" \
        "S8: a same-line CellData element contributes no name"
    assert_not_contains "$observed" "S8_PAYLOAD_MUST_NOT_APPEAR" \
        "S8: no appended-payload byte reaches the output"
    if (( elapsed >= 10 )); then
        _fail "S8: the extractor must not wait for the appended payload" \
            "elapsed seconds: ${elapsed}"
    fi

    # A complete header larger than any fixed limit still yields its names.
    local large="${workspace}/large.vtu"
    {
        printf '<VTKFile><Piece>\n<FieldData>\n'
        awk 'BEGIN { for (i = 0; i < 900; i++) printf "  pad %05d %s\n", i, \
             "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }'
        printf '</FieldData>\n<PointData><DataArray Name="U"/><DataArray Name="p"/></PointData>'
        printf '<CellData><DataArray Name="S8_LATE_CELL"/></CellData>\n</Piece>\n'
        printf '  <AppendedData encoding="raw">\n_S8_LATE_PAYLOAD\n  </AppendedData></VTKFile>\n'
    } > "$large"
    local large_offset
    large_offset="$(grep -abo '<PointData' "$large" | head -n 1 | cut -d: -f1)"
    if (( large_offset <= 65536 )); then
        _fail "S8: the large-header fixture must declare PointData beyond 65536 bytes" \
            "observed offset: ${large_offset}"
    fi
    observed="$(bash -c 'source "$1"; vtu_header_point_data_names "$2"' _ "$extractor" "$large")"
    assert_eq "U p" "$observed" \
        "S8: a PointData declaration beyond 65536 bytes is still read"
    assert_not_contains "$observed" "S8_LATE_CELL" \
        "S8: the large-header CellData element contributes no name"
    assert_not_contains "$observed" "S8_LATE_PAYLOAD" \
        "S8: the large-header payload contributes no name"
}

s9_upload_step_includes_hidden_files() {
    local block
    block="$(ab_workflow_step_block "Upload the evidence artifacts")"
    assert_contains "$block" "include-hidden-files: true" \
        "S9: the upload step includes the dot-prefixed Failure Artifacts"
}

# ---- the observation list ---------------------------------------------------

AB_OBSERVATIONS=(
    t1_mesh_unset_vector
    t2_mesh_zero_vector
    t3_mesh_empty_vector
    t4_mesh_on_vector
    t5_mesh_invalid_value_execution
    t6_flow_on_vector
    t7_transport_on_vector
    t8_rank_count_unchanged
    t9_post_result_unchanged
    t10_flow_transport_invalid_value_execution
    t11_mesh_help_invalid_value
    t12_flow_help_invalid_value
    t13_transport_help_invalid_value
    t14_launcher_rejects_unvalidated
    t15_launcher_rejects_bad_rank_count
    s1_upload_path_is_runner_temp
    s2_if_no_files_found_is_error
    s3_job_env_declares_no_evidence_dir
    s4_first_step_sets_evidence_dir
    s5_orchestrator_step_sets_the_optin
    s6_capture_step_names_every_failure_artifact
    s7_capture_step_names_every_log_directory
    s8_capture_step_writes_the_vtu_manifest
    s9_upload_step_includes_hidden_files
)

# One observation runs in this process when the caller names it. The scenario
# runner never uses this form; the scenario itself uses it for each child.
if [[ "${1:-}" == "--observation" ]]; then
    "$2"
    exit 0
fi

failed_observations=()
for observation in "${AB_OBSERVATIONS[@]}"; do
    if bash "${BASH_SOURCE[0]}" --observation "$observation" 2>&1 |
            sed -e "s/^/  [${observation}] /"; then
        printf 'OBSERVATION PASS: %s\n' "$observation"
    else
        printf 'OBSERVATION FAIL: %s\n' "$observation"
        failed_observations+=("$observation")
    fi
done

printf '\nObservations : %s\n' "${#AB_OBSERVATIONS[@]}"
printf 'Failed       : %s\n' "${#failed_observations[@]}"

if (( ${#failed_observations[@]} > 0 )); then
    printf 'Failed observations: %s\n' "${failed_observations[*]}" >&2
    exit 1
fi
