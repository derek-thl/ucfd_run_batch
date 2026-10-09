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
# Checks S42 to S47 cover the capture-only spatial test of the same workflow
# (Issue #80, corrected contract 5847967745). They run the same extracted steps.
# They prove the copy of the refined concaveCells VTP file from its exact v2512
# path at the dynamic phase time, the provenance check before the refined check,
# the discovery faults, the 20 MiB VTP limit, the zero-concavity rule, the two
# setup logs and their 1 MiB limit, the final-inventory rule, and the permitted
# archive content.
#
# Checks S48 to S52 cover the capture deadline correction of the same workflow
# (Issue #80, contract 5964418182). They run the same extracted steps. Fake
# find, sha256sum, cp, and date commands block, fail, or move the clock for one
# selected capture operation. The checks prove that no capture operation starts
# without active time, that a slow candidate discovery, hash, or copy stops
# with its process group before the active-work deadline, that no partial hash,
# exclusion row, candidate list, or copy is kept, that a failed operation is an
# explicit capture failure, and that the summary and the upload stay eligible.
# Check S53 covers PR #93 review 5399027552: the blocked wrapper exits on
# SIGTERM, and its child ignores SIGTERM. The check proves that the child gets
# SIGKILL after the kill grace and is gone before the operation returns.
#
# Check S54 covers the same case for the command runner run_bounded (Issue #80,
# contract 5971128677). It calls the run_bounded function from the workflow
# with a controlled command, and it runs the diagnostic step with a blocked
# blockMesh. The command exits on SIGTERM at once, or 4 seconds later near the
# end of the first kill grace (PR #94 review 5404512470), and its child ignores
# SIGTERM. The check proves that the child stops before run_bounded returns,
# and that the cleanup ends with the one kill grace, at the active-work
# deadline. Check S55 proves the late case for a capture operation, which uses
# the same cleanup function. It also proves that a capture operation that
# completes but leaves a TERM-ignoring child gives that child at most the kill
# grace, and that the diagnostic then continues.
#
# Checks S56 to S67 cover the fixture-only mean-speed validation workflow
# openfoam-m3-metric-validation.yml (Issue #80, contract 6043302440 with
# correction 6043318728). They run its extracted steps with fake system
# commands and a fake OpenFOAM tree. The fake simpleFoam calculates the
# volume-weighted mean speed from the generated two-cell mesh and U field. The
# checks prove the interface, the exact command and dictionary, the fixture
# geometry and the expected 11/3 m/s, the complete PASS evidence, the ref, SHA,
# package, and environment gates, each fail-closed condition, the command,
# budget, log, and artifact limits, the process-group cleanup, and that the run
# writes only inside its unique task directory, which the last step removes.
#
# Checks S68 and S69 cover PR #97 review 5453307998: a timed-out install can
# leave a root process that the runner user may not signal. S68 proves that the
# install stop signals the install group through sudo -n kill, and that a
# process that does not stop fails the run in a bounded time and keeps the task
# directory. S69 uses real processes of another host user. It proves that the
# stop and the cleanup do not take a group as empty when kill -0 fails with
# EPERM, that an unreadable /proc entry, a refused sudo, or a slow scan keeps
# the task directory, and that a complete scan removes it.
#
# Check S70 covers PR #97 review 5454383774: each privileged signal helper
# could start a new limit, so a 12-second operation returned after 22
# seconds. With a sudo that hangs, S70 proves that the run, the install with
# its stop, and stop_operation_group alone end by the absolute operation
# deadline, that the result is FAIL_PROCESS_STOP, and that each slow helper
# stops.
#
# Check S71 covers PR #97 review 5455232932: the procps kill takes the first
# argument of the form -<number> as the signal, also after --, so
# "kill -s TERM -- -58" printed its usage and sent nothing. S71 runs the
# install signal helper with the real external kill on a small group ID that
# is also a signal number and that no process group uses: each call must
# parse the group as the operand. S71 also proves that a group ID below 2 is
# refused. That part uses a refusing fake sudo, so no kill runs.
#
# Checks S72 to S81 cover the M3 mean-speed collection in the evidence
# workflow (Issue #80, admission 6064804618 of approved proposal 6064220318).
# They run the extracted capture step with a completed two-cell Case 7 flow
# result, RAS kEpsilon inputs, a fake OpenFOAM tree, and fake system commands.
# They prove the volume-weighted mean of the recorded latest time with the two
# exact vectors and dictionary, NOT_ATTEMPTED after a failed product run, the
# time, source, snapshot, environment, and output gates, a valid zero value and
# no scientific range, the time, byte, process-stop, and cleanup limits, the
# separate product, mesh, convergence, and PointData verdicts, and the
# unchanged workflow interface.
#
# Checks S82 to S86 cover PR #98 review 5461418991: a failed log inventory or
# log copy (F1), a transient file above the task byte limit (F2), an
# incomplete process check before the removal (F3), a slow read of the
# post-processing time record (F4), and a value or volume that does not
# convert to a finite double (F5).
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
    # The command exits on SIGTERM, FAKE_HANG_EXIT_DELAY seconds later (default
    # 0), and its child ignores SIGTERM (contract 5971128677, PR #94 review
    # 5404512470). If the child is alive when spatial/manifest.env appears,
    # after run_bounded returned, it writes "<DIAG_FAKE_PIDS>.survivor".
    for entry in ${FAKE_HANG_IGNORE_TERM:-}; do
        if [[ "$entry" == "$name" ]]; then
            trap 'sleep "${FAKE_HANG_EXIT_DELAY:-0}"; exit 0' TERM
            (
                trap '' TERM
                for (( tick = 0; tick < 300; tick++ )); do
                    if [[ -e "${DIAG_DIR}/evidence/spatial/manifest.env" ]]; then
                        : > "${DIAG_FAKE_PIDS}.survivor"
                        exit 0
                    fi
                    sleep 0.1
                done
            ) &
            printf '%s\n%s\n' "$$" "$!" >> "$DIAG_FAKE_PIDS"
            wait
            exit 0
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
            time3) phase Refined 3 ;;
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
        }
        # -writeSets vtk writes each written set as VTK XML geometry at
        # postProcessing/<time>/<set>/<set>.vtp (v2512 checkTools.C). The
        # concaveCells geometry exists only for a concave count; the nearPoints
        # geometry is another set. FAKE_VTK selects a fault, and force writes
        # the concaveCells geometry for any count.
        write_vtp() {
            local base="postProcessing/${time}" file
            file="${base}/concaveCells/concaveCells.vtp"
            mkdir -p "$base"
            printf '<?xml version="1.0"?>\n<VTKFile type="PolyData">near points</VTKFile>\n' > "${base}/nearPoints.vtp"
            [[ "$1" == concave:* || "${FAKE_VTK:-ok}" == force ]] || return 0
            mkdir -p "${base}/concaveCells"
            case "${FAKE_VTK:-ok}" in
                ok|force)
                    printf '<?xml version="1.0"?>\n<VTKFile type="PolyData">concave cells at time %s</VTKFile>\n' \
                        "$time" > "$file" ;;
                missing) ;;
                wrong_path)
                    mkdir -p "postProcessing/checkMesh/${time}"
                    printf 'concave cells\n' > "postProcessing/checkMesh/${time}/concaveCells.vtp" ;;
                legacy) printf '# vtk DataFile Version 2.0\n' > "${base}/concaveCells/concaveCells.vtk" ;;
                duplicate) printf 'concave cells\n' > "$file"; printf 'concave cells\n' > "${base}/concaveCells.vtp" ;;
                empty) : > "$file" ;;
                unreadable) printf 'concave cells\n' > "$file"; chmod 000 "$file" ;;
                directory) mkdir -p "$file" ;;
                symlink) printf 'concave cells\n' > "${base}/concaveCells/target.dat"; ln -s target.dat "$file" ;;
                size:*) head -c "${FAKE_VTK#size:}" /dev/zero > "$file" ;;
                # Oversized rejected candidates (PR #92 review 5394488889).
                big_wrong_path)
                    mkdir -p "postProcessing/checkMesh/${time}"
                    head -c 20971521 /dev/zero > "postProcessing/checkMesh/${time}/concaveCells.vtp" ;;
                big_legacy) head -c 20971521 /dev/zero > "${base}/concaveCells/concaveCells.vtk" ;;
                big_duplicate)
                    head -c 20971521 /dev/zero > "$file"
                    printf 'concave cells\n' > "${base}/concaveCells.vtp"
                    ln -s concaveCells.vtp "${base}/concaveCells/concaveCells.vtk" ;;
                # Two oversized candidates with different bytes (contract
                # 5964418182). The sorted scan hashes the shallow one first.
                big_two)
                    head -c 20971521 /dev/zero > "$file"
                    head -c 20971521 /dev/zero | tr '\0' 'b' > "${base}/concaveCells.vtp" ;;
            esac
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
        (( write_geometry )) && write_vtp "$mode"
        echo "End" ;;
    reconstructParMesh)
        time="$(after -time "$@" || true)"
        mkdir -p "${time}/polyMesh"
        : > "${time}/polyMesh/owner"
        echo "End" ;;
    *)
        echo "End" ;;
esac
# FAKE_CLOCK_JUMP selects one command. After it, the fake date reports a time
# past the active-work deadline (contract 5964418182).
tag="$name"
if [[ "$name" == checkMesh ]] && has -parallel "$@"; then
    tag=checkMesh-parallel
fi
if [[ -n "${FAKE_CLOCK_JUMP:-}" && "$FAKE_CLOCK_JUMP" == "$tag" ]]; then
    : > "$DIAG_FAKE_CLOCK_MARK"
fi
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
# The real setup Stage writes these two logs when it rotates the STL files
# (setup_cases.sh). FAKE_SETUP_LOG selects a fault, or a stale set geometry
# file before any mesh command.
transform="${flow}/log.surfaceTransformPoints"
check="${flow}/log.surfaceCheck"
printf 'Set centre of rotation to (297.57 -836.476 42.985)\n' > "$transform"
printf 'Bounding Box : (-2.43 -1036.48 0) (597.57 -636.476 85.97)\n' > "$check"
case "${FAKE_SETUP_LOG:-ok}" in
    missing_transform) rm -f "$transform" ;;
    missing_check) rm -f "$check" ;;
    big_transform) head -c 1048577 /dev/zero | tr '\0' 'x' > "$transform" ;;
    big_check) head -c 1048577 /dev/zero | tr '\0' 'x' > "$check" ;;
    limit_check) head -c 1048576 /dev/zero | tr '\0' 'x' > "$check" ;;
    directory_check) rm -f "$check"; mkdir "$check" ;;
    unreadable_check) chmod 000 "$check" ;;
    stale_vtp)
        mkdir -p "${flow}/postProcessing/1/concaveCells"
        printf 'stale\n' > "${flow}/postProcessing/1/concaveCells/concaveCells.vtp" ;;
    stale_vtk) printf 'stale\n' > "${flow}/constant/concaveCells.vtk" ;;
    stale_big_vtp)
        mkdir -p "${flow}/postProcessing/1/concaveCells"
        head -c 20971521 /dev/zero > "${flow}/postProcessing/1/concaveCells/concaveCells.vtp" ;;
esac
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
if [[ "${FAKE_CLOCK_JUMP:-}" == setup ]]; then
    : > "$DIAG_FAKE_CLOCK_MARK"
fi
echo "setup done"
DIAG_SETUP
    chmod +x "$1"
}

# ab_diag_write_capture_fake <file> - the fake find, sha256sum, cp, and date of
# the capture deadline checks (Issue #80, contract 5964418182). Each call runs
# the real command unless a check selects a fault for one capture operation:
#   FAKE_SLOW_DISCOVERY or FAKE_FAIL_DISCOVERY = before | after - the first or
#       the second concaveCells discovery blocks or fails;
#   FAKE_SLOW_HASH or FAKE_FAIL_HASH = <pattern> - the hash of a file whose
#       absolute path matches the pattern blocks or fails, for a file argument
#       and for a file on standard input;
#   FAKE_SLOW_COPY or FAKE_FAIL_COPY = <pattern> - the copy of a matching
#       source file blocks or fails.
# A blocked call first writes partial output: a candidate, a wrong hash, or half
# of the file. It records its process and its child process in DIAG_FAKE_PIDS
# and waits 30 seconds before the real command. With FAKE_SLOW_SECONDS, the call
# waits that time and writes no partial output, so its complete output is
# exact. With FAKE_SLOW_IGNORE_TERM=1, the child process ignores SIGTERM, and
# the call itself still exits on SIGTERM (PR #93 review 5399027552). If that
# child is alive when spatial/manifest.env appears, after the operation
# returned, it writes "<DIAG_FAKE_PIDS>.survivor". It ends after 30 seconds.
# With FAKE_SLOW_EXIT_DELAY, the blocked call exits that many seconds after
# SIGTERM (PR #94 review 5404512470). FAKE_LEAVE_CHILD_HASH = <pattern> - a
# matching hash completes at once, but it leaves such a TERM-ignoring child in
# its process group.
# After the FAKE_CLOCK_JUMP command, date +%s is 100000 seconds later.
# Each find, sha256sum, and cp call appends one line to DIAG_FAKE_CAPTURE_CALLS:
# name, target, and each argument, separated by tabs. The target is the
# absolute file of a hash, the absolute source of a copy, "discovery" for a
# concaveCells discovery, or "-".
ab_diag_write_capture_fake() {
    local name
    {
        printf '#!/usr/bin/env bash\n'
        for name in find sha256sum cp date; do
            printf 'REAL_%s=%q\n' "${name^^}" "$(command -v "$name")"
        done
        cat <<'CAPTURE_FAKE'
set -u
name="${0##*/}"
real_var="REAL_${name^^}"
real="${!real_var}"
if [[ "$name" == date ]]; then
    if [[ "$*" == "+%s" && -n "${DIAG_FAKE_CLOCK_MARK:-}" && -e "$DIAG_FAKE_CLOCK_MARK" ]]; then
        echo "$(( $("$real" +%s) + 100000 ))"
        exit 0
    fi
    exec "$real" "$@"
fi
calls="${DIAG_FAKE_CAPTURE_CALLS:-/dev/null}"
# absolute <path> - the path from the root. Links are not resolved.
absolute() {
    if [[ "$1" == /* ]]; then printf '%s' "$1"; else printf '%s/%s' "$PWD" "$1"; fi
}
# term_ignoring_child - start a background child that ignores SIGTERM. If it is
# alive when spatial/manifest.env appears, it writes the survivor file.
term_ignoring_child() {
    (
        trap '' TERM
        manifest="${DIAG_DIR:-/nonexistent}/evidence/spatial/manifest.env"
        for (( tick = 0; tick < 300; tick++ )); do
            if [[ -e "$manifest" ]]; then
                : > "${DIAG_FAKE_PIDS}.survivor"
                exit 0
            fi
            sleep 0.1
        done
    ) &
}
target="-"
mode=""
case "$name" in
    find)
        if [[ " $* " == *" concaveCells.vtp "* ]]; then
            target=discovery
            count="$(awk -F '\t' '$1 == "find" && $2 == "discovery"' "$calls" 2>/dev/null | wc -l)"
            when=after
            (( count == 0 )) && when=before
            [[ "${FAKE_SLOW_DISCOVERY:-}" == "$when" ]] && mode=slow
            [[ "${FAKE_FAIL_DISCOVERY:-}" == "$when" ]] && mode=fail
        fi ;;
    sha256sum)
        if (( $# > 0 )); then
            target="$(absolute "${!#}")"
        elif [[ -n "${FAKE_SLOW_HASH:-}${FAKE_FAIL_HASH:-}${FAKE_LEAVE_CHILD_HASH:-}" ]]; then
            target="$(readlink "/proc/$$/fd/0" 2>/dev/null || echo -)"
        fi
        # Each fault value is a pattern, so it is not quoted.
        [[ -n "${FAKE_SLOW_HASH:-}" && "$target" == $FAKE_SLOW_HASH ]] && mode=slow
        [[ -n "${FAKE_FAIL_HASH:-}" && "$target" == $FAKE_FAIL_HASH ]] && mode=fail ;;
    cp)
        if (( $# >= 2 )); then
            target="$(absolute "${@: -2:1}")"
            [[ -n "${FAKE_SLOW_COPY:-}" && "$target" == $FAKE_SLOW_COPY ]] && mode=slow
            [[ -n "${FAKE_FAIL_COPY:-}" && "$target" == $FAKE_FAIL_COPY ]] && mode=fail
        fi ;;
esac
record="${name}"$'\t'"${target}"
for argument in "$@"; do record+=$'\t'"${argument}"; done
printf '%s\n' "$record" >> "$calls"
if [[ "$name" == sha256sum && -n "${FAKE_LEAVE_CHILD_HASH:-}" && "$target" == $FAKE_LEAVE_CHILD_HASH ]]; then
    term_ignoring_child
    printf '%s\n' "$!" >> "${DIAG_FAKE_PIDS:-/dev/null}"
fi
if [[ "$mode" == fail ]]; then
    echo "fake ${name}: forced capture failure" >&2
    exit 1
fi
if [[ "$mode" == slow ]]; then
    if [[ -z "${FAKE_SLOW_SECONDS:-}" ]]; then
        case "$name" in
            find) printf './postProcessing/partial/concaveCells.vtp\n' ;;
            sha256sum) printf '%064d  partial\n' 0 ;;
            cp) head -c "$(( $(stat -c %s -- "$target") / 2 ))" -- "$target" > "${!#}" ;;
        esac
    fi
    if [[ "${FAKE_SLOW_IGNORE_TERM:-}" == 1 ]]; then
        term_ignoring_child
    else
        sleep "${FAKE_SLOW_SECONDS:-30}" &
    fi
    printf '%s\n%s\n' "$$" "$!" >> "${DIAG_FAKE_PIDS:-/dev/null}"
    if [[ -n "${FAKE_SLOW_EXIT_DELAY:-}" ]]; then
        trap 'sleep "$FAKE_SLOW_EXIT_DELAY"; exit 0' TERM
    fi
    wait "$!"
fi
exec "$real" "$@"
CAPTURE_FAKE
    } > "$1"
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
    : > "${workspace}/capture_calls.tsv"
    : > "${workspace}/fake_pids"
    cp -- "${REPO_ROOT}/.openfoam-version" "${checkout}/.openfoam-version"
    cp -- "${SRC_DIR}/output_batch_1.csv" "${checkout}/src/output_batch_1.csv"
    cp -R -- "${MASTER_SRC_DIR}/simpleFoam_files" "${checkout}/src/master_batch/simpleFoam_files"
    ab_diag_write_setup_stub "${checkout}/src/run_batch.sh"

    ab_diag_write_fake "${workspace}/diag_fake"
    for name in curl sudo apt-get dpkg-query gcc gh; do
        ln -s "${workspace}/diag_fake" "${workspace}/fakebin/${name}"
    done
    ab_diag_write_capture_fake "${workspace}/capture_fake"
    for name in find sha256sum cp date; do
        ln -s "${workspace}/capture_fake" "${workspace}/fakebin/${name}"
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
                DIAG_FAKE_CALLS="${workspace}/calls.tsv" DIAG_FAKE_PIDS="${workspace}/fake_pids"
                DIAG_FAKE_CAPTURE_CALLS="${workspace}/capture_calls.tsv"
                DIAG_FAKE_CLOCK_MARK="${workspace}/clock_jumped")
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

# ab_diag_manifest <workspace> <key> - one value of the spatial-capture manifest.
ab_diag_manifest() {
    ab_file_value "$(ab_diag_dir "$1")/evidence/spatial/manifest.env" "$2" 2>/dev/null
}

# ab_diag_inventory_sha <workspace> <path> - the checksum of one FILE row of the
# uploaded inventory, or nothing.
ab_diag_inventory_sha() {
    awk -F '\t' -v p="$2" '$1 == "FILE" && $4 == p { print $3 }' \
        "$(ab_diag_dir "$1")/upload/inventory.txt"
}

# ab_sha <file> - the SHA-256 of one file.
ab_sha() {
    sha256sum < "$1" | cut -d' ' -f1
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
    # This run includes the spatial capture (Issue #80, contract 5847967745).
    assert_eq "COMPLETE" "$(ab_diag_value "$workspace" SPATIAL_CAPTURE)" "S40: the run includes the spatial capture"
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

# ---- S42 to S47: the capture-only spatial test (Issue #80) -----------------

# The concave-cell run of S42 to S47: a clean background and 23913 concave
# cells in the refined and final meshes.
AB_DIAG_CONCAVE=(FAKE_CHECK_PHASE=concave:23913 FAKE_CHECK_FINAL=concave:23913)

s42_spatial_capture_copies_the_refined_vtp() {
    local workspace run dir flow source copy archive name prefix
    workspace="$(new_workspace s42_spatial_complete)"
    ab_diag_fixture "$workspace"
    # The phase time 3 proves that the path comes from the phase map.
    run="$(ab_diag_run "$workspace" FAKE_SNAPPY=time3 "${AB_DIAG_CONCAVE[@]}")"
    dir="$(ab_diag_dir "$workspace")"
    flow="${workspace}/checkout/${AB_DIAG_FLOW}"
    source="${flow}/postProcessing/3/concaveCells/concaveCells.vtp"
    copy="${dir}/evidence/spatial/concaveCells.vtp"

    assert_contains "$run" "package=0 " "S42: the package step ends with status 0"
    assert_contains "$run" "summary=0" "S42: the summary step ends with status 0"
    assert_eq "FIRST_CONCAVITY_AT_REFINED_MESH" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S42: a complete capture keeps the diagnostic class"
    assert_eq "3" "$(ab_diag_value "$workspace" REFINED_TIME)" "S42: the refined time is the phase time"
    assert_eq "COMPLETE" "$(ab_diag_value "$workspace" SPATIAL_CAPTURE)" "S42: the result shows a complete capture"
    assert_eq "CAPTURED" "$(ab_diag_value "$workspace" SETUP_LOGS)" "S42: the result shows the setup logs"
    assert_eq "COMPLETE" "$(ab_diag_manifest "$workspace" SPATIAL_CAPTURE)" \
        "S42: the manifest shows a complete capture"

    # The VTP file: the exact source path, the bytes, the size, and the hash.
    assert_file_exists "$copy" "S42: the VTP file is copied"
    cmp -s -- "$source" "$copy" || _fail "S42: the copy must have the bytes of the source"
    assert_eq "${AB_DIAG_FLOW}/postProcessing/3/concaveCells/concaveCells.vtp" \
        "$(ab_diag_manifest "$workspace" VTK_SOURCE)" "S42: the manifest records the exact source path"
    assert_eq "spatial/concaveCells.vtp" "$(ab_diag_manifest "$workspace" VTK_DESTINATION)" \
        "S42: the manifest records the destination"
    assert_eq "$(stat -c %s -- "$source")" "$(ab_diag_manifest "$workspace" VTK_BYTES)" \
        "S42: the manifest records the byte count"
    assert_eq "$(ab_sha "$source")" "$(ab_diag_manifest "$workspace" VTK_SHA256)" \
        "S42: the manifest records the SHA-256"
    assert_eq "0" "$(ab_diag_manifest "$workspace" VTK_CANDIDATES_BEFORE_CHECK)" \
        "S42: no set geometry exists before the refined check"
    assert_eq "1" "$(ab_diag_manifest "$workspace" VTK_CANDIDATES_AFTER_CHECK)" \
        "S42: the refined check writes one set geometry file"
    # The phase time, the command, the Case, the main SHA, and the run ID.
    assert_eq "3" "$(ab_diag_manifest "$workspace" REFINED_TIME)" "S42: the manifest records the phase time"
    assert_eq "23913" "$(ab_diag_manifest "$workspace" REFINED_CONCAVE_CELLS)" \
        "S42: the manifest records the refined concave count"
    assert_eq "mpirun --oversubscribe -np 8 checkMesh -parallel -allGeometry -allTopology -time 3 -writeSets vtk" \
        "$(ab_diag_manifest "$workspace" REFINED_CHECK_VECTOR)" "S42: the manifest records the exact command vector"
    assert_eq "7" "$(ab_diag_manifest "$workspace" CASE_ID)" "S42: the manifest records the Case"
    assert_eq "6f198977b700a2bcb664bcc704a3d506eefb67ab" "$(ab_diag_manifest "$workspace" MAIN_SHA)" \
        "S42: the manifest records the main SHA"
    assert_eq "4242" "$(ab_diag_manifest "$workspace" RUN_ID)" "S42: the manifest records the run ID"

    # The two setup logs: source, destination, size, hash, and bytes.
    for name in surfaceTransformPoints surfaceCheck; do
        case "$name" in
            surfaceTransformPoints) prefix=TRANSFORM_LOG ;;
            surfaceCheck) prefix=CHECK_LOG ;;
        esac
        assert_eq "${AB_DIAG_FLOW}/log.${name}" "$(ab_diag_manifest "$workspace" "${prefix}_SOURCE")" \
            "S42: the manifest records the ${name} log source"
        assert_eq "logs/setup-${name}.log" "$(ab_diag_manifest "$workspace" "${prefix}_DESTINATION")" \
            "S42: the manifest records the ${name} log destination"
        assert_eq "$(stat -c %s -- "${flow}/log.${name}")" "$(ab_diag_manifest "$workspace" "${prefix}_BYTES")" \
            "S42: the manifest records the ${name} log size"
        assert_eq "$(ab_sha "${flow}/log.${name}")" "$(ab_diag_manifest "$workspace" "${prefix}_SHA256")" \
            "S42: the manifest records the ${name} log SHA-256"
        cmp -s -- "${flow}/log.${name}" "${dir}/evidence/logs/setup-${name}.log" ||
            _fail "S42: the ${name} log copy must have the bytes of the source"
        assert_eq "$(ab_sha "${flow}/log.${name}")" "$(ab_diag_inventory_sha "$workspace" "logs/setup-${name}.log")" \
            "S42: the final inventory shows the ${name} log"
    done
    assert_eq "$(ab_sha "$source")" "$(ab_diag_inventory_sha "$workspace" spatial/concaveCells.vtp)" \
        "S42: the final inventory shows the VTP file"

    # The spatial additions are the VTP file, the two setup logs, and the
    # manifest. No mesh, other set, field, VTU, STL, or source archive.
    archive="$(ab_diag_archive_list "$workspace")"
    assert_eq "evidence/spatial/concaveCells.vtp" \
        "$(grep -E '\.(vtk|vtp|vtu|vtm|pvd|stl|obj|gz|tgz|zip)$' <<< "$archive" || true)" \
        "S42: the only geometry file in the archive is the refined concaveCells VTP file"
    for name in evidence/logs/setup-surfaceTransformPoints.log evidence/logs/setup-surfaceCheck.log \
                evidence/spatial/manifest.env; do
        assert_contains "$archive" "$name" "S42: the archive holds ${name}"
    done
    for name in polyMesh processor postProcessing nearPoints triSurface; do
        assert_not_contains "$archive" "$name" "S42: the archive holds no ${name} file"
    done
    assert_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time 3" \
        "S42: the diagnostic continues after a complete capture"
    assert_contains "$(cat "${workspace}/step_summary")" '| Spatial capture | `COMPLETE` |' \
        "S42: the job summary shows the spatial capture"
    assert_contains "$(cat "${workspace}/step_summary")" '| Setup logs | `CAPTURED` |' \
        "S42: the job summary shows the setup logs"
}

s43_spatial_capture_discovery_faults() {
    local workspace run dir entry mode cause archive
    local entries=("missing:MISSING" "wrong_path:WRONG_PATH" "legacy:LEGACY_FORMAT" "duplicate:DUPLICATE"
                   "empty:EMPTY" "directory:NOT_REGULAR_FILE" "symlink:NOT_REGULAR_FILE")
    # A root process can read a file without read permission.
    (( EUID != 0 )) && entries+=("unreadable:UNREADABLE")
    for entry in "${entries[@]}"; do
        mode="${entry%%:*}"
        cause="INCONCLUSIVE_SPATIAL_VTK_${entry#*:}"
        workspace="$(new_workspace "s43_${mode}")"
        ab_diag_fixture "$workspace"
        run="$(ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_VTK="$mode")"
        dir="$(ab_diag_dir "$workspace")"
        assert_eq "$cause" "$(ab_diag_value "$workspace" DIAG_RESULT)" "S43: the ${mode} VTP fault is ${cause}"
        assert_eq "$cause" "$(ab_diag_value "$workspace" SPATIAL_CAPTURE)" "S43: the result shows the ${mode} capture"
        assert_eq "$cause" "$(ab_diag_manifest "$workspace" SPATIAL_CAPTURE)" \
            "S43: the manifest shows the ${mode} capture"
        assert_eq "spatial-capture" "$(ab_diag_value "$workspace" DIAG_STOP_POINT)" \
            "S43: the ${mode} capture stops the run"
        assert_eq "23913" "$(ab_diag_value "$workspace" REFINED_CONCAVE_CELLS)" \
            "S43: the refined check evidence is kept after the ${mode} capture"
        assert_file_missing "${dir}/evidence/spatial/concaveCells.vtp" "S43: no VTP file is copied after the ${mode} fault"
        archive="$(ab_diag_archive_list "$workspace")"
        if grep -Eq '\.(vtk|vtp)$' <<< "$archive"; then
            _fail "S43: the archive must hold no set geometry after the ${mode} capture"
        fi
        assert_not_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time" \
            "S43: no reconstruction runs after the ${mode} capture"
        # A failed capture keeps the summary and the upload eligible.
        assert_contains "$run" "package=0 " "S43: the package step ends with status 0 after the ${mode} capture"
        assert_contains "$run" "summary=0" "S43: the summary step ends with status 0 after the ${mode} capture"
        assert_file_exists "${dir}/upload/result.env" "S43: the upload holds the result after the ${mode} capture"
        assert_file_exists "${dir}/upload/inventory.txt" "S43: the upload holds the inventory after the ${mode} capture"
        assert_contains "$archive" "evidence/spatial/manifest.env" \
            "S43: the archive holds the manifest after the ${mode} capture"
        assert_contains "$(cat "${workspace}/step_summary")" "| Spatial capture | \`${cause}\` |" \
            "S43: the job summary shows the ${mode} capture"
    done
    # Both entries of a duplicate are named, and neither is copied.
    workspace="$(new_workspace s43_duplicate_names)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_VTK=duplicate > /dev/null
    assert_eq "2" "$(ab_diag_manifest "$workspace" VTK_CANDIDATES_AFTER_CHECK)" "S43: the manifest counts both entries"
    assert_contains "$(ab_diag_manifest "$workspace" VTK_CANDIDATE_PATHS)" \
        "${AB_DIAG_FLOW}/postProcessing/1/concaveCells.vtp" "S43: the manifest names the other entry"
    assert_contains "$(ab_diag_manifest "$workspace" VTK_CANDIDATE_PATHS)" \
        "${AB_DIAG_FLOW}/postProcessing/1/concaveCells/concaveCells.vtp" "S43: the manifest names the expected entry"
}

s44_spatial_capture_vtp_size_limit() {
    local workspace dir source size
    # One byte above 20 MiB: the file is excluded with its path, size, and
    # hash, and the result is an output limit.
    workspace="$(new_workspace s44_above_limit)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_VTK=size:20971521 > /dev/null
    dir="$(ab_diag_dir "$workspace")"
    source="${workspace}/checkout/${AB_DIAG_FLOW}/postProcessing/1/concaveCells/concaveCells.vtp"
    assert_eq "INCONCLUSIVE_SPATIAL_VTK_OUTPUT_LIMIT" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S44: a VTP file above 20971520 bytes is INCONCLUSIVE_SPATIAL_VTK_OUTPUT_LIMIT"
    assert_contains "$(cat "${dir}/evidence/excluded.tsv")" \
        "${AB_DIAG_FLOW}/postProcessing/1/concaveCells/concaveCells.vtp	20971521	$(ab_sha "$source")	" \
        "S44: excluded.tsv records the path, the size, and the hash"
    assert_eq "1" "$(tail -n +2 "${dir}/evidence/excluded.tsv" | wc -l | tr -d ' ')" \
        "S44: excluded.tsv has one row for the one oversized file"
    assert_contains "$(cat "${dir}/upload/inventory.txt")" \
        "EXCLUDED	20971521	$(ab_sha "$source")	${AB_DIAG_FLOW}/postProcessing/1/concaveCells/concaveCells.vtp" \
        "S44: the inventory names the excluded VTP file"
    assert_file_missing "${dir}/evidence/spatial/concaveCells.vtp" "S44: the large VTP file is not copied"
    size="$(du -cb "${dir}/upload" | tail -n 1 | cut -f1)"
    (( size < 1048576 )) || _fail "S44: the upload must not hold the large VTP file" "bytes: ${size}"
    assert_not_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time" \
        "S44: no reconstruction runs after the VTP limit"

    # Exactly 20 MiB is inside the limit.
    workspace="$(new_workspace s44_at_limit)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_VTK=size:20971520 > /dev/null
    dir="$(ab_diag_dir "$workspace")"
    assert_eq "COMPLETE" "$(ab_diag_value "$workspace" SPATIAL_CAPTURE)" "S44: a 20971520-byte VTP file is captured"
    assert_eq "20971520" "$(stat -c %s -- "${dir}/evidence/spatial/concaveCells.vtp" 2>/dev/null)" \
        "S44: the copy has all 20971520 bytes"
    assert_eq "FIRST_CONCAVITY_AT_REFINED_MESH" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S44: the diagnostic class stands with a VTP file at the limit"
    size="$(stat -c %s -- "${dir}/upload/m3-mesh-diagnostic-evidence.tar.gz")"
    (( size <= 47185920 )) || _fail "S44: the archive must stay inside 45 MiB" "bytes: ${size}"

    # Every oversized readable regular candidate gets an exclusion row before
    # the stop, and the primary cause stays (PR #92 review 5394488889). A
    # symbolic link is not followed, and no rejected file is copied.
    local entry mode cause big rows expected
    for entry in "big_wrong_path:WRONG_PATH:postProcessing/checkMesh/1/concaveCells.vtp" \
                 "big_legacy:LEGACY_FORMAT:postProcessing/1/concaveCells/concaveCells.vtk" \
                 "big_duplicate:DUPLICATE:postProcessing/1/concaveCells/concaveCells.vtp"; do
        IFS=: read -r mode cause big <<< "$entry"
        workspace="$(new_workspace "s44_${mode}")"
        ab_diag_fixture "$workspace"
        ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_VTK="$mode" > /dev/null
        dir="$(ab_diag_dir "$workspace")"
        source="${workspace}/checkout/${AB_DIAG_FLOW}/${big}"
        assert_eq "INCONCLUSIVE_SPATIAL_VTK_${cause}" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
            "S44: an oversized ${mode} candidate keeps the primary cause ${cause}"
        rows="$(tail -n +2 "${dir}/evidence/excluded.tsv")"
        expected="${AB_DIAG_FLOW}/${big}	20971521	$(ab_sha "$source")	"
        assert_contains "$rows" "$expected" "S44: excluded.tsv records the ${mode} path, size, and hash"
        assert_eq "1" "$(awk 'NF' <<< "$rows" | wc -l | tr -d ' ')" \
            "S44: excluded.tsv has one row for the ${mode} candidates"
        assert_eq "1" "$(ab_diag_manifest "$workspace" VTK_OVERSIZED_CANDIDATES)" \
            "S44: the manifest counts one oversized ${mode} candidate"
        assert_contains "$(cat "${dir}/upload/inventory.txt")" \
            "EXCLUDED	20971521	$(ab_sha "$source")	${AB_DIAG_FLOW}/${big}" \
            "S44: the inventory names the excluded ${mode} candidate"
        assert_file_missing "${dir}/evidence/spatial/concaveCells.vtp" "S44: no file is copied after ${mode}"
        if ab_diag_archive_list "$workspace" | grep -Eq '\.(vtk|vtp)$'; then
            _fail "S44: the archive must hold no set geometry after ${mode}"
        fi
        size="$(du -cb "${dir}/upload" | tail -n 1 | cut -f1)"
        (( size < 1048576 )) || _fail "S44: the upload must not hold the ${mode} candidate" "bytes: ${size}"
        assert_not_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time" \
            "S44: no reconstruction runs after ${mode}"
    done
    # In the duplicate set, the small file and the symbolic link to the large
    # file have no exclusion row.
    assert_not_contains "$rows" "${AB_DIAG_FLOW}/postProcessing/1/concaveCells.vtp	" \
        "S44: the small duplicate has no exclusion row"
    assert_not_contains "$rows" "concaveCells/concaveCells.vtk" \
        "S44: the symbolic link to the large file is not followed"
    assert_eq "3" "$(ab_diag_manifest "$workspace" VTK_CANDIDATES_AFTER_CHECK)" \
        "S44: the manifest counts the three duplicate entries"
}

s45_spatial_capture_provenance_and_zero_count() {
    local workspace mode dir stale
    # An entry before the refined check cannot prove its origin.
    for mode in stale_vtp stale_vtk; do
        workspace="$(new_workspace "s45_${mode}")"
        ab_diag_fixture "$workspace"
        ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_SETUP_LOG="$mode" > /dev/null
        assert_eq "INCONCLUSIVE_SPATIAL_VTK_PROVENANCE" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
            "S45: a ${mode} entry before the refined check is INCONCLUSIVE_SPATIAL_VTK_PROVENANCE"
        assert_eq "1" "$(ab_diag_manifest "$workspace" VTK_CANDIDATES_BEFORE_CHECK)" \
            "S45: the manifest counts the ${mode} entry"
        assert_not_contains "$(ab_diag_calls "$workspace")" "checkMesh -parallel" \
            "S45: the refined check does not run after a ${mode} entry"
        assert_file_missing "$(ab_diag_dir "$workspace")/evidence/spatial/concaveCells.vtp" \
            "S45: a ${mode} entry is not copied"
    done
    # An oversized stale entry also gets its exclusion row (PR #92 review
    # 5394488889), and the primary cause stays.
    workspace="$(new_workspace s45_stale_big_vtp)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_SETUP_LOG=stale_big_vtp > /dev/null
    dir="$(ab_diag_dir "$workspace")"
    stale="${AB_DIAG_FLOW}/postProcessing/1/concaveCells/concaveCells.vtp"
    assert_eq "INCONCLUSIVE_SPATIAL_VTK_PROVENANCE" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S45: an oversized stale entry keeps the provenance cause"
    assert_contains "$(cat "${dir}/evidence/excluded.tsv")" \
        "${stale}	20971521	$(ab_sha "${workspace}/checkout/${stale}")	" \
        "S45: excluded.tsv records the oversized stale entry"

    # An exact zero count and no entry: nothing to locate, and the existing
    # classifier decides.
    workspace="$(new_workspace s45_zero_clean)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" > /dev/null
    dir="$(ab_diag_dir "$workspace")"
    assert_eq "NOT_APPLICABLE_NO_REFINED_CONCAVITY" "$(ab_diag_value "$workspace" SPATIAL_CAPTURE)" \
        "S45: a zero refined count gives NOT_APPLICABLE_NO_REFINED_CONCAVITY in the result"
    assert_eq "NOT_APPLICABLE_NO_REFINED_CONCAVITY" "$(ab_diag_manifest "$workspace" SPATIAL_CAPTURE)" \
        "S45: a zero refined count gives NOT_APPLICABLE_NO_REFINED_CONCAVITY in the manifest"
    assert_eq "NO_CONCAVITY_REPRODUCED" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S45: the existing classifier decides a zero refined count"
    assert_not_contains "$(cat "${dir}/upload/result.env")" "SPATIAL_VTK_MISSING" \
        "S45: a zero refined count is no missing VTP file"
    assert_file_missing "${dir}/evidence/spatial/concaveCells.vtp" "S45: no VTP file is copied for a zero count"
    assert_eq "" "$(ab_diag_inventory_sha "$workspace" spatial/concaveCells.vtp)" \
        "S45: the inventory has no VTP row for a zero count"
    assert_ne "" "$(ab_diag_inventory_sha "$workspace" logs/setup-surfaceCheck.log)" \
        "S45: the inventory shows the setup logs for a zero count"
    workspace="$(new_workspace s45_zero_final_fails)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_CHECK_FINAL=concave:5 > /dev/null
    assert_eq "NO_PHASE_CONCAVITY_BUT_FINAL_CHECK_FAILS" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S45: a zero refined count keeps the final-check class"
    assert_eq "NOT_APPLICABLE_NO_REFINED_CONCAVITY" "$(ab_diag_value "$workspace" SPATIAL_CAPTURE)" \
        "S45: the final-check class has no spatial capture"

    # An exact zero count with an entry, and an unavailable count.
    workspace="$(new_workspace s45_zero_unexpected)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_VTK=force > /dev/null
    assert_eq "INCONCLUSIVE_SPATIAL_VTK_UNEXPECTED" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S45: a VTP file with a zero refined count is INCONCLUSIVE_SPATIAL_VTK_UNEXPECTED"
    assert_file_missing "$(ab_diag_dir "$workspace")/evidence/spatial/concaveCells.vtp" \
        "S45: an unexpected VTP file is not copied"
    assert_not_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time" \
        "S45: no reconstruction runs after an unexpected VTP file"
    workspace="$(new_workspace s45_count_unavailable)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_CHECK_PHASE=failed_nocount FAKE_CHECK_FINAL=concave:9 FAKE_VTK=force > /dev/null
    assert_eq "INCONCLUSIVE_CONCAVE_COUNT" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S45: an unavailable refined count keeps its first cause"
    assert_eq "INCONCLUSIVE_SPATIAL_COUNT_UNAVAILABLE" "$(ab_diag_value "$workspace" SPATIAL_CAPTURE)" \
        "S45: an unavailable refined count gives an explicit spatial-count state"
    assert_file_missing "$(ab_diag_dir "$workspace")/evidence/spatial/concaveCells.vtp" \
        "S45: a VTP file without an exact count is not a validated capture"
}

s46_spatial_capture_setup_logs() {
    local workspace dir entry mode cause source
    local entries=("missing_transform:MISSING" "missing_check:MISSING" "directory_check:NOT_REGULAR_FILE")
    (( EUID != 0 )) && entries+=("unreadable_check:UNREADABLE")
    for entry in "${entries[@]}"; do
        mode="${entry%%:*}"
        cause="INCONCLUSIVE_SETUP_LOG_${entry#*:}"
        workspace="$(new_workspace "s46_${mode}")"
        ab_diag_fixture "$workspace"
        ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_SETUP_LOG="$mode" > /dev/null
        assert_eq "$cause" "$(ab_diag_value "$workspace" DIAG_RESULT)" "S46: a ${mode} setup log is ${cause}"
        assert_eq "$cause" "$(ab_diag_value "$workspace" SETUP_LOGS)" "S46: the result shows the ${mode} setup log"
        assert_eq "setup-logs" "$(ab_diag_value "$workspace" DIAG_STOP_POINT)" \
            "S46: the ${mode} setup log stops the run"
        assert_not_contains "$(ab_diag_calls "$workspace")" "surfaceFeatureExtract" \
            "S46: no mesh command runs after a ${mode} setup log"
    done

    # A setup log above 1 MiB is not cut and not uploaded.
    for mode in big_transform big_check; do
        workspace="$(new_workspace "s46_${mode}")"
        ab_diag_fixture "$workspace"
        ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_SETUP_LOG="$mode" > /dev/null
        dir="$(ab_diag_dir "$workspace")"
        case "$mode" in
            big_transform) source="${AB_DIAG_FLOW}/log.surfaceTransformPoints" ;;
            big_check) source="${AB_DIAG_FLOW}/log.surfaceCheck" ;;
        esac
        assert_eq "INCONCLUSIVE_SETUP_LOG_OUTPUT_LIMIT" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
            "S46: a ${mode} setup log above 1 MiB is INCONCLUSIVE_SETUP_LOG_OUTPUT_LIMIT"
        assert_contains "$(cat "${dir}/evidence/excluded.tsv")" \
            "${source}	1048577	$(ab_sha "${workspace}/checkout/${source}")	" \
            "S46: excluded.tsv records the ${mode} path, size, and hash"
        if ab_diag_archive_list "$workspace" | grep -Eq "/setup-${source##*log.}\.log$"; then
            _fail "S46: the ${mode} setup log must not be uploaded"
        fi
        if find "${dir}/evidence" -type f -size +1024k | grep -q .; then
            _fail "S46: no evidence file may exceed 1 MiB after a ${mode} setup log"
        fi
        assert_not_contains "$(ab_diag_calls "$workspace")" "surfaceFeatureExtract" \
            "S46: no mesh command runs after a ${mode} setup log"
    done

    # A setup log of exactly 1 MiB is inside the limit.
    workspace="$(new_workspace s46_limit_check)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" FAKE_SETUP_LOG=limit_check > /dev/null
    dir="$(ab_diag_dir "$workspace")"
    assert_eq "CAPTURED" "$(ab_diag_value "$workspace" SETUP_LOGS)" "S46: a 1048576-byte setup log is captured"
    assert_eq "1048576" "$(stat -c %s -- "${dir}/evidence/logs/setup-surfaceCheck.log" 2>/dev/null)" \
        "S46: the setup log copy has all 1048576 bytes"
    assert_eq "NO_CONCAVITY_REPRODUCED" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S46: the diagnostic continues with a setup log at the limit"
}

s47_spatial_capture_final_inventory_rule() {
    local workspace dir
    # A conclusive class needs the VTP file in the final inventory.
    workspace="$(new_workspace s47_vtp_removed)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" > /dev/null
    dir="$(ab_diag_dir "$workspace")"
    rm -f -- "${dir}/evidence/spatial/concaveCells.vtp"
    env RUNNER_TEMP="${workspace}/runner_temp" DIAG_DIR="$dir" GITHUB_ENV="${workspace}/github_env" \
        bash "${workspace}/package_step.sh" > "${workspace}/package2.out" 2>&1 ||
        _fail "S47: the package step must end with status 0"
    assert_eq "INCONCLUSIVE_SPATIAL_INVENTORY" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S47: a conclusive class without the VTP file in the inventory is INCONCLUSIVE_SPATIAL_INVENTORY"
    assert_eq "FIRST_CONCAVITY_AT_REFINED_MESH" "$(ab_diag_value "$workspace" DIAG_PRIOR_RESULT)" \
        "S47: the prior result is kept for reference"
    assert_contains "$(ab_diag_value "$workspace" DIAG_REASON)" "spatial/concaveCells.vtp" \
        "S47: the reason names the missing VTP file"
    assert_eq "$(ab_sha "${dir}/evidence/result.env")" "$(ab_diag_inventory_sha "$workspace" result.env)" \
        "S47: the inventory shows the changed result file"

    # A changed copy does not match the manifest hash.
    workspace="$(new_workspace s47_vtp_changed)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" > /dev/null
    dir="$(ab_diag_dir "$workspace")"
    printf 'x' >> "${dir}/evidence/spatial/concaveCells.vtp"
    env RUNNER_TEMP="${workspace}/runner_temp" DIAG_DIR="$dir" GITHUB_ENV="${workspace}/github_env" \
        bash "${workspace}/package_step.sh" > "${workspace}/package2.out" 2>&1 ||
        _fail "S47: the package step must end with status 0"
    assert_eq "INCONCLUSIVE_SPATIAL_INVENTORY" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S47: a VTP file with another hash is INCONCLUSIVE_SPATIAL_INVENTORY"

    # A zero count needs both setup logs in the final inventory.
    workspace="$(new_workspace s47_log_removed)"
    ab_diag_fixture "$workspace"
    ab_diag_run "$workspace" > /dev/null
    dir="$(ab_diag_dir "$workspace")"
    rm -f -- "${dir}/evidence/logs/setup-surfaceCheck.log"
    env RUNNER_TEMP="${workspace}/runner_temp" DIAG_DIR="$dir" GITHUB_ENV="${workspace}/github_env" \
        bash "${workspace}/package_step.sh" > "${workspace}/package2.out" 2>&1 ||
        _fail "S47: the package step must end with status 0"
    assert_eq "INCONCLUSIVE_SPATIAL_INVENTORY" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "S47: a conclusive class without a setup log in the inventory is INCONCLUSIVE_SPATIAL_INVENTORY"
    assert_eq "NO_CONCAVITY_REPRODUCED" "$(ab_diag_value "$workspace" DIAG_PRIOR_RESULT)" \
        "S47: the prior zero-count result is kept for reference"
}

# ---- S48 to S52: the capture deadline correction (Issue #80) ---------------

# The active-work window of the blocked-operation checks: the fake work before
# the capture takes about 1 second, and a blocked operation meets the deadline
# reserve about 10 seconds after the start.
AB_CAPTURE_WINDOW=15

# The VTP file of the concave-cell run, as the fake capture commands see it.
AB_CAPTURE_VTP="*/flow/postProcessing/1/concaveCells/concaveCells.vtp"

# ab_capture_window_run <workspace> [NAME=value ...] - one concave-cell run whose
# active-work deadline is AB_CAPTURE_WINDOW seconds after the call.
ab_capture_window_run() {
    local workspace="$1"
    shift
    ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" "$@" \
        DIAG_ACTIVE_DEADLINE="$(( $(date +%s) + AB_CAPTURE_WINDOW ))"
}

# ab_capture_targets <workspace> <name> - the targets of the fake capture calls
# of one command, one per line.
ab_capture_targets() {
    awk -F '\t' -v name="$2" '$1 == name { print $2 }' "${1}/capture_calls.tsv"
}

# ab_assert_capture_stop <workspace> <run> <cause> <state-key> <operation> <path>
# <label> - the common result of an incomplete capture operation: the explicit
# cause and stop point, the state, the operation, and its path in the result
# and the manifest, no complete capture, no partial hash, no temporary output,
# and an eligible package, summary, and upload.
ab_assert_capture_stop() {
    local workspace="$1" run="$2" cause="$3" key="$4" operation="$5" path="$6" label="$7"
    local dir point timeout name summary
    dir="$(ab_diag_dir "$workspace")"
    case "$cause" in
        INCONCLUSIVE_CAPTURE_TIMEOUT) point=capture-timeout timeout=YES ;;
        *) point=capture-failure timeout=NO ;;
    esac
    assert_eq "$cause" "$(ab_diag_value "$workspace" DIAG_RESULT)" "${label}: the result is ${cause}"
    assert_eq "$point" "$(ab_diag_value "$workspace" DIAG_STOP_POINT)" "${label}: the stop point is ${point}"
    assert_eq "$cause" "$(ab_diag_value "$workspace" "$key")" "${label}: the result shows ${key}=${cause}"
    assert_eq "$cause" "$(ab_diag_manifest "$workspace" "$key")" "${label}: the manifest shows ${key}=${cause}"
    assert_eq "$timeout" "$(ab_diag_value "$workspace" CAPTURE_TIMEOUT)" \
        "${label}: the result shows CAPTURE_TIMEOUT=${timeout}"
    assert_eq "$timeout" "$(ab_diag_manifest "$workspace" CAPTURE_TIMEOUT)" \
        "${label}: the manifest shows CAPTURE_TIMEOUT=${timeout}"
    assert_eq "$operation" "$(ab_diag_value "$workspace" CAPTURE_INCOMPLETE_OPERATION)" \
        "${label}: the result names the ${operation} operation"
    assert_eq "$operation" "$(ab_diag_manifest "$workspace" CAPTURE_INCOMPLETE_OPERATION)" \
        "${label}: the manifest names the ${operation} operation"
    assert_eq "$path" "$(ab_diag_value "$workspace" CAPTURE_INCOMPLETE_PATH)" \
        "${label}: the result names the path of the operation"
    assert_eq "$path" "$(ab_diag_manifest "$workspace" CAPTURE_INCOMPLETE_PATH)" \
        "${label}: the manifest names the path of the operation"
    assert_ne "COMPLETE" "$(ab_diag_value "$workspace" SPATIAL_CAPTURE)" \
        "${label}: the result never shows a complete capture"
    assert_ne "COMPLETE" "$(ab_diag_manifest "$workspace" SPATIAL_CAPTURE)" \
        "${label}: the manifest never shows a complete capture"
    for name in spatial/manifest.env excluded.tsv; do
        assert_not_contains "$(cat "${dir}/evidence/${name}" 2>/dev/null)" "$(printf '%064d' 0)" \
            "${label}: ${name} holds no partial hash"
    done
    assert_eq "" "$(find "${dir}/capture-tmp" -mindepth 1 2>/dev/null)" \
        "${label}: no temporary capture output remains"
    assert_contains "$run" "package=0 " "${label}: the package step ends with status 0"
    assert_contains "$run" "summary=0" "${label}: the summary step ends with status 0"
    assert_file_exists "${dir}/upload/result.env" "${label}: the upload holds the result"
    assert_file_exists "${dir}/upload/inventory.txt" "${label}: the upload holds the inventory"
    assert_contains "$(ab_diag_archive_list "$workspace")" "evidence/spatial/manifest.env" \
        "${label}: the archive holds the manifest"
    summary="$(cat "${workspace}/step_summary")"
    assert_contains "$summary" "| Result | \`${cause}\` |" "${label}: the job summary shows the result"
    assert_contains "$summary" "| Capture timeout | \`${timeout}\` |" \
        "${label}: the job summary shows the capture timeout state"
    assert_contains "$summary" "| Incomplete capture operation | \`${operation}\` |" \
        "${label}: the job summary shows the incomplete operation"
}

# ab_assert_capture_in_window <workspace> <run> <label> - the blocked operation
# stopped before the active-work deadline, with its process and child process.
ab_assert_capture_in_window() {
    local workspace="$1" run="$2" label="$3" end deadline elapsed
    end="$(ab_diag_value "$workspace" DIAG_ACTIVE_END)"
    deadline="$(ab_diag_value "$workspace" DIAG_ACTIVE_DEADLINE)"
    elapsed="$(sed -e 's/.*elapsed=\([0-9]*\).*/\1/' <<< "$run")"
    if [[ ! "$end" =~ ^[0-9]+$ || ! "$deadline" =~ ^[0-9]+$ ]] || (( end > deadline )); then
        _fail "${label}: the diagnostic must end before the active-work deadline" "end: ${end}, deadline: ${deadline}"
    fi
    (( elapsed <= AB_CAPTURE_WINDOW )) ||
        _fail "${label}: the blocked operation must stop inside the active-work window" "elapsed: ${elapsed}"
    ab_assert_fakes_stopped "$workspace" "$label"
}

s48_capture_deadline_expired_before_an_operation() {
    local workspace run entry jump operation key path label calls
    for entry in "setup:setup-log-hash:SETUP_LOGS:${AB_DIAG_FLOW}/log.surfaceTransformPoints" \
                 "snappyHexMesh:vtk-discovery-before-check:SPATIAL_CAPTURE:${AB_DIAG_FLOW}" \
                 "checkMesh-parallel:vtk-discovery-after-check:SPATIAL_CAPTURE:${AB_DIAG_FLOW}"; do
        IFS=: read -r jump operation key path <<< "$entry"
        label="S48 (${jump})"
        workspace="$(new_workspace "s48_${jump}")"
        ab_diag_fixture "$workspace"
        # The deadline passes after the selected command, so the next capture
        # operation has no active time left.
        run="$(ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_CLOCK_JUMP="$jump")"
        ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_TIMEOUT "$key" "$operation" "$path" "$label"
        assert_contains "$(ab_diag_value "$workspace" DIAG_REASON)" "no active time was left" \
            "${label}: the reason says that no active time was left"
        calls="$(ab_diag_calls "$workspace")"
        case "$jump" in
            setup)
                assert_not_contains "$(ab_capture_targets "$workspace" sha256sum)" "/log.surfaceTransformPoints" \
                    "${label}: no hash process starts"
                assert_eq "UNAVAILABLE" "$(ab_diag_manifest "$workspace" TRANSFORM_LOG_SHA256)" \
                    "${label}: the manifest has no hash"
                assert_eq "NOT_RUN" "$(ab_diag_value "$workspace" SPATIAL_CAPTURE)" \
                    "${label}: the spatial capture does not run"
                assert_not_contains "$calls" "surfaceFeatureExtract" "${label}: no mesh command runs" ;;
            snappyHexMesh)
                assert_eq "0" "$(ab_capture_targets "$workspace" find | grep -c '^discovery$' || true)" \
                    "${label}: no discovery process starts"
                assert_eq "UNAVAILABLE" "$(ab_diag_manifest "$workspace" VTK_CANDIDATES_BEFORE_CHECK)" \
                    "${label}: the manifest has no candidate count"
                assert_not_contains "$calls" "checkMesh -parallel" "${label}: the refined check does not run"
                assert_eq "CAPTURED" "$(ab_diag_value "$workspace" SETUP_LOGS)" "${label}: the setup logs stay captured"
                assert_contains "$(ab_diag_archive_list "$workspace")" "evidence/logs/setup-surfaceCheck.log" \
                    "${label}: the completed setup log copy is uploaded" ;;
            checkMesh-parallel)
                assert_eq "1" "$(ab_capture_targets "$workspace" find | grep -c '^discovery$' || true)" \
                    "${label}: only the discovery before the refined check runs"
                assert_eq "UNAVAILABLE" "$(ab_diag_manifest "$workspace" VTK_CANDIDATES_AFTER_CHECK)" \
                    "${label}: the manifest has no candidate count after the check"
                assert_eq "23913" "$(ab_diag_value "$workspace" REFINED_CONCAVE_CELLS)" \
                    "${label}: the refined check evidence is kept"
                assert_not_contains "$calls" "reconstructParMesh -time" "${label}: no reconstruction runs" ;;
        esac
    done
}

s49_capture_slow_discovery_stops_in_the_window() {
    local workspace run when label
    for when in before after; do
        label="S49 (${when})"
        workspace="$(new_workspace "s49_${when}")"
        ab_diag_fixture "$workspace"
        run="$(ab_capture_window_run "$workspace" FAKE_SLOW_DISCOVERY="$when")"
        ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_TIMEOUT SPATIAL_CAPTURE \
            "vtk-discovery-${when}-check" "$AB_DIAG_FLOW" "$label"
        ab_assert_capture_in_window "$workspace" "$run" "$label"
        assert_not_contains "$(ab_diag_manifest "$workspace" VTK_CANDIDATE_PATHS)" "partial" \
            "${label}: no partial candidate list is kept"
        case "$when" in
            before)
                assert_eq "UNAVAILABLE" "$(ab_diag_manifest "$workspace" VTK_CANDIDATES_BEFORE_CHECK)" \
                    "${label}: the manifest has no candidate count"
                assert_not_contains "$(ab_diag_calls "$workspace")" "checkMesh -parallel" \
                    "${label}: the refined check does not run" ;;
            after)
                assert_eq "0" "$(ab_diag_manifest "$workspace" VTK_CANDIDATES_BEFORE_CHECK)" \
                    "${label}: the completed discovery before the check is kept"
                assert_eq "UNAVAILABLE" "$(ab_diag_manifest "$workspace" VTK_CANDIDATES_AFTER_CHECK)" \
                    "${label}: the manifest has no candidate count after the check"
                assert_eq "23913" "$(ab_diag_value "$workspace" REFINED_CONCAVE_CELLS)" \
                    "${label}: the refined check evidence is kept"
                assert_not_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time" \
                    "${label}: no reconstruction runs" ;;
        esac
    done
}

s50_capture_slow_hash_publishes_no_partial_hash() {
    local workspace run dir flow label rows first
    # The first setup log.
    label="S50 (transform log)"
    workspace="$(new_workspace s50_transform_hash)"
    ab_diag_fixture "$workspace"
    run="$(ab_capture_window_run "$workspace" FAKE_SLOW_HASH="*/flow/log.surfaceTransformPoints")"
    dir="$(ab_diag_dir "$workspace")"
    ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_TIMEOUT SETUP_LOGS setup-log-hash \
        "${AB_DIAG_FLOW}/log.surfaceTransformPoints" "$label"
    ab_assert_capture_in_window "$workspace" "$run" "$label"
    assert_eq "UNAVAILABLE" "$(ab_diag_manifest "$workspace" TRANSFORM_LOG_SHA256)" "${label}: no hash is published"
    assert_file_missing "${dir}/evidence/logs/setup-surfaceTransformPoints.log" "${label}: no copy is made"
    assert_not_contains "$(ab_diag_calls "$workspace")" "surfaceFeatureExtract" "${label}: no mesh command runs"

    # The second setup log, above 1 MiB: no exclusion row without a complete
    # hash. The completed first log stays valid evidence.
    label="S50 (check log)"
    workspace="$(new_workspace s50_check_hash)"
    ab_diag_fixture "$workspace"
    run="$(ab_capture_window_run "$workspace" FAKE_SETUP_LOG=big_check FAKE_SLOW_HASH="*/flow/log.surfaceCheck")"
    dir="$(ab_diag_dir "$workspace")"
    flow="${workspace}/checkout/${AB_DIAG_FLOW}"
    ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_TIMEOUT SETUP_LOGS setup-log-hash \
        "${AB_DIAG_FLOW}/log.surfaceCheck" "$label"
    ab_assert_capture_in_window "$workspace" "$run" "$label"
    assert_eq "UNAVAILABLE" "$(ab_diag_manifest "$workspace" CHECK_LOG_SHA256)" "${label}: no hash is published"
    assert_eq "0" "$(tail -n +2 "${dir}/evidence/excluded.tsv" | wc -l | tr -d ' ')" \
        "${label}: no exclusion row is published"
    assert_eq "$(ab_sha "${flow}/log.surfaceTransformPoints")" "$(ab_diag_manifest "$workspace" TRANSFORM_LOG_SHA256)" \
        "${label}: the completed first log hash is kept"
    assert_eq "$(ab_sha "${flow}/log.surfaceTransformPoints")" \
        "$(ab_diag_inventory_sha "$workspace" logs/setup-surfaceTransformPoints.log)" \
        "${label}: the completed first log copy is uploaded"

    # The second of two oversized candidates: the first exclusion row stays,
    # and the timeout replaces the duplicate cause.
    label="S50 (oversized candidate)"
    workspace="$(new_workspace s50_candidate_hash)"
    ab_diag_fixture "$workspace"
    run="$(ab_capture_window_run "$workspace" FAKE_VTK=big_two FAKE_SLOW_HASH="$AB_CAPTURE_VTP")"
    dir="$(ab_diag_dir "$workspace")"
    flow="${workspace}/checkout/${AB_DIAG_FLOW}"
    ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_TIMEOUT SPATIAL_CAPTURE vtk-exclusion-hash \
        "${AB_DIAG_FLOW}/postProcessing/1/concaveCells/concaveCells.vtp" "$label"
    ab_assert_capture_in_window "$workspace" "$run" "$label"
    rows="$(tail -n +2 "${dir}/evidence/excluded.tsv")"
    first="${AB_DIAG_FLOW}/postProcessing/1/concaveCells.vtp"
    assert_eq "${first}	20971521	$(ab_sha "${workspace}/checkout/${first}")	the VTK file is above 20971520 bytes" \
        "$rows" "${label}: the one completed exclusion row stays, and no other row is published"
    assert_eq "1" "$(ab_diag_manifest "$workspace" VTK_OVERSIZED_CANDIDATES)" \
        "${label}: the manifest counts one completed exclusion"
    assert_eq "2" "$(ab_diag_manifest "$workspace" VTK_CANDIDATES_AFTER_CHECK)" \
        "${label}: the completed discovery is kept"
    assert_contains "$(cat "${dir}/upload/inventory.txt")" \
        "EXCLUDED	20971521	$(ab_sha "${workspace}/checkout/${first}")	${first}" \
        "${label}: the inventory names the completed exclusion"

    # The VTP file.
    label="S50 (VTP file)"
    workspace="$(new_workspace s50_vtp_hash)"
    ab_diag_fixture "$workspace"
    run="$(ab_capture_window_run "$workspace" FAKE_SLOW_HASH="$AB_CAPTURE_VTP")"
    dir="$(ab_diag_dir "$workspace")"
    ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_TIMEOUT SPATIAL_CAPTURE vtp-hash \
        "${AB_DIAG_FLOW}/postProcessing/1/concaveCells/concaveCells.vtp" "$label"
    ab_assert_capture_in_window "$workspace" "$run" "$label"
    assert_eq "UNAVAILABLE" "$(ab_diag_manifest "$workspace" VTK_SHA256)" "${label}: no hash is published"
    assert_file_missing "${dir}/evidence/spatial/concaveCells.vtp" "${label}: no copy is made"
    assert_contains "$(ab_diag_archive_list "$workspace")" "evidence/logs/setup-surfaceCheck.log" \
        "${label}: the completed setup log copy is uploaded"
}

s51_capture_slow_copy_publishes_no_partial_file() {
    local workspace run dir flow label entry name prefix path
    for entry in "surfaceTransformPoints:TRANSFORM_LOG" "surfaceCheck:CHECK_LOG"; do
        IFS=: read -r name prefix <<< "$entry"
        label="S51 (${name} log)"
        workspace="$(new_workspace "s51_${name}_copy")"
        ab_diag_fixture "$workspace"
        run="$(ab_capture_window_run "$workspace" FAKE_SLOW_COPY="*/flow/log.${name}")"
        dir="$(ab_diag_dir "$workspace")"
        flow="${workspace}/checkout/${AB_DIAG_FLOW}"
        ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_TIMEOUT SETUP_LOGS setup-log-copy \
            "${AB_DIAG_FLOW}/log.${name}" "$label"
        ab_assert_capture_in_window "$workspace" "$run" "$label"
        assert_eq "UNAVAILABLE" "$(ab_diag_manifest "$workspace" "${prefix}_DESTINATION")" \
            "${label}: the manifest names no destination"
        assert_file_missing "${dir}/evidence/logs/setup-${name}.log" "${label}: no partial copy is evidence"
        assert_eq "" "$(ab_diag_inventory_sha "$workspace" "logs/setup-${name}.log")" \
            "${label}: no partial copy is inventoried"
        assert_eq "$(ab_sha "${flow}/log.${name}")" "$(ab_diag_manifest "$workspace" "${prefix}_SHA256")" \
            "${label}: the completed hash is kept"
    done
    # The completed first log stays valid evidence.
    assert_eq "$(ab_sha "${flow}/log.surfaceTransformPoints")" \
        "$(ab_diag_inventory_sha "$workspace" logs/setup-surfaceTransformPoints.log)" \
        "S51 (surfaceCheck log): the completed first log copy is uploaded"

    label="S51 (VTP file)"
    workspace="$(new_workspace s51_vtp_copy)"
    ab_diag_fixture "$workspace"
    run="$(ab_capture_window_run "$workspace" FAKE_SLOW_COPY="$AB_CAPTURE_VTP")"
    dir="$(ab_diag_dir "$workspace")"
    path="${AB_DIAG_FLOW}/postProcessing/1/concaveCells/concaveCells.vtp"
    ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_TIMEOUT SPATIAL_CAPTURE vtp-copy "$path" "$label"
    ab_assert_capture_in_window "$workspace" "$run" "$label"
    assert_eq "UNAVAILABLE" "$(ab_diag_manifest "$workspace" VTK_DESTINATION)" \
        "${label}: the manifest names no destination"
    assert_eq "$(ab_sha "${workspace}/checkout/${path}")" "$(ab_diag_manifest "$workspace" VTK_SHA256)" \
        "${label}: the completed hash is kept"
    assert_file_missing "${dir}/evidence/spatial/concaveCells.vtp" "${label}: no partial copy is evidence"
    assert_eq "" "$(ab_diag_inventory_sha "$workspace" spatial/concaveCells.vtp)" \
        "${label}: no partial copy is inventoried"
    if ab_diag_archive_list "$workspace" | grep -Eq '\.(vtk|vtp)$'; then
        _fail "${label}: the archive must hold no set geometry"
    fi
    assert_not_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time" "${label}: no reconstruction runs"
}

s52_capture_failure_and_delayed_success() {
    local workspace run dir source label
    # A failed operation that is not a timeout.
    label="S52 (VTP copy failure)"
    workspace="$(new_workspace s52_copy_failure)"
    ab_diag_fixture "$workspace"
    run="$(ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_FAIL_COPY="$AB_CAPTURE_VTP")"
    ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_FAILURE SPATIAL_CAPTURE vtp-copy \
        "${AB_DIAG_FLOW}/postProcessing/1/concaveCells/concaveCells.vtp" "$label"
    assert_contains "$(ab_diag_value "$workspace" DIAG_REASON)" "status 1" "${label}: the reason gives the status"
    assert_file_missing "$(ab_diag_dir "$workspace")/evidence/spatial/concaveCells.vtp" "${label}: no copy is made"
    assert_not_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time" "${label}: no reconstruction runs"

    label="S52 (discovery failure)"
    workspace="$(new_workspace s52_discovery_failure)"
    ab_diag_fixture "$workspace"
    run="$(ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_FAIL_DISCOVERY=after)"
    ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_FAILURE SPATIAL_CAPTURE \
        vtk-discovery-after-check "$AB_DIAG_FLOW" "$label"
    assert_eq "UNAVAILABLE" "$(ab_diag_manifest "$workspace" VTK_CANDIDATES_AFTER_CHECK)" \
        "${label}: the manifest has no candidate count after the check"

    label="S52 (setup log hash failure)"
    workspace="$(new_workspace s52_hash_failure)"
    ab_diag_fixture "$workspace"
    run="$(ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_FAIL_HASH="*/flow/log.surfaceCheck")"
    ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_FAILURE SETUP_LOGS setup-log-hash \
        "${AB_DIAG_FLOW}/log.surfaceCheck" "$label"
    assert_eq "UNAVAILABLE" "$(ab_diag_manifest "$workspace" CHECK_LOG_SHA256)" "${label}: no hash is published"
    assert_file_missing "$(ab_diag_dir "$workspace")/evidence/logs/setup-surfaceCheck.log" "${label}: no copy is made"

    # A slow hash and a slow copy that finish inside the window keep the
    # complete capture and the diagnostic class.
    label="S52 (delayed success)"
    workspace="$(new_workspace s52_delayed_success)"
    ab_diag_fixture "$workspace"
    run="$(ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_SLOW_HASH="$AB_CAPTURE_VTP" \
           FAKE_SLOW_COPY="$AB_CAPTURE_VTP" FAKE_SLOW_SECONDS=2)"
    dir="$(ab_diag_dir "$workspace")"
    source="${workspace}/checkout/${AB_DIAG_FLOW}/postProcessing/1/concaveCells/concaveCells.vtp"
    assert_eq "FIRST_CONCAVITY_AT_REFINED_MESH" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "${label}: the diagnostic class stands"
    assert_eq "COMPLETE" "$(ab_diag_value "$workspace" SPATIAL_CAPTURE)" "${label}: the capture is complete"
    assert_eq "NO" "$(ab_diag_value "$workspace" CAPTURE_TIMEOUT)" "${label}: the result shows no capture timeout"
    assert_eq "NO" "$(ab_diag_manifest "$workspace" CAPTURE_TIMEOUT)" "${label}: the manifest shows no capture timeout"
    assert_eq "NONE" "$(ab_diag_manifest "$workspace" CAPTURE_INCOMPLETE_OPERATION)" \
        "${label}: the manifest names no incomplete operation"
    cmp -s -- "$source" "${dir}/evidence/spatial/concaveCells.vtp" ||
        _fail "${label}: the copy must have the bytes of the source"
    assert_eq "$(ab_sha "$source")" "$(ab_diag_manifest "$workspace" VTK_SHA256)" "${label}: the hash is exact"
    assert_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time 1" "${label}: the diagnostic continues"
    assert_contains "$(cat "${workspace}/step_summary")" '| Capture timeout | `NO` |' \
        "${label}: the job summary shows no capture timeout"
    ab_assert_fakes_stopped "$workspace" "$label"
}

s53_capture_term_ignoring_child_is_killed() {
    local workspace run entry operation fault path label end deadline elapsed
    # The blocked wrapper exits on SIGTERM, so timeout returns, and its child
    # ignores SIGTERM (PR #93 review 5399027552). The hash wrapper is the direct
    # child of timeout. The discovery wrapper is a grandchild, under bash -c.
    for entry in "vtp-hash:FAKE_SLOW_HASH=${AB_CAPTURE_VTP}:${AB_DIAG_FLOW}/postProcessing/1/concaveCells/concaveCells.vtp" \
                 "vtk-discovery-after-check:FAKE_SLOW_DISCOVERY=after:${AB_DIAG_FLOW}"; do
        IFS=: read -r operation fault path <<< "$entry"
        label="S53 (${operation})"
        workspace="$(new_workspace "s53_${operation}")"
        ab_diag_fixture "$workspace"
        run="$(ab_capture_window_run "$workspace" "$fault" FAKE_SLOW_IGNORE_TERM=1)"
        ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_TIMEOUT SPATIAL_CAPTURE \
            "$operation" "$path" "$label"
        # The child is gone before the operation returns: it never sees the
        # manifest that the stop writes after the operation.
        assert_file_missing "${workspace}/fake_pids.survivor" \
            "${label}: the TERM-ignoring child is gone before the operation returns"
        ab_assert_fakes_stopped "$workspace" "$label"
        # SIGKILL comes after the kill grace, at the end of the reserve.
        end="$(ab_diag_value "$workspace" DIAG_ACTIVE_END)"
        deadline="$(ab_diag_value "$workspace" DIAG_ACTIVE_DEADLINE)"
        elapsed="$(sed -e 's/.*elapsed=\([0-9]*\).*/\1/' <<< "$run")"
        if [[ ! "$end" =~ ^[0-9]+$ || ! "$deadline" =~ ^[0-9]+$ ]] || (( end < deadline || end > deadline + 1 )); then
            _fail "${label}: SIGKILL must come after the kill grace, at the active-work deadline" \
                  "end: ${end}, deadline: ${deadline}"
        fi
        (( elapsed <= AB_CAPTURE_WINDOW + 1 )) ||
            _fail "${label}: the operation must stop at the end of the kill reserve" "elapsed: ${elapsed}"
    done
}

# ---- S54: the run_bounded command group (Issue #80) ------------------------

# ab_diag_functions <workspace> - every top-level function of the diagnostic
# script in the workflow. A definition starts at a "name() {" line and ends at
# the next "}" line, both at the first column of the script.
ab_diag_functions() {
    awk '/<<.MESH_DIAGNOSTIC.$/ { inside = 1; next } /^MESH_DIAGNOSTIC$/ { inside = 0 } inside' \
        "${1}/diagnostic_step.sh" |
        awk '/^[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ { body = 1 } body { print } body && /^\}$/ { body = 0 }'
}

# ab_write_term_ignoring_command <file> [<exit-delay>] - a command that exits
# on SIGTERM, <exit-delay> seconds later (default 0). Its child ignores SIGTERM
# and ends by itself after 30 seconds. Both print their PIDs.
ab_write_term_ignoring_command() {
    {
        printf '#!/usr/bin/env bash\n'
        printf "trap 'sleep %s; exit 0' TERM\n" "${2:-0}"
        cat <<'TERM_IGNORING_COMMAND'
(
    trap '' TERM
    printf 'CHILD_PID=%s\n' "$BASHPID"
    for (( tick = 0; tick < 300; tick++ )); do sleep 0.1; done
) &
printf 'PARENT_PID=%s\n' "$$"
wait
TERM_IGNORING_COMMAND
    } > "$1"
    chmod +x "$1"
}

s54_run_bounded_stops_the_command_group() {
    local workspace run probe limit elapsed child parent dir end deadline delay label
    # The command exits on SIGTERM at once, or 4 seconds later, near the end of
    # the first kill grace (PR #94 review 5404512470). Its child ignores
    # SIGTERM. timeout sends its own SIGKILL 5 seconds after SIGTERM, so a
    # 4-second exit still returns status 124.
    for delay in 0 4; do
        # The run_bounded function of the workflow, called directly. Directly
        # after the function returns, the same shell checks the child.
        label="S54 (function, exit ${delay} s after SIGTERM)"
        workspace="$(new_workspace "s54_function_${delay}")"
        ab_diag_fixture "$workspace"
        ab_diag_functions "$workspace" > "${workspace}/functions.sh"
        grep -q '^run_bounded() {$' "${workspace}/functions.sh" ||
            _fail "${label}: the run_bounded function must be extracted from the workflow"
        ab_write_term_ignoring_command "${workspace}/term_ignoring_command" "$delay"
        probe="$(cd "$workspace" && bash -c '
            source ./functions.sh
            EVIDENCE="${PWD}/evidence"
            EXCLUDED="${PWD}/excluded"
            mkdir -p "${EVIDENCE}/logs" "$EXCLUDED"
            KILL_GRACE=5
            LOG_LIMIT=1048576
            DIAG_SEQ=0
            DIAG_ACTIVE_DEADLINE=$(( $(date +%s) + 8 ))
            start=$(date +%s)
            run_bounded term-ignoring 30 ./term_ignoring_command
            end=$(date +%s)
            child=$(sed -n "s/^CHILD_PID=//p" "$RUN_LOG")
            parent=$(sed -n "s/^PARENT_PID=//p" "$RUN_LOG")
            alive=NO
            if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null; then
                alive=YES
                kill -KILL "$child" 2>/dev/null
            fi
            printf "status=%s outcome=%s elapsed=%s child=%s parent=%s child_alive_at_return=%s\n" \
                "$RUN_STATUS" "$RUN_OUTCOME" "$(( end - start ))" "${child:-NONE}" "${parent:-NONE}" "$alive"
        ')"
        child="$(sed -n 's/.* child=\([^ ]*\) .*/\1/p' <<< "$probe")"
        parent="$(sed -n 's/.* parent=\([^ ]*\) .*/\1/p' <<< "$probe")"
        [[ "$child" =~ ^[0-9]+$ && "$parent" =~ ^[0-9]+$ ]] ||
            _fail "${label}: the command and its child must start" "probe: ${probe}"
        printf '%s\n%s\n' "$parent" "$child" >> "${workspace}/fake_pids"
        assert_contains "$probe" "child_alive_at_return=NO" \
            "${label}: the TERM-ignoring child stops before run_bounded returns"
        assert_contains "$probe" "status=124 outcome=TIMEOUT " "${label}: the result is still a timeout"
        ab_assert_fakes_stopped "$workspace" "$label"
        # SIGKILL comes at the end of the one kill grace that follows SIGTERM
        # at the limit. A late command exit starts no second grace.
        limit="$(awk -F '\t' '$2 == "term-ignoring" { print $4 }' "${workspace}/evidence/commands.tsv")"
        elapsed="$(sed -n 's/.* elapsed=\([0-9]*\) .*/\1/p' <<< "$probe")"
        if [[ ! "$limit" =~ ^[0-9]+$ || ! "$elapsed" =~ ^[0-9]+$ ]] \
           || (( elapsed < limit + 5 - 1 || elapsed > limit + 5 + 1 )); then
            _fail "${label}: SIGKILL must come at the end of the one 5-second kill grace" \
                  "limit: ${limit}, elapsed: ${elapsed}"
        fi
        assert_contains "$(cat "${workspace}/evidence/commands.tsv")" "	124	TIMEOUT	" \
            "${label}: the command record shows the timeout"
    done

    for delay in 0 4; do
        # The diagnostic step: a blocked blockMesh exits on SIGTERM, and its
        # child ignores SIGTERM. The child writes a survivor file if it is
        # alive when the manifest appears, after run_bounded returned.
        label="S54 (step, exit ${delay} s after SIGTERM)"
        workspace="$(new_workspace "s54_step_${delay}")"
        ab_diag_fixture "$workspace"
        run="$(ab_diag_run "$workspace" FAKE_HANG_IGNORE_TERM=blockMesh FAKE_HANG_EXIT_DELAY="$delay" \
               DIAG_ACTIVE_DEADLINE="$(( $(date +%s) + 12 ))")"
        dir="$(ab_diag_dir "$workspace")"
        assert_eq "INCONCLUSIVE_TIMEOUT" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
            "${label}: the result class stays INCONCLUSIVE_TIMEOUT"
        assert_eq "blockMesh" "$(ab_diag_value "$workspace" DIAG_STOP_POINT)" "${label}: the run stops at blockMesh"
        assert_file_missing "${workspace}/fake_pids.survivor" \
            "${label}: the TERM-ignoring child stops before run_bounded returns"
        ab_assert_fakes_stopped "$workspace" "$label"
        end="$(ab_diag_value "$workspace" DIAG_ACTIVE_END)"
        deadline="$(ab_diag_value "$workspace" DIAG_ACTIVE_DEADLINE)"
        if [[ ! "$end" =~ ^[0-9]+$ || ! "$deadline" =~ ^[0-9]+$ ]] || (( end > deadline + 1 )); then
            _fail "${label}: the cleanup must end at the active-work deadline" "end: ${end}, deadline: ${deadline}"
        fi
        assert_not_contains "$(ab_diag_calls "$workspace")" "decomposePar" "${label}: no command runs after the timeout"
        assert_contains "$run" "package=0 " "${label}: the package step ends with status 0"
        assert_contains "$run" "summary=0" "${label}: the summary step ends with status 0"
        assert_file_exists "${dir}/upload/result.env" "${label}: the upload holds the result"
        assert_contains "$(cat "${workspace}/step_summary")" '| Result | `INCONCLUSIVE_TIMEOUT` |' \
            "${label}: the job summary shows the timeout"
    done
}

s55_capture_cleanup_stays_in_the_reserve() {
    local workspace run end deadline label="S55 (VTP hash, exit 4 s after SIGTERM)"
    # capture_op uses the same cleanup function (PR #94 review 5404512470).
    # The blocked hash call is the direct child of timeout. It exits 4 seconds
    # after SIGTERM, near the end of the first kill grace, and its child
    # ignores SIGTERM.
    workspace="$(new_workspace s55_capture_late_exit)"
    ab_diag_fixture "$workspace"
    run="$(ab_capture_window_run "$workspace" FAKE_SLOW_HASH="$AB_CAPTURE_VTP" FAKE_SLOW_IGNORE_TERM=1 \
           FAKE_SLOW_EXIT_DELAY=4)"
    ab_assert_capture_stop "$workspace" "$run" INCONCLUSIVE_CAPTURE_TIMEOUT SPATIAL_CAPTURE vtp-hash \
        "${AB_DIAG_FLOW}/postProcessing/1/concaveCells/concaveCells.vtp" "$label"
    assert_file_missing "${workspace}/fake_pids.survivor" \
        "${label}: the TERM-ignoring child is gone before the operation returns"
    ab_assert_fakes_stopped "$workspace" "$label"
    end="$(ab_diag_value "$workspace" DIAG_ACTIVE_END)"
    deadline="$(ab_diag_value "$workspace" DIAG_ACTIVE_DEADLINE)"
    if [[ ! "$end" =~ ^[0-9]+$ || ! "$deadline" =~ ^[0-9]+$ ]] || (( end > deadline + 1 )); then
        _fail "${label}: the cleanup must stay inside the kill reserve" "end: ${end}, deadline: ${deadline}"
    fi

    # A hash that completes at once but leaves a child that ignores SIGTERM.
    # The cleanup gives the child at most the 5-second kill grace, not the rest
    # of the active window, so the diagnostic continues inside the window.
    label="S55 (VTP hash completes and leaves a child)"
    workspace="$(new_workspace s55_capture_leftover_child)"
    ab_diag_fixture "$workspace"
    run="$(ab_diag_run "$workspace" "${AB_DIAG_CONCAVE[@]}" FAKE_LEAVE_CHILD_HASH="$AB_CAPTURE_VTP" \
           DIAG_ACTIVE_DEADLINE="$(( $(date +%s) + 25 ))")"
    assert_contains "$(cat "${workspace}/diagnostic.out")" "capture vtp-hash: COMPLETED" \
        "${label}: the hash completes"
    assert_contains "$(cat "${workspace}/diagnostic.out")" "stopped with SIGKILL" \
        "${label}: the cleanup stops the remaining child"
    assert_file_missing "${workspace}/fake_pids.survivor" \
        "${label}: the TERM-ignoring child is gone before the operation returns"
    ab_assert_fakes_stopped "$workspace" "$label"
    assert_eq "COMPLETE" "$(ab_diag_value "$workspace" SPATIAL_CAPTURE)" "${label}: the capture is complete"
    assert_eq "FIRST_CONCAVITY_AT_REFINED_MESH" "$(ab_diag_value "$workspace" DIAG_RESULT)" \
        "${label}: the diagnostic class stands"
    assert_contains "$(ab_diag_calls "$workspace")" "reconstructParMesh -time 1" "${label}: the diagnostic continues"
}

# ---- S56 to S67: the M3 mean-speed fixture validation (Issue #80) ------------
#
# The workflow openfoam-m3-metric-validation.yml validates the exact v2512
# mean-speed command on a synthetic two-cell Case (Architect contract
# 6043302440, correction 6043318728). These checks run its extracted steps
# with fake system commands and a fake OpenFOAM tree. The fake simpleFoam
# calculates sum(V_i |U_i|) / sum(V_i) from the generated fixture mesh and U
# field, and writes the v2512 volFieldValue file under the Case start time.
# No check installs OpenFOAM, runs a solver, or dispatches a workflow.

METRIC_WORKFLOW="${REPO_ROOT}/.github/workflows/openfoam-m3-metric-validation.yml"

# The fake workflow commit. The dispatch input must equal it.
AB_METRIC_SHA="6f198977b700a2bcb664bcc704a3d506eefb67ab"

# GitHub runs each `shell: bash` step as `bash --noprofile --norc -eo pipefail
# {0}`, so the checks run each extracted step the same way.
AB_STEP_BASH=(bash --noprofile --norc -eo pipefail)

# The exact command vector of the Architect contract, as the workflow text.
AB_METRIC_COMMAND="simpleFoam -case \"\$CASE_DIR\" -postProcess -time \"\$SELECTED_TIME\" -fields '(U)' -dict \"\$TASK_TEMP/config/metric-functions\""

# The exact function block of the Architect contract (comment 6043302440).
AB_METRIC_FUNCTIONS='functions
{
    m3MagU
    {
        type    mag;
        libs    (fieldFunctionObjects);
        field   U;
        result  m3MagU;
    }

    m3MeanSpeed
    {
        type            volFieldValue;
        libs            (fieldFunctionObjects);
        fields           (m3MagU);
        operation        volAverage;
        regionType       all;
        region           region0;
        writeToFile      true;
        writeFields      false;
        writePrecision   17;
        log              true;
    }
}'

# ab_metric_write_mesh_awk <file> - an awk program that reads an ASCII
# OpenFOAM polyMesh (points, faces, owner, neighbour) and one volVectorField.
# It prints each cell volume (divergence theorem with the face centres and the
# area vectors of planar quadrilateral faces) and speed, the number of
# boundary faces that point out of their cell, the total volume, and the mean
# speed sum(V_i |U_i|) / sum(V_i). Variables: dir (the Case) and field.
ab_metric_write_mesh_awk() {
    cat > "$1" <<'MESH_AWK'
function body(file, out,    line, n, inside) {
    n = 0; inside = 0
    while ((getline line < file) > 0) {
        if (!inside) { if (line ~ /^\($/) inside = 1; continue }
        if (line ~ /^\)$/) break
        out[n++] = line
    }
    close(file)
    return n
}
BEGIN {
    np = body(dir "/constant/polyMesh/points", praw)
    for (i = 0; i < np; i++) {
        s = praw[i]; gsub(/[()]/, "", s); split(s, c, " ")
        px[i] = c[1]; py[i] = c[2]; pz[i] = c[3]
    }
    nf = body(dir "/constant/polyMesh/faces", fraw)
    for (f = 0; f < nf; f++) {
        s = fraw[f]; sub(/^[0-9]+\(/, "", s); sub(/\)$/, "", s)
        fn[f] = split(s, v, " ")
        for (k = 1; k <= fn[f]; k++) fv[f, k - 1] = v[k]
    }
    no = body(dir "/constant/polyMesh/owner", oraw)
    nn = body(dir "/constant/polyMesh/neighbour", nraw)
    cells = 0
    for (f = 0; f < no; f++) { own[f] = oraw[f] + 0; if (own[f] + 1 > cells) cells = own[f] + 1 }
    for (f = 0; f < nn; f++) { nei[f] = nraw[f] + 0; if (nei[f] + 1 > cells) cells = nei[f] + 1 }
    for (f = 0; f < nf; f++) {
        a = fv[f, 0]; b = fv[f, 1]; q = fv[f, 2]; d = fv[f, 3]
        d1x = px[q] - px[a]; d1y = py[q] - py[a]; d1z = pz[q] - pz[a]
        d2x = px[d] - px[b]; d2y = py[d] - py[b]; d2z = pz[d] - pz[b]
        sx[f] = 0.5 * (d1y * d2z - d1z * d2y)
        sy[f] = 0.5 * (d1z * d2x - d1x * d2z)
        sz[f] = 0.5 * (d1x * d2y - d1y * d2x)
        cx[f] = (px[a] + px[b] + px[q] + px[d]) / 4
        cy[f] = (py[a] + py[b] + py[q] + py[d]) / 4
        cz[f] = (pz[a] + pz[b] + pz[q] + pz[d]) / 4
        flux = (cx[f] * sx[f] + cy[f] * sy[f] + cz[f] * sz[f]) / 3
        vol[own[f]] += flux
        mx[own[f]] += cx[f]; my[own[f]] += cy[f]; mz[own[f]] += cz[f]; m[own[f]]++
        if (f < nn) {
            vol[nei[f]] -= flux
            mx[nei[f]] += cx[f]; my[nei[f]] += cy[f]; mz[nei[f]] += cz[f]; m[nei[f]]++
        }
    }
    outward = 0
    for (f = nn; f < nf; f++) {
        o = own[f]
        if ((cx[f] - mx[o] / m[o]) * sx[f] + (cy[f] - my[o] / m[o]) * sy[f] \
            + (cz[f] - mz[o] / m[o]) * sz[f] > 0) outward++
    }
    while ((getline line < field) > 0) {
        if (line !~ /^internalField[ \t]+nonuniform/) continue
        sub(/^[^(]*\(/, "", line); sub(/\);[ \t]*$/, "", line); gsub(/[()]/, " ", line)
        nu = split(line, u, " ")
    }
    close(field)
    total = 0; weighted = 0
    for (i = 0; i < cells; i++) {
        speed = sqrt(u[3 * i + 1] ^ 2 + u[3 * i + 2] ^ 2 + u[3 * i + 3] ^ 2)
        total += vol[i]; weighted += vol[i] * speed
        printf "cell %d volume %.17g speed %.17g\n", i, vol[i], speed
    }
    printf "faces %d internal %d outward %d values %d\n", nf, nn, outward, nu
    printf "total %.17g mean %.17g\n", total, weighted / total
}
MESH_AWK
}

# ab_metric_write_fake <file> <mesh-awk> - the one fake command of the metric
# checks. The command name comes from $0. Each call appends one line to
# METRIC_FAKE_CALLS: name, working directory, and each argument, separated by
# tabs. The OpenFOAM fakes read the generated fixture: foamListTimes prints
# its latest time, checkMesh prints its cell count and volumes in the v2512
# format, and simpleFoam calculates the mean speed and writes the
# volFieldValue file under the start time of the fixture control dictionary
# (v2512 Time::setControls and writeFile::newFileAtStartTime). Each FAKE_*
# value selects one fault.
ab_metric_write_fake() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'MESH_AWK=%q\n' "$2"
        cat <<'METRIC_FAKE'
set -u
name="${0##*/}"
record="${name}"$'\t'"${PWD}"
for argument in "$@"; do record+=$'\t'"${argument}"; done
printf '%s\n' "$record" >> "$METRIC_FAKE_CALLS"
after() { local want="$1" a previous=""; shift; for a in "$@"; do [[ "$previous" == "$want" ]] && { printf '%s' "$a"; return 0; }; previous="$a"; done; return 1; }
for entry in ${FAKE_FAIL:-}; do
    [[ "$entry" == "$name" ]] && { echo "fake ${name}: forced failure" >&2; exit 1; }
done
for entry in ${FAKE_BLOCK:-}; do
    if [[ "$entry" == "$name" ]]; then
        printf '%s\n' "$$" >> "$METRIC_FAKE_PIDS"
        exec sleep 300
    fi
done
case "$name" in
    curl) exit 0 ;;
    sudo)
        # The fake install runs nothing, but the process control is real: sudo
        # -n kill and the sudo -n sh process scan run. FAKE_SUDO=deny refuses
        # them, as sudo without root access does. FAKE_SUDO=user runs them
        # without root, so the /proc entries of root processes stay unreadable.
        # FAKE_SUDO=slow hangs: it ignores SIGTERM, writes its PID, and runs
        # nothing. By default the scan has the root view: the unreadable
        # entries drop out, because no root process of the test host uses a
        # test directory.
        [[ "${1:-}" == -n ]] && shift
        case "${1:-}" in
            kill|sh)
                case "${FAKE_SUDO:-root}" in
                    deny) echo "sudo: a password is required" >&2; exit 1 ;;
                    user) exec "$@" ;;
                    slow)
                        printf '%s\n' "$$" >> "$METRIC_FAKE_PIDS"
                        trap '' TERM
                        exec sleep 300 ;;
                esac
                [[ "$1" == kill ]] && exec "$@"
                "$@" | grep -v ': Permission denied$'
                exit "${PIPESTATUS[0]}" ;;
            apt-get)
                # FAKE_ROOT_CHILD=<file>: the install leaves a process that
                # ignores SIGTERM in the operation group, as a root process of
                # apt-get can, writes its PID to the file, and blocks.
                if [[ "${2:-}" == install && -n "${FAKE_ROOT_CHILD:-}" ]]; then
                    ( trap '' TERM; exec sleep 300 ) < /dev/null > /dev/null 2>&1 &
                    printf '%s\n' "$!" > "$FAKE_ROOT_CHILD"
                    exec sleep 300
                fi ;;
        esac
        exit 0 ;;
    dpkg-query)
        case "${!#}" in
            openfoam2512-default) printf '%s' "${FAKE_PACKAGE_VERSION-2512.0-2}" ;;
            openfoam2512) printf '%s' "${FAKE_CORE_VERSION-2512.0-2}" ;;
            *) exit 1 ;;
        esac
        exit 0 ;;
    gcc) echo 13.3.0; exit 0 ;;
    uname)
        [[ "$*" == -m ]] && { echo "${FAKE_ARCH-x86_64}"; exit 0; }
        PATH=/usr/bin:/bin exec uname "$@" ;;
    tar) PATH=/usr/bin:/bin exec tar "$@" ;;
esac
case_dir="$(after -case "$@")"
time="$(after -time "$@")"
latest() {
    find "$case_dir" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended -regex '.*/[0-9]+([.][0-9]+)?' \
        -printf '%f\n' | sort -g | tail -n 1
}
# mesh <time> - "cells min max total mean" of the fixture at one time.
mesh() {
    awk -v dir="$case_dir" -v field="${case_dir}/$1/U" -f "$MESH_AWK" | awk '
        $1 == "cell" { n++; v = $4 + 0; if (n == 1 || v < min) min = v; if (n == 1 || v > max) max = v }
        $1 == "total" { total = $2; mean = $4 }
        END { printf "%d %.6g %.6g %s %s\n", n, min, max, total, mean }'
}
tamper() {
    local entry
    for entry in ${FAKE_TAMPER:-}; do
        [[ "${entry%%:*}" == "$name" ]] || continue
        case "${entry#*:}" in
            remove-U) rm -f -- "${case_dir}/2/U" ;;
            link-U) mv -- "${case_dir}/2/U" "${case_dir}/2/U.real" && ln -s U.real "${case_dir}/2/U" ;;
            edit-U) printf '\n' >> "${case_dir}/2/U" ;;
            edit-earlier-U) printf '\n' >> "${case_dir}/1/U" ;;
            make-output)
                mkdir -p "${case_dir}/postProcessing/m3MeanSpeed/2"
                : > "${case_dir}/postProcessing/m3MeanSpeed/2/volFieldValue.dat" ;;
        esac
    done
}
case "$name" in
    foamListTimes)
        if [[ -n "${FAKE_LIST_TIMES+set}" ]]; then
            printf '%b' "$FAKE_LIST_TIMES"
        else
            latest
        fi ;;
    checkMesh)
        read -r cells min max total mean <<< "$(mesh "$time")"
        cells="${FAKE_CELLS-$cells}"
        cat <<CHECK_LOG
Create time

Create mesh for time = ${time}

Check mesh...

Time = ${time}

Mesh stats
    points:           12
    faces:            11
    internal faces:   1
    cells:            ${cells}
    faces per cell:   6
    boundary patches: 1
    point zones:      0
    face zones:       0
    cell zones:       0

Overall number of cells of each type:
    hexahedra:     ${cells}
    polyhedra:     0

Checking topology...
    Boundary definition OK.
    Cell to face addressing OK.
    Point usage OK.
    Upper triangular ordering OK.
    Face vertices OK.
    Number of regions: 1 (OK).

Checking geometry...
    Overall domain bounding box (0 0 0) (3 1 1)
    Boundary openness (0 0 0) OK.
    Max aspect ratio = 2 OK.
    Minimum face area = 1. Maximum face area = 2.  Face area magnitudes OK.
CHECK_LOG
        if [[ -n "${FAKE_NEGATIVE_VOLUME:-}" ]]; then
            echo " ***Zero or negative cell volume detected.  Minimum negative volume: -1, Number of negative volume cells: 1"
        elif [[ -z "${FAKE_NO_VOLUME_LINE:-}" ]]; then
            printf '    Min volume = %s. Max volume = %s.  Total volume = %s.  Cell volumes OK.\n' \
                "${FAKE_MIN_VOLUME-$min}" "${FAKE_MAX_VOLUME-$max}" "${FAKE_TOTAL_VOLUME-$(printf '%.6g' "$total")}"
        fi
        printf '    Mesh non-orthogonality Max: 0 average: 0\n    Face pyramids OK.\n\nMesh OK.\n\nEnd\n\n' ;;
    simpleFoam)
        # FAKE_TERM_CHILD=<file>: leave a child that ignores SIGTERM, write its
        # PID to the file, and block.
        if [[ -n "${FAKE_TERM_CHILD:-}" ]]; then
            ( trap '' TERM; exec sleep 300 ) < /dev/null > /dev/null 2>&1 &
            printf '%s\n' "$!" > "$FAKE_TERM_CHILD"
            exec sleep 300
        fi
        dict="$(after -dict "$@")"
        [[ -f "$dict" ]] || { echo "fake simpleFoam: cannot open ${dict}" >&2; exit 1; }
        # FAKE_TOUCH_FILE=<file>: change one byte stream during the calculation.
        if [[ -n "${FAKE_TOUCH_FILE:-}" ]]; then
            printf '\n' >> "$FAKE_TOUCH_FILE"
        fi
        # FAKE_ESCAPE=<file>: a process that leaves the operation group and keeps
        # its working directory in the Case; its PID goes to the file.
        if [[ -n "${FAKE_ESCAPE:-}" ]]; then
            ( cd -- "$case_dir" && exec setsid sleep 60 ) < /dev/null > /dev/null 2>&1 &
            printf '%s\n' "$!" > "$FAKE_ESCAPE"
        fi
        # FAKE_BIG_FILE=<bytes>: a sparse file of that apparent size in the Case.
        # A writer that a file limit stops ends with the status of that stop.
        if [[ -n "${FAKE_BIG_FILE:-}" ]]; then
            truncate -s "$FAKE_BIG_FILE" "${case_dir}/big.bin" || exit $?
        fi
        # FAKE_TRANSIENT_BYTES=<bytes>: a sparse file of that apparent size
        # exists for a moment; the task bytes at that moment go to
        # FAKE_TRANSIENT_RECORD.
        if [[ -n "${FAKE_TRANSIENT_BYTES:-}" ]]; then
            truncate -s "$FAKE_TRANSIENT_BYTES" "${case_dir}/transient.bin" || exit $?
            du -sb -- "${case_dir%/case}" | cut -f 1 > "$FAKE_TRANSIENT_RECORD"
            rm -f -- "${case_dir}/transient.bin"
        fi
        # FAKE_MAPPED_FILE=<file>: a process of the test user that leaves its
        # group, maps a file of the Case, closes that file, and moves its
        # working directory out of the Case. Its PID goes to the file.
        if [[ -n "${FAKE_MAPPED_FILE:-}" ]]; then
            setsid python3 -c 'import mmap, os, sys, time
fd = os.open(os.path.join(sys.argv[1], "system", "controlDict"), os.O_RDONLY)
mapped = mmap.mmap(fd, 0, prot=mmap.PROT_READ)
os.close(fd)
os.chdir("/")
print(os.getpid(), flush=True)
time.sleep(30)' "$case_dir" < /dev/null > "$FAKE_MAPPED_FILE" 2> /dev/null &
            for (( wait_tick = 0; wait_tick < 200; wait_tick++ )); do
                [[ -s "$FAKE_MAPPED_FILE" ]] && break
                sleep 0.01
            done
        fi
        # FAKE_HIDDEN_USER=<file>: a process of the test user that leaves its
        # group, keeps its working directory in the Case, and makes its /proc
        # entries unreadable (PR_SET_DUMPABLE 0). Its PID goes to the file.
        if [[ -n "${FAKE_HIDDEN_USER:-}" ]]; then
            setsid python3 -c 'import ctypes, os, sys, time
os.chdir(sys.argv[1])
if ctypes.CDLL(None).prctl(4, 0, 0, 0, 0) != 0:
    raise SystemExit(2)
print(os.getpid(), flush=True)
time.sleep(30)' "$case_dir" < /dev/null > "$FAKE_HIDDEN_USER" 2> /dev/null &
            for (( wait_tick = 0; wait_tick < 200; wait_tick++ )); do
                [[ -s "$FAKE_HIDDEN_USER" ]] && break
                sleep 0.01
            done
        fi
        start_from="$(awk '$1 == "startFrom" { sub(/;$/, "", $2); print $2 }' "${case_dir}/system/controlDict")"
        if [[ "$start_from" == latestTime ]]; then
            start="$(latest)"
        else
            start="$(awk '$1 == "startTime" { sub(/;$/, "", $2); print $2 }' "${case_dir}/system/controlDict")"
        fi
        read -r cells min max total mean <<< "$(mesh "${FAKE_VALUE_TIME:-$time}")"
        # OpenFOAM writes doubles: awk formats a double, Bash printf a long double.
        value="${FAKE_VALUE-$(awk -v m="$mean" 'BEGIN { printf "%.17e", m + 0 }')}"
        # dat <file> <rows> - the v2512 volFieldValue file with writePrecision 17.
        dat() {
            local r
            mkdir -p "${1%/*}"
            {
                printf '# %-23s: %s\n' Region "${FAKE_REGION-all region0}"
                printf '# %-23s: %s\n' Cells "${FAKE_DAT_CELLS-$cells}"
                printf '# %-23s: %s\n' Volume "${FAKE_DAT_VOLUME-$(awk -v t="$total" 'BEGIN { printf "%.17e", t + 0 }')}"
                printf '# %-23s\t%s\n' Time "${FAKE_COLUMN-volAverage(m3MagU)}"
                for (( r = 0; r < $2; r++ )); do
                    if [[ "${FAKE_OUTPUT:-}" == no-value ]]; then
                        printf '%-25s\n' "${FAKE_ROW_TIME-$time}"
                    else
                        printf '%-25s\t%s\n' "${FAKE_ROW_TIME-$time}" "$value"
                    fi
                done
            } > "$1"
        }
        output="${case_dir}/postProcessing/m3MeanSpeed/${start}/volFieldValue.dat"
        case "${FAKE_OUTPUT:-normal}" in
            none) ;;
            header-only) dat "$output" 0 ;;
            two-rows) dat "$output" 2 ;;
            two-headers) dat "$output" 1; sed -i -e '1p' "$output" ;;
            second-file) dat "$output" 1; dat "${output%.dat}_${time}.dat" 1 ;;
            other-time) dat "$output" 1; dat "${case_dir}/postProcessing/m3MeanSpeed/1/volFieldValue.dat" 1 ;;
            region-folder) dat "${case_dir}/postProcessing/region1/m3MeanSpeed/${start}/volFieldValue.dat" 1 ;;
            symlink) dat "${output%/*}/real.dat" 1; ln -s real.dat "$output" ;;
            *) dat "$output" 1 ;;
        esac
        if [[ -n "${FAKE_STDOUT_BYTES:-}" ]]; then
            head -c "$FAKE_STDOUT_BYTES" /dev/zero | tr '\0' 'x'
        else
            echo "    volAverage(region0) of m3MagU = ${value}"
        fi ;;
esac
tamper
exit 0
METRIC_FAKE
    } > "$1"
    chmod +x "$1"
}

# ab_metric_fixture <workspace> - fake system commands, a fake OpenFOAM tree,
# and the extracted workflow steps.
ab_metric_fixture() {
    local workspace="$1" name step tree
    tree="${workspace}/openfoam/openfoam2512/platforms/linux64GccDPInt32Opt/bin"
    mkdir -p "${workspace}/runner_temp" "${workspace}/tmp" "${workspace}/fakebin" \
             "${workspace}/openfoam/openfoam2512/etc" "$tree" "${workspace}/elsewhere"
    : > "${workspace}/github_env"
    : > "${workspace}/step_summary"
    : > "${workspace}/calls.tsv"
    : > "${workspace}/fake_pids"
    ab_metric_write_mesh_awk "${workspace}/mesh_metric.awk"
    ab_metric_write_fake "${workspace}/metric_fake" "${workspace}/mesh_metric.awk"
    for name in curl sudo dpkg-query gcc uname; do
        ln -s "${workspace}/metric_fake" "${workspace}/fakebin/${name}"
    done
    for name in foamListTimes checkMesh simpleFoam; do
        ln -s "${workspace}/metric_fake" "${tree}/${name}"
    done
    ln -s "${workspace}/metric_fake" "${workspace}/elsewhere/simpleFoam"
    cat > "${workspace}/openfoam/openfoam2512/etc/bashrc" <<METRIC_BASHRC
if [[ -n "\${FAKE_BASHRC_STATUS:-}" ]]; then return "\${FAKE_BASHRC_STATUS}"; fi
export WM_PROJECT_VERSION="\${FAKE_WM_VERSION-v2512}"
export WM_OPTIONS=linux64GccDPInt32Opt
export WM_COMPILER="\${FAKE_WM_COMPILER-Gcc}"
export PATH="\${FAKE_EXTRA_PATH:+\${FAKE_EXTRA_PATH}:}${tree}:\${PATH}"
METRIC_BASHRC
    ab_step_run_body "Start the validation clock" "$METRIC_WORKFLOW" > "${workspace}/clock_step.sh"
    ab_step_run_body "Run the metric validation" "$METRIC_WORKFLOW" > "${workspace}/run_step.sh"
    ab_step_run_body "Package the validation evidence" "$METRIC_WORKFLOW" > "${workspace}/package_step.sh"
    ab_step_run_body "Remove the task directory" "$METRIC_WORKFLOW" > "${workspace}/cleanup_step.sh"
    for step in clock run package cleanup; do
        [[ -s "${workspace}/${step}_step.sh" ]] ||
            _fail "S56: the ${step} step body must be extracted from the metric workflow"
        bash -n "${workspace}/${step}_step.sh" || _fail "S56: the extracted ${step} step must parse"
    done
}

# ab_metric_base <workspace> - the runner environment of every step.
ab_metric_base() {
    printf '%s\n' "PATH=${1}/fakebin:${PATH}" "TMPDIR=${1}/tmp" "RUNNER_TEMP=${1}/runner_temp" \
        "GITHUB_ENV=${1}/github_env" "GITHUB_STEP_SUMMARY=${1}/step_summary" "GITHUB_SHA=${AB_METRIC_SHA}" \
        "GITHUB_REF=refs/heads/main" "GITHUB_RUN_ID=4343" "EXPECTED_MAIN_SHA=${AB_METRIC_SHA}" \
        "METRIC_FAKE_CALLS=${1}/calls.tsv" "METRIC_FAKE_PIDS=${1}/fake_pids"
}

# ab_metric_run <workspace> [NAME=value ...] - run the extracted clock,
# validation, and package steps in order. Values published through GITHUB_ENV
# reach the later steps, as on the runner. The arguments override them, and
# OPENFOAM_ROOT selects the fake OpenFOAM tree. Prints the validation step
# status, its elapsed seconds, and the package step status.
ab_metric_run() {
    local workspace="$1" start elapsed status package base=() published=()
    shift
    mapfile -t base < <(ab_metric_base "$workspace")
    env "${base[@]}" "${AB_STEP_BASH[@]}" "${workspace}/clock_step.sh" > "${workspace}/clock.out" 2>&1 ||
        _fail "S56: the clock step must succeed"
    mapfile -t published < <(grep -E '^[A-Z_][A-Z0-9_]*=' "${workspace}/github_env")
    start="$(date +%s)"
    env "${base[@]}" "${published[@]}" OPENFOAM_ROOT="${workspace}/openfoam" "$@" \
        "${AB_STEP_BASH[@]}" "${workspace}/run_step.sh" > "${workspace}/run.out" 2>&1 && status=0 || status=$?
    elapsed=$(( $(date +%s) - start ))
    env "${base[@]}" "${published[@]}" "$@" "${AB_STEP_BASH[@]}" "${workspace}/package_step.sh" \
        > "${workspace}/package.out" 2>&1 && package=0 || package=$?
    printf 'status=%s elapsed=%s package=%s\n' "$status" "$elapsed" "$package"
}

# ab_metric_package <workspace> [NAME=value ...] - run the extracted package
# step again. Prints its status.
ab_metric_package() {
    local workspace="$1" status base=() published=()
    shift
    mapfile -t base < <(ab_metric_base "$workspace")
    mapfile -t published < <(grep -E '^[A-Z_][A-Z0-9_]*=' "${workspace}/github_env")
    env "${base[@]}" "${published[@]}" "$@" "${AB_STEP_BASH[@]}" "${workspace}/package_step.sh" \
        > "${workspace}/package.out" 2>&1 && status=0 || status=$?
    printf '%s\n' "$status"
}

# ab_metric_cleanup <workspace> [NAME=value ...] - run the extracted cleanup
# and summary step. Prints its status.
ab_metric_cleanup() {
    local workspace="$1" status base=() published=()
    shift
    mapfile -t base < <(ab_metric_base "$workspace")
    mapfile -t published < <(grep -E '^[A-Z_][A-Z0-9_]*=' "${workspace}/github_env")
    env "${base[@]}" "${published[@]}" "$@" "${AB_STEP_BASH[@]}" "${workspace}/cleanup_step.sh" \
        > "${workspace}/cleanup.out" 2>&1 && status=0 || status=$?
    printf '%s\n' "$status"
}

# ab_metric_root <workspace> - the unique task directory of the last run.
ab_metric_root() {
    ab_file_value "${1}/github_env" METRIC_TASK_ROOT
}

# ab_metric_task <workspace> - the m3-mean-speed-validation directory.
ab_metric_task() {
    ab_file_value "${1}/github_env" METRIC_TASK_TEMP
}

# ab_metric_value <workspace> <key> - one value of the uploaded result file.
ab_metric_value() {
    ab_file_value "$(ab_metric_root "$1")/upload/result.env" "$2"
}

# ab_metric_calls <workspace> - the fake calls, one per line: name, then the
# arguments, separated by single spaces.
ab_metric_calls() {
    awk -F '\t' '{ line = $1; for (i = 3; i <= NF; i++) line = line " " $i; print line }' "${1}/calls.tsv"
}

# ab_metric_count <workspace> <name> - the number of calls of one fake command.
ab_metric_count() {
    awk -F '\t' -v name="$2" '$1 == name' "${1}/calls.tsv" | wc -l
}

# ab_metric_library <workspace> - the validation script without its final
# mode selection: the constants, the state, and every function.
ab_metric_library() {
    awk '/<<.METRIC_VALIDATION.$/ { inside = 1; next } /^METRIC_VALIDATION$/ { inside = 0 } inside' \
        "${1}/run_step.sh" | awk '/^case "\$\{1:-\}" in$/ { exit } { print }'
}

# ab_metric_expect <label> <result> <stop-point> [NAME=value ...] - one run in
# a new workspace. @WORKSPACE@ in a value names that workspace. The uploaded
# result and the stop point must match, the validation step must fail, and
# the package step must complete. Sets AB_METRIC_LAST to the workspace.
ab_metric_expect() {
    local label="$1" result="$2" point="$3" workspace run argument arguments=()
    shift 3
    workspace="$(new_workspace "${label//[^A-Za-z0-9_.-]/_}")"
    ab_metric_fixture "$workspace"
    for argument in "$@"; do
        arguments+=("${argument//@WORKSPACE@/${workspace}}")
    done
    run="$(ab_metric_run "$workspace" "${arguments[@]}")"
    [[ "$(ab_metric_value "$workspace" METRIC_RESULT)" == "$result" ]] ||
        _fail "${label}: the result must be ${result}" "actual: $(ab_metric_value "$workspace" METRIC_RESULT)" \
              "reason: $(ab_metric_value "$workspace" METRIC_REASON)" "$(tail -n 5 "${workspace}/run.out")"
    assert_eq "$point" "$(ab_metric_value "$workspace" METRIC_STOP_POINT)" "${label}: the stop point"
    assert_contains "$run" "status=1 " "${label}: the validation step fails"
    assert_contains "$run" "package=0" "${label}: the package step completes"
    assert_file_exists "$(ab_metric_root "$workspace")/upload/m3-metric-validation-evidence.tar.gz" \
        "${label}: the evidence archive is uploaded"
    AB_METRIC_LAST="$workspace"
}

# ab_metric_no_command <workspace> <label> <name>... - no call of each name.
ab_metric_no_command() {
    local workspace="$1" label="$2" name
    shift 2
    for name in "$@"; do
        assert_eq "0" "$(ab_metric_count "$workspace" "$name")" "${label}: no ${name} call"
    done
}

# ab_metric_step_timeout <step-name> - the timeout-minutes value of one step.
ab_metric_step_timeout() {
    awk -v want="      - name: $1" '
        $0 == want { found = 1; next }
        found && /^      - name: / { exit }
        found && /^        timeout-minutes: [0-9]+[[:space:]]*$/ { print $2; exit }
    ' "$METRIC_WORKFLOW"
}

s56_metric_workflow_interface() {
    local workflow script workspace step minutes total=0 job window first second name constant
    assert_file_exists "$METRIC_WORKFLOW" "S56: the metric workflow exists"
    workflow="$(cat "$METRIC_WORKFLOW")"
    # workflow_dispatch with one required input is the only trigger.
    assert_eq $'on:\n  workflow_dispatch:\n    inputs:\n      expected_main_sha:\n        description: The exact main commit SHA of the Architect execution admission\n        required: true\n        type: string' \
        "$(awk '/^on:/ { on = 1; print; next } on && /^[^ ]/ { exit } on && NF { print }' "$METRIC_WORKFLOW")" \
        "S56: workflow_dispatch with the required expected_main_sha input is the only trigger"
    assert_contains "$workflow" $'permissions:\n  contents: read' "S56: the token can only read contents"
    assert_contains "$workflow" "runs-on: ubuntu-24.04" "S56: the job runs on ubuntu-24.04"
    assert_contains "$workflow" $'    defaults:\n      run:\n        shell: bash\n' \
        "S56: each step runs as bash -eo pipefail, as the checks run it"
    assert_contains "$workflow" "EXPECTED_MAIN_SHA: \${{ inputs.expected_main_sha }}" \
        "S56: the input reaches the validation step only as an environment value"
    assert_not_contains "$workflow" "continue-on-error" "S56: no step continues after an error"
    assert_not_contains "$workflow" "actions/checkout" "S56: the fixture needs no checkout"
    # The upload holds only the package.
    assert_contains "$workflow" "uses: actions/upload-artifact@v4" "S56: the evidence is uploaded"
    assert_contains "$workflow" "name: m3-metric-validation-evidence" "S56: the artifact name"
    assert_contains "$workflow" "path: \${{ env.METRIC_TASK_ROOT }}/upload" "S56: only the package is uploaded"
    assert_contains "$workflow" "if-no-files-found: error" "S56: a missing package fails the upload"
    assert_contains "$workflow" "retention-days: 90" "S56: the artifact is kept for 90 days"
    # batch-contract runs for the new workflow on push and on pull_request.
    assert_eq "2" "$(grep -c "^      - '.github/workflows/openfoam-m3-metric-validation.yml'$" "$CONTRACT_WORKFLOW")" \
        "S56: both batch-contract path filters name the metric workflow"
    # The exact contract command, once, and the contract limits.
    workspace="$(new_workspace s56_interface)"
    ab_metric_fixture "$workspace"
    script="$(awk '/<<.METRIC_VALIDATION.$/ { inside = 1; next } /^METRIC_VALIDATION$/ { inside = 0 } inside' \
        "${workspace}/run_step.sh")"
    [[ -n "$script" ]] || _fail "S56: the validation script must be extracted"
    bash -n <<< "$script" || _fail "S56: the validation script must parse"
    assert_eq "1" "$(grep -cF -- "$AB_METRIC_COMMAND" <<< "$script")" "S56: the exact contract command appears once"
    assert_eq "1" "$(grep -cE '^[[:space:]]*simpleFoam[[:space:]]' <<< "$script")" \
        "S56: the script runs simpleFoam in one place"
    assert_eq "0" "$(grep -cE '^[[:space:]]*(postProcess|foamPostProcess|foamDictionary)[[:space:]]' <<< "$script")" \
        "S56: the script runs no other post-processing command"
    for constant in 'PACKAGE="openfoam2512-default"' 'PACKAGE_VERSION="2512.0-2"' 'PROJECT_VERSION="v2512"' \
                    'ARCHITECTURE="x86_64"' 'KILL_GRACE=5' 'INSTALL_CAP=180' 'OPENFOAM_CAP=60' \
                    'OPENFOAM_BUDGET=240' 'PHASE_CAP=30' 'LOG_LIMIT=1048576' 'LOGS_LIMIT=8388608' \
                    'ARTIFACT_LIMIT=10485760' 'EXPECTED_VALUE="11/3"' 'TOLERANCE=1e-6' 'REGION="region0"' \
                    'EXPECTED_REF="refs/heads/main"'; do
        assert_eq "1" "$(grep -cx -- "$constant" <<< "$script")" "S56: the script sets ${constant}"
    done
    # The time limits: a 10-minute job, five step guards with a one-minute
    # margin, and an active window inside the validation step guard.
    job="$(awk '/^    timeout-minutes: [0-9]+[[:space:]]*$/ { print $2; exit }' "$METRIC_WORKFLOW")"
    assert_eq "10" "$job" "S56: the hard job timeout is 10 minutes"
    for step in "Start the validation clock" "Run the metric validation" "Package the validation evidence" \
                "Upload the validation evidence" "Remove the task directory"; do
        minutes="$(ab_metric_step_timeout "$step")"
        [[ "$minutes" =~ ^[0-9]+$ ]] || { _fail "S56: the step '${step}' must have a timeout"; minutes=0; }
        total=$(( total + minutes ))
    done
    (( total + 1 <= job )) || _fail "S56: the step timeouts must leave a one-minute job margin" "steps: ${total} min"
    env RUNNER_TEMP="${workspace}/runner_temp" GITHUB_ENV="${workspace}/github_env" \
        "${AB_STEP_BASH[@]}" "${workspace}/clock_step.sh" > /dev/null 2>&1 || _fail "S56: the clock step must succeed"
    first="$(ab_metric_root "$workspace")"
    window=$(( $(ab_file_value "${workspace}/github_env" METRIC_ACTIVE_DEADLINE) - \
               $(ab_file_value "${workspace}/github_env" METRIC_CLOCK_START) ))
    assert_eq "290" "$window" "S56: the active work ends 290 seconds after the clock starts"
    (( window <= $(ab_metric_step_timeout "Run the metric validation") * 60 )) ||
        _fail "S56: the validation step guard must not stop the work before the active-work deadline"
    # The worst case: the clock guard, the window, the package budget, the
    # upload guard, and the cleanup budget stay inside the job limit.
    (( 60 + window + 30 + 60 + 30 <= job * 60 )) || _fail "S56: the worst case must fit in the job limit"
    assert_eq "/usr/lib/openfoam" "$(ab_file_value "${workspace}/github_env" OPENFOAM_ROOT)" \
        "S56: the clock step names the installed OpenFOAM root"
    # Each run gets its own unique task directory under RUNNER_TEMP.
    env RUNNER_TEMP="${workspace}/runner_temp" GITHUB_ENV="${workspace}/github_env" \
        "${AB_STEP_BASH[@]}" "${workspace}/clock_step.sh" > /dev/null 2>&1 || _fail "S56: the clock step must succeed"
    second="$(ab_metric_root "$workspace")"
    assert_ne "$first" "$second" "S56: each run has a unique task directory"
    for name in "$first" "$second"; do
        [[ "${name#"${workspace}/runner_temp/"}" =~ ^m3-metric-validation\.[A-Za-z0-9]{8}$ ]] ||
            _fail "S56: the task directory must be a unique directory directly under RUNNER_TEMP" "$name"
        assert_dir_exists "${name}/m3-mean-speed-validation/case" "S56: the task layout has case"
        assert_dir_exists "${name}/m3-mean-speed-validation/config" "S56: the task layout has config"
        assert_dir_exists "${name}/m3-mean-speed-validation/logs" "S56: the task layout has logs"
        assert_dir_exists "${name}/m3-mean-speed-validation/evidence" "S56: the task layout has evidence"
    done
    assert_eq "FAIL_NOT_STARTED" "$(ab_file_value "${second}/m3-mean-speed-validation/evidence/result.env" METRIC_RESULT)" \
        "S56: the clock step writes an early failure result"
}

s57_metric_fixture_is_two_cells_with_the_expected_mean() {
    local workspace task case_dir out expected_files actual_files mean
    workspace="$(new_workspace s57_fixture)"
    ab_metric_fixture "$workspace"
    ab_metric_run "$workspace" > /dev/null
    task="$(ab_metric_task "$workspace")"
    case_dir="${task}/case"
    # Only the synthetic fixture: no Case 7 file, mesh tool input, or STL.
    expected_files=$'case/1/U\ncase/1/p\ncase/2/U\ncase/2/p\ncase/constant/polyMesh/boundary\ncase/constant/polyMesh/faces\ncase/constant/polyMesh/neighbour\ncase/constant/polyMesh/owner\ncase/constant/polyMesh/points\ncase/constant/transportProperties\ncase/constant/turbulenceProperties\ncase/system/controlDict\ncase/system/fvSchemes\ncase/system/fvSolution\nconfig/metric-functions'
    actual_files="$(cd "$task" && find case config -type f ! -path 'case/postProcessing/*' | LC_ALL=C sort)"
    assert_eq "$expected_files" "$actual_files" "S57: the fixture has exactly the synthetic Case files"
    # The mesh: two cells, volumes 1 and 2, total 3, every boundary face out.
    out="$(awk -v dir="$case_dir" -v field="${case_dir}/2/U" -f "${workspace}/mesh_metric.awk")"
    assert_contains "$out" $'cell 0 volume 1 speed 5\ncell 1 volume 2 speed 3' \
        "S57: cell 0 has volume 1 and speed 5, and cell 1 has volume 2 and speed 3 at the latest time"
    assert_contains "$out" "faces 11 internal 1 outward 10 values 6" \
        "S57: one internal face, and each of the ten boundary faces points out of its cell"
    mean="$(awk '$1 == "total" { print $2 " " $4 }' <<< "$out")"
    awk -v t="${mean% *}" -v m="${mean#* }" 'BEGIN { d = m - 11/3; if (d < 0) d = -d; exit !(t == 3 && d <= 1e-12) }' ||
        _fail "S57: the fixture total volume is 3 and its mean speed is 11/3" "total and mean: ${mean}"
    # The earlier time gives another value, as do the two wrong formulas.
    out="$(awk -v dir="$case_dir" -v field="${case_dir}/1/U" -f "${workspace}/mesh_metric.awk")"
    mean="$(awk '$1 == "total" { print $4 }' <<< "$out")"
    awk -v m="$mean" 'BEGIN { d = m - 11/3; if (d < 0) d = -d; exit !(d > 1e-6) }' ||
        _fail "S57: the earlier time must give another mean speed" "mean: ${mean}"
    awk 'BEGIN { a = sqrt(((3 - 6) / 3) ^ 2 + (4 / 3) ^ 2); m = (5 + 3) / 2; e = 11/3
                 exit !((a - e) ^ 2 > 1e-12 && (m - e) ^ 2 > 1e-12) }' ||
        _fail "S57: the magnitude of the mean vector and the arithmetic mean must differ from 11/3"
    # The start time is the latest time, so the output is written under it.
    assert_eq "1" "$(grep -cE '^startFrom[[:space:]]+latestTime;$' "${case_dir}/system/controlDict")" \
        "S57: the fixture control dictionary starts from the latest time"
    # The dictionary: one FoamFile header, then the exact contract block.
    assert_eq "$AB_METRIC_FUNCTIONS" "$(awk '/^functions$/ { f = 1 } f' "${task}/config/metric-functions")" \
        "S57: the dictionary holds the exact contract function block"
    assert_eq "FoamFile" "$(head -n 1 "${task}/config/metric-functions")" "S57: the dictionary starts with its header"
    assert_contains "$(cat "${task}/config/metric-functions")" "    class       dictionary;" \
        "S57: the dictionary header names the dictionary class"
    # The fixture manifest records each file with its size and checksum.
    while IFS=$'\t' read -r path bytes sha; do
        [[ "$path" == path ]] && continue
        assert_eq "$(stat -c %s -- "${task}/${path}") $(ab_sha "${task}/${path}")" "${bytes} ${sha}" \
            "S57: the fixture manifest row of ${path}"
    done < "${task}/evidence/fixture.tsv"
    assert_eq "15" "$(tail -n +2 "${task}/evidence/fixture.tsv" | wc -l)" "S57: the manifest has one row for each file"
}

s58_metric_pass_records_the_complete_evidence() {
    local workspace run task root calls row labels extract file status summary
    workspace="$(new_workspace s58_pass)"
    ab_metric_fixture "$workspace"
    run="$(ab_metric_run "$workspace")"
    assert_contains "$run" "status=0 " "S58: the validation step passes"
    assert_contains "$run" "package=0" "S58: the package step completes"
    root="$(ab_metric_root "$workspace")"
    task="$(ab_metric_task "$workspace")"
    assert_eq "PASS" "$(ab_metric_value "$workspace" METRIC_RESULT)" "S58: the result is PASS"
    assert_eq "NONE" "$(ab_metric_value "$workspace" METRIC_STOP_POINT)" "S58: no stop point"
    assert_eq "$AB_METRIC_SHA" "$(ab_metric_value "$workspace" MAIN_SHA)" "S58: the main SHA"
    assert_eq "$AB_METRIC_SHA" "$(ab_metric_value "$workspace" EXPECTED_MAIN_SHA_INPUT)" "S58: the input SHA"
    assert_eq "refs/heads/main" "$(ab_metric_value "$workspace" WORKFLOW_REF)" "S58: the ref"
    assert_eq "2512.0-2" "$(ab_metric_value "$workspace" INSTALLED_PACKAGE_VERSION)" "S58: the package version"
    assert_eq "v2512" "$(ab_metric_value "$workspace" LOADED_PROJECT_VERSION)" "S58: the project version"
    assert_eq "linux64GccDPInt32Opt" "$(ab_metric_value "$workspace" LOADED_WM_OPTIONS)" "S58: WM_OPTIONS"
    assert_eq "2" "$(ab_metric_value "$workspace" SELECTED_TIME)" "S58: the selected time is the latest time"
    assert_eq "region0" "$(ab_metric_value "$workspace" SELECTED_REGION)" "S58: the selected region"
    assert_eq "2" "$(ab_metric_value "$workspace" MESH_CELLS)" "S58: the checkMesh cell count"
    assert_eq "1 2" "$(ab_metric_value "$workspace" CELL_VOLUMES)" "S58: the cell volumes"
    assert_eq "3" "$(ab_metric_value "$workspace" MESH_TOTAL_VOLUME)" "S58: the checkMesh total volume"
    assert_eq "MESH_OK" "$(ab_metric_value "$workspace" MESH_CHECK)" "S58: the checkMesh result"
    assert_eq "YES" "$(ab_metric_value "$workspace" INPUTS_UNCHANGED)" "S58: the inputs are unchanged"
    assert_eq "$(ab_sha "${task}/case/2/U")" "$(ab_metric_value "$workspace" U_LATEST_SHA256)" "S58: the latest U hash"
    assert_eq "$(ab_sha "${task}/case/1/U")" "$(ab_metric_value "$workspace" U_EARLIER_SHA256)" "S58: the earlier U hash"
    assert_eq "$(ab_sha "${task}/config/metric-functions")" "$(ab_metric_value "$workspace" DICTIONARY_SHA256)" \
        "S58: the dictionary hash"
    assert_eq "$(stat -c %s -- "${task}/config/metric-functions")" "$(ab_metric_value "$workspace" DICTIONARY_BYTES)" \
        "S58: the dictionary size"
    assert_eq "$(printf '%q ' simpleFoam -case "${task}/case" -postProcess -time 2 -fields '(U)' -dict \
        "${task}/config/metric-functions" | sed -e 's/ $//')" "$(ab_metric_value "$workspace" METRIC_VECTOR)" \
        "S58: the exact metric command vector"
    assert_eq "postProcessing/m3MeanSpeed/2/volFieldValue.dat" "$(ab_metric_value "$workspace" OUTPUT_PATH)" \
        "S58: the exact output path"
    assert_eq "$(ab_sha "${task}/case/postProcessing/m3MeanSpeed/2/volFieldValue.dat")" \
        "$(ab_metric_value "$workspace" OUTPUT_SHA256)" "S58: the output hash"
    assert_eq "2" "$(ab_metric_value "$workspace" OUTPUT_TIME)" "S58: the output time"
    assert_eq "all region0" "$(ab_metric_value "$workspace" OUTPUT_REGION)" "S58: the output region"
    assert_eq "volAverage(m3MagU)" "$(ab_metric_value "$workspace" OUTPUT_FIELD)" "S58: the output field"
    assert_eq "2" "$(ab_metric_value "$workspace" OUTPUT_CELLS)" "S58: the output cell count"
    assert_eq "3.00000000000000000e+00" "$(ab_metric_value "$workspace" OUTPUT_VOLUME)" "S58: the output volume"
    assert_eq "3.66666666666666652e+00" "$(ab_metric_value "$workspace" OUTPUT_VALUE)" "S58: the parsed value"
    assert_eq "3.6666666666666665" "$(ab_metric_value "$workspace" EXPECTED_VALUE_DECIMAL)" "S58: the expected value"
    awk -v e="$(ab_metric_value "$workspace" ABSOLUTE_ERROR)" 'BEGIN { exit !(e + 0 <= 1e-15) }' ||
        _fail "S58: the absolute error is recorded" "$(ab_metric_value "$workspace" ABSOLUTE_ERROR)"
    assert_eq "1e-6" "$(ab_metric_value "$workspace" TOLERANCE)" "S58: the tolerance"
    for row in INSTALL_SECONDS OPENFOAM_SECONDS SETUP_SECONDS EVIDENCE_SECONDS ACTIVE_ELAPSED_SECONDS; do
        [[ "$(ab_metric_value "$workspace" "$row")" =~ ^[0-9]+$ ]] || _fail "S58: ${row} is recorded"
    done
    # The identity.
    for row in "PACKAGE=openfoam2512-default" "PACKAGE_VERSION=2512.0-2" "CORE_PACKAGE_VERSION=2512.0-2" \
               "ARCHITECTURE=x86_64" "GCC_VERSION=13.3.0" "WM_PROJECT_VERSION=v2512" "WM_COMPILER=Gcc" \
               "WM_OPTIONS=linux64GccDPInt32Opt" "OPENFOAM_BASHRC=${workspace}/openfoam/openfoam2512/etc/bashrc" \
               "PATH_simpleFoam=${workspace}/openfoam/openfoam2512/platforms/linux64GccDPInt32Opt/bin/simpleFoam"; do
        assert_contains "$(cat "${task}/evidence/identity.txt")" "$row" "S58: the identity records ${row%%=*}"
    done
    # The exact command vectors, in order, each once.
    calls="$(ab_metric_calls "$workspace" | grep -vE '^(dpkg-query|uname|gcc) ')"
    # The two sides of `curl ... | sudo bash` start together, in either order.
    calls="$(head -n 2 <<< "$calls" | LC_ALL=C sort; tail -n +3 <<< "$calls")"
    assert_eq "curl -fsSL https://dl.openfoam.com/add-debian-repo.sh
sudo bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends openfoam2512-default=2512.0-2
foamListTimes -case ${task}/case -latestTime
checkMesh -case ${task}/case -allGeometry -allTopology -time 2
simpleFoam -case ${task}/case -postProcess -time 2 -fields (U) -dict ${task}/config/metric-functions" \
        "$calls" "S58: the install pins the package version, and each OpenFOAM command runs once"
    # Each bounded operation, its class, cap, and outcome.
    labels="$(awk -F '\t' 'NR > 1 { print $2 ":" $3 ":" $4 ":" $9 }' "${task}/evidence/commands.tsv" | tr '\n' ' ')"
    assert_eq "install:INSTALL:180:COMPLETED fixture:SETUP:30:COMPLETED fixture-manifest:SETUP:30:COMPLETED copy-dictionaries:SETUP:30:COMPLETED foamListTimes:OPENFOAM:60:COMPLETED checkMesh:OPENFOAM:60:COMPLETED parse-checkMesh:EVIDENCE:30:COMPLETED hash-inputs-before:EVIDENCE:30:COMPLETED metric:OPENFOAM:60:COMPLETED hash-inputs-after:EVIDENCE:30:COMPLETED list-output:EVIDENCE:30:COMPLETED copy-output:EVIDENCE:30:COMPLETED hash-output:EVIDENCE:30:COMPLETED parse-output:EVIDENCE:30:COMPLETED " \
        "$labels" "S58: every operation is bounded and completes"
    awk -F '\t' 'NR > 1 && !($10 ~ /^[0-9]+$/ && $5 <= $4 && $7 - $6 <= $5) { bad++ } END { exit bad > 0 }' \
        "${task}/evidence/commands.tsv" || _fail "S58: each operation records its group and stays in its limit"
    # The archive: the evidence, the logs, and the dictionary only.
    extract="${workspace}/extract"
    mkdir -p "$extract"
    tar -xzf "${root}/upload/m3-metric-validation-evidence.tar.gz" -C "$extract"
    assert_eq "" "$(cd "$extract" && find . -type f | grep -vE '^\./(evidence|logs)/|^\./config/metric-functions$')" \
        "S58: the archive holds only evidence, logs, and the metric dictionary"
    assert_eq "" "$(cd "$extract" && find . -type f -name '*.vtu' -o -type f -path '*polyMesh*' -o -type f -name U -o -type f -name p)" \
        "S58: the archive holds no mesh, field, or VTU file"
    for file in controlDict fvSchemes fvSolution transportProperties turbulenceProperties; do
        assert_file_exists "${extract}/evidence/dictionaries/${file}" "S58: the archive keeps the ${file} dictionary"
    done
    cmp -s "${extract}/evidence/output/volFieldValue.dat" "${task}/case/postProcessing/m3MeanSpeed/2/volFieldValue.dat" ||
        _fail "S58: the archive keeps the exact output"
    cmp -s "${root}/upload/result.env" "${extract}/evidence/result.env" || _fail "S58: the upload result is the archive result"
    cmp -s "${root}/upload/inventory.txt" "${extract}/evidence/inventory.txt" ||
        _fail "S58: the upload inventory is the archive inventory"
    while IFS=$'\t' read -r kind bytes sha path; do
        [[ "$kind" == FILE ]] || continue
        assert_eq "${bytes} ${sha}" "$(stat -c %s -- "${extract}/${path}") $(ab_sha "${extract}/${path}")" \
            "S58: the inventory row of ${path}"
    done < "${extract}/evidence/inventory.txt"
    assert_eq "$(( $(cd "$extract" && find . -type f | wc -l) - 1 ))" \
        "$(awk -F '\t' '$1 == "FILE"' "${extract}/evidence/inventory.txt" | wc -l)" \
        "S58: the inventory lists every other archive file"
    # The cleanup and the summary.
    status="$(ab_metric_cleanup "$workspace")"
    assert_eq "0" "$status" "S58: the cleanup step passes for PASS and a completed removal"
    assert_dir_missing "$root" "S58: the cleanup removes the task directory"
    summary="$(cat "${workspace}/step_summary")"
    assert_contains "$summary" "| Result | \`PASS\` |" "S58: the summary shows the result"
    assert_contains "$summary" "| Mean speed (m/s) | 3.66666666666666652e+00 |" "S58: the summary shows the value"
    assert_contains "$summary" "| Cleanup | \`REMOVED\` |" "S58: the summary shows the cleanup"
    assert_contains "$summary" "does not accept M3" "S58: the summary states the evidence limit"
}

s59_metric_dispatch_gates() {
    local label sha upper
    upper="$(tr '[:lower:]' '[:upper:]' <<< "$AB_METRIC_SHA")"
    ab_metric_expect "S59 wrong ref" FAIL_REF dispatch GITHUB_REF=refs/heads/feat/80-m3-metric-validation
    ab_metric_no_command "$AB_METRIC_LAST" "S59 wrong ref" curl sudo foamListTimes checkMesh simpleFoam
    assert_eq "1" "$(ab_metric_cleanup "$AB_METRIC_LAST")" "S59: the job fails for a refused dispatch"
    assert_dir_missing "$(ab_metric_root "$AB_METRIC_LAST")" "S59: the cleanup still removes the task directory"
    for sha in 1111111111111111111111111111111111111111 "${AB_METRIC_SHA:0:7}" "$upper" ""; do
        label="S59 input sha '${sha}'"
        ab_metric_expect "$label" FAIL_SHA dispatch EXPECTED_MAIN_SHA="$sha"
        ab_metric_no_command "$AB_METRIC_LAST" "$label" curl sudo foamListTimes checkMesh simpleFoam
    done
}

s60_metric_package_and_environment_gates() {
    local label
    ab_metric_expect "S60 package version" FAIL_PACKAGE identity FAKE_PACKAGE_VERSION=2512.0-1
    ab_metric_no_command "$AB_METRIC_LAST" "S60 package version" foamListTimes checkMesh simpleFoam
    ab_metric_expect "S60 no package" FAIL_PACKAGE identity FAKE_FAIL=dpkg-query
    ab_metric_expect "S60 install failure" FAIL_INSTALL install FAKE_FAIL=sudo
    ab_metric_no_command "$AB_METRIC_LAST" "S60 install failure" dpkg-query foamListTimes checkMesh simpleFoam
    # A simpleFoam outside the installed tree comes first in PATH.
    for label in "FAKE_WM_VERSION=v2506" "FAKE_ARCH=aarch64" "FAKE_WM_COMPILER=Clang" "FAKE_BASHRC_STATUS=1" \
                 "FAKE_EXTRA_PATH=@WORKSPACE@/elsewhere"; do
        ab_metric_expect "S60 ${label}" FAIL_ENVIRONMENT identity "$label"
        ab_metric_no_command "$AB_METRIC_LAST" "S60 ${label}" foamListTimes checkMesh simpleFoam
    done
}

s61_metric_time_and_region_fail_closed() {
    ab_metric_expect "S61 earlier latest time" FAIL_TIME latest-time FAKE_LIST_TIMES='1\n'
    ab_metric_no_command "$AB_METRIC_LAST" "S61 earlier latest time" checkMesh simpleFoam
    ab_metric_expect "S61 two time lines" FAIL_PARSE latest-time FAKE_LIST_TIMES='1\n2\n'
    ab_metric_expect "S61 no time line" FAIL_PARSE latest-time FAKE_LIST_TIMES=''
    ab_metric_expect "S61 output time" FAIL_TIME output FAKE_ROW_TIME=1
    ab_metric_expect "S61 earlier-time values" FAIL_TOLERANCE output FAKE_VALUE_TIME=1
    assert_eq "9.33333333333333393e+00" "$(ab_metric_value "$AB_METRIC_LAST" OUTPUT_VALUE)" \
        "S61: the earlier-time values give 28/3 and fail"
    ab_metric_expect "S61 other region" FAIL_REGION output FAKE_REGION='all region1'
    ab_metric_expect "S61 cell zone" FAIL_REGION output FAKE_REGION='cellZone region0'
    ab_metric_expect "S61 region type only" FAIL_REGION output FAKE_REGION='all'
    ab_metric_expect "S61 region folder" FAIL_OUTPUT_MISSING output FAKE_OUTPUT=region-folder
}

s62_metric_mesh_evidence_fail_closed() {
    ab_metric_expect "S62 three cells" FAIL_CELL_COUNT mesh FAKE_CELLS=3
    ab_metric_no_command "$AB_METRIC_LAST" "S62 three cells" simpleFoam
    ab_metric_expect "S62 one cell" FAIL_CELL_COUNT mesh FAKE_CELLS=1
    ab_metric_expect "S62 negative volume" FAIL_CELL_VOLUME mesh FAKE_NEGATIVE_VOLUME=1
    ab_metric_expect "S62 zero volume" FAIL_CELL_VOLUME mesh FAKE_MIN_VOLUME=0
    ab_metric_expect "S62 wrong volumes" FAIL_CELL_VOLUME mesh FAKE_MIN_VOLUME=1.5 FAKE_MAX_VOLUME=1.5
    ab_metric_expect "S62 total volume" FAIL_TOTAL_VOLUME mesh FAKE_TOTAL_VOLUME=4
    ab_metric_expect "S62 no volume line" FAIL_PARSE mesh FAKE_NO_VOLUME_LINE=1
    ab_metric_expect "S62 non-finite volume" FAIL_NON_FINITE mesh FAKE_MAX_VOLUME=nan
    ab_metric_expect "S62 checkMesh failure" FAIL_COMMAND mesh FAKE_FAIL=checkMesh
    ab_metric_no_command "$AB_METRIC_LAST" "S62 checkMesh failure" simpleFoam
    ab_metric_expect "S62 output cells" FAIL_CELL_COUNT output FAKE_DAT_CELLS=3
    ab_metric_expect "S62 output volume" FAIL_TOTAL_VOLUME output FAKE_DAT_VOLUME=4.00000000000000000e+00
    ab_metric_expect "S62 output zero volume" FAIL_CELL_VOLUME output FAKE_DAT_VOLUME=0.00000000000000000e+00
    ab_metric_expect "S62 output infinite volume" FAIL_NON_FINITE output FAKE_DAT_VOLUME=inf
}

s63_metric_inputs_and_output_fail_closed() {
    ab_metric_expect "S63 missing U" FAIL_MISSING_U inputs FAKE_TAMPER=checkMesh:remove-U
    ab_metric_no_command "$AB_METRIC_LAST" "S63 missing U" simpleFoam
    ab_metric_expect "S63 linked U" FAIL_MISSING_U inputs FAKE_TAMPER=checkMesh:link-U
    ab_metric_expect "S63 changed U" FAIL_FIELD_HASH inputs FAKE_TAMPER=checkMesh:edit-U
    ab_metric_no_command "$AB_METRIC_LAST" "S63 changed U" simpleFoam
    ab_metric_expect "S63 changed earlier U" FAIL_FIELD_HASH inputs FAKE_TAMPER=checkMesh:edit-earlier-U
    ab_metric_expect "S63 U changed by the metric command" FAIL_FIELD_HASH output FAKE_TAMPER=simpleFoam:edit-U
    ab_metric_expect "S63 U removed by the metric command" FAIL_MISSING_U output FAKE_TAMPER=simpleFoam:remove-U
    ab_metric_expect "S63 output before the command" FAIL_OUTPUT_DUPLICATE metric FAKE_TAMPER=checkMesh:make-output
    ab_metric_no_command "$AB_METRIC_LAST" "S63 output before the command" simpleFoam
    ab_metric_expect "S63 no output" FAIL_OUTPUT_MISSING output FAKE_OUTPUT=none
    ab_metric_expect "S63 header only" FAIL_OUTPUT_MISSING output FAKE_OUTPUT=header-only
    ab_metric_expect "S63 two rows" FAIL_OUTPUT_DUPLICATE output FAKE_OUTPUT=two-rows
    ab_metric_expect "S63 second file" FAIL_OUTPUT_DUPLICATE output FAKE_OUTPUT=second-file
    ab_metric_expect "S63 other time folder" FAIL_OUTPUT_DUPLICATE output FAKE_OUTPUT=other-time
    ab_metric_expect "S63 linked output" FAIL_OUTPUT_MISSING output FAKE_OUTPUT=symlink
    # A failed command is not retried, and nothing runs after it.
    ab_metric_expect "S63 metric command failure" FAIL_COMMAND metric FAKE_FAIL=simpleFoam
    assert_eq "1" "$(ab_metric_count "$AB_METRIC_LAST" simpleFoam)" "S63: the failed metric command runs once"
    assert_eq "1" "$(ab_metric_count "$AB_METRIC_LAST" foamListTimes)" "S63: foamListTimes runs once"
    assert_eq "1" "$(ab_metric_count "$AB_METRIC_LAST" checkMesh)" "S63: checkMesh runs once"
    assert_eq "1" "$(ab_metric_calls "$AB_METRIC_LAST" | grep -c '^sudo apt-get install ')" "S63: the install runs once"
    assert_not_contains "$(awk -F '\t' 'NR > 1 { print $2 }' "$(ab_metric_task "$AB_METRIC_LAST")/evidence/commands.tsv")" \
        "hash-inputs-after" "S63: no operation runs after the failed command"
}

s64_metric_value_fail_closed() {
    local value
    for value in nan -nan inf -inf; do
        ab_metric_expect "S64 value ${value}" FAIL_NON_FINITE output FAKE_VALUE="$value"
    done
    ab_metric_expect "S64 text value" FAIL_PARSE output FAKE_VALUE=abc
    ab_metric_expect "S64 partial number" FAIL_PARSE output FAKE_VALUE=3.67x
    ab_metric_expect "S64 no value" FAIL_PARSE output FAKE_OUTPUT=no-value
    ab_metric_expect "S64 other field" FAIL_PARSE output 'FAKE_COLUMN=volAverage(U)'
    ab_metric_expect "S64 above the tolerance" FAIL_TOLERANCE output FAKE_VALUE=3.6666677
    ab_metric_expect "S64 magnitude of the mean vector" FAIL_TOLERANCE output FAKE_VALUE=1.6666666666666667
    ab_metric_expect "S64 arithmetic mean" FAIL_TOLERANCE output FAKE_VALUE=4
    # A value inside the tolerance passes.
    local workspace run
    workspace="$(new_workspace s64_inside)"
    ab_metric_fixture "$workspace"
    run="$(ab_metric_run "$workspace" FAKE_VALUE=3.6666675)"
    assert_eq "PASS" "$(ab_metric_value "$workspace" METRIC_RESULT)" "S64: a value 8.3e-7 from 11/3 passes"
    assert_contains "$run" "status=0 " "S64: the validation step passes inside the tolerance"
}

s65_metric_limits_and_process_cleanup() {
    local workspace library now out run elapsed task row pid re status probe=()
    workspace="$(new_workspace s65_limits)"
    ab_metric_fixture "$workspace"
    library="$(ab_metric_library "$workspace")"
    probe=(METRIC_TASK_ROOT="${workspace}/probe" METRIC_TASK_TEMP="${workspace}/probe/m3-mean-speed-validation")
    mkdir -p "${workspace}/probe/m3-mean-speed-validation"
    # op_limit: the contract caps, the budgets left, and the active window.
    now="$(date +%s)"
    out="$(env "${probe[@]}" bash -c "${library}
        METRIC_ACTIVE_DEADLINE=$(( now + 1000 ))
        echo \$(op_limit INSTALL 180) \$(op_limit OPENFOAM 60) \$(op_limit SETUP 30) \$(op_limit EVIDENCE 30) \$(op_limit PACKAGE 30)
        OPENFOAM_USED=236; echo \$(op_limit OPENFOAM 60)
        OPENFOAM_USED=240; echo \$(op_limit OPENFOAM 60)
        SETUP_USED=25 EVIDENCE_USED=29 PACKAGE_USED=30; echo \$(op_limit SETUP 30) \$(op_limit EVIDENCE 30) \$(op_limit PACKAGE 30)")"
    assert_eq $'180 60 30 30 30\n4\n0\n5 1 0' "$out" "S65: the caps are 180, 60, and 30 s, the OpenFOAM commands share 240 s"
    out="$(env "${probe[@]}" bash -c "${library}
        METRIC_ACTIVE_DEADLINE=\$(( \$(date +%s) + 100 ))
        echo \$(op_limit INSTALL 180) \$(op_limit OPENFOAM 60) \$(op_limit EVIDENCE 30) \$(op_limit PACKAGE 30)
        METRIC_ACTIVE_DEADLINE=\$(( \$(date +%s) + 50 ))
        echo \$(op_limit INSTALL 180) \$(op_limit OPENFOAM 60) \$(op_limit SETUP 30) \$(op_limit EVIDENCE 30)
        METRIC_ACTIVE_DEADLINE=\$(( \$(date +%s) + 10 ))
        echo \$(op_limit INSTALL 180) \$(op_limit EVIDENCE 30) \$(op_limit PACKAGE 30)")"
    re="^(69|70) 60 30 30"$'\n'"(19|20) (19|20) (19|20) 30"$'\n'"0 (9|10) 30$"
    [[ "$out" =~ $re ]] ||
        _fail "S65: install, setup, and OpenFOAM keep the evidence budget before the deadline" "$out"
    # bounded: SIGTERM at the limit less the kill grace, and SIGKILL to a
    # child that ignores SIGTERM at the limit. The command exits 4 seconds
    # after SIGTERM. The function returns only after the child stops.
    ab_write_term_ignoring_command "${workspace}/term_ignoring_command" 4
    out="$(cd "$workspace" && env "${probe[@]}" bash -c "${library}
        bounded probe 7 '${workspace}/probe.out' '${workspace}/probe.err' ./term_ignoring_command
        echo \"outcome=\${OP_OUTCOME} elapsed=\$(( OP_END - OP_START )) group=\${OP_GROUP}\"")"
    pid="$(ab_file_value "${workspace}/probe.out" CHILD_PID)"
    [[ "$pid" =~ ^[0-9]+$ ]] || _fail "S65: the probe child must start" "$(cat "${workspace}/probe.out")"
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null
        _fail "S65: the TERM-ignoring child must stop before bounded returns"
    fi
    [[ "$out" =~ outcome=TIMEOUT\ elapsed=(6|7|8)\  ]] ||
        _fail "S65: the operation ends with SIGKILL at its 7-second limit" "$out"
    # A blocked metric command stops at its limit, and the evidence remains.
    workspace="$(new_workspace s65_blocked)"
    ab_metric_fixture "$workspace"
    now="$(date +%s)"
    run="$(ab_metric_run "$workspace" FAKE_BLOCK=simpleFoam METRIC_ACTIVE_DEADLINE="$(( now + 30 + 9 ))")"
    elapsed="$(sed -e 's/.*elapsed=\([0-9]*\).*/\1/' <<< "$run")"
    assert_eq "FAIL_TIMEOUT" "$(ab_metric_value "$workspace" METRIC_RESULT)" "S65: a blocked command is FAIL_TIMEOUT"
    assert_eq "metric" "$(ab_metric_value "$workspace" METRIC_STOP_POINT)" "S65: the run stops at the metric command"
    (( elapsed <= 10 )) || _fail "S65: the blocked command must stop before the evidence budget" "elapsed: ${elapsed}"
    task="$(ab_metric_task "$workspace")"
    row="$(awk -F '\t' '$2 == "metric" { print $5 " " $9 " " ($7 - $6) }' "${task}/evidence/commands.tsv")"
    [[ "$row" =~ ^([0-9]+)\ TIMEOUT\ ([0-9]+)$ ]] && (( BASH_REMATCH[1] < 60 && BASH_REMATCH[2] <= BASH_REMATCH[1] )) ||
        _fail "S65: the metric row shows the window limit and the timeout" "$row"
    while IFS= read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            _fail "S65: the blocked fake must stop" "pid ${pid}"
        fi
    done < "${workspace}/fake_pids"
    assert_contains "$run" "package=0" "S65: the package step completes after a timeout"
    # No time left: no operation starts.
    ab_metric_expect "S65 no time" FAIL_TIMEOUT install METRIC_ACTIVE_DEADLINE="$(( $(date +%s) - 1 ))"
    ab_metric_no_command "$AB_METRIC_LAST" "S65 no time" curl sudo foamListTimes checkMesh simpleFoam
    assert_contains "$(cat "$(ab_metric_task "$AB_METRIC_LAST")/evidence/commands.tsv")" $'\tNOT_STARTED\t-\t-\t' \
        "S65: the install row shows NOT_STARTED"
    # The package budget: a blocked archive stops at the budget, and only the
    # result and the reason are uploaded.
    workspace="$(new_workspace s65_package)"
    ab_metric_fixture "$workspace"
    ab_metric_run "$workspace" > /dev/null
    ln -s "${workspace}/metric_fake" "${workspace}/fakebin/tar"
    now="$(date +%s)"
    env PATH="${workspace}/fakebin:${PATH}" FAKE_BLOCK=tar METRIC_FAKE_CALLS="${workspace}/calls.tsv" \
        METRIC_FAKE_PIDS="${workspace}/fake_pids" METRIC_TASK_ROOT="$(ab_metric_root "$workspace")" \
        METRIC_TASK_TEMP="$(ab_metric_task "$workspace")" bash -c "${library}
        PHASE_CAP=7
        main_package" > "${workspace}/package_probe.out" 2>&1 && status=0 || status=$?
    elapsed=$(( $(date +%s) - now ))
    assert_eq "1" "$status" "S65: an incomplete package fails"
    (( elapsed <= 8 )) || _fail "S65: the package stops at its budget" "elapsed: ${elapsed}"
    assert_eq "FAIL_EVIDENCE_PACKAGE" "$(ab_metric_value "$workspace" METRIC_RESULT)" \
        "S65: an incomplete evidence package fails closed"
    assert_eq "PASS" "$(ab_metric_value "$workspace" METRIC_PRIOR_RESULT)" "S65: the prior result stays recorded"
    assert_file_exists "$(ab_metric_root "$workspace")/upload/reason.txt" "S65: the upload keeps the reason"
    assert_file_missing "$(ab_metric_root "$workspace")/upload/m3-metric-validation-evidence.tar.gz" \
        "S65: no partial archive"
    while IFS= read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            _fail "S65: the blocked archive must stop" "pid ${pid}"
        fi
    done < "${workspace}/fake_pids"
}

s66_metric_log_and_artifact_limits() {
    local workspace task root file extract
    ab_metric_expect "S66 log above the limit" FAIL_OUTPUT_LIMIT metric FAKE_STDOUT_BYTES=1048577
    task="$(ab_metric_task "$AB_METRIC_LAST")"
    root="$(ab_metric_root "$AB_METRIC_LAST")"
    assert_contains "$(cat "${task}/evidence/excluded.tsv")" $'logs/09-metric.stdout.log\t1048577\t' \
        "S66: the excluded log keeps its size and checksum"
    assert_contains "$(cat "${root}/upload/inventory.txt")" $'EXCLUDED\t1048577\t' "S66: the inventory lists the excluded log"
    assert_not_contains "$(tar -tzf "${root}/upload/m3-metric-validation-evidence.tar.gz")" "09-metric.stdout.log" \
        "S66: the archive does not hold the excluded log"
    # A log of exactly 1 MiB stays.
    workspace="$(new_workspace s66_log_limit)"
    ab_metric_fixture "$workspace"
    ab_metric_run "$workspace" FAKE_STDOUT_BYTES=1048576 > /dev/null
    assert_eq "PASS" "$(ab_metric_value "$workspace" METRIC_RESULT)" "S66: a log of exactly 1 MiB stays"
    # The kept logs together: at most 8 MiB.
    for file in 1 2 3 4 5 6 7 8; do
        head -c 1048576 /dev/zero > "$(ab_metric_task "$workspace")/logs/9${file}-extra.stdout.log"
    done
    assert_eq "0" "$(ab_metric_package "$workspace")" "S66: the package step completes"
    assert_eq "FAIL_OUTPUT_LIMIT" "$(ab_metric_value "$workspace" METRIC_RESULT)" "S66: logs above 8 MiB together fail"
    assert_eq "PASS" "$(ab_metric_value "$workspace" METRIC_PRIOR_RESULT)" "S66: the prior result stays recorded"
    assert_contains "$(cat "$(ab_metric_task "$workspace")/evidence/excluded.tsv")" "above 8388608 bytes together" \
        "S66: the excluded logs keep the reason"
    extract="${workspace}/extract"
    mkdir -p "$extract"
    tar -xzf "$(ab_metric_root "$workspace")/upload/m3-metric-validation-evidence.tar.gz" -C "$extract"
    (( $(find "${extract}/logs" -type f -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }') <= 8388608 )) ||
        _fail "S66: the archive keeps at most 8 MiB of logs"
    # The artifact: at most 10 MiB, or only the result, the inventory, and the reason.
    workspace="$(new_workspace s66_artifact)"
    ab_metric_fixture "$workspace"
    ab_metric_run "$workspace" > /dev/null
    head -c 11534336 /dev/urandom > "$(ab_metric_task "$workspace")/evidence/extra.bin"
    assert_eq "0" "$(ab_metric_package "$workspace")" "S66: the package step completes"
    root="$(ab_metric_root "$workspace")"
    assert_eq "FAIL_ARTIFACT_LIMIT" "$(ab_metric_value "$workspace" METRIC_RESULT)" "S66: an artifact above 10 MiB fails"
    (( $(find "${root}/upload" -type f -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }') <= 10485760 )) ||
        _fail "S66: the upload stays at or below 10 MiB"
    assert_eq $'evidence/\nevidence/inventory.txt\nevidence/reason.txt\nevidence/result.env' \
        "$(tar -tzf "${root}/upload/m3-metric-validation-evidence.tar.gz" | LC_ALL=C sort)" \
        "S66: the reduced archive holds only the result, the inventory, and the reason"
}

s67_metric_task_directory_and_cleanup() {
    local workspace before after root status sleeper group
    # Every file of the run is inside the unique task directory, and the
    # cleanup removes only that directory.
    workspace="$(new_workspace s67_tree)"
    ab_metric_fixture "$workspace"
    # The harness writes its own step outputs (*.out) at the workspace top.
    before="$(cd "$workspace" && find . -mindepth 1 ! -path './*.out' | LC_ALL=C sort)"
    ab_metric_run "$workspace" > /dev/null
    root="$(ab_metric_root "$workspace")"
    after="$(cd "$workspace" && find . -mindepth 1 ! -path './*.out' ! -path "./runner_temp/${root##*/}" \
        ! -path "./runner_temp/${root##*/}/*" | LC_ALL=C sort)"
    assert_eq "$before" "$after" "S67: the run writes no file outside the task directory"
    assert_eq "0" "$(ab_metric_cleanup "$workspace")" "S67: the cleanup passes"
    assert_eq "$before" "$(cd "$workspace" && find . -mindepth 1 ! -path './*.out' | LC_ALL=C sort)" \
        "S67: after the cleanup, only the task directory is gone"
    # A process with its working directory in the task directory stops the
    # removal.
    workspace="$(new_workspace s67_active)"
    ab_metric_fixture "$workspace"
    ab_metric_run "$workspace" > /dev/null
    root="$(ab_metric_root "$workspace")"
    (cd "${root}/m3-mean-speed-validation" && exec sleep 30) &
    sleeper=$!
    sleep 0.2
    status="$(ab_metric_cleanup "$workspace")"
    kill "$sleeper" 2>/dev/null
    wait "$sleeper" 2>/dev/null || true
    assert_eq "1" "$status" "S67: the cleanup fails while a process uses the task directory"
    assert_dir_exists "$root" "S67: the task directory stays while a process uses it"
    assert_contains "$(cat "${workspace}/step_summary")" "| Cleanup | \`NOT_REMOVED_PROCESS_ACTIVE\` |" \
        "S67: the summary shows the active process"
    assert_eq "0" "$(ab_metric_cleanup "$workspace")" "S67: the cleanup passes after the process stops"
    assert_dir_missing "$root" "S67: the cleanup then removes the task directory"
    # A process in a recorded operation group stops the removal.
    workspace="$(new_workspace s67_group)"
    ab_metric_fixture "$workspace"
    ab_metric_run "$workspace" > /dev/null
    root="$(ab_metric_root "$workspace")"
    setsid sleep 30 < /dev/null > /dev/null 2>&1 &
    sleeper=$!
    sleep 0.2
    group="$(ps -o pgid= -p "$sleeper" | tr -d ' ')"
    printf '99\tprobe\tEVIDENCE\t30\t30\t0\t0\t0\tCOMPLETED\t%s\t-\tprobe\n' "$group" \
        >> "$(ab_metric_task "$workspace")/evidence/commands.tsv"
    status="$(ab_metric_cleanup "$workspace")"
    kill "$sleeper" 2>/dev/null
    wait "$sleeper" 2>/dev/null || true
    assert_eq "1" "$status" "S67: the cleanup fails while a recorded group has a process"
    assert_dir_exists "$root" "S67: the task directory stays while a recorded group has a process"
    # Only the unique task directory under RUNNER_TEMP.
    workspace="$(new_workspace s67_path)"
    ab_metric_fixture "$workspace"
    ab_metric_run "$workspace" > /dev/null
    mkdir -p "${workspace}/runner_temp/other"
    for root in "${workspace}/runner_temp" "${workspace}/runner_temp/other" "${workspace}/elsewhere"; do
        status="$(ab_metric_cleanup "$workspace" METRIC_TASK_ROOT="$root")"
        assert_eq "1" "$status" "S67: the cleanup refuses ${root#"${workspace}/"}"
        assert_dir_exists "$root" "S67: the refused directory stays: ${root#"${workspace}/"}"
        assert_contains "$(cat "${workspace}/cleanup.out")" "cleanup: REFUSED_UNEXPECTED_PATH" \
            "S67: the refusal is explicit for ${root#"${workspace}/"}"
    done
}

# ---- S68 to S70: root processes and the process checks (PR #97) ------------
#
# The install runs the repository script and apt-get as root through sudo. The
# runner user may not signal a root process, and kill -0 fails for it with
# EPERM, so a check with kill -0 takes a group of root processes as empty
# (Architect review 5453307998). S68 uses the fake sudo: the install leaves a
# process that ignores SIGTERM, the stop must signal the install group through
# sudo -n kill, and when sudo refuses, the process stays, as a root process
# stays for a runner-user signal. S69 uses real host processes of another
# user: a process group for which kill -0 fails with EPERM, and /proc entries
# that the test user may not read. No signal reaches a process of another
# user: each attempt fails with EPERM, as the kill -0 check shows first.

# ab_metric_foreign_group - one process group of the test host with a live
# process, for which kill -0 fails with EPERM for the test user.
ab_metric_foreign_group() {
    local group out
    for group in $(ps -eo pgid=,stat= | awk '$1 > 1 && $2 !~ /^Z/ { print $1 }' | sort -un); do
        if out="$(LC_ALL=C kill -0 -- "-${group}" 2>&1)"; then
            continue
        fi
        if [[ "$out" == *"Operation not permitted"* ]]; then
            printf '%s\n' "$group"
            return 0
        fi
    done
    return 0
}

s68_metric_install_stop_reaches_root_processes() {
    local workspace run elapsed task group child calls status alive summary library out outcome probe=()
    # sudo is available: SIGTERM, then SIGKILL at the limit, both to the
    # recorded install group through sudo -n kill.
    workspace="$(new_workspace s68_root_stop)"
    ab_metric_fixture "$workspace"
    run="$(ab_metric_run "$workspace" FAKE_ROOT_CHILD="${workspace}/root_child" \
        METRIC_ACTIVE_DEADLINE="$(( $(date +%s) + 30 + 12 ))")"
    elapsed="$(sed -e 's/.*elapsed=\([0-9]*\).*/\1/' <<< "$run")"
    child="$(cat "${workspace}/root_child" 2>/dev/null || true)"
    [[ "$child" =~ ^[0-9]+$ ]] || _fail "S68: the install must start the TERM-ignoring child" \
        "$(tail -n 5 "${workspace}/run.out")"
    if kill -0 "$child" 2>/dev/null; then
        kill -KILL "$child" 2>/dev/null || true
        _fail "S68: the install stop must end the TERM-ignoring child"
    fi
    assert_eq "FAIL_TIMEOUT" "$(ab_metric_value "$workspace" METRIC_RESULT)" "S68: the install timeout is FAIL_TIMEOUT"
    assert_eq "install" "$(ab_metric_value "$workspace" METRIC_STOP_POINT)" "S68: the run stops at the install"
    task="$(ab_metric_task "$workspace")"
    group="$(awk -F '\t' '$2 == "install" { print $10 }' "${task}/evidence/commands.tsv")"
    [[ "$group" =~ ^[0-9]+$ ]] || _fail "S68: the install row records its group" "$group"
    assert_eq "TIMEOUT" "$(awk -F '\t' '$2 == "install" { print $9 }' "${task}/evidence/commands.tsv")" \
        "S68: the install row shows the timeout"
    calls="$(ab_metric_calls "$workspace" | grep -E '^sudo -n kill ' || true)"
    assert_eq "sudo -n kill -TERM -- -${group}
sudo -n kill -KILL -- -${group}" "$calls" "S68: SIGTERM, then SIGKILL, go to the install group through sudo"
    (( elapsed <= 15 )) || _fail "S68: the install stops at its 12-second limit" "elapsed: ${elapsed}"
    assert_eq "1" "$(ab_metric_cleanup "$workspace")" "S68: the job fails for the timeout"
    assert_dir_missing "$(ab_metric_root "$workspace")" "S68: the cleanup removes the task directory after the stop"
    # sudo refuses: the child stays, as a root process stays. The run fails
    # closed in a bounded time, and the cleanup keeps the task directory while
    # the child runs in it.
    workspace="$(new_workspace s68_root_survivor)"
    ab_metric_fixture "$workspace"
    run="$(ab_metric_run "$workspace" FAKE_ROOT_CHILD="${workspace}/root_child" FAKE_SUDO=deny \
        METRIC_ACTIVE_DEADLINE="$(( $(date +%s) + 30 + 12 ))")"
    elapsed="$(sed -e 's/.*elapsed=\([0-9]*\).*/\1/' <<< "$run")"
    child="$(cat "${workspace}/root_child" 2>/dev/null || true)"
    [[ "$child" =~ ^[0-9]+$ ]] || _fail "S68: the install must start the TERM-ignoring child" \
        "$(tail -n 5 "${workspace}/run.out")"
    alive=no
    if kill -0 "$child" 2>/dev/null; then alive=yes; fi
    status="$(ab_metric_cleanup "$workspace")"
    summary="$(cat "${workspace}/step_summary")"
    if kill -0 "$child" 2>/dev/null; then alive="${alive} yes"; else alive="${alive} no"; fi
    kill -KILL "$child" 2>/dev/null || true
    task="$(ab_metric_task "$workspace")"
    assert_eq "yes yes" "$alive" "S68: the child survives the refused signals, and the cleanup sends no signal"
    assert_eq "FAIL_PROCESS_STOP" "$(ab_metric_value "$workspace" METRIC_RESULT)" \
        "S68: a process that does not stop is FAIL_PROCESS_STOP"
    assert_eq "install" "$(ab_metric_value "$workspace" METRIC_STOP_POINT)" "S68: the run stops at the install"
    assert_eq "NOT_STOPPED" "$(awk -F '\t' '$2 == "install" { print $9 }' "${task}/evidence/commands.tsv")" \
        "S68: the install row shows NOT_STOPPED"
    (( elapsed <= 20 )) || _fail "S68: the stop is bounded: the limit, then at most the kill grace" "elapsed: ${elapsed}"
    assert_eq "1" "$status" "S68: the cleanup fails while the child runs"
    assert_dir_exists "$(ab_metric_root "$workspace")" "S68: the task directory stays while the child runs"
    assert_contains "$summary" "| Cleanup | \`NOT_REMOVED_PROCESS_ACTIVE\` |" "S68: the summary shows the active process"
    sleep 0.2
    assert_eq "1" "$(ab_metric_cleanup "$workspace")" "S68: the job still fails after the child stops"
    assert_dir_missing "$(ab_metric_root "$workspace")" "S68: the cleanup then removes the task directory"
    # A log above the limit does not hide a process that did not stop.
    library="$(ab_metric_library "$workspace")"
    probe=(METRIC_TASK_ROOT="${workspace}/probe" METRIC_TASK_TEMP="${workspace}/probe/m3-mean-speed-validation"
           METRIC_ACTIVE_DEADLINE="$(( $(date +%s) + 100 ))")
    mkdir -p "${workspace}/probe/m3-mean-speed-validation/logs" "${workspace}/probe/m3-mean-speed-validation/evidence" \
             "${workspace}/probe/excluded" "${workspace}/probe/scratch"
    for outcome in NOT_STOPPED COMPLETED; do
        head -c 1048577 /dev/zero > "${workspace}/probe/m3-mean-speed-validation/logs/01-probe.stdout.log"
        out="$(env "${probe[@]}" bash -c "${library}
            OP_OUTCOME=${outcome}
            log_limit '${workspace}/probe/m3-mean-speed-validation/logs/01-probe.stdout.log'
            echo outcome=\${OP_OUTCOME}" 2>&1 || true)"
        if [[ "$outcome" == NOT_STOPPED ]]; then
            assert_contains "$out" "outcome=NOT_STOPPED" "S68: a log above the limit keeps NOT_STOPPED"
        else
            assert_contains "$out" "outcome=OUTPUT_LIMIT" "S68: a log above the limit gives OUTPUT_LIMIT"
        fi
    done
}

s69_metric_process_checks_do_not_depend_on_permission() {
    local workspace library root group out status summary start elapsed pid holder zombie tick probe=()
    # A recorded group that the test user may not signal: kill -0 fails with
    # EPERM, but the group has a live process.
    group="$(ab_metric_foreign_group)"
    [[ -n "$group" ]] || _fail "S69: the test host must have a process group that the test user may not signal" \
        "Run the contract tests as a user other than root."
    workspace="$(new_workspace s69_foreign_group)"
    ab_metric_fixture "$workspace"
    library="$(ab_metric_library "$workspace")"
    probe=(PATH="${workspace}/fakebin:${PATH}" FAKE_SUDO=deny METRIC_FAKE_CALLS="${workspace}/calls.tsv"
           METRIC_FAKE_PIDS="${workspace}/fake_pids" METRIC_TASK_ROOT="${workspace}/probe"
           METRIC_TASK_TEMP="${workspace}/probe/m3-mean-speed-validation")
    mkdir -p "${workspace}/probe/m3-mean-speed-validation"
    # The stop of an operation group does not take that group as empty. The
    # signals fail with EPERM, so the group stays, and the stop says so after
    # the kill grace.
    start="$(date +%s)"
    out="$(env "${probe[@]}" bash -c "${library}
        stop_operation_group ${group} probe \$(( \$(date +%s%3N) + 1000 )) && echo status=0 || echo status=\$?
        echo stop=\${OP_STOP:-UNSET}" 2>&1 || true)"
    elapsed=$(( $(date +%s) - start ))
    assert_contains "$out" "status=1" "S69: the stop does not take a group of another user as empty" "$out"
    assert_contains "$out" "stop=NOT_STOPPED" "S69: the stop records NOT_STOPPED"
    (( elapsed <= 9 )) || _fail "S69: the stop of a group that stays is bounded" "elapsed: ${elapsed}"
    # A group with only a zombie is empty: a zombie has stopped. Its parent
    # sleeps in another group and does not reap it.
    bash -c 'setsid sleep 0 & echo "$!" > "$1"; exec sleep 30' _ "${workspace}/zombie" \
        < /dev/null > /dev/null 2>&1 &
    holder=$!
    zombie=""
    for (( tick = 0; tick < 50; tick++ )); do
        zombie="$(cat "${workspace}/zombie" 2>/dev/null || true)"
        if [[ "$zombie" =~ ^[0-9]+$ && "$(awk '{ print $3 }' "/proc/${zombie}/stat" 2>/dev/null || true)" == Z ]]; then
            break
        fi
        sleep 0.1
    done
    if [[ ! "$zombie" =~ ^[0-9]+$ || "$(awk '{ print $3 }' "/proc/${zombie}/stat" 2>/dev/null || true)" != Z ]]; then
        kill "$holder" 2>/dev/null || true
        _fail "S69: the probe must make a zombie in its own group" "pid: ${zombie}"
    fi
    out="$(env "${probe[@]}" bash -c "${library}
        stop_operation_group ${zombie} probe \$(( \$(date +%s%3N) + 1000 )) && echo status=0 || echo status=\$?
        echo stop=\${OP_STOP:-UNSET}" 2>&1 || true)"
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    assert_contains "$out" "status=0" "S69: a group with only a zombie is empty" "$out"
    assert_contains "$out" "stop=EMPTY" "S69: the stop records EMPTY for a group with only a zombie"
    # The cleanup does not take that group as empty.
    ab_metric_run "$workspace" > /dev/null
    root="$(ab_metric_root "$workspace")"
    printf '99\tprobe\tEVIDENCE\t30\t30\t0\t0\t0\tCOMPLETED\t%s\t-\tprobe\n' "$group" \
        >> "$(ab_metric_task "$workspace")/evidence/commands.tsv"
    status="$(ab_metric_cleanup "$workspace")"
    assert_eq "1" "$status" "S69: the cleanup fails while a recorded group of another user has a process"
    assert_dir_exists "$root" "S69: the task directory stays while a recorded group of another user has a process"
    assert_contains "$(cat "${workspace}/step_summary")" "| Cleanup | \`NOT_REMOVED_PROCESS_ACTIVE\` |" \
        "S69: the summary shows the active group"
    # Every started operation records its group, also the package operation,
    # which has no commands.tsv row. A live group in that record keeps the
    # task directory.
    workspace="$(new_workspace s69_group_record)"
    ab_metric_fixture "$workspace"
    ab_metric_run "$workspace" > /dev/null
    root="$(ab_metric_root "$workspace")"
    out="$(awk -F '\t' 'NR > 1 { print $10 " " $2 }' "$(ab_metric_task "$workspace")/evidence/commands.tsv")"
    assert_eq "$out" "$(head -n -1 "${root}/process-groups.tsv" 2>/dev/null | tr '\t' ' ')" \
        "S69: the group record lists the group of each command row"
    [[ "$(tail -n 1 "${root}/process-groups.tsv" 2>/dev/null)" =~ ^[0-9]+$'\t'package$ ]] ||
        _fail "S69: the group record lists the package group last"
    setsid sleep 30 < /dev/null > /dev/null 2>&1 &
    pid=$!
    sleep 0.2
    printf '%s\tpackage\n' "$(ps -o pgid= -p "$pid" | tr -d ' ')" >> "${root}/process-groups.tsv"
    status="$(ab_metric_cleanup "$workspace")"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    assert_eq "1" "$status" "S69: the cleanup fails while a group of the record has a process"
    assert_dir_exists "$root" "S69: the task directory stays while a group of the record has a process"
    assert_contains "$(cat "${workspace}/cleanup.out")" "cleanup: NOT_REMOVED_PROCESS_ACTIVE" \
        "S69: the cleanup result is the active group of the record"
    # A /proc entry that the scan cannot read makes the check incomplete. The
    # test user may not read the working directory of a root process.
    if readlink /proc/1/cwd > /dev/null 2>&1; then
        _fail "S69: the test user must not be able to read /proc/1/cwd" "Run the contract tests as a user other than root."
    fi
    workspace="$(new_workspace s69_scan)"
    ab_metric_fixture "$workspace"
    ab_metric_run "$workspace" > /dev/null
    root="$(ab_metric_root "$workspace")"
    status="$(ab_metric_cleanup "$workspace" FAKE_SUDO=user)"
    assert_eq "1" "$status" "S69: the cleanup fails when the scan cannot read a /proc entry"
    assert_dir_exists "$root" "S69: the task directory stays after an incomplete scan"
    assert_contains "$(cat "${workspace}/cleanup.out")" "cleanup: NOT_REMOVED_PROCESS_CHECK_INCOMPLETE" \
        "S69: the cleanup result is the incomplete scan"
    assert_contains "$(cat "${workspace}/cleanup.out")" "Permission denied" "S69: the log shows the unreadable entry"
    # Without root access the scan does not run.
    status="$(ab_metric_cleanup "$workspace" FAKE_SUDO=deny)"
    assert_eq "1" "$status" "S69: the cleanup fails without root access"
    assert_dir_exists "$root" "S69: the task directory stays without root access"
    assert_contains "$(cat "${workspace}/cleanup.out")" "cleanup: NOT_REMOVED_PROCESS_CHECK_FAILED" \
        "S69: the cleanup result is the failed scan"
    # The scan is bounded.
    ln -s "${workspace}/metric_fake" "${workspace}/fakebin/find"
    start="$(date +%s)"
    status="$(ab_metric_cleanup "$workspace" FAKE_BLOCK=find)"
    elapsed=$(( $(date +%s) - start ))
    rm -f -- "${workspace}/fakebin/find"
    assert_eq "1" "$status" "S69: the cleanup fails when the scan does not end"
    assert_dir_exists "$root" "S69: the task directory stays after a scan timeout"
    assert_contains "$(cat "${workspace}/cleanup.out")" "cleanup: NOT_REMOVED_PROCESS_CHECK_TIMEOUT" \
        "S69: the cleanup result is the scan timeout"
    (( elapsed <= 10 )) || _fail "S69: the scan stops at its limit" "elapsed: ${elapsed}"
    while IFS= read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            _fail "S69: the blocked scan must stop" "pid ${pid}"
        fi
    done < "${workspace}/fake_pids"
    # With the root view and no user, the cleanup removes the directory.
    status="$(ab_metric_cleanup "$workspace")"
    summary="$(cat "${workspace}/step_summary")"
    assert_eq "0" "$status" "S69: the cleanup passes after a complete scan"
    assert_dir_missing "$root" "S69: the cleanup removes the task directory after a complete scan"
    assert_contains "$summary" "| Cleanup | \`REMOVED\` |" "S69: the summary shows the removal"
}

s70_metric_stop_ends_by_the_operation_deadline() {
    local workspace run elapsed task row child pid library out start sleeper group probe=()
    # sudo hangs: each sudo -n kill helper ignores SIGTERM and sends no signal
    # (review 5454383774). The helpers, the SIGKILL, and the check must end by
    # the absolute deadline of the install, and the run fails closed.
    workspace="$(new_workspace s70_slow_helper)"
    ab_metric_fixture "$workspace"
    run="$(ab_metric_run "$workspace" FAKE_ROOT_CHILD="${workspace}/root_child" FAKE_SUDO=slow \
        METRIC_ACTIVE_DEADLINE="$(( $(date +%s) + 30 + 12 ))")"
    elapsed="$(sed -e 's/.*elapsed=\([0-9]*\).*/\1/' <<< "$run")"
    child="$(cat "${workspace}/root_child" 2>/dev/null || true)"
    if [[ "$child" =~ ^[0-9]+$ ]]; then
        kill -KILL "$child" 2>/dev/null || true
    else
        _fail "S70: the install must start the TERM-ignoring child" "$(tail -n 5 "${workspace}/run.out")"
    fi
    task="$(ab_metric_task "$workspace")"
    row="$(awk -F '\t' '$2 == "install" { print $5 " " ($7 - $6) " " $9 }' "${task}/evidence/commands.tsv")"
    assert_eq "FAIL_PROCESS_STOP" "$(ab_metric_value "$workspace" METRIC_RESULT)" \
        "S70: a group that does not stop by its deadline is FAIL_PROCESS_STOP"
    assert_eq "install" "$(ab_metric_value "$workspace" METRIC_STOP_POINT)" "S70: the run stops at the install"
    [[ "$row" =~ ^([0-9]+)\ ([0-9]+)\ NOT_STOPPED$ ]] && (( BASH_REMATCH[2] <= BASH_REMATCH[1] )) ||
        _fail "S70: the install with its stop ends by its limit" "limit, elapsed, outcome: ${row}"
    (( elapsed <= 13 )) || _fail "S70: the validation step ends at the 12-second install limit" "elapsed: ${elapsed}"
    assert_contains "$(ab_metric_calls "$workspace" | grep -E '^sudo -n kill ' || true)" "sudo -n kill -KILL -- -" \
        "S70: the SIGKILL helper starts before the deadline"
    while IFS= read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            _fail "S70: each slow helper must stop by the deadline" "pid ${pid}"
        fi
    done < "${workspace}/fake_pids"
    # stop_operation_group alone, for a live group of the test with a deadline
    # 3 seconds ahead: it returns by the deadline although each helper hangs.
    library="$(ab_metric_library "$workspace")"
    : > "${workspace}/fake_pids"
    probe=(PATH="${workspace}/fakebin:${PATH}" FAKE_SUDO=slow METRIC_FAKE_CALLS="${workspace}/calls.tsv"
           METRIC_FAKE_PIDS="${workspace}/fake_pids" METRIC_TASK_ROOT="${workspace}/probe"
           METRIC_TASK_TEMP="${workspace}/probe/m3-mean-speed-validation")
    mkdir -p "${workspace}/probe/m3-mean-speed-validation"
    setsid bash -c "trap '' TERM; exec sleep 300" < /dev/null > /dev/null 2>&1 &
    sleeper=$!
    sleep 0.2
    group="$(ps -o pgid= -p "$sleeper" | tr -d ' ')"
    start="$(date +%s%3N)"
    out="$(env "${probe[@]}" bash -c "${library}
        OP_CLASS=INSTALL
        stop_operation_group ${group} probe \$(( \$(date +%s%3N) + 3000 )) && echo status=0 || echo status=\$?
        echo stop=\${OP_STOP:-UNSET}" 2>&1 || true)"
    elapsed=$(( $(date +%s%3N) - start ))
    kill -KILL "$sleeper" 2>/dev/null || true
    wait "$sleeper" 2>/dev/null || true
    assert_contains "$out" "status=1" "S70: the probe group stays"
    assert_contains "$out" "stop=NOT_STOPPED" "S70: the stop records NOT_STOPPED"
    (( elapsed <= 4000 )) ||
        _fail "S70: the stop ends by its absolute deadline although each helper hangs" \
              "elapsed: ${elapsed} ms for a deadline 3000 ms after the probe start"
    while IFS= read -r pid; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            _fail "S70: each slow helper of the probe must stop by the deadline" "pid ${pid}"
        fi
    done < "${workspace}/fake_pids"
    # SIGKILL comes STOP_RESERVE (1 second) before the deadline. A command that
    # ignores SIGTERM ends about 1 second before its 7-second limit, and the
    # stop then finds an empty group.
    start="$(date +%s%3N)"
    out="$(env "${probe[@]}" bash -c "${library}
        bounded probe 7 '${workspace}/probe.out' '${workspace}/probe.err' bash -c \"trap '' TERM; exec sleep 300\"
        echo outcome=\${OP_OUTCOME} stop=\${OP_STOP}" 2>&1 || true)"
    elapsed=$(( $(date +%s%3N) - start ))
    assert_contains "$out" "outcome=TIMEOUT stop=EMPTY" "S70: timeout kills the TERM-ignoring command"
    (( elapsed >= 5500 && elapsed <= 6600 )) ||
        _fail "S70: SIGKILL comes 1 second before the 7-second limit" "elapsed: ${elapsed} ms"
    # The same when the command exits 4 seconds after SIGTERM and leaves a
    # child that ignores SIGTERM: the stop sends SIGKILL 1 second before the
    # cap, not at the cap.
    ab_write_term_ignoring_command "${workspace}/term_ignoring_command" 4
    start="$(date +%s%3N)"
    out="$(cd "$workspace" && env "${probe[@]}" bash -c "${library}
        bounded probe 7 '${workspace}/late.out' '${workspace}/late.err' ./term_ignoring_command
        echo outcome=\${OP_OUTCOME} stop=\${OP_STOP}" 2>&1 || true)"
    elapsed=$(( $(date +%s%3N) - start ))
    pid="$(ab_file_value "${workspace}/late.out" CHILD_PID)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        _fail "S70: the TERM-ignoring child must stop before bounded returns"
    fi
    assert_contains "$out" "outcome=TIMEOUT stop=STOPPED" "S70: the stop ends the TERM-ignoring child"
    (( elapsed >= 5500 && elapsed <= 6600 )) ||
        _fail "S70: the stop sends SIGKILL 1 second before the 7-second limit" "elapsed: ${elapsed} ms"
}

s71_metric_root_signal_vector_takes_a_small_group_id() {
    local workspace library out calls candidate group probe=()
    workspace="$(new_workspace s71_vector)"
    ab_metric_fixture "$workspace"
    library="$(ab_metric_library "$workspace")"
    # A small group ID that is also a signal number, and that no process group
    # of the host uses: kill -0 fails with ESRCH and sends no signal. Linux
    # gives a PID below 300 only at boot, so no new process gets this ID.
    group=""
    for candidate in 58 34 15 9 3; do
        if [[ "$(LC_ALL=C bash -c "kill -0 -- -${candidate}" 2>&1)" == *"No such process"* ]]; then
            group="$candidate"
            break
        fi
    done
    [[ -n "$group" ]] || _fail "S71: the test host must have a free small process group ID"
    probe=(PATH="${workspace}/fakebin:${PATH}" LC_ALL=C METRIC_FAKE_CALLS="${workspace}/calls.tsv"
           METRIC_FAKE_PIDS="${workspace}/fake_pids" METRIC_TASK_ROOT="${workspace}/probe"
           METRIC_TASK_TEMP="${workspace}/probe/m3-mean-speed-validation")
    mkdir -p "${workspace}/probe/m3-mean-speed-validation"
    # The install helper runs the real external kill through the fake sudo.
    : > "${workspace}/calls.tsv"
    out="$(env "${probe[@]}" bash -c "${library}
        OP_CLASS=INSTALL
        signal_group TERM ${group} \$(( \$(date +%s%3N) + 3000 ))
        signal_group KILL ${group} \$(( \$(date +%s%3N) + 3000 ))" 2>&1 || true)"
    calls="$(ab_metric_calls "$workspace" | grep -E '^sudo -n kill ' || true)"
    assert_eq "sudo -n kill -TERM -- -${group}
sudo -n kill -KILL -- -${group}" "$calls" "S71: the signal comes first, and the group is the operand"
    assert_not_contains "$out" "Usage" "S71: the external kill accepts the vector"
    assert_eq "2" "$(grep -c -- "(-${group}): No such process" <<< "$out")" \
        "S71: each signal goes to the free group -${group}"
    # A group ID below 2 is refused: kill to -1 reaches every process, and kill
    # to -0 reaches the group of the caller. The fake sudo refuses, so no kill
    # runs in this part.
    : > "${workspace}/calls.tsv"
    out="$(env "${probe[@]}" FAKE_SUDO=deny bash -c "${library}
        OP_CLASS=INSTALL
        signal_group TERM 1 \$(( \$(date +%s%3N) + 3000 ))
        signal_group KILL 0 \$(( \$(date +%s%3N) + 3000 ))" 2>&1 || true)"
    assert_eq "" "$(ab_metric_calls "$workspace" | grep -E '^sudo ' || true)" "S71: no signal helper starts for group 1 or 0"
    assert_eq "2" "$(grep -c 'refused' <<< "$out")" "S71: each refusal is in the log"
}

# ---- S72 to S81: the M3 mean-speed collection (Issue #80) --------------------
#
# The evidence workflow collects the cell-volume-weighted mean speed of Case 7
# after a successful product run (admission 6064804618, approved proposal
# 6064220318). These checks run the extracted capture step as GitHub runs it,
# with a Batch Workspace that holds a completed two-cell Case 7 flow result, a
# fake OpenFOAM tree, and fake system commands. The two-cell Case comes from
# the merged metric-validation workflow; the checks add RAS kEpsilon inputs.
# The fake simpleFoam calculates sum(V_i |U_i|) / sum(V_i) from the copied mesh
# and U field. A second Case 8 with other speeds must never be used. No check
# installs OpenFOAM, runs a solver, or dispatches a workflow.

AB_COLLECT_DICTIONARY_SHA="ca8014349e58428377f5fa6d0b890e5850c2b13af42527a05e8ddb5146d137ef"
AB_COLLECT_SHA="7c5a0e3e3b1d4c8f9a2b6d0e1f3a5c7e9b1d3f5a"

# ab_collect_ras <flow-case> - RAS kEpsilon inputs: the turbulence dictionary
# and k, epsilon, and nut at times 1 and 2.
ab_collect_ras() {
    local flow="$1" time field
    cat > "${flow}/constant/turbulenceProperties" <<'COLLECT_RAS'
FoamFile
{
    version     2.0;
    format      ascii;
    class       dictionary;
    location    "constant";
    object      turbulenceProperties;
}

simulationType      RAS;

RAS
{
    RASModel        kEpsilon;
    turbulence      on;
    printCoeffs     on;
}
COLLECT_RAS
    for time in 1 2; do
        for field in k epsilon nut; do
            {
                printf 'FoamFile\n{\n    version     2.0;\n    format      ascii;\n'
                printf '    class       volScalarField;\n    location    "%s";\n    object      %s;\n}\n\n' \
                    "$time" "$field"
                printf 'dimensions      [0 2 -2 0 0 0 0];\n\ninternalField   nonuniform List<scalar> 2(0.1 0.2);\n\n'
                printf 'boundaryField\n{\n    outside\n    {\n        type            zeroGradient;\n    }\n}\n'
            } > "${flow}/${time}/${field}"
        done
    done
}

# ab_collect_fixture <workspace> - the extracted evidence steps, the fake
# OpenFOAM tree and system commands, and a Batch Workspace with completed
# Case 7 and Case 8 flow results: latest time 2, earlier time 1, the flow
# completion record, and the post-processing time record.
ab_collect_fixture() {
    local workspace="$1" batch tree name library task case_id
    ab_capture_fixture "$workspace"
    batch="${workspace}/checkout/src/batch_9"
    tree="${workspace}/openfoam/openfoam2512/platforms/linux64GccDPInt32Opt/bin"
    mkdir -p "$tree" "${workspace}/openfoam/openfoam2512/etc" "${workspace}/elsewhere"
    : > "${workspace}/calls.tsv"
    ab_metric_write_mesh_awk "${workspace}/mesh_metric.awk"
    ab_metric_write_fake "${workspace}/metric_fake" "${workspace}/mesh_metric.awk"
    for name in curl sudo dpkg-query gcc uname; do
        ln -s "${workspace}/metric_fake" "${workspace}/fakebin/${name}"
    done
    for name in foamListTimes checkMesh simpleFoam; do
        ln -s "${workspace}/metric_fake" "${tree}/${name}"
    done
    ln -s "${workspace}/metric_fake" "${workspace}/elsewhere/simpleFoam"
    cat > "${workspace}/openfoam/openfoam2512/etc/bashrc" <<COLLECT_BASHRC
if [[ -n "\${FAKE_BASHRC_STATUS:-}" ]]; then return "\${FAKE_BASHRC_STATUS}"; fi
export WM_PROJECT_VERSION="\${FAKE_WM_VERSION-v2512}"
export WM_OPTIONS=linux64GccDPInt32Opt
export WM_COMPILER="\${FAKE_WM_COMPILER-Gcc}"
export PATH="\${FAKE_EXTRA_PATH:+\${FAKE_EXTRA_PATH}:}${tree}:\${PATH}"
COLLECT_BASHRC
    # The two-cell Case and the metric dictionary of the merged validation
    # workflow.
    library="$(ab_step_run_body "Run the metric validation" "$METRIC_WORKFLOW" |
        awk '/<<.METRIC_VALIDATION.$/ { inside = 1; next } /^METRIC_VALIDATION$/ { inside = 0 } inside' |
        awk '/^case "\$\{1:-\}" in$/ { stop = 1 } !stop { print }')"
    task="${workspace}/fixture/m3-mean-speed-validation"
    mkdir -p "$task"
    env METRIC_TASK_ROOT="${workspace}/fixture" METRIC_TASK_TEMP="$task" bash -c "${library}
        write_fixture" || _fail "the validation fixture writer must succeed"
    cp -- "${task}/config/metric-functions" "${workspace}/validation-metric-functions"
    for case_id in case_7 case_8; do
        mkdir -p "${batch}/${case_id}/vtk"
        cp -R -- "${task}/case" "${batch}/${case_id}/flow"
        ab_collect_ras "${batch}/${case_id}/flow"
        : > "${batch}/${case_id}/flow/flow.marker"
        : > "${batch}/${case_id}/flow/case.foam"
        printf '2\n' > "${batch}/${case_id}/vtk/flow_latest_time.txt"
        : > "${batch}/${case_id}/vtk/post_processing.complete"
    done
    # Case 8 has other speeds, so a wrong Case gives another value.
    sed -i -e 's/(3 4 0)/(30 40 0)/' "${batch}/case_8/flow/2/U"
}

# ab_collect_flow <workspace> - the Case 7 flow result directory.
ab_collect_flow() {
    printf '%s\n' "${1}/checkout/src/batch_9/case_7/flow"
}

# ab_collect_run <workspace> [NAME=value ...] - run the extracted capture step
# as GitHub runs it, after a successful product run, with the fake OpenFOAM
# tree and a far deadline. The arguments override the environment. Prints
# status= and elapsed= lines.
ab_collect_run() {
    local workspace="$1" start status
    shift
    start="$(date +%s)"
    env PATH="${workspace}/fakebin:${PATH}" \
        TMPDIR="${workspace}/tmp" \
        RUNNER_TEMP="${workspace}/runner_temp" \
        EVIDENCE_DIR="${workspace}/runner_temp/evidence" \
        GITHUB_ENV="${workspace}/github_env" \
        GITHUB_WORKSPACE="${workspace}/checkout" \
        GITHUB_SHA="$AB_COLLECT_SHA" GITHUB_RUN_ID=4545 \
        LIB="${workspace}/runner_temp/evidence_lib.sh" \
        CAPTURE_DEADLINE="$(( start + 100000 ))" \
        EVIDENCE_CLOCK_START="$(( start - 1000 ))" \
        CAPTURE_START_GUARD_SECONDS=60 \
        CHECKOUT_RESULT=SUCCEEDED BASELINE_RESULT=SUCCEEDED INSTALL_RESULT=SUCCEEDED \
        PREPARE_RESULT=SUCCEEDED ORCHESTRATOR_STARTED=true OVERALL_RESULT=SUCCEEDED \
        OPENFOAM_BASELINE=v2512 OPENFOAM_PACKAGE=openfoam2512-default OPENFOAM_VERSION=v2512 \
        OPENFOAM_BASHRC="${workspace}/openfoam/openfoam2512/etc/bashrc" \
        METRIC_FAKE_CALLS="${workspace}/calls.tsv" \
        METRIC_FAKE_PIDS="${workspace}/fake_pids" \
        "$@" "${AB_STEP_BASH[@]}" "${workspace}/capture_step.sh" > "${workspace}/capture_step.out" 2>&1 \
        && status=0 || status=$?
    printf 'status=%s\nelapsed=%s\n' "$status" "$(( $(date +%s) - start ))"
}

# ab_collect_value <workspace> <key> - one value of the metric result file.
ab_collect_value() {
    ab_file_value "${1}/runner_temp/evidence/m3-mean-speed/result.env" "$2"
}

# ab_collect_tasks <workspace> - the metric task directories under RUNNER_TEMP.
ab_collect_tasks() {
    find "${1}/runner_temp" -mindepth 1 -maxdepth 1 -name 'm3-metric-collection.*' -print | LC_ALL=C sort
}

# ab_collect_summary <workspace> - run the extracted summary step with the
# values that the capture step published. Prints the job summary.
ab_collect_summary() {
    local workspace="$1"
    : > "${workspace}/step_summary"
    env GITHUB_STEP_SUMMARY="${workspace}/step_summary" \
        CAPTURE_RESULT="$(ab_env_last "$workspace" CAPTURE_RESULT)" \
        CAPTURE_REASON="$(ab_env_last "$workspace" CAPTURE_REASON)" \
        VTU_REQUIRED_FIELDS_VERDICT="$(ab_env_last "$workspace" VTU_REQUIRED_FIELDS_VERDICT)" \
        MESH_QUALITY_VERDICT="$(ab_env_last "$workspace" MESH_QUALITY_VERDICT)" \
        CONVERGENCE_VERDICT="$(ab_env_last "$workspace" CONVERGENCE_VERDICT)" \
        MEAN_SPEED_VERDICT="$(ab_env_last "$workspace" MEAN_SPEED_VERDICT)" \
        MEAN_SPEED_REASON_CODE="$(ab_env_last "$workspace" MEAN_SPEED_REASON_CODE)" \
        MEAN_SPEED_REASON="$(ab_env_last "$workspace" MEAN_SPEED_REASON)" \
        MEAN_SPEED_VALUE="$(ab_env_last "$workspace" MEAN_SPEED_VALUE)" \
        OVERALL_RESULT=SUCCEEDED \
        "${AB_STEP_BASH[@]}" "${workspace}/summary_step.sh" > /dev/null 2>&1 ||
        _fail "the extracted summary step must succeed"
    cat "${workspace}/step_summary"
}

# ab_collect_expect <label> <reason-code> <setup|-> [NAME=value ...] - one run
# in a new workspace. <setup> is a function that changes the fixture first. The
# metric must be UNAVAILABLE with the reason code, no accepted value, a capture
# step that ends with status 0, and a published verdict. A failed attempt must
# give a capture note and an incomplete capture. NOT_ATTEMPTED gives neither.
# The task directory must be gone. Sets AB_COLLECT_LAST to the workspace.
ab_collect_expect() {
    local label="$1" code="$2" setup="$3" workspace run argument arguments=()
    shift 3
    workspace="$(new_workspace "${label//[^A-Za-z0-9_.-]/_}")"
    ab_collect_fixture "$workspace"
    if [[ "$setup" != - ]]; then
        "$setup" "$workspace"
    fi
    for argument in "$@"; do
        arguments+=("${argument//@WORKSPACE@/${workspace}}")
    done
    run="$(ab_collect_run "$workspace" "${arguments[@]}")"
    [[ "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" == "$code" ]] ||
        _fail "${label}: the metric reason code must be ${code}" \
              "actual: $(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" \
              "reason: $(ab_collect_value "$workspace" MEAN_SPEED_REASON)" \
              "$(tail -n 8 "${workspace}/capture_step.out" 2>/dev/null)"
    assert_eq "UNAVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" "${label}: the metric is UNAVAILABLE"
    assert_eq "UNAVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VALUE)" "${label}: no value is accepted"
    assert_contains "$run" "status=0" "${label}: the capture step ends with status 0"
    assert_eq "UNAVAILABLE" "$(ab_env_last "$workspace" MEAN_SPEED_VERDICT)" "${label}: GITHUB_ENV has the verdict"
    assert_eq "$code" "$(ab_env_last "$workspace" MEAN_SPEED_REASON_CODE)" "${label}: GITHUB_ENV has the reason code"
    if [[ "$code" == NOT_ATTEMPTED ]]; then
        assert_eq "COMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "${label}: no attempt gives no capture note"
    else
        assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" \
            "${label}: a failed attempt gives an incomplete capture"
        assert_contains "$(cat "${workspace}/runner_temp/evidence/capture-work-notes.txt")" \
            "M3 mean speed: ${code}" "${label}: the capture note names the reason"
    fi
    assert_eq "" "$(ab_collect_tasks "$workspace")" "${label}: no task directory remains"
    AB_COLLECT_LAST="$workspace"
}

# ab_collect_no_openfoam <workspace> <label> - no metric OpenFOAM command ran.
ab_collect_no_openfoam() {
    assert_eq "0" "$(awk -F '\t' '$1 == "foamListTimes" || $1 == "simpleFoam" || $1 == "checkMesh"' \
        "${1}/calls.tsv" | wc -l)" "${2}: no OpenFOAM command runs"
}

# ab_collect_no_calculation <workspace> <label> - no simpleFoam command ran.
ab_collect_no_calculation() {
    assert_eq "0" "$(awk -F '\t' '$1 == "simpleFoam"' "${1}/calls.tsv" | wc -l)" "${2}: no metric calculation runs"
}

# ab_collect_tree_sha <directory> - one checksum line for each file, sorted.
ab_collect_tree_sha() {
    (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
}

# ab_collect_block <workspace> - the metric functions of the capture work
# script, between their begin and end markers.
ab_collect_block() {
    awk '/^# ---- M3 mean speed: begin ----$/ { inside = 1 } inside && !done { print } /^# ---- M3 mean speed: end ----$/ { done = 1 }' \
        "${1}/capture_step.sh"
}

s72_collect_volume_weighted_mean_of_the_latest_time() {
    local workspace run flow evidence before after calls task line summary file
    workspace="$(new_workspace s72_collect)"
    ab_collect_fixture "$workspace"
    flow="$(ab_collect_flow "$workspace")"
    evidence="${workspace}/runner_temp/evidence/m3-mean-speed"
    before="$(ab_collect_tree_sha "$flow")"
    run="$(ab_collect_run "$workspace")"
    after="$(ab_collect_tree_sha "$flow")"
    assert_contains "$run" "status=0" "S72: the capture step ends with status 0"
    [[ "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" == AVAILABLE ]] ||
        _fail "S72: the metric must be AVAILABLE" \
              "code: $(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" \
              "reason: $(ab_collect_value "$workspace" MEAN_SPEED_REASON)" "$(tail -n 8 "${workspace}/capture_step.out")"
    assert_eq "NONE" "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" "S72: no failure reason"
    # sum(V_i |U_i|) / sum(V_i) = (1 * 5 + 2 * 3) / 3 = 11/3 m/s at the latest time.
    assert_eq "3.66666666666666652e+00" "$(ab_collect_value "$workspace" MEAN_SPEED_VALUE)" \
        "S72: the volume-weighted mean speed of the latest time"
    awk -v v="$(ab_collect_value "$workspace" MEAN_SPEED_VALUE)" 'BEGIN { d = v - 11 / 3; if (d < 0) d = -d; exit !(d <= 1e-6) }' ||
        _fail "S72: the value must be 11/3 m/s within 1e-6 m/s"
    assert_eq "m/s" "$(ab_collect_value "$workspace" MEAN_SPEED_UNIT)" "S72: the unit"
    for line in "SELECTED_TIME=2" "POST_PROCESSING_TIME=2" "OUTPUT_TIME=2" "OUTPUT_CELLS=2" \
                "OUTPUT_VOLUME=3.00000000000000000e+00" "OUTPUT_REGION=all region0" "OUTPUT_FIELD=volAverage(m3MagU)" \
                "OUTPUT_PATH=postProcessing/m3MeanSpeed/2/volFieldValue.dat" "DICTIONARY_BYTES=636" \
                "DICTIONARY_SHA256=${AB_COLLECT_DICTIONARY_SHA}" "INPUTS_UNCHANGED=YES" "INPUT_FILES=15" \
                "CLEANUP_RESULT=REMOVED" "SOURCE_FLOW_CASE=src/batch_9/case_7/flow" "MAIN_SHA=${AB_COLLECT_SHA}" \
                "RUN_ID=4545"; do
        assert_eq "${line#*=}" "$(ab_collect_value "$workspace" "${line%%=*}")" "S72: the result records ${line%%=*}"
    done
    # The exact two vectors, each once, on Case 7 only.
    calls="$(ab_metric_calls "$workspace" | grep -E '^(foamListTimes|simpleFoam|checkMesh|curl|sudo) ' || true)"
    task="$(sed -n -e 's|^simpleFoam -case \(.*\)/case -postProcess .*|\1|p' <<< "$calls")"
    [[ "$task" =~ ^${workspace}/runner_temp/m3-metric-collection\.[A-Za-z0-9]{8}$ ]] ||
        _fail "S72: the calculation runs in one unique task directory under RUNNER_TEMP" "$calls"
    assert_eq "foamListTimes -case ${flow} -latestTime
simpleFoam -case ${task}/case -postProcess -time 2 -fields (U) -dict ${task}/config/metric-functions" \
        "$calls" "S72: the exact selection and calculation vectors, each once"
    assert_not_contains "$(cat "${workspace}/calls.tsv")" "case_8" "S72: Case 8 is never used"
    # The isolated snapshot and the unchanged source Case.
    assert_eq "$before" "$after" "S72: the command does not change the source Case"
    assert_file_missing "${flow}/postProcessing" "S72: no output reaches the source Case"
    assert_eq "" "$(ab_collect_tasks "$workspace")" "S72: the cleanup removes the task directory"
    cmp -s "${workspace}/validation-metric-functions" "${evidence}/metric-functions" ||
        _fail "S72: the dictionary bytes are the bytes of the merged validation workflow"
    assert_eq "$AB_COLLECT_DICTIONARY_SHA" "$(ab_sha "${evidence}/metric-functions")" "S72: the dictionary hash"
    cmp -s "${evidence}/source-before.tsv" "${evidence}/snapshot-before.tsv" ||
        _fail "S72: the snapshot bytes equal the source bytes"
    cmp -s "${evidence}/source-before.tsv" "${evidence}/source-after.tsv" ||
        _fail "S72: the source bytes stay the same after the calculation"
    cmp -s "${evidence}/snapshot-before.tsv" "${evidence}/snapshot-after.tsv" ||
        _fail "S72: the snapshot bytes stay the same after the calculation"
    for file in constant/polyMesh/points constant/polyMesh/faces constant/polyMesh/owner constant/polyMesh/neighbour \
                constant/polyMesh/boundary constant/transportProperties constant/turbulenceProperties \
                system/controlDict system/fvSchemes system/fvSolution 2/U 2/p 2/k 2/epsilon 2/nut; do
        assert_contains "$(cat "${evidence}/source-before.tsv")" "${file}"$'\t'"$(stat -c %s -- "${flow}/${file}")"$'\t'"$(ab_sha "${flow}/${file}")" \
            "S72: the source manifest records ${file}"
    done
    assert_not_contains "$(cat "${evidence}/source-before.tsv")" "1/U" "S72: the earlier time is not copied"
    assert_eq "$(ab_collect_value "$workspace" OUTPUT_SHA256)" "$(ab_sha "${evidence}/output/volFieldValue.dat")" \
        "S72: the output copy has the recorded checksum"
    assert_contains "$(cat "${evidence}/identity.txt")" "WM_PROJECT_VERSION=v2512" "S72: the identity records the version"
    assert_contains "$(cat "${evidence}/identity.txt")" \
        "PATH_simpleFoam=${workspace}/openfoam/openfoam2512/platforms/linux64GccDPInt32Opt/bin/simpleFoam" \
        "S72: the identity records the command path"
    assert_contains "$(cat "${evidence}/commands.tsv")" $'\tCOMPLETED\t' "S72: the command record has outcomes"
    assert_eq "" "$(cd "$evidence" && find . -type f \( -name U -o -name p -o -name k -o -name epsilon -o -name nut \
        -o -name points -o -name faces -o -name owner -o -name neighbour -o -name boundary -o -name '*.vtu' \) -print)" \
        "S72: the evidence holds no mesh, field, or VTU file"
    while IFS=$'\t' read -r line file; do
        [[ "$line" == FILE ]] || continue
        assert_file_exists "${evidence}/${file}" "S72: the inventory lists an existing file ${file}"
    done < <(awk -F '\t' '{ print $1 "\t" $4 }' "${evidence}/inventory.txt")
    assert_eq "$(( $(cd "$evidence" && find . -type f | wc -l) - 2 ))" "$(awk -F '\t' '$1 == "FILE"' "${evidence}/inventory.txt" | wc -l)" \
        "S72: the inventory lists every evidence file except itself and the result"
    # The capture and the summary.
    assert_eq "COMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "S72: the capture is complete"
    assert_eq "AVAILABLE" "$(ab_env_last "$workspace" MEAN_SPEED_VERDICT)" "S72: GITHUB_ENV has the verdict"
    summary="$(ab_collect_summary "$workspace")"
    assert_contains "$summary" "| Mean speed | \`AVAILABLE\` |" "S72: the summary shows the verdict"
    assert_contains "$summary" "| Mean speed (m/s) | 3.66666666666666652e+00 |" "S72: the summary shows the value"
}

s73_collect_needs_a_successful_product_run() {
    local label
    for label in "OVERALL_RESULT=FAILED_EXIT_1" "OVERALL_RESULT=BUDGET_EXCEEDED" "PREPARE_RESULT=INFRASTRUCTURE_FAILURE"; do
        ab_collect_expect "S73 ${label}" NOT_ATTEMPTED - "$label"
        ab_collect_no_openfoam "$AB_COLLECT_LAST" "S73 ${label}"
        assert_eq "0" "$(awk -F '\t' '$1 == "dpkg-query"' "${AB_COLLECT_LAST}/calls.tsv" | wc -l)" \
            "S73 ${label}: no identity command runs"
    done
    ab_collect_expect "S73 no flow record" SOURCE_MISMATCH ab_collect_no_marker
    ab_collect_no_openfoam "$AB_COLLECT_LAST" "S73 no flow record"
    ab_collect_expect "S73 no post-processing record" SOURCE_MISMATCH ab_collect_no_post
    ab_collect_no_openfoam "$AB_COLLECT_LAST" "S73 no post-processing record"
}
ab_collect_no_marker() { rm -f -- "$(ab_collect_flow "$1")/flow.marker"; }
ab_collect_no_post() { rm -f -- "${1}/checkout/src/batch_9/case_7/vtk/post_processing.complete"; }

s74_collect_selects_only_the_recorded_latest_time() {
    local label
    for label in "FAKE_LIST_TIMES=" "FAKE_LIST_TIMES=0\n" "FAKE_LIST_TIMES=1\n2\n" "FAKE_LIST_TIMES=1\n" \
                 "FAKE_LIST_TIMES=two\n"; do
        ab_collect_expect "S74 ${label}" SOURCE_MISMATCH - "$label"
        ab_collect_no_calculation "$AB_COLLECT_LAST" "S74 ${label}"
    done
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" MEAN_SPEED_REASON)" "is not a numeric time" \
        "S74: a time that is not a number has its exact reason"
    ab_collect_expect "S74 zero record" SOURCE_MISMATCH ab_collect_record_zero "FAKE_LIST_TIMES=0\n"
    ab_collect_no_calculation "$AB_COLLECT_LAST" "S74 zero record"
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" MEAN_SPEED_REASON)" "not a result time" \
        "S74: time 0 is not a result time, also when the record names it"
    ab_collect_expect "S74 earlier record" SOURCE_MISMATCH ab_collect_record_earlier
    ab_collect_no_calculation "$AB_COLLECT_LAST" "S74 earlier record"
    ab_collect_expect "S74 two-line record" SOURCE_MISMATCH ab_collect_record_two_lines
    ab_collect_no_calculation "$AB_COLLECT_LAST" "S74 two-line record"
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" MEAN_SPEED_REASON)" "time record is not one numeric time" \
        "S74: a two-line record has its exact reason"
    ab_collect_expect "S74 selection failure" COMMAND_FAILURE - FAKE_FAIL=foamListTimes
    ab_collect_no_calculation "$AB_COLLECT_LAST" "S74 selection failure"
}
ab_collect_record_earlier() { printf '1\n' > "${1}/checkout/src/batch_9/case_7/vtk/flow_latest_time.txt"; }
ab_collect_record_zero() { printf '0\n' > "${1}/checkout/src/batch_9/case_7/vtk/flow_latest_time.txt"; }
ab_collect_record_two_lines() { printf '2\n2\n' > "${1}/checkout/src/batch_9/case_7/vtk/flow_latest_time.txt"; }

s75_collect_isolates_exact_input_bytes() {
    local setup
    for setup in ab_collect_no_epsilon ab_collect_komega ab_collect_start_time ab_collect_link_field \
                 ab_collect_hard_link ab_collect_mesh_override ab_collect_unsafe_name; do
        ab_collect_expect "S75 ${setup#ab_collect_}" SOURCE_MISMATCH "$setup"
        ab_collect_no_calculation "$AB_COLLECT_LAST" "S75 ${setup#ab_collect_}"
        if [[ "$setup" == ab_collect_mesh_override ]]; then
            assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" MEAN_SPEED_REASON)" "override" \
                "S75: a mesh in the time directory has its exact reason"
        fi
    done
    ab_collect_expect "S75 changed copy" INPUT_CHANGED ab_collect_bad_copy
    ab_collect_no_calculation "$AB_COLLECT_LAST" "S75 changed copy"
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" MEAN_SPEED_REASON)" "before the calculation" \
        "S75: a snapshot that differs from the source stops the work before the calculation"
    ab_collect_expect "S75 copy failure" COMMAND_FAILURE ab_collect_fail_copy
    ab_collect_no_calculation "$AB_COLLECT_LAST" "S75 copy failure"
    ab_collect_expect "S75 changed source" INPUT_CHANGED - \
        "FAKE_TOUCH_FILE=@WORKSPACE@/checkout/src/batch_9/case_7/flow/2/U"
    ab_collect_expect "S75 changed snapshot" INPUT_CHANGED - FAKE_TAMPER=simpleFoam:edit-U
}
ab_collect_no_epsilon() { rm -f -- "$(ab_collect_flow "$1")/2/epsilon"; }
ab_collect_komega() { sed -i -e 's/kEpsilon/kOmega/' "$(ab_collect_flow "$1")/constant/turbulenceProperties"; }
ab_collect_start_time() {
    sed -i -e 's/^startFrom .*/startFrom         startTime;/' "$(ab_collect_flow "$1")/system/controlDict"
}
ab_collect_link_field() {
    local flow
    flow="$(ab_collect_flow "$1")"
    mv -- "${flow}/2/nut" "${flow}/2/nut.real"
    ln -s nut.real "${flow}/2/nut"
}
ab_collect_hard_link() { ln -- "$(ab_collect_flow "$1")/constant/polyMesh/points" "${1}/points.link"; }
ab_collect_mesh_override() { mkdir -p "$(ab_collect_flow "$1")/2/polyMesh"; }
ab_collect_unsafe_name() { printf 'x\n' > "$(ab_collect_flow "$1")/2/bad name"; }
ab_collect_fail_copy() { ab_fake_fail "$1" cp '--parents'; }
# ab_collect_bad_copy <workspace> - a cp that copies, and then changes one byte
# of the snapshot U when it makes the snapshot.
ab_collect_bad_copy() {
    local real
    real="$(command -v cp)"
    {
        printf '#!/usr/bin/env bash\n'
        printf '%q "$@" || exit $?\n' "$real"
        printf 'for argument in "$@"; do [[ "$argument" == --parents ]] && printf x >> "${@: -1}/2/U"; done\n'
        printf 'exit 0\n'
    } > "${1}/fakebin/cp"
    chmod +x "${1}/fakebin/cp"
}

s76_collect_output_fails_closed() {
    local entry
    ab_collect_expect "S76 command failure" COMMAND_FAILURE - FAKE_FAIL=simpleFoam
    while IFS='|' read -r entry code; do
        ab_collect_expect "S76 ${entry}" "$code" - "$entry"
    done <<'COLLECT_CASES'
FAKE_OUTPUT=none|MISSING_OUTPUT
FAKE_OUTPUT=region-folder|MISSING_OUTPUT
FAKE_OUTPUT=second-file|DUPLICATE_OUTPUT
FAKE_OUTPUT=other-time|DUPLICATE_OUTPUT
FAKE_OUTPUT=two-rows|DUPLICATE_OUTPUT
FAKE_OUTPUT=two-headers|DUPLICATE_OUTPUT
FAKE_REGION=all region1|PARSE_FAILURE
FAKE_COLUMN=volAverage(U)|PARSE_FAILURE
FAKE_ROW_TIME=1|PARSE_FAILURE
FAKE_DAT_CELLS=|PARSE_FAILURE
FAKE_VALUE=abc|PARSE_FAILURE
FAKE_DAT_VOLUME=0|INVALID_VOLUME
FAKE_DAT_VOLUME=-3|INVALID_VOLUME
FAKE_VALUE=nan|NON_FINITE_VALUE
FAKE_VALUE=inf|NON_FINITE_VALUE
FAKE_VALUE=-1.5e+00|NEGATIVE_VALUE
COLLECT_CASES
}

s77_collect_accepts_zero_and_has_no_range() {
    local value workspace
    for value in 0 1.234e+03; do
        workspace="$(new_workspace "s77_value_${value}")"
        ab_collect_fixture "$workspace"
        ab_collect_run "$workspace" FAKE_VALUE="$value" > /dev/null
        assert_eq "AVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" \
            "S77: the value ${value} is AVAILABLE"
        assert_eq "$value" "$(ab_collect_value "$workspace" MEAN_SPEED_VALUE)" "S77: the value ${value} stays as written"
    done
}

s78_collect_requires_the_proven_environment() {
    local label
    for label in "FAKE_PACKAGE_VERSION=2512.0-1" "FAKE_ARCH=aarch64" "FAKE_WM_VERSION=v2506" \
                 "FAKE_WM_COMPILER=Clang" "FAKE_BASHRC_STATUS=1" "FAKE_EXTRA_PATH=@WORKSPACE@/elsewhere" \
                 "OPENFOAM_BASELINE=v2506"; do
        ab_collect_expect "S78 ${label}" ENVIRONMENT_MISMATCH - "$label"
        ab_collect_no_openfoam "$AB_COLLECT_LAST" "S78 ${label}"
        assert_eq "0" "$(awk -F '\t' '$1 == "curl" || $1 == "sudo"' "${AB_COLLECT_LAST}/calls.tsv" | wc -l)" \
            "S78 ${label}: no package is installed"
    done
}

s79_collect_limits_stops_and_cleanup() {
    local workspace run elapsed child pid library out group start
    # A blocked calculation with a child that ignores SIGTERM stops in the
    # metric window, and the capture, summary, and upload stay eligible.
    workspace="$(new_workspace s79_timeout)"
    ab_collect_fixture "$workspace"
    run="$(ab_collect_run "$workspace" FAKE_TERM_CHILD="${workspace}/term_child" \
        CAPTURE_DEADLINE="$(( $(date +%s) + 180 + 40 ))")"
    elapsed="$(sed -n -e 's/^elapsed=//p' <<< "$run")"
    child="$(cat "${workspace}/term_child" 2>/dev/null || true)"
    if [[ "$child" =~ ^[0-9]+$ ]] && kill -0 "$child" 2>/dev/null; then
        kill -KILL "$child" 2>/dev/null || true
        _fail "S79: the TERM-ignoring child must stop in the metric window"
    fi
    [[ "$child" =~ ^[0-9]+$ ]] || _fail "S79: the blocked calculation must start" "$(tail -n 8 "${workspace}/capture_step.out")"
    assert_eq "TIMEOUT" "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" "S79: a blocked calculation is TIMEOUT"
    assert_eq "REMOVED" "$(ab_collect_value "$workspace" CLEANUP_RESULT)" "S79: the cleanup still removes the task directory"
    assert_contains "$run" "status=0" "S79: the capture step ends with status 0"
    (( elapsed <= 40 )) || _fail "S79: the metric work ends before the capture work limit" "elapsed: ${elapsed}"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "S79: the capture is incomplete"
    assert_contains "$(ab_collect_summary "$workspace")" "| Mean speed | \`UNAVAILABLE\` |" "S79: the summary still runs"
    # No time for the metric work: nothing starts.
    ab_collect_expect "S79 no budget" TIMEOUT - "CAPTURE_DEADLINE=$(( $(date +%s) + 180 + 25 ))"
    ab_collect_no_openfoam "$AB_COLLECT_LAST" "S79 no budget"
    # The input, log, and task-directory byte limits.
    ab_collect_expect "S79 file count" RESOURCE_LIMIT ab_collect_many_files
    ab_collect_no_calculation "$AB_COLLECT_LAST" "S79 file count"
    ab_collect_expect "S79 input bytes" RESOURCE_LIMIT ab_collect_big_input
    ab_collect_no_calculation "$AB_COLLECT_LAST" "S79 input bytes"
    ab_collect_expect "S79 log bytes" RESOURCE_LIMIT - FAKE_STDOUT_BYTES=1048577
    assert_contains "$(cat "${AB_COLLECT_LAST}/runner_temp/evidence/m3-mean-speed/excluded.tsv")" $'\t1048577\t' \
        "S79: the excluded log keeps its size"
    ab_collect_expect "S79 task bytes" RESOURCE_LIMIT - FAKE_BIG_FILE=4294967297
    # A process that leaves the group and keeps its working directory in the
    # task directory stops the removal.
    workspace="$(new_workspace s79_user)"
    ab_collect_fixture "$workspace"
    ab_collect_run "$workspace" FAKE_ESCAPE="${workspace}/escape" > /dev/null
    pid="$(cat "${workspace}/escape" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then kill -KILL "$pid" 2>/dev/null || true; fi
    assert_eq "CLEANUP_FAILURE" "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" \
        "S79: a process in the task directory stops the removal"
    assert_eq "REFUSED_PROCESS_ACTIVE" "$(ab_collect_value "$workspace" CLEANUP_RESULT)" "S79: the cleanup refusal is explicit"
    [[ -n "$(ab_collect_tasks "$workspace")" ]] || _fail "S79: the task directory stays while a process uses it"
    # A failed removal.
    ab_collect_failed_removal
    # A capture that stops before the metric work publishes UNAVAILABLE with
    # NOT_COMPLETED, never AVAILABLE.
    workspace="$(new_workspace s79_not_reached)"
    ab_collect_fixture "$workspace"
    ab_collect_run "$workspace" LIB="${workspace}/missing-library.sh" > /dev/null
    assert_eq "FAILED" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "S79: the capture work does not run"
    assert_eq "UNAVAILABLE" "$(ab_env_last "$workspace" MEAN_SPEED_VERDICT)" "S79: no metric after a stopped capture"
    assert_eq "NOT_COMPLETED" "$(ab_env_last "$workspace" MEAN_SPEED_REASON_CODE)" \
        "S79: a capture that stops before the metric work gives NOT_COMPLETED"
    assert_contains "$(ab_collect_summary "$workspace")" "| Mean speed | \`UNAVAILABLE\` |" \
        "S79: the summary shows the stopped metric"
    # A process group that the stop cannot empty: kill -0 fails with EPERM, and
    # the stop says NOT_STOPPED by its deadline. NOT_STOPPED is a process-stop
    # failure.
    group="$(ab_metric_foreign_group)"
    [[ -n "$group" ]] || _fail "S79: the test host must have a process group that the test user may not signal"
    workspace="$(new_workspace s79_stop)"
    ab_collect_fixture "$workspace"
    library="$(ab_collect_block "$workspace")"
    [[ -n "$library" ]] || _fail "S79: the metric functions must be extracted"
    start="$(date +%s%3N)"
    out="$(env PATH="${workspace}/fakebin:${PATH}" bash -c "set -euo pipefail
        ${library}
        metric_stop_group ${group} probe \$(( \$(date +%s%3N) + 2000 )) && echo stop-status=0 || echo stop-status=\$?
        echo stop=\${M_STOP}
        M_CODE='' M_REASON='' M_OUTCOME=NOT_STOPPED M_GROUP=${group} M_STATUS=0 M_LIMIT=2000
        metric_require metric COMMAND_FAILURE && echo require-status=0 || echo require-status=\$?
        echo code=\${M_CODE}" 2>&1 || true)"
    assert_contains "$out" "stop-status=1" "S79: the stop does not take a group of another user as empty"
    assert_contains "$out" "stop=NOT_STOPPED" "S79: the stop records NOT_STOPPED"
    (( $(date +%s%3N) - start <= 3500 )) || _fail "S79: the stop ends by its deadline"
    assert_contains "$out" "require-status=1" "S79: NOT_STOPPED stops the metric work"
    assert_contains "$out" "code=PROCESS_STOP_FAILURE" "S79: NOT_STOPPED is a process-stop failure"
}
ab_collect_many_files() {
    local flow index
    flow="$(ab_collect_flow "$1")"
    for (( index = 0; index < 245; index++ )); do : > "${flow}/2/extra${index}"; done
}
ab_collect_big_input() { truncate -s 2147483649 "$(ab_collect_flow "$1")/2/big"; }
ab_collect_failed_removal() {
    local workspace
    workspace="$(new_workspace s79_remove)"
    ab_collect_fixture "$workspace"
    ab_fake_fail "$workspace" rm '*m3-metric-collection.*'
    ab_collect_run "$workspace" > /dev/null
    assert_eq "CLEANUP_FAILURE" "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" "S79: a failed removal is a cleanup failure"
    assert_eq "UNAVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" "S79: no value after a failed removal"
    assert_contains "$(ab_collect_value "$workspace" CLEANUP_RESULT)" "FAILED" "S79: the cleanup result shows the failure"
}

s80_collect_keeps_the_other_verdicts_separate() {
    local workspace batch summary
    workspace="$(new_workspace s80_separate)"
    ab_collect_fixture "$workspace"
    batch="${workspace}/checkout/src/batch_9"
    ab_checkmesh_log "${batch}/case_7/flow/log.checkMesh" failed
    printf '<VTKFile><Piece><PointData><DataArray Name="U"/></PointData></Piece></VTKFile>\n' \
        > "${batch}/case_7/vtk/flow_latest_100.vtu"
    ab_collect_run "$workspace" > /dev/null
    assert_eq "AVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" "S80: the metric is AVAILABLE"
    assert_eq "MESH_QUALITY_REVIEW_REQUIRED" "$(ab_env_last "$workspace" MESH_QUALITY_VERDICT)" \
        "S80: failed mesh checks stay blocking for mesh acceptance"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" VTU_REQUIRED_FIELDS_VERDICT)" \
        "S80: missing required PointData stays incomplete"
    assert_ne "CONVERGED" "$(ab_env_last "$workspace" CONVERGENCE_VERDICT)" "S80: the metric gives no convergence"
    assert_contains "$(cat "${workspace}/runner_temp/evidence/phase-results.txt")" "OVERALL_RESULT=SUCCEEDED" \
        "S80: the product result stays"
    assert_not_contains "$(cat "${workspace}/runner_temp/evidence/mesh-quality.txt")" "MEAN_SPEED" \
        "S80: the mesh evidence holds no metric value"
    summary="$(ab_collect_summary "$workspace")"
    assert_contains "$summary" "| Mesh quality | \`MESH_QUALITY_REVIEW_REQUIRED\` |" "S80: the mesh row stays separate"
    assert_contains "$summary" "| VTU required fields | \`INCOMPLETE\` |" "S80: the PointData row stays separate"
    assert_contains "$summary" "| Mean speed | \`AVAILABLE\` |" "S80: the metric row is separate"
}

s81_collect_keeps_the_workflow_interface() {
    local workspace body name constant
    workspace="$(new_workspace s81_interface)"
    ab_collect_fixture "$workspace"
    body="$(cat "${workspace}/capture_step.sh")"
    assert_eq $'on:\n  workflow_dispatch:' \
        "$(awk '/^on:/ { on = 1; print; next } on && /^[^ ]/ { exit } on && NF { print }' "$WORKFLOW")" \
        "S81: workflow_dispatch without inputs is the only trigger"
    assert_contains "$(cat "$WORKFLOW")" $'permissions:\n  contents: read' "S81: the token can only read contents"
    assert_contains "$(cat "$WORKFLOW")" $'  evidence:\n    name: OpenFOAM v2512 four-Stage evidence\n    runs-on: ubuntu-24.04\n    timeout-minutes: 120' \
        "S81: the job, runner, and 120-minute setting stay"
    assert_eq "Start the evidence clock|Create the bounded-runner library|Check out the repository|Record the checkout phase result|Resolve the OpenFOAM baseline|Install OpenFOAM v2512|Record the OpenFOAM version|Prepare the one-Case DOE Batch CSV|Run the Orchestrator|Capture the evidence|Write the job summary|Upload the evidence artifacts" \
        "$(sed -n -e 's/^      - name: //p' "$WORKFLOW" | paste -sd '|' -)" "S81: the step list stays"
    assert_eq "1" "$(grep -cF -- "bash -c 'bash src/run_batch.sh --stage setup,mesh,flow,post-processing -j 1 \"\$1\" \\" "$WORKFLOW")" \
        "S81: the Orchestrator vector stays"
    assert_eq "10" "$(awk '/^      - name: Capture the evidence$/ { found = 1; next } found && /^        timeout-minutes:/ { print $2; exit }' "$WORKFLOW")" \
        "S81: the capture step guard stays 10 minutes"
    for constant in 'work_cap_seconds=480' 'deadline_reserve_seconds=180'; do
        assert_eq "1" "$(grep -cx -- "$constant" <<< "$body")" "S81: the capture keeps ${constant}"
    done
    assert_eq "1" "$(grep -cF -- 'foamListTimes -case "$SOURCE_FLOW_CASE" -latestTime' <<< "$body")" \
        "S81: the exact selection vector appears once"
    assert_eq "1" "$(grep -cF -- "simpleFoam -case \"\$CASE_DIR\" -postProcess -time \"\$SELECTED_TIME\" -fields '(U)' -dict \"\$TASK_TEMP/config/metric-functions\"" <<< "$body")" \
        "S81: the exact calculation vector appears once"
    assert_eq "2" "$(grep -cE '^[[:space:]]*metric_foam_op [A-Za-z-]+ [A-Z]+ ' <<< "$body")" \
        "S81: the metric work runs only the two OpenFOAM vectors"
    for constant in 'METRIC_TOTAL_MS=180000' 'METRIC_SELECT_MS=10000' 'METRIC_CALC_MS=60000' 'METRIC_WORK_MS=90000' \
                    'METRIC_CLEANUP_MS=20000' 'METRIC_KILL_GRACE_MS=5000' 'METRIC_STOP_RESERVE_MS=1000' \
                    'METRIC_MAX_FILES=256' 'METRIC_MAX_INPUT_BYTES=2147483648' 'METRIC_MAX_TASK_BYTES=4294967296' \
                    'METRIC_LOG_LIMIT=1048576' 'METRIC_LOGS_LIMIT=8388608' 'METRIC_EVIDENCE_LIMIT=10485760' \
                    "METRIC_DICTIONARY_SHA256=${AB_COLLECT_DICTIONARY_SHA}"; do
        assert_eq "1" "$(grep -cx -- "$constant" <<< "$body")" "S81: the metric work sets ${constant}"
    done
    for name in "name: openfoam-v2512-evidence" "path: \${{ runner.temp }}/evidence" "include-hidden-files: true" \
                "retention-days: 90"; do
        assert_contains "$(cat "$WORKFLOW")" "$name" "S81: the upload keeps ${name}"
    done
}

s82_collect_failed_log_evidence_fails_closed() {
    # F1: the log inventory or the log copy fails. The evidence is incomplete,
    # so no value is accepted.
    ab_collect_expect "S82 log inventory" COMMAND_FAILURE ab_collect_fail_log_sizes
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" LOGS_RETAINED)" "NO_" "S82: the logs are not retained"
    ab_collect_expect "S82 log copy" COMMAND_FAILURE ab_collect_fail_log_copy
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" LOGS_RETAINED)" "NO_" "S82: the logs are not retained"
    # A failed listing of the evidence inventory is not an empty inventory.
    ab_collect_expect "S82 evidence inventory" COMMAND_FAILURE ab_collect_fail_inventory
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" INVENTORY)" "UNAVAILABLE_" "S82: the inventory is not complete"
}
ab_collect_fail_log_sizes() { ab_fake_fail "$1" find '*m3-metric-collection.*/logs'; }
ab_collect_fail_log_copy() { ab_fake_fail "$1" cp '*m3-mean-speed/logs/'; }
ab_collect_fail_inventory() { ab_fake_fail "$1" find './inventory.txt'; }

s83_collect_task_bytes_stay_in_the_limit() {
    local workspace observed evidence label before
    # F2: a file that would take the task directory above 4294967296 apparent
    # bytes for a moment is stopped, so the task directory never holds it.
    workspace="$(new_workspace s83_transient)"
    ab_collect_fixture "$workspace"
    ab_collect_run "$workspace" FAKE_TRANSIENT_BYTES=4294967297 \
        FAKE_TRANSIENT_RECORD="${workspace}/observed_task_bytes" > /dev/null
    observed="$(cat "${workspace}/observed_task_bytes" 2>/dev/null || true)"
    if [[ "$observed" =~ ^[0-9]+$ ]] && (( observed > 4294967296 )); then
        _fail "S83: the task directory must never hold more than 4294967296 bytes" "observed: ${observed}"
    fi
    assert_eq "RESOURCE_LIMIT" "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" \
        "S83: a file above the task byte limit is RESOURCE_LIMIT"
    assert_eq "UNAVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" "S83: no value is accepted"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "S83: the capture is incomplete"
    # The file limit of the copy and of the calculation is the task bytes left
    # after the measurement just before the operation.
    evidence="${workspace}/runner_temp/evidence/m3-mean-speed"
    for label in copy:task-bytes-before-copy:TASK_COPY_FILE_LIMIT_BYTES \
                 metric:task-bytes-before-calculation:TASK_CALCULATION_FILE_LIMIT_BYTES; do
        before="$(cut -f 1 "${evidence}/$(cut -d : -f 2 <<< "$label").out" 2>/dev/null || true)"
        [[ "$before" =~ ^[0-9]+$ ]] || _fail "S83: the measurement before ${label%%:*} is recorded"
        assert_eq "$(( 4294967296 - before ))" "$(ab_collect_value "$workspace" "${label##*:}")" \
            "S83: the ${label%%:*} file limit is the task bytes left"
        assert_eq "$(( 4294967296 - before ))" \
            "$(awk -F '\t' -v op="${label%%:*}" '$2 == op { print $5 }' "${evidence}/commands.tsv")" \
            "S83: the ${label%%:*} operation runs with that file limit"
    done
    # An input file above the 1048577-byte limit of the other operations
    # copies, because the copy has the task bytes left.
    workspace="$(new_workspace s83_large_input)"
    ab_collect_fixture "$workspace"
    truncate -s 2097152 "$(ab_collect_flow "$workspace")/2/large"
    ab_collect_run "$workspace" > /dev/null
    assert_eq "AVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" "S83: a 2097152-byte input copies"
    assert_eq "16" "$(ab_collect_value "$workspace" INPUT_FILES)" "S83: the large input is in the snapshot"
    # Two files, each in its file limit, that together take the task directory
    # above the limit, are seen by the measurement after the calculation.
    ab_collect_expect "S83 measured total" RESOURCE_LIMIT - FAKE_BIG_FILE=4293918720 FAKE_STDOUT_BYTES=1048577
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" MEAN_SPEED_REASON)" "the task directory has" \
        "S83: the measurement after the calculation sees the total"
}

s84_collect_cleanup_needs_a_complete_process_check() {
    local workspace pid
    # F3: a process check that cannot read a process of the test user keeps
    # the task directory.
    workspace="$(new_workspace s84_failed_scan)"
    ab_collect_fixture "$workspace"
    ab_fake_fail "$workspace" find '/proc/*'
    ab_collect_run "$workspace" > /dev/null
    assert_eq "CLEANUP_FAILURE" "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" \
        "S84: a failed process check stops the removal"
    assert_eq "REFUSED_PROCESS_CHECK" "$(ab_collect_value "$workspace" CLEANUP_RESULT)" \
        "S84: the refusal names the process check"
    [[ -n "$(ab_collect_tasks "$workspace")" ]] || _fail "S84: the task directory stays after a failed process check"
    workspace="$(new_workspace s84_hidden_user)"
    ab_collect_fixture "$workspace"
    ab_collect_run "$workspace" FAKE_HIDDEN_USER="${workspace}/hidden_user" > /dev/null
    pid="$(cat "${workspace}/hidden_user" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        kill -KILL "$pid" 2>/dev/null || true
    else
        _fail "S84: the hidden process must start" "$(tail -n 5 "${workspace}/capture_step.out")"
    fi
    assert_eq "CLEANUP_FAILURE" "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" \
        "S84: an unreadable process of the test user stops the removal"
    assert_eq "REFUSED_PROCESS_CHECK" "$(ab_collect_value "$workspace" CLEANUP_RESULT)" \
        "S84: the refusal names the incomplete process check"
    assert_eq "UNAVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" "S84: no value is accepted"
    [[ -n "$(ab_collect_tasks "$workspace")" ]] || _fail "S84: the task directory stays while the process check is incomplete"
    # A process that only maps a file of the task directory also uses it.
    workspace="$(new_workspace s84_mapped_file)"
    ab_collect_fixture "$workspace"
    ab_collect_run "$workspace" FAKE_MAPPED_FILE="${workspace}/mapped_file" > /dev/null
    pid="$(cat "${workspace}/mapped_file" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        kill -KILL "$pid" 2>/dev/null || true
    else
        _fail "S84: the mapping process must start" "$(tail -n 5 "${workspace}/capture_step.out")"
    fi
    assert_eq "REFUSED_PROCESS_ACTIVE" "$(ab_collect_value "$workspace" CLEANUP_RESULT)" \
        "S84: a mapped file of the task directory stops the removal"
    assert_contains "$(ab_collect_value "$workspace" MEAN_SPEED_REASON)" "/maps" "S84: the reason names the mapped file"
    [[ -n "$(ab_collect_tasks "$workspace")" ]] || _fail "S84: the task directory stays while a file of it is mapped"
}

s85_collect_time_record_read_is_bounded() {
    local workspace start finish end used
    # F4: a slow read of the post-processing time record stops in its limit,
    # and the metric work ends by its absolute end.
    workspace="$(new_workspace s85_slow_record)"
    ab_collect_fixture "$workspace"
    ab_fake_hang "$workspace" cat '*flow_latest_time.txt'
    ab_fake_hang "$workspace" head '*flow_latest_time.txt'
    ab_collect_run "$workspace" CAPTURE_DEADLINE="$(( $(date +%s) + 180 + 45 ))" > /dev/null
    ab_assert_fakes_stopped "$workspace" "S85"
    assert_eq "TIMEOUT" "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" \
        "S85: a slow time-record read is TIMEOUT"
    start="$(ab_collect_value "$workspace" METRIC_START_MS)"
    finish="$(ab_collect_value "$workspace" METRIC_FINISH_MS)"
    end="$(ab_collect_value "$workspace" METRIC_END_MS)"
    used="$(ab_collect_value "$workspace" WORK_USED_MS)"
    [[ "$finish" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] && (( finish <= end )) ||
        _fail "S85: the metric work ends by its absolute end" "finish: ${finish}, end: ${end}"
    [[ "$used" =~ ^[0-9]+$ ]] && (( used >= 1000 )) ||
        _fail "S85: the read counts against the work budget" "used: ${used} ms"
    [[ "$start" =~ ^[0-9]+$ ]] || _fail "S85: the start is recorded"
    # The read takes at most 65 bytes, and the record must be one line of at
    # most 64 bytes with no NUL byte.
    ab_collect_expect "S85 long record" SOURCE_MISMATCH ab_collect_record_long
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" MEAN_SPEED_REASON)" "more than 64 bytes" \
        "S85: a record above 64 bytes is refused"
    ab_collect_expect "S85 NUL record" SOURCE_MISMATCH ab_collect_record_nul
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" MEAN_SPEED_REASON)" "NUL byte" \
        "S85: a record with a NUL byte is refused"
}
ab_collect_record_long() { printf '%064d\n' 2 > "${1}/checkout/src/batch_9/case_7/vtk/flow_latest_time.txt"; }
ab_collect_record_nul() { printf '2\n\0' > "${1}/checkout/src/batch_9/case_7/vtk/flow_latest_time.txt"; }

s86_collect_value_and_volume_convert_to_finite_doubles() {
    # F5: a token that does not convert to a finite double, and a volume that
    # converts to zero.
    ab_collect_expect "S86 speed 1e9999" NON_FINITE_VALUE - FAKE_VALUE=1e9999
    ab_collect_expect "S86 volume 1e-9999" INVALID_VOLUME - FAKE_DAT_VOLUME=1e-9999
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
    s42_spatial_capture_copies_the_refined_vtp
    s43_spatial_capture_discovery_faults
    s44_spatial_capture_vtp_size_limit
    s45_spatial_capture_provenance_and_zero_count
    s46_spatial_capture_setup_logs
    s47_spatial_capture_final_inventory_rule
    s48_capture_deadline_expired_before_an_operation
    s49_capture_slow_discovery_stops_in_the_window
    s50_capture_slow_hash_publishes_no_partial_hash
    s51_capture_slow_copy_publishes_no_partial_file
    s52_capture_failure_and_delayed_success
    s53_capture_term_ignoring_child_is_killed
    s54_run_bounded_stops_the_command_group
    s55_capture_cleanup_stays_in_the_reserve
    s56_metric_workflow_interface
    s57_metric_fixture_is_two_cells_with_the_expected_mean
    s58_metric_pass_records_the_complete_evidence
    s59_metric_dispatch_gates
    s60_metric_package_and_environment_gates
    s61_metric_time_and_region_fail_closed
    s62_metric_mesh_evidence_fail_closed
    s63_metric_inputs_and_output_fail_closed
    s64_metric_value_fail_closed
    s65_metric_limits_and_process_cleanup
    s66_metric_log_and_artifact_limits
    s67_metric_task_directory_and_cleanup
    s68_metric_install_stop_reaches_root_processes
    s69_metric_process_checks_do_not_depend_on_permission
    s70_metric_stop_ends_by_the_operation_deadline
    s71_metric_root_signal_vector_takes_a_small_group_id
    s72_collect_volume_weighted_mean_of_the_latest_time
    s73_collect_needs_a_successful_product_run
    s74_collect_selects_only_the_recorded_latest_time
    s75_collect_isolates_exact_input_bytes
    s76_collect_output_fails_closed
    s77_collect_accepts_zero_and_has_no_range
    s78_collect_requires_the_proven_environment
    s79_collect_limits_stops_and_cleanup
    s80_collect_keeps_the_other_verdicts_separate
    s81_collect_keeps_the_workflow_interface
    s82_collect_failed_log_evidence_fails_closed
    s83_collect_task_bytes_stay_in_the_limit
    s84_collect_cleanup_needs_a_complete_process_check
    s85_collect_time_record_read_is_bounded
    s86_collect_value_and_volume_convert_to_finite_doubles
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
