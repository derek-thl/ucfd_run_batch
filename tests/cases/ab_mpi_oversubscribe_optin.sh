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
# Checks S10 to S17 execute code extracted from that workflow (Issue #87). S10
# runs the production VTU reader on a finite ASCII VTU file without an
# <AppendedData> marker under a 5-second limit. S11 to S14 run the capture step
# body with a controlled deadline, a synthetic Batch Workspace, and fake
# commands that block, so the work limit, the early phase results, and the
# capture result are observable without OpenFOAM and without a dispatch. S15
# checks that the summary and the upload steps stay eligible. S16 and S17 prove
# that a VTU parse failure and a failed Stage evidence search or copy give an
# incomplete capture (PR #88 review 5289074428).
#
# Checks S18 to S24 cover the M3 evidence-recovery contract (Issue #80). They run
# the extracted capture step on synthetic VTU files, checkMesh logs, simpleFoam
# logs, and the committed Case controls. They prove the per-file required-field
# verdict, the retained original tags with offsets and checksums, the tag output
# limits, the scan timeout, the mesh-quality verdict, the convergence verdict,
# and the job summary rows. S25 and S26 cover PR #89 review 5298374123: Name
# text inside another attribute value is not a field name, and the convergence
# verdict fails closed on changed controls, missing final records, and a stale
# or wrong solver marker. S27 covers PR #89 review 5299046150: text inside an
# XML comment, a CDATA section, or a processing instruction is not markup, and
# an unterminated comment or a document type declaration gives no names. S28
# covers PR #89 review 5299460078: an unclosed or mismatched element gives no
# names, and only a direct DataArray child of PointData or CellData counts. S29
# covers PR #89 review 5300443151: a start or end tag with invalid syntax gives
# no names, and the original bytes of a rejected evidence tag are kept.
#
# Checks S30 to S41 cover the Case 7 mesh-phase diagnostic workflow
# openfoam-m3-mesh-diagnostic.yml (Issue #80). They run its extracted steps with
# a fake checkout, a fake setup Stage, a fake OpenFOAM tree, and fake system
# commands. They prove the interface, the Case identity and version gates, the
# help checks, the command order, the phase map, the result classes, the exact
# check evidence, the stop rules, the timeouts, the output limits, and that no
# solver, flow Stage, post-processing Stage, or dispatch runs.
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

# ab_extract_vtu_extractor - print the production VTU header reader from the
# workflow, de-indented so that it can be sourced. The test therefore runs the
# exact committed code, not a copy of it. The reader is the block between the
# two reader marker comments. A workflow without the markers holds only the
# single vtu_header_point_data_names function.
ab_extract_vtu_extractor() {
    if grep -q '^          # ---- VTU header reader: begin ----$' "$WORKFLOW"; then
        awk '
            /^          # ---- VTU header reader: begin ----$/ { inside = 1; next }
            /^          # ---- VTU header reader: end ----$/ { exit }
            inside { print }
        ' "$WORKFLOW" | sed -e 's/^          //'
        return 0
    fi
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

# ab_vtu_fields <extractor> <file> [<seconds>] - run the extracted production
# reader on one file under a timeout. Prints the names, then status=<status>.
ab_vtu_fields() {
    local extractor="$1" file="$2" seconds="${3:-10}" observed status
    observed="$(timeout "$seconds" bash -c 'source "$1"; vtu_header_point_data_names "$2"' _ \
        "$extractor" "$file")" && status=0 || status=$?
    printf '%s\nstatus=%s\n' "$observed" "$status"
}

# ab_ascii_vtu <file> <data-lines> - a finite ASCII VTU file without an
# <AppendedData> marker. PointData holds U and p, and a same-line CellData
# element follows it. Each data line has 64 bytes.
ab_ascii_vtu() {
    local file="$1" lines="$2"
    {
        printf '<?xml version="1.0"?>\n<VTKFile type="UnstructuredGrid">\n'
        printf '<UnstructuredGrid><Piece NumberOfPoints="1" NumberOfCells="1">\n'
        printf '<PointData Vectors="U" Scalars="p">\n'
        printf '<DataArray type="Float32" Name="U" NumberOfComponents="3" format="ascii">\n'
        awk -v n="$lines" 'BEGIN { for (i = 0; i < n; i++)
            printf "%015d %015d %015d %015d\n", i, i, i, i }'
        printf '</DataArray>\n<DataArray type="Float32" Name="p" format="ascii">\n'
        awk -v n="$lines" 'BEGIN { for (i = 0; i < n; i++)
            printf "%015d %015d %015d %015d\n", i, i, i, i }'
        printf '</DataArray>\n</PointData><CellData><DataArray Name="S10_CELL"/></CellData>\n'
        printf '</Piece></UnstructuredGrid>\n</VTKFile>\n'
    } > "$file"
}

s10_vtu_reader_reads_a_large_no_marker_file() {
    local workspace extractor fixture bytes result
    workspace="$(new_workspace s10_no_marker)"
    extractor="${workspace}/vtu_extractor.sh"
    ab_extract_vtu_extractor > "$extractor"
    bash -n "$extractor" ||
        _fail "S10: the extracted production extractor must parse"

    # At least 512 KiB, with no <AppendedData> marker. The reader must read the
    # complete finite file in one linear pass under the same 5-second limit.
    fixture="${workspace}/ascii.vtu"
    ab_ascii_vtu "$fixture" 4200
    bytes="$(wc -c < "$fixture" | tr -d ' ')"
    if (( bytes < 524288 )); then
        _fail "S10: the no-marker fixture must hold at least 512 KiB" "bytes: ${bytes}"
    fi
    if grep -q 'AppendedData' "$fixture"; then
        _fail "S10: the no-marker fixture must not hold an <AppendedData> marker"
    fi

    result="$(ab_vtu_fields "$extractor" "$fixture" 5)"
    assert_eq "$(printf 'U p\nstatus=0')" "$result" \
        "S10: a ${bytes}-byte ASCII VTU file without <AppendedData> gives U p within 5 seconds"
    assert_not_contains "$result" "S10_CELL" \
        "S10: the same-line CellData element contributes no name"

    # A failed or incomplete parse is not a valid empty result.
    printf '<VTKFile><Piece><PointData></PointData></Piece>\n</VTKFile>\n' \
        > "${workspace}/empty.vtu"
    assert_eq "$(printf '\nstatus=0')" "$(ab_vtu_fields "$extractor" "${workspace}/empty.vtu")" \
        "S10: an empty PointData element is a complete parse with no name"
    printf '<VTKFile><Piece><PointData><DataArray Name="U"/>\n' > "${workspace}/truncated.vtu"
    assert_eq "$(printf '\nstatus=2')" "$(ab_vtu_fields "$extractor" "${workspace}/truncated.vtu")" \
        "S10: an unclosed PointData element is an incomplete parse with no name"
    assert_eq "$(printf '\nstatus=1')" "$(ab_vtu_fields "$extractor" "${workspace}/absent.vtu")" \
        "S10: a missing file is a read failure with no name"
}

# ---- S11 to S15: the bounded capture step -----------------------------------

# ab_step_run_body <step-name> [<workflow>] - the dedented shell body of one
# workflow step. The body is the block under `run: |`, which the workflows
# indent by ten spaces. The extraction ends at the first line that leaves that
# body. The default workflow is openfoam-evidence.yml.
ab_step_run_body() {
    awk -v want="      - name: $1" '
        $0 == want { found = 1; next }
        found && /^      - name: / { exit }
        found && !inside && /^        run: \|[[:space:]]*$/ { inside = 1; next }
        inside {
            if ($0 ~ /^[[:space:]]*$/) { print ""; next }
            if ($0 !~ /^          /) { exit }
            print substr($0, 11)
        }
    ' "${2:-$WORKFLOW}"
}

# ab_capture_fixture <workspace> - a Batch Workspace with Stage evidence, one VTU
# file, the production bounded-runner library, and a fake-command directory.
ab_capture_fixture() {
    local workspace="$1" batch
    mkdir -p "${workspace}/runner_temp" "${workspace}/tmp" "${workspace}/fakebin"
    : > "${workspace}/github_env"
    : > "${workspace}/fake_pids"

    batch="${workspace}/checkout/src/batch_9"
    mkdir -p "${batch}/case_7/vtk" "${batch}/_flow_logs"
    printf 'case,status\ncase_7,OK\n' > "${batch}/setup_cases_summary.csv"
    printf 'case,status\ncase_7,FAILED\n' > "${batch}/run_flow_cases_summary.csv"
    printf 'case_7\n' > "${batch}/.run_flow_cases_failed"
    printf 'flow log\n' > "${batch}/_flow_logs/case_7.log"
    printf 'solver log\n' > "${batch}/case_7/log.simpleFoam"
    {
        printf '<VTKFile><Piece><PointData><DataArray Name="U"/><DataArray Name="p"/>'
        printf '</PointData></Piece>\n<AppendedData encoding="raw">_payload\n'
        printf '</AppendedData></VTKFile>\n'
    } > "${batch}/case_7/vtk/flow_latest_100.vtu"

    ab_step_run_body "Create the bounded-runner library" > "${workspace}/lib_step.sh"
    ab_step_run_body "Capture the evidence" > "${workspace}/capture_step.sh"
    ab_step_run_body "Write the job summary" > "${workspace}/summary_step.sh"
    bash -n "${workspace}/capture_step.sh" ||
        _fail "S11: the extracted capture step must parse"
    RUNNER_TEMP="${workspace}/runner_temp" GITHUB_ENV="${workspace}/github_env" \
        bash "${workspace}/lib_step.sh" > /dev/null ||
        _fail "S11: the production bounded-runner library step must succeed"
}

# ab_fake_hang <workspace> <command> <argument-pattern> - a fake command that
# records its process ID and blocks when one argument matches the pattern, and
# that runs the real command otherwise.
ab_fake_hang() {
    local workspace="$1" name="$2" pattern="$3" real
    real="$(command -v "$name")"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for argument in "$@"; do\n'
        printf '    case "$argument" in\n'
        printf '        %s)\n' "$pattern"
        printf '            printf "%%s\\n" "$$" >> %q\n' "${workspace}/fake_pids"
        printf '            [[ -f "${EVIDENCE_DIR}/phase-results.txt" ]] &&\n'
        printf '                printf "present\\n" >> %q\n' "${workspace}/phase_results_at_block"
        printf '            exec sleep 300 ;;\n'
        printf '    esac\n'
        printf 'done\n'
        printf 'exec %q "$@"\n' "$real"
    } > "${workspace}/fakebin/${name}"
    chmod +x "${workspace}/fakebin/${name}"
}

# ab_fake_fail <workspace> <command> <argument-pattern> - a fake command that
# ends with status 1 and writes nothing when one argument matches the pattern,
# and that runs the real command otherwise.
ab_fake_fail() {
    local workspace="$1" name="$2" pattern="$3" real
    real="$(command -v "$name")"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for argument in "$@"; do\n'
        printf '    case "$argument" in\n'
        printf '        %s) exit 1 ;;\n' "$pattern"
        printf '    esac\n'
        printf 'done\n'
        printf 'exec %q "$@"\n' "$real"
    } > "${workspace}/fakebin/${name}"
    chmod +x "${workspace}/fakebin/${name}"
}

# ab_run_capture <workspace> <deadline> - run the extracted capture step with a
# controlled deadline and a known product failure. Prints status=<status> and
# elapsed=<seconds>.
ab_run_capture() {
    local workspace="$1" deadline="$2" start status
    start="$(date +%s)"
    env PATH="${workspace}/fakebin:${PATH}" \
        TMPDIR="${workspace}/tmp" \
        RUNNER_TEMP="${workspace}/runner_temp" \
        EVIDENCE_DIR="${workspace}/runner_temp/evidence" \
        GITHUB_ENV="${workspace}/github_env" \
        GITHUB_WORKSPACE="${workspace}/checkout" \
        LIB="${workspace}/runner_temp/evidence_lib.sh" \
        CAPTURE_DEADLINE="$deadline" \
        EVIDENCE_CLOCK_START="$(( deadline - 6300 ))" \
        CAPTURE_START_GUARD_SECONDS=60 \
        PREPARE_RESULT=SUCCEEDED ORCHESTRATOR_STARTED=true \
        OVERALL_RESULT=FAILED_EXIT_1 \
        bash "${workspace}/capture_step.sh" > "${workspace}/capture_step.out" 2>&1 \
        && status=0 || status=$?
    printf 'status=%s\nelapsed=%s\n' "$status" "$(( $(date +%s) - start ))"
}

# ab_env_last <workspace> <key> - the last GITHUB_ENV value of one key.
ab_env_last() {
    awk -v key="$2" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) }
                     END { print value }' "${1}/github_env"
}

# ab_run_summary <workspace> - run the extracted summary step with the capture
# result that the capture step published. Prints the job summary.
ab_run_summary() {
    local workspace="$1"
    : > "${workspace}/step_summary"
    env GITHUB_STEP_SUMMARY="${workspace}/step_summary" \
        CAPTURE_RESULT="$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        CAPTURE_REASON="$(ab_env_last "$workspace" CAPTURE_REASON)" \
        VTU_REQUIRED_FIELDS_VERDICT="$(ab_env_last "$workspace" VTU_REQUIRED_FIELDS_VERDICT)" \
        MESH_QUALITY_VERDICT="$(ab_env_last "$workspace" MESH_QUALITY_VERDICT)" \
        CONVERGENCE_VERDICT="$(ab_env_last "$workspace" CONVERGENCE_VERDICT)" \
        OVERALL_RESULT=FAILED_EXIT_1 \
        bash "${workspace}/summary_step.sh" > /dev/null 2>&1 ||
        _fail "the extracted summary step must succeed"
    cat "${workspace}/step_summary"
}

# ab_assert_fakes_stopped <workspace> <label> - no blocked fake command runs.
ab_assert_fakes_stopped() {
    local workspace="$1" label="$2" pid
    [[ -s "${workspace}/fake_pids" ]] ||
        _fail "${label}: the blocking fake command must run"
    while IFS= read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            _fail "${label}: the capture step must stop the blocked process ${pid}"
        fi
    done < "${workspace}/fake_pids"
}

# ab_assert_kept_evidence <workspace> <label> - the early and the Stage evidence.
ab_assert_kept_evidence() {
    local evidence="${1}/runner_temp/evidence" label="$2"
    assert_file_exists "${evidence}/phase-results.txt" \
        "${label}: phase-results.txt exists"
    if [[ -s "${1}/fake_pids" ]]; then
        assert_eq "present" "$(cat "${1}/phase_results_at_block" 2>/dev/null)" \
            "${label}: phase-results.txt exists before the blocked capture operation"
    fi
    assert_contains "$(cat "${evidence}/phase-results.txt")" "OVERALL_RESULT=FAILED_EXIT_1" \
        "${label}: the product result stays FAILED_EXIT_1"
    assert_not_contains "$(cat "${evidence}/phase-results.txt")" "CAPTURE_RESULT" \
        "${label}: the capture result does not replace a phase result"
}

s11_capture_completes_under_the_480_second_cap() {
    local workspace run evidence start
    workspace="$(new_workspace s11_complete)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"

    # A far deadline, so the 480-second work cap is the earlier limit.
    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))")"

    assert_contains "$run" "status=0" "S11: the capture step ends with status 0"
    start="$(awk -F= '$1 == "CAPTURE_START" { print $2; exit }' "${evidence}/capture-clock.txt")"
    assert_contains "$(cat "${evidence}/capture-clock.txt")" \
        "CAPTURE_WORK_END=$(( start + 480 ))" \
        "S11: the work limit is 480 seconds after capture start"
    assert_contains "$(cat "${evidence}/capture-clock.txt")" \
        "CAPTURE_WORK_LIMIT_SOURCE=CAPTURE_WORK_CAP" \
        "S11: the 480-second cap is the recorded limit source"
    assert_eq "COMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S11: GITHUB_ENV records a complete capture"
    assert_contains "$(cat "${evidence}/capture-result.txt")" "CAPTURE_RESULT=COMPLETE" \
        "S11: capture-result.txt records a complete capture"
    ab_assert_kept_evidence "$workspace" "S11"
    assert_file_exists "${evidence}/summaries/run_flow_cases_summary.csv" \
        "S11: the flow Stage summary is kept"
    assert_file_exists "${evidence}/stage-logs/.run_flow_cases_failed" \
        "S11: the flow Failure Artifact is kept"
    assert_file_exists "${evidence}/stage-logs/case_7/log.simpleFoam" \
        "S11: the Case log is kept"
    assert_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_OBSERVED_FIELDS=U p" \
        "S11: the manifest records the observed fields"
    assert_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=PRESENT" \
        "S11: the manifest records present VTU evidence"
    assert_contains "$(cat "${evidence}/vtu-point-data.txt")" \
        "VTU_SHA256=$(sha256sum -- "${workspace}/checkout/src/batch_9/case_7/vtk/flow_latest_100.vtu" | cut -d' ' -f1)" \
        "S11: the manifest keeps the source VTU checksum"
    if find "$evidence" -name '*.vtu' | grep -q .; then
        _fail "S11: the evidence directory must hold no VTU file"
    fi
}

s12_capture_operation_stops_before_the_deadline_reserve() {
    local workspace run evidence deadline elapsed summary
    workspace="$(new_workspace s12_operation_timeout)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    # The checksum of the VTU file blocks.
    ab_fake_hang "$workspace" sha256sum '*flow_latest_100.vtu'

    # The deadline leaves 16 seconds of work before the 180-second reserve, so
    # the deadline reserve is the earlier limit.
    deadline="$(( $(date +%s) + 180 + 16 ))"
    run="$(ab_run_capture "$workspace" "$deadline")"

    assert_contains "$run" "status=0" "S12: the capture step ends with status 0"
    elapsed="$(printf '%s\n' "$run" | awk -F= '$1 == "elapsed" { print $2 }')"
    if (( elapsed > 16 )); then
        _fail "S12: the capture step must end at the work limit" "elapsed: ${elapsed}"
    fi
    assert_contains "$(cat "${evidence}/capture-clock.txt")" \
        "CAPTURE_WORK_END=$(( deadline - 180 ))" \
        "S12: the work limit is 180 seconds before the deadline"
    assert_contains "$(cat "${evidence}/capture-clock.txt")" \
        "CAPTURE_WORK_LIMIT_SOURCE=CAPTURE_DEADLINE_RESERVE" \
        "S12: the deadline reserve is the recorded limit source"
    ab_assert_fakes_stopped "$workspace" "S12"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S12: GITHUB_ENV records an incomplete capture"
    assert_contains "$(ab_env_last "$workspace" CAPTURE_REASON)" \
        "VTU checksum case_7/vtk/flow_latest_100.vtu: exceeded the capture work limit" \
        "S12: the capture reason names the stopped operation"
    ab_assert_kept_evidence "$workspace" "S12"
    assert_file_exists "${evidence}/summaries/run_flow_cases_summary.csv" \
        "S12: the flow Stage summary is kept"
    assert_file_exists "${evidence}/stage-logs/.run_flow_cases_failed" \
        "S12: the flow Failure Artifact is kept"
    assert_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_SHA256=UNAVAILABLE" \
        "S12: the stopped checksum is UNAVAILABLE"
    assert_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=PARTIAL" \
        "S12: the manifest does not report present VTU evidence"
    assert_not_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=PRESENT" \
        "S12: the manifest reports no complete VTU evidence"

    summary="$(ab_run_summary "$workspace")"
    assert_contains "$summary" '| Capture result | `INCOMPLETE` |' \
        "S12: the job summary shows the capture result"
    assert_contains "$summary" "exceeded the capture work limit" \
        "S12: the job summary shows the capture reason"
    assert_contains "$summary" '| Overall result | `FAILED_EXIT_1` |' \
        "S12: the job summary keeps the product result"
}

s13_capture_work_stops_at_the_outer_limit() {
    local workspace run evidence elapsed
    workspace="$(new_workspace s13_outer_timeout)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    # A copy that no operation bound covers blocks, so only the outer limit
    # can stop the capture work.
    printf 'blocked log\n' > "${workspace}/checkout/src/batch_9/case_7/log.HANG"
    ab_fake_hang "$workspace" cp '*log.HANG'

    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 180 + 16 ))")"

    assert_contains "$run" "status=0" "S13: the capture step ends with status 0"
    elapsed="$(printf '%s\n' "$run" | awk -F= '$1 == "elapsed" { print $2 }')"
    if (( elapsed > 16 )); then
        _fail "S13: the capture step must end at the work limit" "elapsed: ${elapsed}"
    fi
    ab_assert_fakes_stopped "$workspace" "S13"
    assert_eq "TIMED_OUT" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S13: GITHUB_ENV records a timed-out capture"
    assert_contains "$(ab_env_last "$workspace" CAPTURE_REASON)" "stopped at the work limit" \
        "S13: the capture reason names the work limit"
    ab_assert_kept_evidence "$workspace" "S13"
    assert_file_exists "${evidence}/summaries/run_flow_cases_summary.csv" \
        "S13: the Stage summary copied before the block is kept"
    assert_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=UNAVAILABLE" \
        "S13: the missing VTU evidence is UNAVAILABLE"
    assert_contains "$(cat "${evidence}/vtu-point-data.txt")" \
        "VTU_REASON=the capture did not complete: TIMED_OUT" \
        "S13: the VTU reason names the capture result"
    assert_contains "$(cat "${evidence}/stage-summary-lines.txt")" "UNAVAILABLE: TIMED_OUT" \
        "S13: the missing Stage summary lines are UNAVAILABLE"
}

s14_capture_without_budget_skips_the_optional_work() {
    local workspace run evidence deadline label
    for deadline in "$(( $(date +%s) + 100 ))" 0; do
        label="S14 deadline ${deadline}"
        workspace="$(new_workspace "s14_no_budget_${deadline}")"
        ab_capture_fixture "$workspace"
        evidence="${workspace}/runner_temp/evidence"

        run="$(ab_run_capture "$workspace" "$deadline")"

        assert_contains "$run" "status=0" "${label}: the capture step ends with status 0"
        assert_eq "SKIPPED_NO_BUDGET" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
            "${label}: GITHUB_ENV records a skipped capture"
        assert_contains "$(ab_env_last "$workspace" CAPTURE_REASON)" "no capture work budget" \
            "${label}: the capture reason names the missing budget"
        ab_assert_kept_evidence "$workspace" "$label"
        assert_file_missing "${evidence}/summaries/run_flow_cases_summary.csv" \
            "${label}: no optional copy runs without a budget"
        assert_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=UNAVAILABLE" \
            "${label}: the missing VTU evidence is UNAVAILABLE"
        assert_contains "$(cat "${evidence}/vtu-point-data.txt")" "SKIPPED_NO_BUDGET" \
            "${label}: the VTU reason names the skipped capture"
    done
}

# PR #88 review 5289074428, finding 1. A VTU parse failure is a capture error,
# so the aggregate capture result must not be COMPLETE.
s16_vtu_parse_failure_is_an_incomplete_capture() {
    local workspace run evidence manifest
    workspace="$(new_workspace s16_parse_failure)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    # A finite VTU file without a marker whose PointData element never closes.
    printf '<VTKFile><Piece><PointData><DataArray Name="U"/>\n' \
        > "${workspace}/checkout/src/batch_9/case_7/vtk/flow_latest_200.vtu"

    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))")"

    assert_contains "$run" "status=0" "S16: the capture step ends with status 0"
    manifest="$(cat "${evidence}/vtu-point-data.txt")"
    assert_contains "$manifest" "VTU_OBSERVED_FIELDS=U p" \
        "S16: the readable VTU file keeps its observed fields"
    assert_contains "$manifest" "VTU_OBSERVED_FIELDS_REASON=the VTU header is incomplete" \
        "S16: the manifest records the parse failure reason"
    assert_contains "$manifest" "VTU_EVIDENCE=PARTIAL" \
        "S16: the manifest does not report present VTU evidence"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S16: a VTU parse failure gives an incomplete capture"
    assert_contains "$(ab_env_last "$workspace" CAPTURE_REASON)" \
        "VTU PointData parse case_7/vtk/flow_latest_200.vtu: the VTU header is incomplete" \
        "S16: the capture reason names the failed parse"
    assert_contains "$(cat "${evidence}/capture-result.txt")" "CAPTURE_RESULT=INCOMPLETE" \
        "S16: capture-result.txt records an incomplete capture"
    ab_assert_kept_evidence "$workspace" "S16"
}

# PR #88 review 5289074428, finding 2. A failed Stage evidence search or copy
# is a capture error. The files already captured stay in the evidence.
s17_stage_evidence_failure_is_an_incomplete_capture() {
    local workspace run evidence reason

    # A failed copy of one Case log.
    workspace="$(new_workspace s17_copy_failure)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    printf 'unreadable log\n' > "${workspace}/checkout/src/batch_9/case_7/log.FAILCOPY"
    ab_fake_fail "$workspace" cp '*log.FAILCOPY'

    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))")"

    assert_contains "$run" "status=0" "S17 copy: the capture step ends with status 0"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S17 copy: a failed Stage evidence copy gives an incomplete capture"
    assert_contains "$(ab_env_last "$workspace" CAPTURE_REASON)" \
        "Stage evidence copy case_7/log.FAILCOPY: the copy failed" \
        "S17 copy: the capture reason names the failed copy"
    assert_file_missing "${evidence}/stage-logs/case_7/log.FAILCOPY" \
        "S17 copy: the failed copy is absent"
    assert_file_exists "${evidence}/stage-logs/case_7/log.simpleFoam" \
        "S17 copy: the other Case log is kept"
    assert_file_exists "${evidence}/summaries/run_flow_cases_summary.csv" \
        "S17 copy: the Stage summary is kept"
    assert_file_exists "${evidence}/stage-logs/.run_flow_cases_failed" \
        "S17 copy: the Failure Artifact is kept"
    ab_assert_kept_evidence "$workspace" "S17 copy"

    # A failed search for the Stage summaries.
    workspace="$(new_workspace s17_search_failure)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    ab_fake_fail "$workspace" find '\*_summary.csv'

    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))")"

    assert_contains "$run" "status=0" "S17 search: the capture step ends with status 0"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S17 search: a failed Stage evidence search gives an incomplete capture"
    reason="$(ab_env_last "$workspace" CAPTURE_REASON)"
    assert_contains "$reason" "Stage evidence search: ended with status 1" \
        "S17 search: the capture reason names the failed search"
    assert_file_missing "${evidence}/summaries/run_flow_cases_summary.csv" \
        "S17 search: the failed search copies no Stage summary"
    assert_file_exists "${evidence}/stage-logs/.run_flow_cases_failed" \
        "S17 search: the Failure Artifact from a later search is kept"
    assert_file_exists "${evidence}/stage-logs/case_7/log.simpleFoam" \
        "S17 search: the Case log from a later search is kept"
    ab_assert_kept_evidence "$workspace" "S17 search"
}

s15_capture_failure_keeps_summary_and_upload_eligible() {
    local capture summary upload
    capture="$(ab_workflow_step_block "Capture the evidence")"
    summary="$(ab_workflow_step_block "Write the job summary")"
    upload="$(ab_workflow_step_block "Upload the evidence artifacts")"
    assert_contains "$capture" "        if: always()" "S15: the capture step always runs"
    assert_contains "$capture" "        timeout-minutes: 10" \
        "S15: the capture step has the 10-minute final guard"
    assert_contains "$summary" "        if: always()" "S15: the summary step always runs"
    assert_contains "$upload" "        if: always()" "S15: the upload step always runs"
    assert_contains "$summary" 'CAPTURE_RESULT' "S15: the summary shows the capture result"
    assert_contains "$summary" 'CAPTURE_REASON' "S15: the summary shows the capture reason"
    # The step publishes NOT_COMPLETED before any capture work, so a step that
    # the final guard stops still reports an incomplete capture.
    assert_contains "$capture" 'CAPTURE_RESULT=NOT_COMPLETED' \
        "S15: the capture step publishes NOT_COMPLETED first"
    assert_eq "$(ab_step_names_after "Capture the evidence")" \
        "$(printf 'Write the job summary\nUpload the evidence artifacts')" \
        "S15: the summary and the upload steps follow the capture step"
}

# ab_step_names_after <step-name> - the names of the steps after one step.
ab_step_names_after() {
    awk -v want="      - name: $1" '
        $0 == want { found = 1; next }
        found && /^      - name: / { print substr($0, 15) }
    ' "$WORKFLOW"
}

# ---- S18 to S24: the M3 evidence-recovery verdicts (Issue #80) --------------

# ab_block_value <file> <block-key> <block-value> <key> - the value of <key> in
# the block that starts at the line <block-key>=<block-value>. A block ends at
# the next <block-key>= line.
ab_block_value() {
    awk -v bk="$2" -v bv="$3" -v key="$4" '
        index($0, bk "=") == 1 { inside = (substr($0, length(bk) + 2) == bv); next }
        inside && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
    ' "$1"
}

# ab_file_value <file> <key> - the last value of <key> in the file.
ab_file_value() {
    awk -v key="$2" 'index($0, key "=") == 1 { value = substr($0, length(key) + 2) }
                     END { print value }' "$1"
}

# ab_vtu_result <workspace> <vtu-path> <key> - one manifest value of one VTU.
ab_vtu_result() {
    ab_block_value "${1}/runner_temp/evidence/vtu-point-data.txt" VTU_PATH "$2" "$3"
}

# ab_check_tag_records <workspace> - compare every retained tag record with the
# source bytes at its recorded offset. Prints sections=<n> max_section=<bytes>
# records=<n> bad=<n>.
ab_check_tag_records() {
    local workspace="$1" dir summary path offset want file bad=0
    dir="${workspace}/tag_records"
    mkdir -p "$dir"
    : > "${dir}/list"
    summary="$(LC_ALL=C awk -v dir="$dir" '
        /^== VTU_TAGS path=/ && !in_record {
            in_section = 1; size = length($0) + 1
            path = $3; sub(/^path=/, "", path); next
        }
        /^== VTU_TAGS_END path=/ && !in_record {
            size += length($0) + 1; sections++
            if (size > max) max = size
            in_section = 0; next
        }
        /^TAG offset=/ && !in_record {
            size += length($0) + 1
            split($2, a, "="); offset = a[2]; split($3, b, "="); want = b[2]
            n++; body = ""; got = -1; in_record = 1; next
        }
        in_record {
            size += length($0) + 1
            body = (got < 0 ? $0 : body "\n" $0); got = length(body)
            if (got >= want) {
                file = dir "/rec" n
                printf "%s", body > file; close(file)
                print path "\t" offset "\t" want "\t" file >> (dir "/list")
                in_record = 0
            }
            next
        }
        END { printf "sections=%d max_section=%d records=%d", sections, max, n }
    ' "${workspace}/runner_temp/evidence/vtu-tags.txt")"
    while IFS=$'\t' read -r path offset want file; do
        if ! cmp -s <(tail -c +"$(( offset + 1 ))" -- \
                "${workspace}/checkout/src/batch_9/${path}" | head -c "$want") "$file"; then
            bad=$(( bad + 1 ))
        fi
    done < "${dir}/list"
    printf '%s bad=%s\n' "$summary" "$bad"
}

# ab_tag_section <workspace> <vtu-path> - the retained tag section of one VTU.
ab_tag_section() {
    awk -v want="$2" '
        /^== VTU_TAGS path=/ { inside = ($3 == "path=" want) }
        inside { print }
        /^== VTU_TAGS_END path=/ { inside = 0 }
    ' "${1}/runner_temp/evidence/vtu-tags.txt"
}

# ab_vtu_appended <file> <PointData-text> [<CellData-text>] - an appended-data VTU
# file. The payload holds NUL bytes and text that looks like a PointData
# element, so a reader that passes the marker gives a wrong result.
ab_vtu_appended() {
    local file="$1" point="$2" cell="${3-}"
    {
        printf '<?xml version="1.0"?>\n<VTKFile type="UnstructuredGrid" version="1.0">\n'
        printf '<UnstructuredGrid>\n<Piece NumberOfPoints="8" NumberOfCells="1">\n'
        if [[ -n "$point" ]]; then printf '%s\n' "$point"; fi
        if [[ -n "$cell" ]]; then printf '%s\n' "$cell"; fi
        printf '</Piece>\n</UnstructuredGrid>\n<AppendedData encoding="raw">\n_'
        head -c 64 /dev/zero
        printf '<PointData><DataArray Name="AB_PAYLOAD_NAME"/></PointData>'
        head -c 64 /dev/zero
        printf '\n</AppendedData>\n</VTKFile>\n'
    } > "$file"
}

# ab_fake_find_extra <workspace> <extra-path> - a fake find that also lists one
# path that does not exist when it searches for VTU files.
ab_fake_find_extra() {
    local workspace="$1" extra="$2" real
    real="$(command -v find)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for argument in "$@"; do\n'
        printf '    if [[ "$argument" == "*.vtu" ]]; then\n'
        printf '        %q "$@"; status=$?\n' "$real"
        printf '        printf "%%s\\n" %q\n' "$extra"
        printf '        exit "$status"\n'
        printf '    fi\n'
        printf 'done\n'
        printf 'exec %q "$@"\n' "$real"
    } > "${workspace}/fakebin/find"
    chmod +x "${workspace}/fakebin/find"
}

s18_vtu_required_field_verdicts_and_original_tags() {
    local workspace run evidence vtk section checked sha_manifest sha_section
    workspace="$(new_workspace s18_vtu_verdicts)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    vtk="${workspace}/checkout/src/batch_9/case_7/vtk"

    # flow_0 requires wallDistance, which the file does not declare.
    ab_vtu_appended "${vtk}/flow_0.vtu" \
        "$(printf '<PointData>\n<DataArray type="Float32" Name="U" format="appended" offset="0"/>\n<DataArray type="Float32" Name="p" format="appended" offset="0"/>\n</PointData>')" \
        "$(printf '<CellData>\n<DataArray type="Float32" Name="U" format="appended" offset="0"/>\n</CellData>')"
    # Reordered names and one extra name.
    ab_vtu_appended "${vtk}/flow_latest_01_match.vtu" \
        "$(printf '<PointData>\n<DataArray Name="p"/>\n<DataArray Name="extra"/>\n<DataArray Name="U"/>\n</PointData>')"
    # Single and double quotes, and one start tag across two lines.
    ab_vtu_appended "${vtk}/flow_latest_02_quotes.vtu" \
        "$(printf "<PointData Scalars='p'>\n<DataArray type='Float32' Name='U' format='appended'/>\n<DataArray type=\"Float32\"\n    Name=\"p\" format=\"appended\"/>\n</PointData>")"
    # An unquoted Name attribute is not evidence. The tag syntax is invalid, so
    # the header is malformed (review 5300443151).
    printf '<VTKFile>\n<Piece>\n<PointData>\n<DataArray type="Float32" Name=U format="ascii">1 2 3</DataArray>\n<DataArray type="Float32" Name="p" format="ascii">1</DataArray>\n</PointData>\n</Piece>\n</VTKFile>\n' \
        > "${vtk}/flow_latest_03_unquoted.vtu"
    # An empty PointData element.
    ab_vtu_appended "${vtk}/flow_latest_04_empty.vtu" "$(printf '<PointData>\n</PointData>')"
    # A PointData declaration after byte 65536, in a finite ASCII file.
    {
        printf '<VTKFile>\n<Piece>\n<FieldData>\n'
        awk 'BEGIN { for (i = 0; i < 900; i++) printf "  pad %05d %s\n", i, \
             "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }'
        printf '</FieldData>\n<PointData>\n<DataArray Name="U" format="ascii">1</DataArray>\n'
        printf '<DataArray Name="p" format="ascii">1</DataArray>\n</PointData>\n</Piece>\n</VTKFile>\n'
    } > "${vtk}/flow_latest_05_late.vtu"
    # No PointData and no CellData.
    ab_vtu_appended "${vtk}/flow_latest_06_absent.vtu" ""
    # CellData only.
    ab_vtu_appended "${vtk}/flow_latest_07_cellonly.vtu" "" \
        "$(printf '<CellData>\n<DataArray Name="U"/>\n<DataArray Name="p"/>\n</CellData>')"
    # A finite ASCII file without a marker.
    ab_ascii_vtu "${vtk}/flow_latest_08_ascii.vtu" 2000
    # Malformed XML: the PointData element never closes.
    printf '<VTKFile>\n<Piece>\n<PointData>\n<DataArray Name="U"/>\n' \
        > "${vtk}/flow_latest_09_malformed.vtu"
    # A selected file that does not exist when the scan starts.
    ab_fake_find_extra "$workspace" "${vtk}/flow_latest_10_missing.vtu"

    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))")"

    assert_contains "$run" "status=0" "S18: the capture step ends with status 0"
    assert_file_exists "${evidence}/vtu-tags.txt" "S18: the tag evidence file exists"

    assert_eq "MISSING_REQUIRED_FIELDS" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_0.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S18: flow_0 without wallDistance is MISSING_REQUIRED_FIELDS"
    assert_eq "wallDistance" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_0.vtu VTU_MISSING_REQUIRED_FIELDS)" \
        "S18: flow_0 names the missing required field"
    assert_eq "U" "$(ab_vtu_result "$workspace" case_7/vtk/flow_0.vtu VTU_OBSERVED_CELL_FIELDS)" \
        "S18: the CellData names stay separate"
    assert_eq "MATCH" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_01_match.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S18: reordered names with an extra name are MATCH"
    assert_eq "p extra U" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_01_match.vtu VTU_OBSERVED_FIELDS)" \
        "S18: the observed names keep the source order"
    assert_eq "MATCH" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_02_quotes.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S18: single- and double-quoted names are MATCH"
    assert_eq "PARSER_FAILURE" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_03_unquoted.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S18: an unquoted Name attribute does not count, and the header is malformed"
    assert_eq "UNAVAILABLE" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_03_unquoted.vtu VTU_OBSERVED_FIELDS)" \
        "S18: no name is observed from a malformed header"
    assert_eq "MISSING_REQUIRED_FIELDS" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_04_empty.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S18: empty observed names are MISSING_REQUIRED_FIELDS"
    assert_eq "U p" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_04_empty.vtu VTU_MISSING_REQUIRED_FIELDS)" \
        "S18: empty observed names miss every required field"
    assert_eq "MATCH" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_05_late.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S18: a PointData declaration after byte 65536 is MATCH"
    assert_eq "SOURCE_POINTDATA_ABSENT" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_06_absent.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S18: a file without PointData is SOURCE_POINTDATA_ABSENT"
    assert_eq "SOURCE_POINTDATA_ABSENT" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_07_cellonly.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S18: a CellData-only file is SOURCE_POINTDATA_ABSENT"
    assert_eq "U p" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_07_cellonly.vtu VTU_OBSERVED_CELL_FIELDS)" \
        "S18: the CellData-only names are recorded as CellData"
    assert_eq "MATCH" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_08_ascii.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S18: a finite ASCII file is MATCH"
    assert_eq "PARSER_FAILURE" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_09_malformed.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S18: malformed XML is PARSER_FAILURE"
    assert_eq "UNAVAILABLE" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_09_malformed.vtu VTU_TAG_EVIDENCE)" \
        "S18: malformed XML has no complete tag evidence"
    assert_eq "MISSING_FILE" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_10_missing.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S18: a selected file that does not exist is MISSING_FILE"
    assert_eq "MATCH" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_100.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S18: the base fixture file is MATCH"

    # A parser failure is a capture error; a source mismatch is not.
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S18: a parser failure gives an incomplete capture"
    # Two files are malformed. The capture reason names the first note, and the
    # notes list both files.
    assert_contains "$(ab_env_last "$workspace" CAPTURE_REASON)" \
        "VTU PointData parse case_7/vtk/flow_latest_03_unquoted.vtu: the VTU header is incomplete or malformed" \
        "S18: the capture reason names the parser failure"
    assert_contains "$(cat "${evidence}/capture-work-notes.txt")" \
        "VTU PointData parse case_7/vtk/flow_latest_09_malformed.vtu" \
        "S18: the capture notes name the malformed file"
    assert_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=PARTIAL" \
        "S18: the aggregate VTU evidence is not PRESENT"
    assert_eq "INCOMPLETE" \
        "$(ab_file_value "${evidence}/vtu-point-data.txt" VTU_REQUIRED_FIELDS_VERDICT)" \
        "S18: the required-field verdict is INCOMPLETE"

    # The retained tags are the original bytes at their recorded offsets.
    checked="$(ab_check_tag_records "$workspace")"
    assert_contains "$checked" "bad=0" "S18: every retained tag equals its source bytes"
    assert_not_contains "$checked" "records=0 " "S18: the tag evidence holds tag records"
    section="$(ab_tag_section "$workspace" case_7/vtk/flow_latest_02_quotes.vtu)"
    assert_contains "$section" "Name='U'" "S18: a single-quoted attribute keeps its quotes"
    assert_contains "$section" "$(printf '<DataArray type="Float32"\n    Name="p"')" \
        "S18: a start tag across two lines keeps its line end"
    sha_manifest="$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_02_quotes.vtu VTU_SHA256)"
    sha_section="$(printf '%s\n' "$section" | head -n 1 | sed -n 's/.* sha256=\([0-9a-f]*\).*/\1/p')"
    assert_eq "$(sha256sum -- "${vtk}/flow_latest_02_quotes.vtu" | cut -d' ' -f1)" "$sha_manifest" \
        "S18: the manifest checksum is the source checksum"
    assert_eq "$sha_manifest" "$sha_section" "S18: the tag section names the source checksum"
    assert_contains "$(ab_tag_section "$workspace" case_7/vtk/flow_latest_03_unquoted.vtu)" \
        "Name=U format" "S18: the unquoted tag is kept as original evidence"
    if ! ab_tag_section "$workspace" case_7/vtk/flow_latest_05_late.vtu |
            awk '/^TAG offset=/ { split($2, a, "="); if (a[2] + 0 > 65536 && $4 == "element=PointData") found = 1 }
                 END { exit !found }'; then
        _fail "S18: the late PointData tag is recorded at an offset above 65536"
    fi
    if grep -rq 'AB_PAYLOAD_NAME' "$evidence"; then
        _fail "S18: no appended-payload byte may reach the evidence"
    fi
    if find "$evidence" -name '*.vtu' | grep -q .; then
        _fail "S18: the evidence directory must hold no VTU file"
    fi
    ab_assert_kept_evidence "$workspace" "S18"
}

s19_source_mismatch_keeps_a_complete_capture() {
    local workspace run evidence
    workspace="$(new_workspace s19_source_mismatch)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    ab_vtu_appended "${workspace}/checkout/src/batch_9/case_7/vtk/flow_0.vtu" \
        "$(printf '<PointData>\n<DataArray Name="U"/>\n<DataArray Name="p"/>\n</PointData>')"

    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))")"

    assert_contains "$run" "status=0" "S19: the capture step ends with status 0"
    assert_eq "COMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S19: a source mismatch alone keeps a complete capture"
    assert_eq "MISSING_REQUIRED_FIELDS" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_0.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S19: flow_0 without wallDistance is MISSING_REQUIRED_FIELDS"
    assert_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=INCOMPLETE" \
        "S19: the aggregate VTU evidence is INCOMPLETE"
    assert_not_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=PRESENT" \
        "S19: the aggregate VTU evidence is not PRESENT"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" VTU_REQUIRED_FIELDS_VERDICT)" \
        "S19: GITHUB_ENV records an incomplete required-field verdict"
    # The base fixture has no checkMesh log and no solver log.
    assert_eq "UNAVAILABLE" "$(ab_file_value "${evidence}/mesh-quality.txt" MESH_QUALITY_VERDICT)" \
        "S19: a missing checkMesh log gives an UNAVAILABLE mesh verdict"
    assert_eq "UNAVAILABLE" "$(ab_file_value "${evidence}/convergence.txt" CONVERGENCE_VERDICT)" \
        "S19: a missing solver log gives an UNAVAILABLE convergence verdict"
    ab_assert_kept_evidence "$workspace" "S19"
}

s20_vtu_tag_evidence_output_limits() {
    local workspace run evidence vtk i checked total file max
    workspace="$(new_workspace s20_output_limit)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    vtk="${workspace}/checkout/src/batch_9/case_7/vtk"
    # Five files, each with more than 16384 bytes of CellData tags.
    for i in 1 2 3 4 5; do
        ab_vtu_appended "${vtk}/flow_latest_${i}.vtu" \
            "$(printf '<PointData>\n<DataArray Name="U"/>\n<DataArray Name="p"/>\n</PointData>')" \
            "$(printf '<CellData>\n'; awk 'BEGIN { for (j = 0; j < 400; j++)
                printf "<DataArray type=\"Float32\" Name=\"cell_%03d\" format=\"appended\" offset=\"0\"/>\n", j }'
               printf '</CellData>')"
    done

    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))")"

    assert_contains "$run" "status=0" "S20: the capture step ends with status 0"
    total="$(wc -c < "${evidence}/vtu-tags.txt" | tr -d ' ')"
    if (( total > 65536 )); then
        _fail "S20: the tag evidence must hold at most 65536 bytes" "bytes: ${total}"
    fi
    checked="$(ab_check_tag_records "$workspace")"
    assert_contains "$checked" "bad=0" "S20: no retained tag is cut"
    max="$(printf '%s\n' "$checked" | sed -n 's/.*max_section=\([0-9]*\).*/\1/p')"
    if (( max > 16384 )); then
        _fail "S20: each tag section must hold at most 16384 bytes" "bytes: ${max}"
    fi
    for i in 1 2 3 4 5; do
        file="case_7/vtk/flow_latest_${i}.vtu"
        assert_eq "OUTPUT_LIMIT" "$(ab_vtu_result "$workspace" "$file" VTU_REQUIRED_FIELDS_RESULT)" \
            "S20: ${file} with too many tags is OUTPUT_LIMIT"
        assert_eq "UNAVAILABLE" "$(ab_vtu_result "$workspace" "$file" VTU_TAG_EVIDENCE)" \
            "S20: ${file} has no complete tag evidence"
        assert_eq "OUTPUT_LIMIT" "$(ab_vtu_result "$workspace" "$file" VTU_TAG_EVIDENCE_REASON)" \
            "S20: ${file} names the output limit"
        assert_eq "U p" "$(ab_vtu_result "$workspace" "$file" VTU_OBSERVED_FIELDS)" \
            "S20: ${file} still reports the parsed PointData names"
    done
    assert_eq "MATCH" "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_100.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S20: a file whose tags fit is MATCH"
    assert_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=INCOMPLETE" \
        "S20: an output limit makes the aggregate VTU evidence INCOMPLETE"
    assert_contains "$(ab_tag_section "$workspace" case_7/vtk/flow_latest_1.vtu)" \
        "tag_evidence=OUTPUT_LIMIT" "S20: the tag section ends with the output-limit result"
}

s21_vtu_scan_timeout_is_distinct() {
    local workspace run evidence elapsed
    workspace="$(new_workspace s21_scan_timeout)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    # The tag scan blocks. Every other awk call runs the real command.
    ab_fake_hang "$workspace" awk 'vtu_scan=1'

    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 180 + 16 ))")"

    assert_contains "$run" "status=0" "S21: the capture step ends with status 0"
    elapsed="$(printf '%s\n' "$run" | awk -F= '$1 == "elapsed" { print $2 }')"
    if (( elapsed > 16 )); then
        _fail "S21: the capture step must end at the work limit" "elapsed: ${elapsed}"
    fi
    ab_assert_fakes_stopped "$workspace" "S21"
    assert_eq "TIMEOUT" \
        "$(ab_vtu_result "$workspace" case_7/vtk/flow_latest_100.vtu VTU_REQUIRED_FIELDS_RESULT)" \
        "S21: a stopped scan is TIMEOUT"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S21: a stopped scan gives an incomplete capture"
    assert_contains "$(ab_env_last "$workspace" CAPTURE_REASON)" \
        "VTU PointData parse case_7/vtk/flow_latest_100.vtu: exceeded the capture work limit" \
        "S21: the capture reason names the stopped scan"
    assert_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=PARTIAL" \
        "S21: the aggregate VTU evidence is PARTIAL"
    assert_contains "$(ab_tag_section "$workspace" case_7/vtk/flow_latest_100.vtu)" \
        "tag_evidence=TIMEOUT" "S21: the tag section ends with the timeout result"
    ab_assert_kept_evidence "$workspace" "S21"
}

# ab_checkmesh_log <file> <mode> - a checkMesh log tail. mode: failed | clean |
# missing (the log has no summary line).
ab_checkmesh_log() {
    local file="$1" mode="$2"
    mkdir -p "$(dirname -- "$file")"
    {
        printf 'Checking geometry...\n    Max skewness = 0.333695 OK.\n'
        case "$mode" in
            failed)
                printf ' ***Concave cells (using face planes) found, number of cells: 23912\n'
                printf '  <<Writing 23912 concave cells to set concaveCells\n\nFailed 1 mesh checks.\n\nEnd\n' ;;
            clean)
                printf '    Concave cell check OK.\n\nMesh OK.\n\nEnd\n' ;;
            missing)
                printf '    Mesh non-orthogonality Max: 27.2781 average: 5.17536\n' ;;
        esac
    } > "$file"
}

s22_mesh_quality_evidence() {
    local workspace run evidence batch mesh
    workspace="$(new_workspace s22_mesh_quality)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    batch="${workspace}/checkout/src/batch_9"
    ab_checkmesh_log "${batch}/case_7/flow/log.checkMesh" failed
    ab_checkmesh_log "${batch}/case_8/flow/log.checkMesh" clean
    ab_checkmesh_log "${batch}/case_9/flow/log.checkMesh" missing

    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))")"

    assert_contains "$run" "status=0" "S22: the capture step ends with status 0"
    mesh="${evidence}/mesh-quality.txt"
    assert_file_exists "$mesh" "S22: the mesh-quality evidence exists"
    assert_eq "1" "$(ab_block_value "$mesh" MESH_LOG case_7/flow/log.checkMesh MESH_FAILED_CHECKS)" \
        "S22: the failed log reports one failed check"
    assert_eq "23912" "$(ab_block_value "$mesh" MESH_LOG case_7/flow/log.checkMesh MESH_CONCAVE_CELLS)" \
        "S22: the failed log reports 23912 concave cells"
    assert_eq "MESH_QUALITY_REVIEW_REQUIRED" \
        "$(ab_block_value "$mesh" MESH_LOG case_7/flow/log.checkMesh MESH_LOG_VERDICT)" \
        "S22: the failed log needs a mesh-quality review"
    assert_eq "0" "$(ab_block_value "$mesh" MESH_LOG case_8/flow/log.checkMesh MESH_FAILED_CHECKS)" \
        "S22: the clean log reports no failed check"
    assert_eq "MESH_QUALITY_CHECKS_PASSED" \
        "$(ab_block_value "$mesh" MESH_LOG case_8/flow/log.checkMesh MESH_LOG_VERDICT)" \
        "S22: the clean log passes the checks"
    assert_eq "UNAVAILABLE" "$(ab_block_value "$mesh" MESH_LOG case_9/flow/log.checkMesh MESH_FAILED_CHECKS)" \
        "S22: a log without summary text is UNAVAILABLE, not zero"
    assert_eq "UNAVAILABLE" "$(ab_block_value "$mesh" MESH_LOG case_9/flow/log.checkMesh MESH_CONCAVE_CELLS)" \
        "S22: a log without summary text has no concave-cell count"
    assert_eq "UNAVAILABLE" \
        "$(ab_block_value "$mesh" MESH_LOG case_9/flow/log.checkMesh MESH_LOG_VERDICT)" \
        "S22: a log without summary text has an UNAVAILABLE verdict"
    assert_eq "MESH_QUALITY_REVIEW_REQUIRED" "$(ab_file_value "$mesh" MESH_QUALITY_VERDICT)" \
        "S22: one failed log makes the aggregate mesh verdict a review"
    assert_eq "MESH_QUALITY_REVIEW_REQUIRED" "$(ab_env_last "$workspace" MESH_QUALITY_VERDICT)" \
        "S22: GITHUB_ENV records the mesh verdict"
    # The Stage evidence is not changed by the mesh verdict.
    if ! cmp -s "${batch}/run_flow_cases_summary.csv" "${evidence}/summaries/run_flow_cases_summary.csv"; then
        _fail "S22: the Stage summary must stay byte-identical"
    fi
    assert_eq "COMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S22: a mesh verdict does not change the capture result"
}

# ab_simplefoam_log <file> <mode> - a simpleFoam log. mode: converged | endtime |
# stale (the marker comes before the final Time block) | wrong_time (the marker
# after the final Time block names an earlier time) | no_final_continuity |
# no_final_residuals (the final Time block has no p record and no k record).
ab_simplefoam_log() {
    local file="$1" mode="$2" time final
    mkdir -p "$(dirname -- "$file")"
    {
        printf 'Exec   : simpleFoam -parallel\nnProcs : 8\n\nStarting time loop\n\n'
        for time in 2999 3000; do
            final=0
            [[ "$time" == 3000 ]] && final=1
            printf 'Time = %s\n\n' "$time"
            printf 'smoothSolver:  Solving for Ux, Initial residual = %s, Final residual = 3e-07, No Iterations 1\n' \
                "$([[ $time == 3000 ]] && echo 1.06518e-05 || echo 2e-05)"
            printf 'smoothSolver:  Solving for Uy, Initial residual = 0.000174519, Final residual = 5e-06, No Iterations 1\n'
            printf 'smoothSolver:  Solving for Uz, Initial residual = 9.66882e-05, Final residual = 3e-06, No Iterations 1\n'
            if ! (( final )) || [[ "$mode" != no_final_residuals ]]; then
                printf 'GAMG:  Solving for p, Initial residual = 0.00136639, Final residual = 0.0001, No Iterations 1\n'
            fi
            if ! (( final )) || [[ "$mode" != no_final_continuity ]]; then
                printf 'time step continuity errors : sum local = 1e-08, global = -2e-10, cumulative = -%s\n' "$time"
            fi
            if ! (( final )) || [[ "$mode" != no_final_residuals ]]; then
                printf 'GAMG:  Solving for p, Initial residual = 0.000146973, Final residual = 8e-06, No Iterations 2\n'
            fi
            printf 'smoothSolver:  Solving for epsilon, Initial residual = 1.2842e-05, Final residual = 3e-07, No Iterations 1\n'
            if ! (( final )) || [[ "$mode" != no_final_residuals ]]; then
                printf 'smoothSolver:  Solving for k, Initial residual = 2.43816e-05, Final residual = 6e-07, No Iterations 1\n'
            fi
            printf 'ExecutionTime = 1 s  ClockTime = 1 s\n\n'
            if ! (( final )) && [[ "$mode" == stale ]]; then
                printf '\nSIMPLE solution converged in 2999 iterations\n\n'
            fi
        done
        case "$mode" in
            converged|no_final_continuity|no_final_residuals)
                printf '\nSIMPLE solution converged in 3000 iterations\n\n' ;;
            wrong_time)
                printf '\nSIMPLE solution converged in 2999 iterations\n\n' ;;
        esac
        printf 'End\n\n'
    } > "$file"
}

s23_flow_convergence_evidence() {
    local workspace run evidence batch conv label
    workspace="$(new_workspace s23_convergence)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    batch="${workspace}/checkout/src/batch_9"
    ab_simplefoam_log "${batch}/case_7/flow/log.simpleFoam" converged
    ab_simplefoam_log "${batch}/case_8/flow/log.simpleFoam" endtime
    ab_simplefoam_log "${batch}/case_9/flow/log.simpleFoam" endtime
    mkdir -p "${batch}/case_7/flow/system" "${batch}/case_8/flow/system"
    # The committed Case controls, so the recorded criterion is the real one.
    cp -- "${MASTER_SRC_DIR}/simpleFoam_files/system/fvSolution" "${batch}/case_7/flow/system/fvSolution"
    cp -- "${MASTER_SRC_DIR}/simpleFoam_files/system/fvSolution" "${batch}/case_8/flow/system/fvSolution"

    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))")"

    assert_contains "$run" "status=0" "S23: the capture step ends with status 0"
    conv="${evidence}/convergence.txt"
    assert_file_exists "$conv" "S23: the convergence evidence exists"
    label=case_7/flow/log.simpleFoam
    assert_eq "CONVERGED" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_LOG_VERDICT)" \
        "S23: an explicit solver marker is CONVERGED"
    assert_eq "SIMPLE solution converged in 3000 iterations" \
        "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" SOLVER_CONVERGENCE_MARKER)" \
        "S23: the solver marker is recorded"
    assert_eq 'U 1e-4; p 1e-4; "(k|omega|epsilon)" 1e-4' \
        "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" RESIDUAL_CONTROL)" \
        "S23: the actual residualControl values are recorded"
    assert_eq "true" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" RESIDUAL_CONTROL_REFERENCE_MATCH)" \
        "S23: the committed controls match the M3 reference"
    assert_eq "case_7/flow/system/fvSolution" \
        "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_CONTROLS_SOURCE)" \
        "S23: the controls source path is recorded"
    label=case_8/flow/log.simpleFoam
    assert_eq "NOT_CONVERGED" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_LOG_VERDICT)" \
        "S23: an end-time log without a marker is NOT_CONVERGED"
    assert_eq "ABSENT" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" SOLVER_CONVERGENCE_MARKER)" \
        "S23: the missing marker is recorded as ABSENT"
    assert_eq "3000" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" FINAL_TIME)" \
        "S23: the final time is recorded"
    assert_eq "1.06518e-05" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" FINAL_INITIAL_RESIDUAL_Ux)" \
        "S23: the final Ux initial residual is from the final time step"
    assert_eq "0.00136639" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" FINAL_INITIAL_RESIDUAL_p)" \
        "S23: the final p initial residual is the first pressure solve"
    assert_eq "2.43816e-05" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" FINAL_INITIAL_RESIDUAL_k)" \
        "S23: the final k initial residual is recorded"
    assert_eq "1.2842e-05" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" FINAL_INITIAL_RESIDUAL_epsilon)" \
        "S23: the final epsilon initial residual is recorded"
    assert_contains "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" FINAL_CONTINUITY)" \
        "cumulative = -3000" "S23: the final continuity record is recorded"
    label=case_9/flow/log.simpleFoam
    assert_eq "UNAVAILABLE" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_LOG_VERDICT)" \
        "S23: a log without control values is UNAVAILABLE"
    assert_eq "UNAVAILABLE" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" RESIDUAL_CONTROL)" \
        "S23: missing control values are UNAVAILABLE"
    assert_eq "UNAVAILABLE" "$(ab_file_value "$conv" CONVERGENCE_VERDICT)" \
        "S23: one unavailable log makes the aggregate verdict UNAVAILABLE"
    assert_file_exists "${evidence}/case-config/case_7/flow/system/fvSolution" \
        "S23: the Case controls are kept as evidence"

    # One converged log alone, and one end-time log alone. The shared fixture
    # holds one more solver log without controls, so these runs remove it.
    workspace="$(new_workspace s23_converged_only)"
    ab_capture_fixture "$workspace"
    rm -f -- "${workspace}/checkout/src/batch_9/case_7/log.simpleFoam"
    ab_simplefoam_log "${workspace}/checkout/src/batch_9/case_7/flow/log.simpleFoam" converged
    mkdir -p "${workspace}/checkout/src/batch_9/case_7/flow/system"
    cp -- "${MASTER_SRC_DIR}/simpleFoam_files/system/fvSolution" \
        "${workspace}/checkout/src/batch_9/case_7/flow/system/fvSolution"
    ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))" > /dev/null
    assert_eq "CONVERGED" "$(ab_env_last "$workspace" CONVERGENCE_VERDICT)" \
        "S23: a converged log alone gives a CONVERGED verdict"

    workspace="$(new_workspace s23_endtime_only)"
    ab_capture_fixture "$workspace"
    rm -f -- "${workspace}/checkout/src/batch_9/case_7/log.simpleFoam"
    ab_simplefoam_log "${workspace}/checkout/src/batch_9/case_7/flow/log.simpleFoam" endtime
    mkdir -p "${workspace}/checkout/src/batch_9/case_7/flow/system"
    cp -- "${MASTER_SRC_DIR}/simpleFoam_files/system/fvSolution" \
        "${workspace}/checkout/src/batch_9/case_7/flow/system/fvSolution"
    ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))" > /dev/null
    assert_eq "NOT_CONVERGED" "$(ab_env_last "$workspace" CONVERGENCE_VERDICT)" \
        "S23: reaching the end time is not convergence"
}

s24_summary_shows_the_evidence_verdicts() {
    local workspace summary
    workspace="$(new_workspace s24_summary)"
    ab_capture_fixture "$workspace"
    ab_checkmesh_log "${workspace}/checkout/src/batch_9/case_7/flow/log.checkMesh" failed
    ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))" > /dev/null

    summary="$(ab_run_summary "$workspace")"
    assert_contains "$summary" '| VTU required fields | `COMPLETE` |' \
        "S24: the job summary shows the VTU required-field verdict"
    assert_contains "$summary" '| Mesh quality | `MESH_QUALITY_REVIEW_REQUIRED` |' \
        "S24: the job summary shows the mesh verdict"
    assert_contains "$summary" '| Convergence | `UNAVAILABLE` |' \
        "S24: the job summary shows the convergence verdict"
    assert_contains "$summary" '| Capture result | `COMPLETE` |' \
        "S24: the job summary keeps the capture result"
}

# ---- S25 and S26: the PR #89 review corrections (review 5298374123) ----------

s25_vtu_name_text_inside_a_value_is_not_a_name() {
    local workspace evidence vtk file checked
    workspace="$(new_workspace s25_vtu_attribute_boundaries)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    vtk="${workspace}/checkout/src/batch_9/case_7/vtk"

    # Name text inside a single-quoted value of another attribute.
    ab_vtu_appended "${vtk}/flow_latest_11_text_single.vtu" \
        "$(printf "<PointData>\n<DataArray Note=' Name=\"U\" '/>\n<DataArray type=\"Float32\" Name=\"p\"/>\n</PointData>")"
    # Name text inside a double-quoted value of another attribute.
    ab_vtu_appended "${vtk}/flow_latest_12_text_double.vtu" \
        "$(printf "<PointData>\n<DataArray Name=\"p\"/>\n<DataArray format=\"ascii\" Note=\"a Name='U' b\"/>\n</PointData>")"
    # A real Name attribute after a value that holds Name text and a '>'
    # character, with spaces around '=' and a tab before the attribute.
    ab_vtu_appended "${vtk}/flow_latest_13_after_text.vtu" \
        "$(printf "<PointData>\n<DataArray Note='a > Name=\"x\"' Name = \"U\"/>\n<DataArray\tName='p'/>\n</PointData>")"
    # S29 holds the invalid-syntax cases: two Name attributes, and a Name after
    # an unquoted value.

    ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))" > /dev/null

    for file in case_7/vtk/flow_latest_11_text_single.vtu case_7/vtk/flow_latest_12_text_double.vtu; do
        assert_eq "MISSING_REQUIRED_FIELDS" \
            "$(ab_vtu_result "$workspace" "$file" VTU_REQUIRED_FIELDS_RESULT)" \
            "S25: ${file}: Name text inside another attribute value is not a field"
        assert_eq "p" "$(ab_vtu_result "$workspace" "$file" VTU_OBSERVED_FIELDS)" \
            "S25: ${file}: only the real Name attribute is observed"
        assert_eq "U" "$(ab_vtu_result "$workspace" "$file" VTU_MISSING_REQUIRED_FIELDS)" \
            "S25: ${file}: the missing required field is named"
        assert_eq "COMPLETE" "$(ab_vtu_result "$workspace" "$file" VTU_TAG_EVIDENCE)" \
            "S25: ${file}: the tag evidence is complete"
    done
    file=case_7/vtk/flow_latest_13_after_text.vtu
    assert_eq "MATCH" "$(ab_vtu_result "$workspace" "$file" VTU_REQUIRED_FIELDS_RESULT)" \
        "S25: a real Name attribute after a value with Name text is MATCH"
    assert_eq "U p" "$(ab_vtu_result "$workspace" "$file" VTU_OBSERVED_FIELDS)" \
        "S25: the name comes from the attribute, not from the value text"
    assert_contains "$(ab_tag_section "$workspace" case_7/vtk/flow_latest_11_text_single.vtu)" \
        "<DataArray Note=' Name=\"U\" '/>" "S25: the tag with Name text is kept as original bytes"
    checked="$(ab_check_tag_records "$workspace")"
    assert_contains "$checked" "bad=0" "S25: every retained tag equals its source bytes"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" VTU_REQUIRED_FIELDS_VERDICT)" \
        "S25: a false field cannot complete the required-field verdict"
    assert_eq "COMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S25: a source mismatch alone keeps a complete capture"
}

# ab_changed_controls <file> - the committed Case controls with 1e-3 in place
# of each 1e-4 residualControl value.
ab_changed_controls() {
    mkdir -p "$(dirname -- "$1")"
    sed -e '/residualControl/,/}/s/1e-4/1e-3/' \
        "${MASTER_SRC_DIR}/simpleFoam_files/system/fvSolution" > "$1"
}

# ab_one_solver_log <workspace> <log-mode> <controls: committed|changed> - run
# the capture step on a Batch Workspace with one solver log only.
ab_one_solver_log() {
    local workspace="$1" batch
    ab_capture_fixture "$workspace"
    batch="${workspace}/checkout/src/batch_9"
    rm -f -- "${batch}/case_7/log.simpleFoam"
    ab_simplefoam_log "${batch}/case_7/flow/log.simpleFoam" "$2"
    if [[ "$3" == changed ]]; then
        ab_changed_controls "${batch}/case_7/flow/system/fvSolution"
    else
        mkdir -p "${batch}/case_7/flow/system"
        cp -- "${MASTER_SRC_DIR}/simpleFoam_files/system/fvSolution" \
            "${batch}/case_7/flow/system/fvSolution"
    fi
    ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))" > /dev/null
}

s26_convergence_verdict_fails_closed() {
    local workspace run evidence batch conv dir mode label
    workspace="$(new_workspace s26_convergence_fail_closed)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    batch="${workspace}/checkout/src/batch_9"
    for mode in converged stale wrong_time no_final_continuity no_final_residuals; do
        dir="${batch}/case_7/conv_${mode}"
        ab_simplefoam_log "${dir}/log.simpleFoam" "$mode"
        mkdir -p "${dir}/system"
        cp -- "${MASTER_SRC_DIR}/simpleFoam_files/system/fvSolution" "${dir}/system/fvSolution"
    done
    ab_simplefoam_log "${batch}/case_7/conv_changed/log.simpleFoam" converged
    ab_changed_controls "${batch}/case_7/conv_changed/system/fvSolution"

    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))")"

    assert_contains "$run" "status=0" "S26: the capture step ends with status 0"
    conv="${evidence}/convergence.txt"

    label=case_7/conv_converged/log.simpleFoam
    assert_eq "CONVERGED" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_LOG_VERDICT)" \
        "S26: a marker after the final Time block with every record is CONVERGED"
    assert_eq "AFTER_FINAL_TIME" \
        "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" SOLVER_CONVERGENCE_MARKER_POSITION)" \
        "S26: the marker position is recorded"
    assert_eq "NONE" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_REQUIRED_RECORDS_MISSING)" \
        "S26: a complete final Time block misses no required record"

    label=case_7/conv_changed/log.simpleFoam
    assert_eq 'U 1e-3; p 1e-3; "(k|omega|epsilon)" 1e-3' \
        "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" RESIDUAL_CONTROL)" \
        "S26: the changed controls are recorded as they are"
    assert_eq "false" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" RESIDUAL_CONTROL_REFERENCE_MATCH)" \
        "S26: the changed controls do not match the M3 reference"
    assert_eq "UNAVAILABLE" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_LOG_VERDICT)" \
        "S26: a marker under changed controls is not CONVERGED"
    assert_contains "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_LOG_REASON)" \
        "M3 reference" "S26: the reason names the M3 reference"

    label=case_7/conv_no_final_residuals/log.simpleFoam
    assert_eq "UNAVAILABLE" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_LOG_VERDICT)" \
        "S26: a marker with missing final residuals is not CONVERGED"
    assert_eq "p k" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_REQUIRED_RECORDS_MISSING)" \
        "S26: the missing final residual records are named"
    assert_eq "" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" FINAL_INITIAL_RESIDUAL_p)" \
        "S26: no earlier p residual is reported as final"

    label=case_7/conv_no_final_continuity/log.simpleFoam
    assert_eq "UNAVAILABLE" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_LOG_VERDICT)" \
        "S26: a marker with no final continuity record is not CONVERGED"
    assert_eq "UNAVAILABLE" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" FINAL_CONTINUITY)" \
        "S26: an earlier continuity record is not reported as final"
    assert_eq "continuity" \
        "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_REQUIRED_RECORDS_MISSING)" \
        "S26: the missing continuity record is named"

    label=case_7/conv_stale/log.simpleFoam
    assert_eq "NOT_CONVERGED" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_LOG_VERDICT)" \
        "S26: a marker followed by a later Time block is NOT_CONVERGED"
    assert_eq "BEFORE_FINAL_TIME" \
        "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" SOLVER_CONVERGENCE_MARKER_POSITION)" \
        "S26: the stale marker position is recorded"
    assert_eq "3000" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" FINAL_TIME)" \
        "S26: the final time is the later Time block"

    label=case_7/conv_wrong_time/log.simpleFoam
    assert_eq "UNAVAILABLE" "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_LOG_VERDICT)" \
        "S26: a marker that names an earlier time is not CONVERGED"
    assert_contains "$(ab_block_value "$conv" CONVERGENCE_LOG "$label" CONVERGENCE_LOG_REASON)" \
        "Time = 3000" "S26: the reason names the final time"

    assert_not_contains "$(cat "$conv")" "CONVERGENCE_VERDICT=CONVERGED" \
        "S26: the aggregate verdict is not CONVERGED"
    assert_eq "COMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S26: a convergence verdict does not change the capture result"

    # One log alone, so the aggregate verdict and GITHUB_ENV show each case.
    workspace="$(new_workspace s26_changed_only)"
    ab_one_solver_log "$workspace" converged changed
    assert_eq "UNAVAILABLE" "$(ab_env_last "$workspace" CONVERGENCE_VERDICT)" \
        "S26: changed controls alone give no CONVERGED verdict"
    workspace="$(new_workspace s26_stale_only)"
    ab_one_solver_log "$workspace" stale committed
    assert_eq "NOT_CONVERGED" "$(ab_env_last "$workspace" CONVERGENCE_VERDICT)" \
        "S26: a stale marker alone gives a NOT_CONVERGED verdict"
    workspace="$(new_workspace s26_no_records_only)"
    ab_one_solver_log "$workspace" no_final_residuals committed
    assert_eq "UNAVAILABLE" "$(ab_env_last "$workspace" CONVERGENCE_VERDICT)" \
        "S26: missing final records alone give no CONVERGED verdict"
}

# ---- S27: XML comments and other non-markup text (review 5299046150) --------

s27_vtu_comment_text_is_not_markup() {
    local workspace evidence vtk file checked
    workspace="$(new_workspace s27_vtu_comments)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    vtk="${workspace}/checkout/src/batch_9/case_7/vtk"

    # The review input: a comment with '>' and an apparent DataArray tag.
    printf '%s\n' '<VTKFile><Piece><PointData><!-- note > <DataArray Name="U"/> --><DataArray Name="p"/></PointData></Piece></VTKFile>' \
        > "${vtk}/flow_latest_16_comment.vtu"
    # A comment across lines, in an appended-data file.
    ab_vtu_appended "${vtk}/flow_latest_17_comment_lines.vtu" \
        "$(printf '<PointData>\n<!--\n  a > b\n  <DataArray Name="U"/>\n-->\n<DataArray Name="p"/>\n</PointData>')"
    # A comment that holds an apparent PointData end tag does not end the element.
    ab_vtu_appended "${vtk}/flow_latest_18_comment_end_tag.vtu" \
        "$(printf '<PointData>\n<!-- a > </PointData> -->\n<DataArray Name="U"/>\n<DataArray Name="p"/>\n</PointData>')"
    # A CDATA section with '>' and an apparent DataArray tag.
    printf '%s\n' '<VTKFile><Piece><PointData><DataArray Name="p" format="ascii"><![CDATA[ 1 > 0 <DataArray Name="U"/> ]]></DataArray></PointData></Piece></VTKFile>' \
        > "${vtk}/flow_latest_19_cdata.vtu"
    # A processing instruction with '>' and an apparent DataArray tag.
    printf '%s\n' '<VTKFile><Piece><PointData><?note a > <DataArray Name="U"/> ?><DataArray Name="p"/></PointData></Piece></VTKFile>' \
        > "${vtk}/flow_latest_20_pi.vtu"
    # A comment that is still open at the appended-data marker is an incomplete
    # header, although the PointData element before it is complete.
    ab_vtu_appended "${vtk}/flow_latest_21_open_comment.vtu" \
        "$(printf '<PointData>\n<DataArray Name="U"/>\n<DataArray Name="p"/>\n</PointData>\n<!-- open')"
    # A document type declaration is not read, so the names are not evidence.
    printf '%s\n' '<!DOCTYPE VTKFile>' '<VTKFile><Piece><PointData><DataArray Name="U"/><DataArray Name="p"/></PointData></Piece></VTKFile>' \
        > "${vtk}/flow_latest_22_doctype.vtu"

    ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))" > /dev/null

    for file in case_7/vtk/flow_latest_16_comment.vtu case_7/vtk/flow_latest_17_comment_lines.vtu \
            case_7/vtk/flow_latest_19_cdata.vtu case_7/vtk/flow_latest_20_pi.vtu; do
        assert_eq "MISSING_REQUIRED_FIELDS" \
            "$(ab_vtu_result "$workspace" "$file" VTU_REQUIRED_FIELDS_RESULT)" \
            "S27: ${file}: a tag inside non-markup text is not a field"
        assert_eq "p" "$(ab_vtu_result "$workspace" "$file" VTU_OBSERVED_FIELDS)" \
            "S27: ${file}: only the real DataArray name is observed"
        assert_eq "U" "$(ab_vtu_result "$workspace" "$file" VTU_MISSING_REQUIRED_FIELDS)" \
            "S27: ${file}: the missing required field is named"
        assert_eq "COMPLETE" "$(ab_vtu_result "$workspace" "$file" VTU_TAG_EVIDENCE)" \
            "S27: ${file}: the tag evidence is complete"
    done
    file=case_7/vtk/flow_latest_18_comment_end_tag.vtu
    assert_eq "MATCH" "$(ab_vtu_result "$workspace" "$file" VTU_REQUIRED_FIELDS_RESULT)" \
        "S27: an end tag inside a comment does not end PointData"
    assert_eq "U p" "$(ab_vtu_result "$workspace" "$file" VTU_OBSERVED_FIELDS)" \
        "S27: the names after the comment are observed"
    for file in case_7/vtk/flow_latest_21_open_comment.vtu case_7/vtk/flow_latest_22_doctype.vtu; do
        assert_eq "PARSER_FAILURE" "$(ab_vtu_result "$workspace" "$file" VTU_REQUIRED_FIELDS_RESULT)" \
            "S27: ${file}: the header is not evidence"
        assert_eq "UNAVAILABLE" "$(ab_vtu_result "$workspace" "$file" VTU_OBSERVED_FIELDS)" \
            "S27: ${file}: no name is reported"
    done
    assert_not_contains "$(ab_tag_section "$workspace" case_7/vtk/flow_latest_16_comment.vtu)" \
        'Name="U"' "S27: no tag inside a comment is kept as tag evidence"
    checked="$(ab_check_tag_records "$workspace")"
    assert_contains "$checked" "bad=0" "S27: every retained tag equals its source bytes"
    assert_not_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=PRESENT" \
        "S27: the aggregate VTU evidence is not PRESENT"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S27: a header that is not evidence gives an incomplete capture"

    # The review input alone: the source has only p, so nothing is PRESENT.
    workspace="$(new_workspace s27_comment_only)"
    ab_capture_fixture "$workspace"
    rm -f -- "${workspace}/checkout/src/batch_9/case_7/vtk/flow_latest_100.vtu"
    printf '%s\n' '<VTKFile><Piece><PointData><!-- note > <DataArray Name="U"/> --><DataArray Name="p"/></PointData></Piece></VTKFile>' \
        > "${workspace}/checkout/src/batch_9/case_7/vtk/flow_latest_16_comment.vtu"
    ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))" > /dev/null
    assert_contains "$(cat "${workspace}/runner_temp/evidence/vtu-point-data.txt")" "VTU_EVIDENCE=INCOMPLETE" \
        "S27: the review input alone gives INCOMPLETE VTU evidence"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" VTU_REQUIRED_FIELDS_VERDICT)" \
        "S27: the review input alone gives an incomplete required-field verdict"
    assert_eq "COMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S27: a source mismatch alone keeps a complete capture"
}

# ---- S28: element nesting inside the header (review 5299460078) ------------

s28_vtu_unclosed_or_mismatched_elements_are_not_evidence() {
    local workspace evidence vtk file checked
    workspace="$(new_workspace s28_vtu_nesting)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    vtk="${workspace}/checkout/src/batch_9/case_7/vtk"

    # The review input: the first DataArray inside PointData never closes.
    printf '%s\n' '<VTKFile><Piece><PointData><DataArray Name="U"><DataArray Name="p"/></PointData></Piece></VTKFile>' \
        > "${vtk}/flow_latest_23_review.vtu"
    # The valid control: paired DataArray elements with content.
    printf '%s\n' '<VTKFile><Piece><PointData><DataArray Name="U" format="ascii">1 2 3</DataArray><DataArray Name="p" format="ascii">4</DataArray></PointData></Piece></VTKFile>' \
        > "${vtk}/flow_latest_24_paired.vtu"
    # A DataArray closed by an end tag with another name.
    printf '%s\n' '<VTKFile><Piece><PointData><DataArray Name="U" format="ascii">1</DataArrayX><DataArray Name="p"/></PointData></Piece></VTKFile>' \
        > "${vtk}/flow_latest_25_mismatch.vtu"
    # Another child element inside PointData that never closes.
    printf '%s\n' '<VTKFile><Piece><PointData><InformationKey name="k"><DataArray Name="U"/><DataArray Name="p"/></PointData></Piece></VTKFile>' \
        > "${vtk}/flow_latest_26_other_child.vtu"
    # Well-formed XML, but the U DataArray is inside another DataArray, so it is
    # not a PointData array.
    printf '%s\n' '<VTKFile><Piece><PointData><DataArray Name="p" format="ascii"><DataArray Name="U"/></DataArray></PointData></Piece></VTKFile>' \
        > "${vtk}/flow_latest_27_nested.vtu"
    # An unclosed DataArray in an appended-data file.
    ab_vtu_appended "${vtk}/flow_latest_28_appended_unclosed.vtu" \
        "$(printf '<PointData>\n<DataArray Name="U">\n<DataArray Name="p"/>\n</PointData>')"
    # Complete PointData, but an unclosed DataArray inside CellData.
    ab_vtu_appended "${vtk}/flow_latest_29_celldata_unclosed.vtu" \
        "$(printf '<PointData>\n<DataArray Name="U"/>\n<DataArray Name="p"/>\n</PointData>')" \
        "$(printf '<CellData>\n<DataArray Name="c">\n</CellData>')"
    # Complete PointData, but the Piece element never closes.
    printf '%s\n' '<VTKFile><Piece><PointData><DataArray Name="U"/><DataArray Name="p"/></PointData></VTKFile>' \
        > "${vtk}/flow_latest_30_piece_unclosed.vtu"
    # A complete VTKFile element inside an outer element that never closes.
    printf '%s\n' '<Outer><VTKFile><Piece><PointData><DataArray Name="U"/><DataArray Name="p"/></PointData></Piece></VTKFile>' \
        > "${vtk}/flow_latest_31_outer_unclosed.vtu"
    # A raw '<' in element text starts no valid element name, although the text
    # after it looks like a self-closing tag.
    printf '%s\n' '<VTKFile><Piece><PointData><DataArray Name="p" format="ascii">1 < 2/></DataArray><DataArray Name="U"/></PointData></Piece></VTKFile>' \
        > "${vtk}/flow_latest_32_raw_lt.vtu"

    ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))" > /dev/null

    for file in case_7/vtk/flow_latest_23_review.vtu case_7/vtk/flow_latest_25_mismatch.vtu \
            case_7/vtk/flow_latest_26_other_child.vtu case_7/vtk/flow_latest_28_appended_unclosed.vtu \
            case_7/vtk/flow_latest_29_celldata_unclosed.vtu case_7/vtk/flow_latest_30_piece_unclosed.vtu \
            case_7/vtk/flow_latest_31_outer_unclosed.vtu case_7/vtk/flow_latest_32_raw_lt.vtu; do
        assert_eq "PARSER_FAILURE" "$(ab_vtu_result "$workspace" "$file" VTU_REQUIRED_FIELDS_RESULT)" \
            "S28: ${file}: an unclosed or mismatched element is not evidence"
        assert_eq "UNAVAILABLE" "$(ab_vtu_result "$workspace" "$file" VTU_OBSERVED_FIELDS)" \
            "S28: ${file}: no name is reported"
        assert_eq "UNAVAILABLE" "$(ab_vtu_result "$workspace" "$file" VTU_TAG_EVIDENCE)" \
            "S28: ${file}: the tag evidence is not complete"
        assert_eq "PARSER_FAILURE" "$(ab_vtu_result "$workspace" "$file" VTU_TAG_EVIDENCE_REASON)" \
            "S28: ${file}: the tag evidence names the parser failure"
    done
    file=case_7/vtk/flow_latest_24_paired.vtu
    assert_eq "MATCH" "$(ab_vtu_result "$workspace" "$file" VTU_REQUIRED_FIELDS_RESULT)" \
        "S28: paired DataArray elements are MATCH"
    assert_eq "U p" "$(ab_vtu_result "$workspace" "$file" VTU_OBSERVED_FIELDS)" \
        "S28: the paired names are observed"
    assert_eq "COMPLETE" "$(ab_vtu_result "$workspace" "$file" VTU_TAG_EVIDENCE)" \
        "S28: the paired tag evidence is complete"
    file=case_7/vtk/flow_latest_27_nested.vtu
    assert_eq "MISSING_REQUIRED_FIELDS" "$(ab_vtu_result "$workspace" "$file" VTU_REQUIRED_FIELDS_RESULT)" \
        "S28: a DataArray inside another DataArray is not a PointData field"
    assert_eq "p" "$(ab_vtu_result "$workspace" "$file" VTU_OBSERVED_FIELDS)" \
        "S28: only the direct PointData child is observed"
    checked="$(ab_check_tag_records "$workspace")"
    assert_contains "$checked" "bad=0" "S28: every retained tag equals its source bytes"
    assert_not_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=PRESENT" \
        "S28: the aggregate VTU evidence is not PRESENT"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S28: a malformed header gives an incomplete capture"

    # The review input alone: nothing is PRESENT or COMPLETE.
    workspace="$(new_workspace s28_review_only)"
    ab_capture_fixture "$workspace"
    rm -f -- "${workspace}/checkout/src/batch_9/case_7/vtk/flow_latest_100.vtu"
    printf '%s\n' '<VTKFile><Piece><PointData><DataArray Name="U"><DataArray Name="p"/></PointData></Piece></VTKFile>' \
        > "${workspace}/checkout/src/batch_9/case_7/vtk/flow_latest_23_review.vtu"
    ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))" > /dev/null
    assert_not_contains "$(cat "${workspace}/runner_temp/evidence/vtu-point-data.txt")" "VTU_EVIDENCE=PRESENT" \
        "S28: the review input alone is not PRESENT VTU evidence"
    assert_ne "COMPLETE" "$(ab_env_last "$workspace" VTU_REQUIRED_FIELDS_VERDICT)" \
        "S28: the review input alone gives no complete required-field verdict"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        "S28: the review input alone gives an incomplete capture"
}

# ---- S29: complete tag syntax (review 5300443151) ---------------------------

# ab_vtu_finite <file> <PointData-text> - a finite ASCII VTU file with one Piece.
ab_vtu_finite() {
    printf '<VTKFile type="UnstructuredGrid">\n<Piece NumberOfPoints="1">\n%s\n</Piece>\n</VTKFile>\n' \
        "$2" > "$1"
}

s29_vtu_invalid_tag_syntax_is_not_evidence() {
    local workspace evidence vtk file checked scan status
    workspace="$(new_workspace s29_vtu_tag_syntax)"
    ab_capture_fixture "$workspace"
    evidence="${workspace}/runner_temp/evidence"
    vtk="${workspace}/checkout/src/batch_9/case_7/vtk"
    local u='<DataArray Name="U"/>' p='<DataArray Name="p"/>'

    # The two review inputs.
    ab_vtu_finite "${vtk}/flow_latest_33_bad_start.vtu" "<PointData bogus>${u}${p}</PointData>"
    ab_vtu_finite "${vtk}/flow_latest_34_bad_end.vtu" "<PointData>${u}${p}</PointData bogus>"
    # The valid control: attributes with both quotes, spaces around '=' and
    # before '>' and '/>', a tab and a line end between attributes, references,
    # and a '>' inside a value.
    ab_vtu_finite "${vtk}/flow_latest_35_valid.vtu" \
        "$(printf '<PointData Scalars="p" Vectors = '"'"'U'"'"' >\n<DataArray type="Float32"\tName="U"\n  NumberOfComponents="3" format="ascii" Note="a &amp; b &#62; &#x3E; c > d">1 2 3</DataArray >\n<DataArray Name='"'"'p'"'"' />\n</PointData >')"
    # Two Name attributes (from S25), and any other repeated attribute.
    ab_vtu_finite "${vtk}/flow_latest_14_two_names.vtu" "<PointData><DataArray Name=\"U\" Name=\"U\"/>${p}</PointData>"
    ab_vtu_finite "${vtk}/flow_latest_36_repeated.vtu" "<PointData>${u}<DataArray type=\"a\" type=\"b\" Name=\"p\"/></PointData>"
    # A quoted Name after an unquoted value (from S25).
    ab_vtu_finite "${vtk}/flow_latest_15_unquoted_first.vtu" "<PointData><DataArray format=ascii Name=\"U\"/>${p}</PointData>"
    # An attribute without a value inside a DataArray tag.
    ab_vtu_finite "${vtk}/flow_latest_37_bad_dataarray.vtu" "<PointData><DataArray Name=\"U\" bogus/>${p}</PointData>"
    # Invalid syntax in a tag outside PointData.
    printf '%s\n' "<VTKFile><Piece NumberOfPoints=1><PointData>${u}${p}</PointData></Piece></VTKFile>" \
        > "${vtk}/flow_latest_38_bad_piece_start.vtu"
    printf '%s\n' "<VTKFile><Piece><PointData>${u}${p}</PointData></Piece bogus></VTKFile>" \
        > "${vtk}/flow_latest_39_bad_piece_end.vtu"
    # A '<' inside a value, a '&' that starts no reference, a space inside
    # '/>', and no space between two attributes.
    ab_vtu_finite "${vtk}/flow_latest_40_lt_in_value.vtu" "<PointData><DataArray Name=\"U\" Note=\"a<b\"/>${p}</PointData>"
    ab_vtu_finite "${vtk}/flow_latest_41_bad_reference.vtu" "<PointData><DataArray Name=\"U\" Note=\"a & b\"/>${p}</PointData>"
    ab_vtu_finite "${vtk}/flow_latest_42_slash_space.vtu" "<PointData>${u}<DataArray Name=\"p\" / ></PointData>"
    ab_vtu_finite "${vtk}/flow_latest_43_no_space.vtu" "<PointData><DataArray type=\"a\"Name=\"U\"/>${p}</PointData>"
    # A self-closing end tag.
    ab_vtu_finite "${vtk}/flow_latest_44_end_slash.vtu" "<PointData>${u}${p}</PointData/>"

    ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))" > /dev/null

    for file in 33_bad_start 34_bad_end 14_two_names 36_repeated 15_unquoted_first 37_bad_dataarray \
            38_bad_piece_start 39_bad_piece_end 40_lt_in_value 41_bad_reference 42_slash_space \
            43_no_space 44_end_slash; do
        file="case_7/vtk/flow_latest_${file}.vtu"
        assert_eq "PARSER_FAILURE" "$(ab_vtu_result "$workspace" "$file" VTU_REQUIRED_FIELDS_RESULT)" \
            "S29: ${file}: invalid tag syntax is not evidence"
        assert_eq "UNAVAILABLE" "$(ab_vtu_result "$workspace" "$file" VTU_OBSERVED_FIELDS)" \
            "S29: ${file}: no name is reported"
        assert_eq "PARSER_FAILURE" "$(ab_vtu_result "$workspace" "$file" VTU_TAG_EVIDENCE_REASON)" \
            "S29: ${file}: the tag evidence names the parser failure"
    done
    file=case_7/vtk/flow_latest_35_valid.vtu
    assert_eq "MATCH" "$(ab_vtu_result "$workspace" "$file" VTU_REQUIRED_FIELDS_RESULT)" \
        "S29: valid PointData and DataArray attributes are MATCH"
    assert_eq "U p" "$(ab_vtu_result "$workspace" "$file" VTU_OBSERVED_FIELDS)" \
        "S29: the valid names are observed"
    assert_eq "COMPLETE" "$(ab_vtu_result "$workspace" "$file" VTU_TAG_EVIDENCE)" \
        "S29: the valid tag evidence is complete"
    # The original bytes of a rejected evidence tag stay in the evidence.
    assert_contains "$(ab_tag_section "$workspace" case_7/vtk/flow_latest_33_bad_start.vtu)" \
        "<PointData bogus>" "S29: the rejected start tag is kept as original evidence"
    assert_contains "$(ab_tag_section "$workspace" case_7/vtk/flow_latest_34_bad_end.vtu)" \
        "</PointData bogus>" "S29: the rejected end tag is kept as original evidence"
    checked="$(ab_check_tag_records "$workspace")"
    assert_contains "$checked" "bad=0" "S29: every retained tag equals its source bytes"
    assert_not_contains "$(cat "${evidence}/vtu-point-data.txt")" "VTU_EVIDENCE=PRESENT" \
        "S29: the aggregate VTU evidence is not PRESENT"
    # A direct scan of a rejected header prints no name record, although the
    # names come before the invalid end tag.
    scan="$(EVIDENCE_DIR="$evidence" TMPDIR="${workspace}/tmp" bash "${workspace}/runner_temp/capture_work.sh" \
            --vtu-scan "${vtk}/flow_latest_34_bad_end.vtu" "" 0)" && status=0 || status=$?
    assert_eq "2" "$status" "S29: a direct scan of a rejected header ends with status 2"
    assert_eq "" "$scan" "S29: a direct scan of a rejected header prints no name record"

    # Each review input alone: nothing is PRESENT or COMPLETE.
    for file in 33_bad_start 34_bad_end; do
        workspace="$(new_workspace "s29_${file}_only")"
        ab_capture_fixture "$workspace"
        rm -f -- "${workspace}/checkout/src/batch_9/case_7/vtk/flow_latest_100.vtu"
        cp -- "${vtk}/flow_latest_${file}.vtu" "${workspace}/checkout/src/batch_9/case_7/vtk/"
        ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))" > /dev/null
        assert_not_contains "$(cat "${workspace}/runner_temp/evidence/vtu-point-data.txt")" \
            "VTU_EVIDENCE=PRESENT" "S29: ${file} alone is not PRESENT VTU evidence"
        assert_ne "COMPLETE" "$(ab_env_last "$workspace" VTU_REQUIRED_FIELDS_VERDICT)" \
            "S29: ${file} alone gives no complete required-field verdict"
        assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
            "S29: ${file} alone gives an incomplete capture"
    done
}

# ---- S30 to S41: the Case 7 mesh-phase diagnostic (Issue #80) ---------------
#
# The diagnostic workflow openfoam-m3-mesh-diagnostic.yml runs one mesh-only
# Case 7 diagnostic. These checks run its extracted steps with a fake checkout,
# a fake setup Stage, a fake OpenFOAM tree, and fake system commands. No check
# installs OpenFOAM, runs a solver, or dispatches a workflow.

DIAG_WORKFLOW="${REPO_ROOT}/.github/workflows/openfoam-m3-mesh-diagnostic.yml"
CONTRACT_WORKFLOW="${REPO_ROOT}/.github/workflows/batch-contract.yml"

# The committed Case 7 row selects this Case directory.
AB_DIAG_FLOW="src/batch_9/case_7/flow"

# ab_diag_write_fake <file> - the one fake command of the diagnostic checks. The
# command name comes from $0. Each call appends one line to DIAG_FAKE_CALLS:
# name, working directory, and each argument, separated by tabs. The line is one
# write, so the two sides of a pipeline cannot mix their records.
ab_diag_write_fake() {
    cat > "$1" <<'DIAG_FAKE'
#!/usr/bin/env bash
set -u
name="${0##*/}"
record="${name}"$'\t'"${PWD}"
for argument in "$@"; do record+=$'\t'"${argument}"; done
printf '%s\n' "$record" >> "$DIAG_FAKE_CALLS"
has() { local want="$1" a; shift; for a in "$@"; do [[ "$a" == "$want" ]] && return 0; done; return 1; }
after() { local want="$1" a previous=""; shift; for a in "$@"; do [[ "$previous" == "$want" ]] && { printf '%s' "$a"; return 0; }; previous="$a"; done; return 1; }
# A forced failure or block applies to a real call, never to a help call.
if ! has -help-full "$@"; then
    for entry in ${FAKE_FAIL:-}; do
        [[ "$entry" == "$name" ]] && { echo "fake ${name}: forced failure" >&2; exit 1; }
    done
    for entry in ${FAKE_HANG:-}; do
        if [[ "$entry" == "$name" ]]; then
            printf '%s\n' "$$" >> "$DIAG_FAKE_PIDS"
            exec sleep 300
        fi
    done
fi
np="${FAKE_MPI_NP:-1}"
write_geometry=0
has -writeSets "$@" && write_geometry=1

case "$name" in
    curl)
        printf 'echo repository added\n'
        exit 0 ;;
    sudo)
        exec "$@" ;;
    apt-get)
        echo "fake apt-get $*"
        exit 0 ;;
    dpkg-query)
        printf '%s' "${FAKE_PACKAGE_VERSION-2512.0-1}"
        exit 0 ;;
    gcc)
        echo "13.3.0"
        exit 0 ;;
    gh)
        exit 0 ;;
    mpirun)
        if [[ "${1:-}" != "--oversubscribe" || "${2:-}" != "-np" ]]; then
            echo "fake mpirun: unexpected launcher $*" >&2
            exit 2
        fi
        export FAKE_MPI_NP="$3"
        shift 3
        exec "$@" ;;
esac

if has -help-full "$@"; then
    case "$name" in
        snappyHexMesh) options=("-dict <file>" "-overwrite" "-parallel") ;;
        checkMesh) options=("-allGeometry" "-allTopology" "-parallel" "-time <ranges>"
                            "-writeAllFields" "-writeSets <surfaceFormat>") ;;
        reconstructParMesh) options=("-constant" "-time <ranges>") ;;
        *) options=() ;;
    esac
    echo "Usage: ${name} [OPTIONS]"
    echo "Options:"
    for option in "${options[@]}"; do
        word="${option%% *}"
        [[ " ${FAKE_HELP_DROP:-} " == *" ${name}:${word} "* ]] && continue
        [[ " ${FAKE_HELP_BARE:-} " == *" ${name}:${word} "* ]] && option="$word"
        printf '  %-28s %s\n' "$option" "fake description"
    done
    exit 0
fi

if [[ " ${FAKE_BIG_LOG:-} " == *" ${name} "* ]]; then
    awk 'BEGIN { for (i = 0; i < 20000; i++) printf "fake log line %06d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'
fi

case "$name" in
    surfaceFeatureExtract)
        echo "End" ;;
    blockMesh)
        mkdir -p constant/polyMesh
        : > constant/polyMesh/owner
        echo "End" ;;
    decomposePar)
        for (( n = 0; n < 8; n++ )); do
            mkdir -p "processor${n}/constant/polyMesh" "processor${n}/0"
            : > "processor${n}/constant/polyMesh/owner"
        done
        echo "End" ;;
    snappyHexMesh)
        phase_dirs() {
            local time="$1" n
            for (( n = 0; n < np; n++ )); do
                mkdir -p "processor${n}/${time}/polyMesh"
                : > "processor${n}/${time}/polyMesh/owner"
            done
        }
        phase() {
            echo "$1 mesh : cells:1175333  faces:3638916  points:1288205  unbalance:0.009"
            echo "Cells per refinement level:"
            printf '    0\t2749\n'
            echo "Writing mesh to time $2"
            echo "Wrote mesh in = 0.71 s."
            phase_dirs "$2"
        }
        echo "Exec   : snappyHexMesh $*"
        case "${FAKE_SNAPPY:-ok}" in
            ok) phase Refined 1 ;;
            missing) echo "Refined mesh : cells:1175333" ;;
            duplicate) phase Refined 1; phase Refined 1 ;;
            unlabelled) echo "Writing mesh to time 1"; phase_dirs 1 ;;
            snapped) phase Refined 1; phase Snapped 2 ;;
            constant) phase Refined constant ;;
            inconsistent) echo "Refined mesh : cells:1175333"; echo "Writing mesh to time 1"; phase_dirs 2 ;;
            extra_rank7) phase Refined 1; mkdir -p processor7/2/polyMesh; : > processor7/2/polyMesh/owner ;;
            extra_processor) phase Refined 1; mkdir -p processor8/1/polyMesh; : > processor8/1/polyMesh/owner ;;
        esac
        echo "Finished meshing without any errors"
        echo "End" ;;
    checkMesh)
        time="$(after -time "$@" || true)"
        if has -parallel "$@"; then
            state=PHASE
        elif [[ "$time" == "0" ]]; then
            state=BACKGROUND
        else
            state=FINAL
        fi
        mode_var="FAKE_CHECK_${state}"
        mode="${!mode_var:-ok}"
        write_set() {
            local count="$1" dir n
            case "$state" in
                BACKGROUND) set -- "constant/polyMesh/sets" ;;
                FINAL) set -- "${time}/polyMesh/sets" ;;
                PHASE) set -- ; for (( n = 0; n < np; n++ )); do set -- "$@" "processor${n}/${time}/polyMesh/sets"; done ;;
            esac
            for dir in "$@"; do
                mkdir -p "$dir"
                printf 'FoamFile { class cellSet; object concaveCells; }\n%s\n(\n)\n' "$count" > "${dir}/concaveCells"
            done
            if (( write_geometry )); then
                mkdir -p "postProcessing/checkMesh/${time}"
                printf 'fake set geometry\n' > "postProcessing/checkMesh/${time}/concaveCells.vtk"
            fi
        }
        echo "Exec   : checkMesh $*"
        echo "Time = ${time}"
        echo "Checking geometry..."
        case "$mode" in
            ok)
                echo "    Concave cell check OK."
                printf '\nMesh OK.\n\n' ;;
            concave:*)
                echo " ***Concave cells (using face planes) found, number of cells: ${mode#concave:}"
                echo "  <<Writing ${mode#concave:} concave cells to set concaveCells"
                write_set "${mode#concave:}"
                printf '\nFailed 1 mesh checks.\n\n' ;;
            concave_noset:*)
                echo " ***Concave cells (using face planes) found, number of cells: ${mode#concave_noset:}"
                printf '\nFailed 1 mesh checks.\n\n' ;;
            other)
                echo "    Concave cell check OK."
                echo " ***Zero or negative cell volume detected.  Minimum negative volume: -1"
                printf '\nFailed 1 mesh checks.\n\n' ;;
            failed_nocount)
                printf '\nFailed 1 mesh checks.\n\n' ;;
            noresult)
                : ;;
        esac
        echo "End" ;;
    reconstructParMesh)
        time="$(after -time "$@" || true)"
        mkdir -p "${time}/polyMesh"
        : > "${time}/polyMesh/owner"
        echo "End" ;;
    *)
        echo "End" ;;
esac
exit 0
DIAG_FAKE
    chmod +x "$1"
}

# ab_diag_write_setup_stub <file> - the fake setup Stage at src/run_batch.sh of
# the fake checkout. It accepts only the exact setup call. It builds the Case 7
# flow Case from the committed templates, as the real setup Stage does, with the
# committed defaults snap off, addLayers off, and eight subdomains. FAKE_SETUP
# selects a fault.
ab_diag_write_setup_stub() {
    cat > "$1" <<'DIAG_SETUP'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'run_batch.sh\t%s' "$PWD"
    for argument in "$@"; do printf '\t%s' "$argument"; done
    printf '\n'
} >> "$DIAG_FAKE_CALLS"
[[ "$*" == "--stage setup -j 1 src/output_batch_9.csv" ]] || { echo "unexpected setup call: $*" >&2; exit 2; }
[[ "${FAKE_SETUP:-ok}" != fail ]] || { echo "fake setup: forced failure" >&2; exit 1; }
template="src/master_batch/simpleFoam_files/system"
batch="src/batch_9"
flow="${batch}/case_7/flow"
mkdir -p "${flow}/system" "${flow}/constant/triSurface" "${flow}/0" "${batch}/case_7/trd"
cp src/output_batch_9.csv "${batch}/output_batch_9.csv"
for dict in controlDict fvSolution snappyHexMeshDict decomposeParDict blockMeshDict; do
    cp "${template}/${dict}" "${flow}/system/${dict}"
done
snap=off layers=off np=8
case "${FAKE_SETUP:-ok}" in
    snap_on) snap=on ;;
    layers_on) layers=on ;;
    np4) np=4 ;;
esac
sed -i -e "s#<snap_ctrl>#${snap}#" -e "s#^addLayers[[:space:]]*on;#addLayers       ${layers};#" \
    "${flow}/system/snappyHexMeshDict"
sed -i -e "s#<np>#${np}#" "${flow}/system/decomposeParDict"
row() {
    printf '"%s","2","%s","%s","180.000","5.0","5.0","%s","%s","%s"\n' \
        "${PWD}/${batch}/output_batch_9.csv" "$1" "$2" "${PWD}/${batch}/$2" "$3" "$4"
}
{
    printf 'csv_file,row_number,case_id,case_name,wd,ws,ws_for_setup,case_dir,status,message\n'
    if [[ "${FAKE_SETUP:-ok}" != no_flow_row ]]; then
        row case_7 case_7/flow created "flow case created"
    fi
    row case_7 case_7/trd created "transport case created"
    if [[ "${FAKE_SETUP:-ok}" == other_case ]]; then
        mkdir -p "${batch}/case_8/flow"
        row case_8 case_8/flow created "flow case created"
    fi
} > "${batch}/setup_cases_summary.csv"
echo "setup done"
DIAG_SETUP
    chmod +x "$1"
}

# ab_diag_fixture <workspace> - a fake checkout with the committed inputs, a
# fake OpenFOAM tree, fake system commands, and the extracted workflow steps.
ab_diag_fixture() {
    local workspace="$1" checkout name
    checkout="${workspace}/checkout"
    mkdir -p "${workspace}/runner_temp" "${workspace}/tmp" "${workspace}/fakebin" \
             "${workspace}/openfoam/openfoam2512/etc" "${workspace}/openfoam/openfoam2512/bin" \
             "${checkout}/src/master_batch"
    : > "${workspace}/github_env"
    : > "${workspace}/step_summary"
    : > "${workspace}/calls.tsv"
    : > "${workspace}/fake_pids"
    cp -- "${REPO_ROOT}/.openfoam-version" "${checkout}/.openfoam-version"
    cp -- "${SRC_DIR}/output_batch_1.csv" "${checkout}/src/output_batch_1.csv"
    cp -R -- "${MASTER_SRC_DIR}/simpleFoam_files" "${checkout}/src/master_batch/simpleFoam_files"
    ab_diag_write_setup_stub "${checkout}/src/run_batch.sh"

    ab_diag_write_fake "${workspace}/diag_fake"
    for name in curl sudo apt-get dpkg-query gcc gh; do
        ln -s "${workspace}/diag_fake" "${workspace}/fakebin/${name}"
    done
    for name in surfaceFeatureExtract blockMesh checkMesh decomposePar snappyHexMesh \
                reconstructParMesh mpirun simpleFoam foamToVTK renumberMesh reconstructPar; do
        ln -s "${workspace}/diag_fake" "${workspace}/openfoam/openfoam2512/bin/${name}"
    done
    cat > "${workspace}/openfoam/openfoam2512/etc/bashrc" <<DIAG_BASHRC
export WM_PROJECT_VERSION="\${FAKE_WM_VERSION-v2512}"
export WM_OPTIONS=linux64GccDPInt32Opt
export PATH="${workspace}/openfoam/openfoam2512/bin:\${PATH}"
DIAG_BASHRC

    ab_step_run_body "Start the diagnostic clock" "$DIAG_WORKFLOW" > "${workspace}/clock_step.sh"
    ab_step_run_body "Run the mesh diagnostic" "$DIAG_WORKFLOW" > "${workspace}/diagnostic_step.sh"
    ab_step_run_body "Package the diagnostic evidence" "$DIAG_WORKFLOW" > "${workspace}/package_step.sh"
    ab_step_run_body "Write the diagnostic summary" "$DIAG_WORKFLOW" > "${workspace}/summary_step.sh"
    local step
    for step in clock diagnostic package summary; do
        [[ -s "${workspace}/${step}_step.sh" ]] ||
            _fail "S30: the ${step} step body must be extracted from the diagnostic workflow"
        bash -n "${workspace}/${step}_step.sh" ||
            _fail "S30: the extracted ${step} step must parse"
    done
}

# ab_diag_run <workspace> [NAME=value ...] - run the extracted clock,
# diagnostic, package, and summary steps in order. Values published through
# GITHUB_ENV reach the later steps, as on the runner. The arguments override
# them, and OPENFOAM_ROOT selects the fake OpenFOAM tree. Prints the diagnostic
# step status, its elapsed seconds, and the package and summary statuses.
ab_diag_run() {
    local workspace="$1" start elapsed status package summary
    shift
    local base=(PATH="${workspace}/fakebin:${PATH}" TMPDIR="${workspace}/tmp"
                RUNNER_TEMP="${workspace}/runner_temp" GITHUB_ENV="${workspace}/github_env"
                GITHUB_WORKSPACE="${workspace}/checkout" GITHUB_STEP_SUMMARY="${workspace}/step_summary"
                GITHUB_SHA=6f198977b700a2bcb664bcc704a3d506eefb67ab GITHUB_RUN_ID=4242
                DIAG_FAKE_CALLS="${workspace}/calls.tsv" DIAG_FAKE_PIDS="${workspace}/fake_pids")
    env "${base[@]}" bash "${workspace}/clock_step.sh" > "${workspace}/clock.out" 2>&1 ||
        _fail "S30: the clock step must succeed"
    local published=()
    mapfile -t published < <(grep -E '^[A-Z_][A-Z0-9_]*=' "${workspace}/github_env")
    start="$(date +%s)"
    env "${base[@]}" "${published[@]}" OPENFOAM_ROOT="${workspace}/openfoam" \
        CHECKOUT_OUTCOME=success "$@" \
        bash "${workspace}/diagnostic_step.sh" > "${workspace}/diagnostic.out" 2>&1 \
        && status=0 || status=$?
    elapsed=$(( $(date +%s) - start ))
    env "${base[@]}" "${published[@]}" "$@" bash "${workspace}/package_step.sh" \
        > "${workspace}/package.out" 2>&1 && package=0 || package=$?
    env "${base[@]}" "${published[@]}" "$@" bash "${workspace}/summary_step.sh" \
        > "${workspace}/summary.out" 2>&1 && summary=0 || summary=$?
    printf 'status=%s elapsed=%s package=%s summary=%s\n' "$status" "$elapsed" "$package" "$summary"
}

# ab_diag_step_timeout <step-name> - the timeout-minutes value of one step of
# the diagnostic workflow, or nothing.
ab_diag_step_timeout() {
    awk -v want="      - name: $1" '
        $0 == want { found = 1; next }
        found && /^      - name: / { exit }
        found && /^        timeout-minutes: [0-9]+[[:space:]]*$/ { print $2; exit }
    ' "$DIAG_WORKFLOW"
}

# ab_diag_dir <workspace> - the diagnostic directory on the fake runner.
ab_diag_dir() {
    printf '%s\n' "${1}/runner_temp/m3-mesh-diagnostic"
}

# ab_diag_value <workspace> <key> - one value of the uploaded result file.
ab_diag_value() {
    ab_file_value "$(ab_diag_dir "$1")/upload/result.env" "$2"
}

# ab_diag_calls <workspace> - the fake calls, one per line: name, then the
# arguments, separated by single spaces.
ab_diag_calls() {
    awk -F '\t' '{ line = $1; for (i = 3; i <= NF; i++) line = line " " $i; print line }' \
        "${1}/calls.tsv"
}

# ab_diag_archive_list <workspace> - the member names of the uploaded archive.
ab_diag_archive_list() {
    tar -tzf "$(ab_diag_dir "$1")/upload/m3-mesh-diagnostic-evidence.tar.gz"
}

s30_diagnostic_workflow_interface() {
    local workflow
    assert_file_exists "$DIAG_WORKFLOW" "S30: the diagnostic workflow exists"
    workflow="$(cat "$DIAG_WORKFLOW")"
    # workflow_dispatch is the only trigger, and it has no inputs.
    assert_eq $'on:\n  workflow_dispatch:' \
        "$(awk '/^on:/ { on = 1; print; next } on && /^[^ ]/ { exit } on && NF { print }' "$DIAG_WORKFLOW")" \
        "S30: workflow_dispatch without inputs is the only trigger"
    assert_not_contains "$workflow" "inputs:" "S30: the dispatch has no inputs"
    assert_contains "$workflow" $'permissions:\n  contents: read' "S30: the token can only read contents"
    assert_contains "$workflow" "runs-on: ubuntu-24.04" "S30: the job runs on ubuntu-24.04"
    assert_contains "$workflow" $'    timeout-minutes: 20\n' "S30: the job limit is 20 minutes"
    assert_contains "$workflow" "retention-days: 90" "S30: the artifact is kept for 90 days"
    assert_contains "$workflow" "uses: actions/upload-artifact@v4" "S30: the evidence is uploaded"
    # batch-contract runs for the new workflow on push and on pull_request.
    assert_eq "2" "$(grep -c "^      - '.github/workflows/openfoam-m3-mesh-diagnostic.yml'$" "$CONTRACT_WORKFLOW")" \
        "S30: both batch-contract path filters name the diagnostic workflow"
    # The clock step publishes the real OpenFOAM root and a 15-minute deadline.
    local workspace
    workspace="$(new_workspace s30_clock)"
    ab_diag_fixture "$workspace"
    # The diagnostic script inside the step body parses too.
    awk '/<<.MESH_DIAGNOSTIC.$/ { inside = 1; next } /^MESH_DIAGNOSTIC$/ { inside = 0 } inside' \
        "${workspace}/diagnostic_step.sh" > "${workspace}/diagnostic_script.sh"
    [[ -s "${workspace}/diagnostic_script.sh" ]] || _fail "S30: the diagnostic script must be extracted"
    bash -n "${workspace}/diagnostic_script.sh" || _fail "S30: the diagnostic script must parse"
    env RUNNER_TEMP="${workspace}/runner_temp" GITHUB_ENV="${workspace}/github_env" \
        bash "${workspace}/clock_step.sh" > /dev/null 2>&1 || _fail "S30: the clock step must succeed"
    assert_eq "/usr/lib/openfoam" "$(ab_file_value "${workspace}/github_env" OPENFOAM_ROOT)" \
        "S30: the clock step names the installed OpenFOAM root"
    # The time reserve (PR #91 review 5303287747). The contract needs at least
    # 3 minutes for summary and upload and a 2-minute job margin after the
    # active work.
    local window job step minutes total=0 later=0 report=0 diag=0
    window=$(( $(ab_file_value "${workspace}/github_env" DIAG_ACTIVE_DEADLINE) - \
               $(ab_file_value "${workspace}/github_env" DIAG_CLOCK_START) ))
    job="$(awk '/^    timeout-minutes: [0-9]+[[:space:]]*$/ { print $2; exit }' "$DIAG_WORKFLOW")"
    assert_eq "20" "$job" "S30: the job limit is 20 minutes"
    for step in "Start the diagnostic clock" "Check out the repository" "Run the mesh diagnostic" \
                "Package the diagnostic evidence" "Write the diagnostic summary" "Upload the diagnostic evidence"; do
        minutes="$(ab_diag_step_timeout "$step")"
        [[ "$minutes" =~ ^[0-9]+$ ]] || { _fail "S30: the step '${step}' must have a timeout"; minutes=0; }
        total=$(( total + minutes ))
        case "$step" in
            "Run the mesh diagnostic") diag="$minutes" ;;
            "Package the diagnostic evidence") later=$(( later + minutes )) ;;
            "Write the diagnostic summary"|"Upload the diagnostic evidence")
                later=$(( later + minutes )); report=$(( report + minutes )) ;;
        esac
    done
    (( window <= 900 )) ||
        _fail "S30: the active work must end at most 15 minutes after the clock start" "window: ${window} s"
    (( window <= diag * 60 )) ||
        _fail "S30: the diagnostic step guard must not stop the work before the active-work deadline" \
              "window: ${window} s, guard: ${diag} min"
    (( report >= 3 )) ||
        _fail "S30: the summary and upload steps must have at least 3 minutes" "minutes: ${report}"
    (( window + later * 60 + 120 <= job * 60 )) ||
        _fail "S30: the active work and the later steps must leave a 2-minute job margin" \
              "window: ${window} s, later steps: ${later} min, job: ${job} min"
    (( total + 2 <= job )) ||
        _fail "S30: all step timeouts together must leave a 2-minute job margin" \
              "steps: ${total} min, job: ${job} min"
    assert_eq "${workspace}/runner_temp/m3-mesh-diagnostic" "$(ab_file_value "${workspace}/github_env" DIAG_DIR)" \
        "S30: the diagnostic directory is runner-temporary"
}

s31_diagnostic_all_clean_records_the_complete_evidence() {
    local workspace run dir calls flow expected archive
    workspace="$(new_workspace s31_all_clean)"
    ab_diag_fixture "$workspace"
    run="$(ab_diag_run "$workspace")"
    dir="$(ab_diag_dir "$workspace")"
    flow="${workspace}/checkout/${AB_DIAG_FLOW}"

    assert_contains "$run" "status=0 " "S31: the diagnostic step ends with status 0"
    assert_contains "$run" "package=0 " "S31: the package step ends with status 0"
    assert_contains "$run" "summary=0" "S31: the summary step ends with status 0"
    assert_eq "NO_CONCAVITY_REPRODUCED" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S31: clean background, phase, and final checks give NO_CONCAVITY_REPRODUCED"
    assert_eq "0" "$(ab_diag_value "$workspace" BACKGROUND_CONCAVE_CELLS)" "S31: the background count is 0"
    assert_eq "0" "$(ab_diag_value "$workspace" REFINED_CONCAVE_CELLS)" "S31: the refined count is 0"
    assert_eq "0" "$(ab_diag_value "$workspace" FINAL_CONCAVE_CELLS)" "S31: the final count is 0"
    assert_eq "1" "$(ab_diag_value "$workspace" REFINED_TIME)" "S31: the refined phase time comes from the log"
    assert_eq "SAME" "$(ab_diag_value "$workspace" FINAL_COMPARISON)" \
        "S31: the final parallel and serial checks are compared"

    # The exact command vectors, in order, in the temporary flow Case.
    calls="$(ab_diag_calls "$workspace")"
    # The two sides of the repository pipeline run at the same time, so each
    # install call is checked alone, and the update comes before the install.
    local line
    for line in "curl -fsSL https://dl.openfoam.com/add-debian-repo.sh" "sudo bash" \
                "sudo apt-get update" "sudo apt-get install -y --no-install-recommends openfoam2512-default"; do
        assert_contains "$calls" "$line" "S31: the install runs '${line}'"
    done
    (( $(grep -n -m1 '^sudo apt-get update$' <<< "$calls" | cut -d: -f1) <
       $(grep -n -m1 '^sudo apt-get install' <<< "$calls" | cut -d: -f1) )) ||
        _fail "S31: the package index update must come before the install"
    expected="snappyHexMesh -help-full
checkMesh -help-full
reconstructParMesh -help-full
run_batch.sh --stage setup -j 1 src/output_batch_9.csv
surfaceFeatureExtract
blockMesh
checkMesh -allGeometry -allTopology -time 0
decomposePar -force
mpirun --oversubscribe -np 8 snappyHexMesh -parallel
snappyHexMesh -parallel
mpirun --oversubscribe -np 8 checkMesh -parallel -allGeometry -allTopology -time 1 -writeSets vtk
checkMesh -parallel -allGeometry -allTopology -time 1 -writeSets vtk
reconstructParMesh -time 1
checkMesh -allGeometry -allTopology -writeAllFields -time 1"
    assert_contains "$calls" "$expected" "S31: the help, setup, and mesh commands run in the contract order"
    assert_not_contains "$calls" "-overwrite" "S31: no command uses -overwrite"
    assert_eq "10" "$(awk -F '\t' -v d="$flow" '$2 == d' "${workspace}/calls.tsv" | wc -l | tr -d ' ')" \
        "S31: every mesh command runs in the generated Case 7 flow directory"

    # Identity, environment, dictionaries, help, commands, phases, and checks.
    assert_file_exists "${dir}/evidence/identity.txt" "S31: the identity record exists"
    assert_contains "$(cat "${dir}/evidence/identity.txt")" "CASE_ID=7" "S31: the Case ID is recorded"
    assert_contains "$(cat "${dir}/evidence/identity.txt")" \
        "SOURCE_CSV_SHA256=$(sha256sum < "${SRC_DIR}/output_batch_1.csv" | cut -d' ' -f1)" \
        "S31: the source CSV checksum is recorded"
    assert_contains "$(cat "${dir}/evidence/identity.txt")" \
        "CASE_ROW_SHA256=$(awk -F, '$1 == "7"' "${SRC_DIR}/output_batch_1.csv" | sha256sum | cut -d' ' -f1)" \
        "S31: the selected row checksum is recorded"
    assert_contains "$(cat "${dir}/evidence/identity.txt")" \
        "MAIN_SHA=6f198977b700a2bcb664bcc704a3d506eefb67ab" "S31: the commit is recorded"
    assert_contains "$(cat "${dir}/evidence/identity.txt")" "WM_PROJECT_VERSION=v2512" \
        "S31: the loaded OpenFOAM version is recorded"
    assert_contains "$(cat "${dir}/evidence/identity.txt")" "OPENFOAM_PACKAGE_VERSION=2512.0-1" \
        "S31: the package version is recorded"
    assert_contains "$(cat "${dir}/evidence/identity.txt")" "WM_OPTIONS=linux64GccDPInt32Opt" \
        "S31: WM_OPTIONS is recorded"
    local dict
    for dict in snappyHexMeshDict fvSolution controlDict; do
        assert_file_exists "${dir}/evidence/dictionaries/${dict}" "S31: ${dict} is kept"
        assert_contains "$(cat "${dir}/evidence/dictionaries.sha256")" \
            "$(sha256sum < "${flow}/system/${dict}" | cut -d' ' -f1)" "S31: the ${dict} checksum is recorded"
    done
    assert_contains "$(cat "${dir}/evidence/controls.txt")" "SNAP=off" "S31: snap=off is recorded"
    assert_contains "$(cat "${dir}/evidence/controls.txt")" "ADD_LAYERS=off" "S31: addLayers=off is recorded"
    assert_contains "$(cat "${dir}/evidence/controls.txt")" "NUMBER_OF_SUBDOMAINS=8" \
        "S31: the eight subdomains are recorded"
    assert_contains "$(cat "${dir}/evidence/help/checkMesh.txt")" "-writeSets <surfaceFormat>" \
        "S31: the installed checkMesh help is kept"
    assert_contains "$(cat "${dir}/evidence/help-checks.txt")" "checkMesh -writeSets <surfaceFormat> FOUND" \
        "S31: the -writeSets argument is verified"
    assert_contains "$(cat "${dir}/evidence/commands.tsv")" "snappyHexMesh	240	" \
        "S31: the snappyHexMesh cap is 240 seconds"
    assert_contains "$(cat "${dir}/evidence/phase-map.txt")" "PHASE_1_LABEL=Refined mesh" \
        "S31: the phase label is recorded"
    assert_contains "$(cat "${dir}/evidence/phase-map.txt")" "PHASE_1_PROCESSOR_DIRECTORIES=8" \
        "S31: the eight processor phase directories are verified"

    # The upload holds the archive, and no mesh, field, VTU, or set geometry.
    archive="$(ab_diag_archive_list "$workspace")"
    assert_contains "$archive" "evidence/result.env" "S31: the archive holds the result"
    assert_contains "$archive" "evidence/commands.tsv" "S31: the archive holds the command record"
    assert_not_contains "$archive" "polyMesh" "S31: the archive holds no mesh"
    assert_not_contains "$archive" ".vtk" "S31: the archive holds no set geometry"
    assert_not_contains "$archive" ".vtu" "S31: the archive holds no VTU file"
    assert_contains "$(cat "${workspace}/step_summary")" '| Result | `NO_CONCAVITY_REPRODUCED` |' \
        "S31: the job summary shows the result"
}

s32_diagnostic_result_classes() {
    local workspace
    # Concavity in the background mesh.
    workspace="$(new_workspace s32_background)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_CHECK_BACKGROUND=concave:12 FAKE_CHECK_PHASE=concave:30 \
        FAKE_CHECK_FINAL=concave:30 > /dev/null
    assert_eq "FIRST_CONCAVITY_AT_BACKGROUND" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S32: a background concavity is FIRST_CONCAVITY_AT_BACKGROUND"
    assert_eq "12" "$(ab_diag_value "$workspace" BACKGROUND_CONCAVE_CELLS)" "S32: the background count is exact"
    assert_eq "1" "$(ab_diag_value "$workspace" BACKGROUND_FAILED_CHECKS)" "S32: the failed checks are recorded"
    assert_contains "$(cat "$(ab_diag_dir "$workspace")/evidence/sets.tsv")" \
        "background	constant/polyMesh/sets/concaveCells	" "S32: the background set path is recorded"

    # Concavity first in the refined mesh. checkMesh reports failure with status 0.
    workspace="$(new_workspace s32_refined)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_CHECK_PHASE=concave:23912 FAKE_CHECK_FINAL=concave:23912 > /dev/null
    assert_eq "FIRST_CONCAVITY_AT_REFINED_MESH" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S32: a clean background and a refined concavity is FIRST_CONCAVITY_AT_REFINED_MESH"
    assert_eq "23912" "$(ab_diag_value "$workspace" REFINED_CONCAVE_CELLS)" "S32: the refined count is exact"
    assert_eq "FAILED" "$(ab_diag_value "$workspace" REFINED_RESULT)" \
        "S32: a failed check with status 0 is still FAILED"
    assert_eq "8" "$(grep -c '^refined	processor[0-7]/1/polyMesh/sets/concaveCells	' \
                     "$(ab_diag_dir "$workspace")/evidence/sets.tsv")" \
        "S32: the set of each processor is recorded"
    assert_eq "SAME" "$(ab_diag_value "$workspace" FINAL_COMPARISON)" "S32: the final comparison is SAME"

    # Clean phases, but a failed reconstructed serial check.
    workspace="$(new_workspace s32_final)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_CHECK_FINAL=concave:5 > /dev/null
    assert_eq "NO_PHASE_CONCAVITY_BUT_FINAL_CHECK_FAILS" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S32: a final-only concavity is NO_PHASE_CONCAVITY_BUT_FINAL_CHECK_FAILS"
    assert_eq "DIFFERENT" "$(ab_diag_value "$workspace" FINAL_COMPARISON)" "S32: the final comparison is DIFFERENT"
    workspace="$(new_workspace s32_final_other)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_CHECK_FINAL=other > /dev/null
    assert_eq "NO_PHASE_CONCAVITY_BUT_FINAL_CHECK_FAILS" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S32: another failed final check is NO_PHASE_CONCAVITY_BUT_FINAL_CHECK_FAILS"
    assert_eq "0" "$(ab_diag_value "$workspace" FINAL_CONCAVE_CELLS)" \
        "S32: the concave check OK line gives the exact count 0"

    # A phase failure without concavity fits no concavity class.
    workspace="$(new_workspace s32_phase_other)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_CHECK_PHASE=other > /dev/null
    assert_eq "INCONCLUSIVE_NON_CONCAVE_PHASE_FAILURE" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S32: a phase failure without concavity is INCONCLUSIVE"
}

s33_diagnostic_check_evidence_must_be_exact() {
    local workspace
    workspace="$(new_workspace s33_no_count)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_CHECK_PHASE=failed_nocount FAKE_CHECK_FINAL=concave:9 > /dev/null
    assert_eq "INCONCLUSIVE_CONCAVE_COUNT" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S33: a failed check without an exact concave count is INCONCLUSIVE"
    assert_eq "UNAVAILABLE" "$(ab_diag_value "$workspace" REFINED_CONCAVE_CELLS)" \
        "S33: a missing count is UNAVAILABLE, not 0"

    workspace="$(new_workspace s33_no_set)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_CHECK_PHASE=concave_noset:40 FAKE_CHECK_FINAL=concave:40 > /dev/null
    assert_eq "INCONCLUSIVE_CONCAVE_SET" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S33: a positive count without its set is INCONCLUSIVE"
    assert_eq "40" "$(ab_diag_value "$workspace" REFINED_CONCAVE_CELLS)" "S33: the count is still recorded"

    workspace="$(new_workspace s33_no_result)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_CHECK_BACKGROUND=noresult > /dev/null
    assert_eq "INCONCLUSIVE_CHECK_RESULT" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S33: a check log without a result line is INCONCLUSIVE"
    assert_eq "UNAVAILABLE" "$(ab_diag_value "$workspace" BACKGROUND_RESULT)" \
        "S33: the missing result is UNAVAILABLE"
}

s34_diagnostic_case_identity_gates() {
    local workspace csv
    csv="${SRC_DIR}/output_batch_1.csv"
    # Missing, duplicate, and changed-header CSV inputs.
    workspace="$(new_workspace s34_missing_row)"
    ab_diag_fixture "$workspace"
    awk -F, '$1 != "7"' "$csv" > "${workspace}/checkout/src/output_batch_1.csv"
    ab_diag_run "$workspace" > /dev/null
    assert_eq "INCONCLUSIVE_CASE_IDENTITY" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S34: a missing Case 7 row is INCONCLUSIVE_CASE_IDENTITY"
    assert_not_contains "$(ab_diag_calls "$workspace")" "run_batch.sh" "S34: setup does not run without the row"

    workspace="$(new_workspace s34_duplicate_row)"
    ab_diag_fixture "$workspace"
    { cat "$csv"; awk -F, '$1 == "7"' "$csv"; } > "${workspace}/checkout/src/output_batch_1.csv"
    ab_diag_run "$workspace" > /dev/null
    assert_eq "INCONCLUSIVE_CASE_IDENTITY" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S34: a duplicate Case 7 row is INCONCLUSIVE_CASE_IDENTITY"

    workspace="$(new_workspace s34_changed_header)"
    ab_diag_fixture "$workspace"
    sed -e '1s/^Case,/CaseID,/' "$csv" > "${workspace}/checkout/src/output_batch_1.csv"
    ab_diag_run "$workspace" > /dev/null
    assert_eq "INCONCLUSIVE_CASE_IDENTITY" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S34: a changed header is INCONCLUSIVE_CASE_IDENTITY"

    workspace="$(new_workspace s34_extra_field)"
    ab_diag_fixture "$workspace"
    awk -F, -v OFS=, '$1 == "7" { $0 = $0 ",extra" } { print }' "$csv" > "${workspace}/checkout/src/output_batch_1.csv"
    ab_diag_run "$workspace" > /dev/null
    assert_eq "INCONCLUSIVE_CASE_IDENTITY" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S34: a row with an extra field is INCONCLUSIVE_CASE_IDENTITY"

    workspace="$(new_workspace s34_existing_run_csv)"
    ab_diag_fixture "$workspace"
    printf 'Case\n9\n' > "${workspace}/checkout/src/output_batch_9.csv"
    ab_diag_run "$workspace" > /dev/null
    assert_eq "INCONCLUSIVE_CASE_IDENTITY" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S34: an existing run CSV is never reused"

    # The setup Stage output must hold Case 7 only, with the committed controls.
    workspace="$(new_workspace s34_other_case)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_SETUP=other_case > /dev/null
    assert_eq "INCONCLUSIVE_CASE_IDENTITY" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S34: a setup result with another Case is INCONCLUSIVE_CASE_IDENTITY"
    workspace="$(new_workspace s34_no_flow_row)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_SETUP=no_flow_row > /dev/null
    assert_eq "INCONCLUSIVE_CASE_IDENTITY" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S34: a setup result without the created flow row is INCONCLUSIVE_CASE_IDENTITY"
    local mode
    for mode in snap_on layers_on np4; do
        workspace="$(new_workspace "s34_${mode}")"
        ab_diag_fixture "$workspace"
        ab_diag_run "$workspace" FAKE_SETUP="$mode" > /dev/null
        assert_eq "INCONCLUSIVE_CASE_OR_PHASE_MISMATCH" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
            "S34: generated controls ${mode} are INCONCLUSIVE_CASE_OR_PHASE_MISMATCH"
        assert_not_contains "$(ab_diag_calls "$workspace")" "blockMesh" \
            "S34: no mesh command runs after the ${mode} mismatch"
    done
    workspace="$(new_workspace s34_setup_fails)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_SETUP=fail > /dev/null
    assert_eq "INCONCLUSIVE_PREPARATION_FAILURE" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S34: a failed setup Stage is INCONCLUSIVE_PREPARATION_FAILURE"
}

s35_diagnostic_version_and_help_gates() {
    local workspace
    workspace="$(new_workspace s35_baseline)"
    ab_diag_fixture "$workspace"
    printf 'v2506\n' > "${workspace}/checkout/.openfoam-version"
    ab_diag_run "$workspace" > /dev/null
    assert_eq "INCONCLUSIVE_VERSION" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S35: a baseline other than v2512 is INCONCLUSIVE_VERSION"
    assert_not_contains "$(ab_diag_calls "$workspace")" "apt-get" "S35: nothing is installed for a wrong baseline"

    workspace="$(new_workspace s35_loaded_version)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_WM_VERSION=v2506 > /dev/null
    assert_eq "INCONCLUSIVE_VERSION" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S35: a loaded version other than v2512 is INCONCLUSIVE_VERSION"
    assert_not_contains "$(ab_diag_calls "$workspace")" "run_batch.sh" "S35: setup does not run for a wrong version"

    workspace="$(new_workspace s35_install_fails)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_FAIL=apt-get > /dev/null
    assert_eq "INCONCLUSIVE_INSTALL" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S35: a failed installation is INCONCLUSIVE_INSTALL"

    local entry
    for entry in "FAKE_HELP_DROP=checkMesh:-writeSets" "FAKE_HELP_BARE=checkMesh:-writeSets" \
                 "FAKE_HELP_DROP=reconstructParMesh:-time" "FAKE_HELP_DROP=snappyHexMesh:-parallel" \
                 "FAKE_HELP_DROP=checkMesh:-allGeometry"; do
        workspace="$(new_workspace "s35_help_${entry//[^A-Za-z]/_}")"
        ab_diag_fixture "$workspace"
        ab_diag_run "$workspace" "$entry" > /dev/null
        assert_eq "INCONCLUSIVE_COMMAND_VALIDATION" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
            "S35: ${entry} is INCONCLUSIVE_COMMAND_VALIDATION"
        assert_not_contains "$(ab_diag_calls "$workspace")" "blockMesh" \
            "S35: no mesh command runs after ${entry}"
        assert_contains "$(cat "$(ab_diag_dir "$workspace")/evidence/help-checks.txt")" "MISSING" \
            "S35: the help check records the missing option for ${entry}"
    done
}

s36_diagnostic_phase_map_must_be_complete() {
    local workspace mode
    # extra_rank7 and extra_processor cover PR #91 review 5303287747: every
    # processor directory counts, not only processor0.
    for mode in duplicate unlabelled constant inconsistent extra_rank7 extra_processor; do
        workspace="$(new_workspace "s36_${mode}")"
        ab_diag_fixture "$workspace"
        ab_diag_run "$workspace" FAKE_SNAPPY="$mode" > /dev/null
        assert_eq "INCONCLUSIVE_PHASE_MAP" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
            "S36: a ${mode} phase map is INCONCLUSIVE_PHASE_MAP"
        assert_not_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time" \
            "S36: no reconstruction runs after a ${mode} phase map"
    done
    # The contract names a missing refinement write and an unexpected phase a
    # Case or phase mismatch.
    for mode in missing snapped; do
        workspace="$(new_workspace "s36_${mode}")"
        ab_diag_fixture "$workspace"
        ab_diag_run "$workspace" FAKE_SNAPPY="$mode" > /dev/null
        assert_eq "INCONCLUSIVE_CASE_OR_PHASE_MISMATCH" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
            "S36: a ${mode} refined phase is INCONCLUSIVE_CASE_OR_PHASE_MISMATCH"
        assert_not_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time" \
            "S36: no reconstruction runs after a ${mode} refined phase"
    done
}

s37_diagnostic_preparation_failure_stops() {
    local workspace name
    for name in surfaceFeatureExtract blockMesh decomposePar snappyHexMesh reconstructParMesh; do
        workspace="$(new_workspace "s37_${name}")"
        ab_diag_fixture "$workspace"
        ab_diag_run "$workspace" FAKE_FAIL="$name" > /dev/null
        assert_eq "INCONCLUSIVE_PREPARATION_FAILURE" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
            "S37: a failed ${name} is INCONCLUSIVE_PREPARATION_FAILURE"
        assert_contains "$(ab_diag_value "$workspace" DIAG_REASON)" "$name" "S37: the reason names ${name}"
        assert_eq "$name" "$(ab_diag_value "$workspace" DIAG_STOP_POINT)" "S37: the run stops at ${name}"
    done
    # The failed blockMesh stops every later mesh command, and the partial
    # evidence is still packaged.
    workspace="$(new_workspace s37_partial)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_FAIL=blockMesh > /dev/null
    assert_not_contains "$(ab_diag_calls "$workspace")" "decomposePar" "S37: no command runs after the failure"
    assert_contains "$(ab_diag_archive_list "$workspace")" "evidence/logs/" "S37: the partial logs are packaged"
    assert_contains "$(ab_diag_archive_list "$workspace")" "evidence/identity.txt" \
        "S37: the partial identity record is packaged"
    assert_contains "$(cat "${workspace}/step_summary")" "INCONCLUSIVE_PREPARATION_FAILURE" \
        "S37: the job summary shows the stop"
}

s38_diagnostic_timeouts_stop_the_work() {
    local workspace run elapsed
    # The per-command cap: blockMesh has 30 seconds, far inside the deadline.
    workspace="$(new_workspace s38_command_cap)"
    ab_diag_fixture "$workspace"
    run="$(ab_diag_run "$workspace" FAKE_HANG=blockMesh)"
    elapsed="$(sed -e 's/.*elapsed=\([0-9]*\).*/\1/' <<< "$run")"
    assert_eq "INCONCLUSIVE_TIMEOUT" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S38: a command past its cap is INCONCLUSIVE_TIMEOUT"
    assert_eq "blockMesh" "$(ab_diag_value "$workspace" DIAG_STOP_POINT)" "S38: the run stops at blockMesh"
    (( elapsed >= 29 && elapsed <= 45 )) ||
        _fail "S38: the blockMesh cap must stop the command after about 30 seconds" "elapsed: ${elapsed}"
    ab_assert_fakes_stopped "$workspace" "S38"
    assert_contains "$(cat "$(ab_diag_dir "$workspace")/evidence/commands.tsv")" "blockMesh	30	30	" \
        "S38: the blockMesh limit is its 30-second cap"

    # The active-work deadline: less time is left than the snappyHexMesh cap.
    workspace="$(new_workspace s38_deadline)"
    ab_diag_fixture "$workspace"
    run="$(ab_diag_run "$workspace" FAKE_HANG=snappyHexMesh DIAG_ACTIVE_DEADLINE="$(( $(date +%s) + 20 ))")"
    elapsed="$(sed -e 's/.*elapsed=\([0-9]*\).*/\1/' <<< "$run")"
    assert_eq "INCONCLUSIVE_TIMEOUT" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S38: the active-work deadline gives INCONCLUSIVE_TIMEOUT"
    assert_eq "snappyHexMesh" "$(ab_diag_value "$workspace" DIAG_STOP_POINT)" \
        "S38: the deadline stops snappyHexMesh"
    (( elapsed <= 21 )) || _fail "S38: the work must end before the active-work deadline" "elapsed: ${elapsed}"
    ab_assert_fakes_stopped "$workspace" "S38"
    assert_not_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time" \
        "S38: no command runs after the timeout"

    # No time left: the next command does not start.
    workspace="$(new_workspace s38_no_time)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" DIAG_ACTIVE_DEADLINE="$(( $(date +%s) - 1 ))" > /dev/null
    assert_eq "INCONCLUSIVE_TIMEOUT" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S38: no active time left gives INCONCLUSIVE_TIMEOUT"
    assert_eq "install" "$(ab_diag_value "$workspace" DIAG_STOP_POINT)" "S38: the install does not start"
    assert_not_contains "$(ab_diag_calls "$workspace")" "apt-get" "S38: no command starts without time"
}

s39_diagnostic_output_limits() {
    local workspace dir archive size
    # A command log above 1 MiB is not cut. It is left out, and the run stops.
    workspace="$(new_workspace s39_log_cap)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_BIG_LOG=snappyHexMesh > /dev/null
    dir="$(ab_diag_dir "$workspace")"
    assert_eq "INCONCLUSIVE_OUTPUT_LIMIT" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S39: a log above 1 MiB is INCONCLUSIVE_OUTPUT_LIMIT"
    assert_contains "$(cat "${dir}/upload/inventory.txt")" "EXCLUDED" "S39: the inventory names the excluded log"
    if ab_diag_archive_list "$workspace" | grep -Eq '/[0-9]+-snappyHexMesh\.log$'; then
        _fail "S39: the oversized snappyHexMesh log must not be packaged"
    fi
    assert_not_contains "$(ab_diag_calls "$workspace")" "checkMesh -parallel" "S39: no command runs after the limit"
    if find "${dir}/evidence" -type f -size +1024k | grep -q .; then
        _fail "S39: no evidence file may exceed 1 MiB"
    fi

    # An archive above 45 MiB is not uploaded. The upload holds a reason and an
    # inventory only.
    workspace="$(new_workspace s39_archive_cap)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" > /dev/null
    dir="$(ab_diag_dir "$workspace")"
    head -c 48000000 /dev/urandom > "${dir}/evidence/large.bin"
    env RUNNER_TEMP="${workspace}/runner_temp" DIAG_DIR="$dir" GITHUB_ENV="${workspace}/github_env" \
        bash "${workspace}/package_step.sh" > "${workspace}/package2.out" 2>&1 ||
        _fail "S39: the package step must end with status 0"
    assert_eq "INCONCLUSIVE_OUTPUT_LIMIT" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S39: an archive above 45 MiB is INCONCLUSIVE_OUTPUT_LIMIT"
    assert_eq "NO_CONCAVITY_REPRODUCED" "$(ab_diag_value "$workspace" DIAG_PRIOR_RESULT)" \
        "S39: the prior result is kept for reference"
    size="$(du -cb "${dir}/upload" | tail -n 1 | cut -f1)"
    (( size < 1048576 )) || _fail "S39: the reduced upload must be small" "bytes: ${size}"
    archive="$(ab_diag_archive_list "$workspace")"
    assert_not_contains "$archive" "large.bin" "S39: the large file is not uploaded"
    assert_contains "$(cat "${dir}/upload/inventory.txt")" "large.bin" "S39: the inventory names the large file"
}

s40_diagnostic_never_solves_or_dispatches() {
    local workspace calls
    workspace="$(new_workspace s40_no_solver)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_CHECK_PHASE=concave:23912 FAKE_CHECK_FINAL=concave:23912 > /dev/null
    calls="$(ab_diag_calls "$workspace")"
    assert_not_contains "$calls" "simpleFoam" "S40: no solver runs"
    assert_not_contains "$calls" "foamToVTK" "S40: no post-processing runs"
    assert_not_contains "$calls" "renumberMesh" "S40: no flow Stage command runs"
    assert_not_contains "$calls" "reconstructPar " "S40: no field reconstruction runs"
    assert_eq "0" "$(grep -c '^gh' <<< "$calls" || true)" "S40: no workflow is dispatched"
    assert_eq "1" "$(grep -c '^run_batch.sh ' <<< "$calls")" "S40: the Orchestrator runs once"
    assert_contains "$calls" "run_batch.sh --stage setup -j 1 src/output_batch_9.csv" \
        "S40: the Orchestrator runs the setup Stage only"
    assert_not_contains "$calls" "--stage mesh" "S40: the mesh Stage never runs"
    assert_not_contains "$calls" "flow,post" "S40: no full-Case run starts"
}

s41_diagnostic_checkout_failure_and_summary() {
    local workspace run
    workspace="$(new_workspace s41_checkout)"
    ab_diag_fixture "$workspace"
    run="$(ab_diag_run "$workspace" CHECKOUT_OUTCOME=failure)"
    assert_contains "$run" "status=0 " "S41: the diagnostic step ends with status 0 after a failed checkout"
    assert_eq "INCONCLUSIVE_CHECKOUT" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S41: a failed checkout is INCONCLUSIVE_CHECKOUT"
    assert_eq "" "$(ab_diag_calls "$workspace")" "S41: no command runs after a failed checkout"
    assert_contains "$(cat "${workspace}/step_summary")" '| Result | `INCONCLUSIVE_CHECKOUT` |' \
        "S41: the job summary shows the checkout stop"
    assert_contains "$(cat "${workspace}/step_summary")" "| Active elapsed seconds |" \
        "S41: the job summary shows the elapsed time"
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
    s10_vtu_reader_reads_a_large_no_marker_file
    s11_capture_completes_under_the_480_second_cap
    s12_capture_operation_stops_before_the_deadline_reserve
    s13_capture_work_stops_at_the_outer_limit
    s14_capture_without_budget_skips_the_optional_work
    s15_capture_failure_keeps_summary_and_upload_eligible
    s16_vtu_parse_failure_is_an_incomplete_capture
    s17_stage_evidence_failure_is_an_incomplete_capture
    s18_vtu_required_field_verdicts_and_original_tags
    s19_source_mismatch_keeps_a_complete_capture
    s20_vtu_tag_evidence_output_limits
    s21_vtu_scan_timeout_is_distinct
    s22_mesh_quality_evidence
    s23_flow_convergence_evidence
    s24_summary_shows_the_evidence_verdicts
    s25_vtu_name_text_inside_a_value_is_not_a_name
    s26_convergence_verdict_fails_closed
    s27_vtu_comment_text_is_not_markup
    s28_vtu_unclosed_or_mismatched_elements_are_not_evidence
    s29_vtu_invalid_tag_syntax_is_not_evidence
    s30_diagnostic_workflow_interface
    s31_diagnostic_all_clean_records_the_complete_evidence
    s32_diagnostic_result_classes
    s33_diagnostic_check_evidence_must_be_exact
    s34_diagnostic_case_identity_gates
    s35_diagnostic_version_and_help_gates
    s36_diagnostic_phase_map_must_be_complete
    s37_diagnostic_preparation_failure_stops
    s38_diagnostic_timeouts_stop_the_work
    s39_diagnostic_output_limits
    s40_diagnostic_never_solves_or_dispatches
    s41_diagnostic_checkout_failure_and_summary
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
