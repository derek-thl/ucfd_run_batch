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
# Check S87 covers PR #98 review 5466999244 (F3): a process of the test user
# that starts before the metric clock and enters the task Case. An unreadable
# one keeps the Case with REFUSED_PROCESS_CHECK; a readable one with
# REFUSED_PROCESS_ACTIVE.
#
# Checks S88 to S92 cover the corrected #80 contract 6084196797: the measured
# totals, positive file allowances, and the transient multi-file limitation
# (S88); and the bounded read-only root check of the cleanup: its fixed source
# and arguments (S89), the failures that keep the task directory (S90), its
# self-termination (S91), and its one cleanup clock (S92). The cleanup check
# reads /proc as root through one exact sudo -n vector. Only the approved
# GitHub-hosted ubuntu-24.04 runner runs that vector with the real sudo, in the
# unchanged steps of S72 to S87. Every other run uses the controlled fake
# boundary of ab_collect_root_fake, which gives and claims no privilege.
#
# Check S93 covers PR #98 review 5476930073 (F6): a terminal time of the
# result frame that is zero, before the launch, after the return, or after the
# absolute end; a frame number with a leading zero; and a failed final clock
# read of the guard or launch or return clock read of the collector, also a
# failed read that sets a valid first field (review 5478239999). Each keeps the
# task directory with REFUSED_PROCESS_CHECK.
#
# Checks S94 to S99 cover the Case 7 functional-record capture in the evidence
# workflow (Issue #80, admission 6136000731 of approved contract 6127203837).
# S94 runs the extracted capture step with the completed collection of S72 and
# a complete set of controlled Case 7 records. S95 to S98 run the extracted
# receipt functions alone, each run with one controlled fault: the time,
# signature, VTU, and producer checks (S95), the distinct source-record results
# (S96), the selected Setup entries (S97), and the time and byte limits (S98).
# S99 checks the frozen blocks and the unchanged interface. A controlled record
# is capability evidence only, never an actual Case receipt or M3 acceptance.
# PR #102 review 5500290409 adds: R1 (S95), a NUL byte after a valid prefix of
# the time record or the signature, and a retained record that a read cannot
# give completely; R2 (S97), a reference source (a DOE Batch CSV or a geometry
# log) that changes between its hashes; R3 (S98), a result.env that cannot be
# written, and a partial result.env.
#
# Checks S100 to S103 cover the fixed provision of the pinned VTU reader (Issue
# #80, admission 6160693923 of dependency addendum 6158946927 and Owner decision
# 6160428682). S100 checks that both workflows embed the same provision block,
# with the thirteen approved artifacts, the exact lock and closure, the approved
# limits and vectors, and that the contract-tests step and the Orchestrator gate
# are the only changes of those steps. S101 runs the extracted block, the
# contract-tests step, and the Orchestrator step with no network access: no
# time, an unsafe RUNNER_TEMP, a failed step, a bounded operation, and the stop
# check. S102 runs the three fixed Python programs with controlled fakes only: a
# fake HTTPS connection and small wheels for the downloader, a fake pip wheel
# for the installer bootstrap, and a fake site for the import check. S103 reads
# the receipt of the real provision of the contract-tests job. Without that task
# root, S103 fails; no test installs a package. A controlled provision is
# capability evidence only.
#
# Checks S104 to S107 cover the focused readback of the two Case 7 flow VTU
# files (Issue #80, approved proposal 6136150842, Sections 2 to 6, and the
# same admission). S104 runs the extracted reader functions with the real
# pinned consumer of the contract-tests provision on controlled VTU files:
# inline ASCII and base64, appended raw and base64, zlib, a polyhedron, and one
# file for each failure: a truncated appended payload, a corrupt compressed
# block, missing or CellData-only U, wrong components, a short array, missing
# Points or cell offsets, bad XML, polyhedron cells without faces, a missing
# wallDistance, two pieces, another data set type, and a reader warning. S105
# runs the extracted readback after the receipt of the S94 fixture with the
# real consumer: two-file PASS, one-file FAIL, a source change during or before
# the read, a failed product run, no provision, a missing file, and a mixed
# time. S106 runs the same readback with controlled fake roots and sites for the
# guards only: timeout, output, memory, version, native, module, receipt,
# root, time, source-size, link, combined-evidence, and stop limits. S107 checks
# the frozen blocks, the call order, the limits, the fixed vector, the reader
# boundary, and the published result. A fake site never proves native decoding,
# and a controlled PASS is capability evidence only, never F4 or M3 acceptance.
#
# Checks S108 and S109 cover the review corrections R1 and R2 of PR #103 (Issue
# #80, correction 6166142012). A fake site writes one complete reader record to
# file descriptor 3 and then ends the native command; the record drives the
# outcome and record guards only and is never a native read. S108: after a
# complete PASS record, an unexpected exit status or a signal gives no PASS,
# and a FAIL record stays FAIL. S109: a result.env that cannot be written, an
# inventory.tsv that cannot be written, and a missing final SHA-256 give no
# retained, side, or published PASS; the publication of the capture step gives
# no PASS without the complete inventory of the retained records.
#
# Every observation runs in its own child process, so one failure cannot hide a
# later failure and no observation can see the workspace of another observation.
# The scenario reports every failing observation and then fails.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# The contract-tests job provisions the pinned VTU reader before the suite
# (S100 to S103). Only the native observations use that task root, so the
# earlier observations run without it, as before.
if [[ -n "${M3_VTU_DEP_ROOT:-}" ]]; then
    AB_VTU_DEP_ROOT="$M3_VTU_DEP_ROOT"
fi
export AB_VTU_DEP_ROOT="${AB_VTU_DEP_ROOT:-}"
unset M3_VTU_DEP_ROOT M3_VTU_PROVISION_RESULT

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
        # FAKE_TRANSIENT_BYTES=<bytes>: FAKE_TRANSIENT_FILES (default 1) sparse
        # files of that apparent size each exist together for a moment; the
        # task bytes at that moment go to FAKE_TRANSIENT_RECORD.
        if [[ -n "${FAKE_TRANSIENT_BYTES:-}" ]]; then
            for (( transient = 0; transient < ${FAKE_TRANSIENT_FILES:-1}; transient++ )); do
                truncate -s "$FAKE_TRANSIENT_BYTES" "${case_dir}/transient${transient}.bin" || exit $?
            done
            du -sb -- "${case_dir%/case}" | cut -f 1 > "$FAKE_TRANSIENT_RECORD"
            rm -f -- "${case_dir}"/transient*.bin
        fi
        # FAKE_OLDER_FIFO=<fifo>, FAKE_OLDER_OUT=<file>: a process that the test
        # started before the metric clock gets the Case path through the FIFO,
        # enters the Case, and writes READY to FAKE_OLDER_OUT.
        if [[ -n "${FAKE_OLDER_FIFO:-}" ]]; then
            printf '%s\n' "$case_dir" > "$FAKE_OLDER_FIFO"
            for (( wait_tick = 0; wait_tick < 300; wait_tick++ )); do
                [[ "$(tail -n 1 "$FAKE_OLDER_OUT" 2>/dev/null)" == READY ]] && break
                sleep 0.01
            done
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

# The cleanup process check (corrected contract 6084196797, Section 4) reads
# /proc as root through one exact sudo -n vector. Only the approved ephemeral
# GitHub-hosted ubuntu-24.04 runner runs that vector with the real sudo, and
# only in an unchanged extracted step. Everywhere else, each extracted step gets
# the controlled fake privilege boundary of ab_collect_root_fake, and no test
# runs the real sudo.
if [[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted && "${ImageOS:-}" == ubuntu24 ]]; then
    AB_CHECK_HOSTED=yes
else
    AB_CHECK_HOSTED=no
fi
AB_CHECK_PREFIX="-n -- /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/bash --noprofile --norc -p -c"

# ab_collect_root_fake <workspace> [find-mode] - the controlled fake privilege
# boundary of the process check in the extracted capture step. It gives no
# privilege and claims none:
# - /usr/bin/sudo becomes <workspace>/rootfake/sudo. It accepts only the exact
#   admitted vector, records each call in root_calls.tsv (the fixed source as
#   its SHA-256), and runs the command after "--" as the test user. As in the
#   worst case of sudo, a SIGTERM of the caller does not stop the command, and
#   the command writes straight to the inherited output. FAKE_CHECK selects one
#   behavior: view (the default) then drops the permission errors of the
#   processes that the test user cannot read, as the root view of a test host
#   does, because no such host process uses a new test directory; user keeps
#   them, as a read that is denied even at the admitted boundary; deny refuses
#   as sudo -n without a rule does; fail runs the check and ends with status 1;
#   big writes more than the file limit; frame:<kind> writes one controlled
#   result frame and runs no check. FAKE_CHECK_DELAY delays the root entry.
#   FAKE_CHECK_CLOCK changes the return clock of ab_check_parent_clock.
# - with a find mode, /usr/bin/find of the fixed check source becomes
#   <workspace>/rootfake/find: fail (a read error), slow (a scan that blocks),
#   ignore (a scan child that ignores SIGTERM), or orphan (the scan ends at once
#   and leaves a check child that ignores SIGTERM). Each records its PIDs in
#   root_children. clock removes the boot clock of the fixed source in the
#   scan, after the launch read, and then runs the real find.
# - stat reports owner 0 for each file under rootfake, as for an installed
#   root-owned tool; FAKE_CHECK_OWNER=keep reports the real owner.
# - the OS record of the hosted-runner gate becomes <workspace>/os-release.
ab_collect_root_fake() {
    local workspace="$1" mode="${2:-}" root="${1}/rootfake" step="${1}/capture_step.sh"
    mkdir -p "$root"
    chmod 755 "$root"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'calls=%q\nchildren=%q\n' "${workspace}/root_calls.tsv" "${workspace}/root_children"
        cat <<'ROOT_FAKE'
set -u
expected="-n -- /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/bash --noprofile --norc -p -c"
record="sudo"
index=0
for argument in "$@"; do
    index=$(( index + 1 ))
    if (( index == 12 )); then
        argument="<source sha256 $(printf '%s' "$argument" | sha256sum | cut -d ' ' -f 1)>"
    fi
    record+=$'\t'"${argument}"
done
printf '%s\n' "$record" >> "$calls"
if (( $# != 19 )) || [[ "${*:1:11}" != "$expected" || "${13}" != m3-process-check ]]; then
    echo "fake sudo: not the admitted process-check vector" >&2
    exit 97
fi
task="${14}" runner="${15}" uid="${16}" end="${18}" token="${19}"
# The worst case of sudo: a SIGTERM of the caller does not stop the command
# (the runner user may be unable to signal the root-owned sudo), and the
# command writes straight to the inherited output.
trap ':' TERM
# FAKE_CHECK_CLOCK=missing|malformed|partial|restore: at the end, the return
# clock of the collector (see ab_check_parent_clock) is removed, holds a
# malformed value, holds the current value with no line end (a read sets the
# valid first field and returns status 1), or is a link to /proc/uptime again.
fake_clock() {
    local clock="${calls%/*}/parent_uptime" up idle
    case "${FAKE_CHECK_CLOCK:-}" in
        missing) rm -f -- "$clock" ;;
        malformed) rm -f -- "$clock"; printf 'x 1.00\n' > "$clock" ;;
        partial)
            read -r up idle < /proc/uptime
            rm -f -- "$clock"
            printf '%s %s' "$up" "$idle" > "$clock" ;;
        restore) rm -f -- "$clock"; ln -s /proc/uptime "$clock" ;;
    esac
}
trap fake_clock EXIT
run() {
    local child status
    "$@" &
    child=$!
    while :; do
        wait "$child" && status=0 || status=$?
        [[ -e "/proc/${child}" ]] || return "$status"
    done
}
if [[ -n "${FAKE_CHECK_DELAY:-}" ]]; then
    sleep "$FAKE_CHECK_DELAY"
fi
mode="${FAKE_CHECK:-view}"
shift 2
case "$mode" in
    view)
        run "$@"
        status=$?
        # The root view, after the check: drop the permission errors. One
        # rename replaces the frame, so the SIGKILL of the outer operation,
        # which can come at the same time, leaves one whole frame.
        out="$(readlink -f "/proc/$$/fd/1")"
        awk '
            /^UNCERTAIN / && (/: Permission denied$/ || /\/maps: grep status 2$/) {
                if (match($0, /\/proc\/[0-9]+/)) hidden[substr($0, RSTART, RLENGTH)] = 1
                next
            }
            /^OLDER_UNREADABLE / && ($2 in hidden) { next }
            { print }' "$out" > "${calls%/*}/root_view.tmp" && mv -f -- "${calls%/*}/root_view.tmp" "$out"
        exit "$status" ;;
    user) run "$@"; exit $? ;;
    deny) echo "sudo: a password is required" >&2; exit 1 ;;
    fail) run "$@"; exit 1 ;;
    big) yes M3_CHECK_OUTPUT | head -c 1100000; exit $? ;;
    frame:*) ;;
    *) echo "fake sudo: unknown FAKE_CHECK ${mode}" >&2; exit 98 ;;
esac
# frame:<kind> - one controlled result frame from this process; no check runs.
kind="${mode#frame:}"
read -r up _ < /proc/uptime
entry=$(( 10#${up/./} ))
scan=$(( end - entry - 600 ))
(( scan > 600 )) && scan=600
read -r line < "/proc/$$/stat"
read -r -a fields <<< "${line##*) }"
own="${fields[19]}" pid=$$ start="${fields[19]}"
if [[ "$kind" == live-monitor ]]; then
    setsid sleep 30 < /dev/null > /dev/null 2>&1 &
    pid=$!
    printf '%s\n' "$pid" >> "$children"
    for (( tick = 0; tick < 100; tick++ )); do
        if read -r line < "/proc/${pid}/stat" && read -r -a fields <<< "${line##*) }" && [[ "${fields[2]}" == "$pid" ]]; then
            break
        fi
        sleep 0.01
    done
    start="${fields[19]}"
fi
group="$pid"
[[ "$kind" == monitor-group ]] && group=$(( pid + 1 ))
frame=("LAUNCH 1 ${token} ${entry} ${scan}" "FRAME 1 ${token} ${task} ${uid} ${end}" "MONITOR ${pid} ${group} ${start} $(id -u)")
case "$kind" in
    unknown) frame+=("NOTE an unknown record") ;;
    duplicate) frame+=("FRAME 1 ${token} ${task} ${uid} ${end}") ;;
    target) frame[1]="FRAME 1 ${token} ${runner}/m3-metric-collection.AAAAAAAA ${uid} ${end}" ;;
    uid) frame[1]="FRAME 1 ${token} ${task} 0 ${end}" ;;
    scan-long) frame[0]="LAUNCH 1 ${token} ${entry} $(( scan + 100 ))" ;;
esac
frame+=("SCAN_END" "CHILD $$ ${own}")
case "$kind" in
    token) frame+=("END 1 ${token}0 COMPLETE ${entry}") ;;
    terminated) frame+=("END 1 ${token} TERMINATED ${entry}") ;;
    no-end) ;;
    end-zero) frame+=("END 1 ${token} COMPLETE 0") ;;
    end-backwards) frame+=("END 1 ${token} COMPLETE $(( entry - 1 ))") ;;
    end-after-return) frame+=("END 1 ${token} COMPLETE ${end}") ;;
    end-after-deadline) frame+=("END 1 ${token} COMPLETE $(( end + 1 ))") ;;
    end-leading-zero) frame+=("END 1 ${token} COMPLETE 0${entry}") ;;
    *) frame+=("END 1 ${token} COMPLETE ${entry}") ;;
esac
[[ "$kind" == after-end ]] && frame+=("SCAN_END")
if [[ "$kind" == truncated ]]; then
    printf '%s\n' "${frame[@]:0:${#frame[@]}-1}"
    printf '%s' "${frame[-1]:0:5}"
else
    printf '%s\n' "${frame[@]}"
fi
exit 0
ROOT_FAKE
    } > "${root}/sudo"
    chmod 755 "${root}/sudo"
    if [[ -n "$mode" ]]; then
        {
            printf '#!/usr/bin/env bash\n'
            printf 'children=%q\nmarker=%q\nmode=%q\nclock=%q\n' "${workspace}/root_children" "${workspace}/root_orphan" \
                "$mode" "${root}/uptime"
            cat <<'ROOT_FIND'
case "$mode" in
    fail) echo "find: simulated read failure" >&2; exit 1 ;;
    clock)
        rm -f -- "$clock"
        exec /usr/bin/find "$@" ;;
    slow) printf '%s\n' "$$" >> "$children"; exec /usr/bin/sleep 300 ;;
    ignore)
        trap '' TERM
        printf '%s\n' "$$" >> "$children"
        /usr/bin/sleep 300 &
        printf '%s\n' "$!" >> "$children"
        wait "$!"
        exit 0 ;;
    orphan)
        if [[ ! -e "$marker" ]]; then
            : > "$marker"
            ( trap '' TERM; exec /usr/bin/sleep 300 ) < /dev/null > /dev/null 2>&1 &
            printf '%s\n' "$!" >> "$children"
        fi
        exit 0 ;;
esac
exit 1
ROOT_FIND
        } > "${root}/find"
        chmod 755 "${root}/find"
        sed -i -e "s|/usr/bin/find|${root}/find|g" "$step"
        if [[ "$mode" == clock ]]; then
            # The fixed source reads its boot clock from rootfake/uptime, a
            # link to /proc/uptime that the fake find removes in the scan.
            ln -sfn /proc/uptime "${root}/uptime"
            sed -i -e "s#{ read -r up rest < /proc/uptime; } 2> /dev/null || return 1#{ read -r up rest < ${root}/uptime; } 2> /dev/null || return 1#" "$step"
            assert_eq "1" "$(grep -cF "< ${root}/uptime;" "$step")" "the fixed source reads its boot clock from the test file"
        fi
    fi
    {
        printf '#!/usr/bin/env bash\n'
        printf 'root=%q\n' "$root"
        cat <<'ROOT_STAT'
arguments=("$@")
last="${arguments[$(( $# > 0 ? $# - 1 : 0 ))]:-}"
if [[ "${FAKE_CHECK_OWNER:-root}" == root && ( "$last" == "$root" || "$last" == "$root"/* ) ]]; then
    arguments=("${arguments[@]//%u/0}")
fi
exec /usr/bin/stat "${arguments[@]}"
ROOT_STAT
    } > "${workspace}/fakebin/stat"
    chmod +x "${workspace}/fakebin/stat"
    printf 'NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="24.04"\n' > "${workspace}/os-release"
    sed -i -e "s|/usr/bin/sudo|${root}/sudo|g" \
        -e "s|^METRIC_OS_RELEASE=/etc/os-release\$|METRIC_OS_RELEASE=${workspace}/os-release|" "$step"
}

# ab_check_guard <workspace> - stop a test that would run the real sudo outside
# the hosted runner, or the real sudo with a fake check tool.
ab_check_guard() {
    local step="${1}/capture_step.sh"
    if grep -qF '/usr/bin/sudo' "$step"; then
        [[ "$AB_CHECK_HOSTED" == yes ]] || _fail "only the hosted runner runs the real sudo; use ab_collect_root_fake"
        if grep -qF '/rootfake/' "$step"; then
            _fail "the real sudo never runs a fake check tool"
        fi
    fi
}

# ab_check_frame <workspace> - the result frame of the process check.
ab_check_frame() {
    cat "${1}/runner_temp/evidence/m3-mean-speed/process-check.txt" 2>/dev/null || true
}

# ab_check_source_sha <workspace> - the SHA-256 of the fixed check source of
# the extracted capture step.
ab_check_source_sha() {
    local library
    library="$(ab_collect_block "$1")"
    bash --noprofile --norc -c "${library}"'
printf "%s" "$METRIC_ROOT_CHECK_SOURCE"' | sha256sum | cut -d ' ' -f 1
}

# ab_check_children_stopped <workspace> <label> - every check child that a fake
# check tool recorded has stopped. A live one is killed and fails the test.
ab_check_children_stopped() {
    local workspace="$1" label="$2" pid
    [[ -s "${workspace}/root_children" ]] || _fail "${label}: the fake check child must start"
    while IFS= read -r pid; do
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            _fail "${label}: the check child ${pid} must stop"
        fi
    done < "${workspace}/root_children"
}

# ab_check_vector_once <workspace> <label> - the command record has exactly
# one privileged row: the process check with the exact admitted vector, the
# SHA-256 of the fixed source, the unique task directory, RUNNER_TEMP, the
# original runner UID, two boot-clock values, and the recorded token. In the
# fake boundary, the fake sudo got that exact vector once.
ab_check_vector_once() {
    local workspace="$1" label="$2" rows sudo=/usr/bin/sudo sha uid
    rows="$(awk -F '\t' 'NR > 1 && $12 ~ /sudo/ { print $2 "\t" $12 }' \
        "${workspace}/runner_temp/evidence/m3-mean-speed/commands.tsv" 2>/dev/null || true)"
    if grep -qF '/rootfake/sudo' "${workspace}/capture_step.sh"; then
        sudo="${workspace}/rootfake/sudo"
    fi
    sha="$(ab_check_source_sha "$workspace")"
    uid="$(id -u)"
    [[ "$rows" =~ ^process-check$'\t'"${sudo} ${AB_CHECK_PREFIX} <METRIC_ROOT_CHECK_SOURCE sha256 ${sha}> m3-process-check ${workspace}/runner_temp/m3-metric-collection."[A-Za-z0-9]{8}" ${workspace}/runner_temp ${uid} "[0-9]+" "[0-9]+" "[A-Za-z0-9]{8,64}$ ]] ||
        _fail "${label}: the one privileged row is the exact admitted process-check vector" "$rows"
    assert_eq "$(ab_collect_value "$workspace" PROCESS_CHECK_TOKEN)" "${rows##* }" "${label}: the vector carries the recorded token"
    if [[ "$sudo" != /usr/bin/sudo ]]; then
        assert_eq "sudo ${AB_CHECK_PREFIX} <source sha256 ${sha}> m3-process-check ${rows#* m3-process-check }" \
            "$(tr '\t' ' ' < "${workspace}/root_calls.tsv")" "${label}: the fake boundary got the exact vector once"
    fi
}

# ab_check_complete <workspace> <label> - a complete process check: the frame
# from LAUNCH to END COMPLETE with the recorded token, the fixed source hash,
# the original runner UID, a monitor that leads its own process group and runs
# as root only through the real admitted vector, a verified stop, a scan of at
# most 600 centiseconds, and one cleanup clock: the check part ends 12000 ms
# after the cleanup entry, and the cleanup 20000 ms after it.
ab_check_complete() {
    local workspace="$1" label="$2" frame token pid group start euid expected scan entry
    frame="$(ab_check_frame "$workspace")"
    token="$(ab_collect_value "$workspace" PROCESS_CHECK_TOKEN)"
    assert_eq "COMPLETE" "$(ab_collect_value "$workspace" PROCESS_CHECK_RESULT)" "${label}: the process check is complete"
    assert_eq "$(id -u)" "$(ab_collect_value "$workspace" ORIGINAL_RUNNER_UID)" "${label}: the original runner UID is recorded"
    assert_eq "$(ab_check_source_sha "$workspace")" "$(ab_collect_value "$workspace" PROCESS_CHECK_SOURCE_SHA256)" \
        "${label}: the result records the SHA-256 of the fixed check source"
    [[ "$token" =~ ^[A-Za-z0-9]{8,64}$ ]] || _fail "${label}: the check token is recorded" "token: ${token}"
    [[ "$(head -n 1 <<< "$frame")" == "LAUNCH 1 ${token} "* ]] ||
        _fail "${label}: the frame starts with the launch record" "$frame"
    [[ "$(tail -n 1 <<< "$frame")" =~ ^END\ 1\ ${token}\ COMPLETE\ [0-9]+$ ]] ||
        _fail "${label}: the frame ends with one complete terminal record" "$frame"
    read -r pid group start euid <<< "$(ab_collect_value "$workspace" PROCESS_CHECK_MONITOR)"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" == "$group" && "$start" =~ ^[0-9]+$ ]] ||
        _fail "${label}: the monitor leads its own process group" "monitor: ${pid} ${group} ${start} ${euid}"
    expected="$(id -u)"
    if ! grep -qF '/rootfake/sudo' "${workspace}/capture_step.sh"; then
        expected=0
    fi
    assert_eq "$expected" "$euid" "${label}: the monitor runs as root only through the real admitted vector"
    assert_eq "YES" "$(ab_collect_value "$workspace" PROCESS_CHECK_STOPPED)" "${label}: the check group is verified stopped"
    scan="$(ab_collect_value "$workspace" PROCESS_CHECK_SCAN_CS)"
    [[ "$scan" =~ ^[0-9]+$ ]] && (( scan >= 1 && scan <= 600 )) ||
        _fail "${label}: the scan has at most 600 centiseconds" "scan: ${scan}"
    entry="$(ab_collect_value "$workspace" CLEANUP_START_MS)"
    [[ "$entry" =~ ^[0-9]+$ ]] || _fail "${label}: the cleanup entry is recorded" "entry: ${entry}"
    assert_eq "$(( entry + 12000 ))" "$(ab_collect_value "$workspace" PROCESS_CHECK_END_MS)" \
        "${label}: the check part ends 12000 ms after the cleanup entry"
    assert_eq "$(( entry + 20000 ))" "$(ab_collect_value "$workspace" CLEANUP_END_MS)" \
        "${label}: the cleanup ends 20000 ms after its entry"
}

# ab_check_measurements <workspace> <label> - the five task-size measurements
# in order, each with its byte count and time, and TASK_MEASURED_MAX_BYTES as
# the largest of them; the result publishes TASK_MEASURED_LIMIT_BYTES.
ab_check_measurements() {
    local workspace="$1" label="$2" rows max
    assert_eq "4294967296" "$(ab_collect_value "$workspace" TASK_MEASURED_LIMIT_BYTES)" \
        "${label}: the result publishes the measured-total limit"
    rows="$(cat "${workspace}/runner_temp/evidence/m3-mean-speed/task-bytes.tsv" 2>/dev/null || true)"
    assert_eq $'label\ntask-bytes-before-copy\ntask-bytes-after-copy\ntask-bytes-before-calculation\ntask-bytes-after-calculation\ntask-bytes-final' \
        "$(cut -f 1 <<< "$rows")" "${label}: the five measurements are recorded in order"
    assert_eq $'label\tbytes\ttime_ms' "$(head -n 1 <<< "$rows")" "${label}: the measurement record has its columns"
    awk -F '\t' 'NR > 1 && !($2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $3 + 0 >= last) { exit 1 } NR > 1 { last = $3 + 0 }' <<< "$rows" ||
        _fail "${label}: each measurement has its byte count and a time, in order" "$rows"
    max="$(awk -F '\t' 'NR > 1 && $2 + 0 > max { max = $2 + 0 } END { printf "%.0f", max }' <<< "$rows")"
    assert_eq "$max" "$(ab_collect_value "$workspace" TASK_MEASURED_MAX_BYTES)" \
        "${label}: TASK_MEASURED_MAX_BYTES is the largest measurement"
}

# ab_check_fixture <workspace> [find-mode] - the extracted capture step with the
# fake privilege boundary, for ab_check_cleanup.
ab_check_fixture() {
    ab_capture_fixture "$1"
    ab_collect_root_fake "$1" "${2:-}"
}

# ab_check_cleanup <workspace> [NAME=value ...] - run the extracted
# metric_cleanup on a new task directory under RUNNER_TEMP, after the
# initialization of metric_collect, as on the hosted runner. The metric end is
# AB_CHECK_END_IN_MS (default 60000) after the start of the cleanup run. With
# AB_CHECK_HIDDEN=<file>, a test process with its working directory in the
# task Case makes its /proc entries unreadable (PR_SET_DUMPABLE 0) first, and
# its PID goes to the file. With AB_CHECK_FIRST=<reason>, an earlier
# COMMAND_FAILURE with that reason comes first. The result record is written as
# at the end of the metric. The task directory path goes to unit_task. Prints
# status=.
ab_check_cleanup() {
    local workspace="$1" library status
    shift
    ab_check_guard "$workspace"
    library="$(ab_collect_block "$workspace")"
    [[ -n "$library" ]] || _fail "the metric functions must be extracted"
    : > "${workspace}/unit_task"
    env PATH="${workspace}/fakebin:${PATH}" TMPDIR="${workspace}/tmp" \
        RUNNER_TEMP="${workspace}/runner_temp" EVIDENCE_DIR="${workspace}/runner_temp/evidence" \
        CAPTURE_WORK_END="$(( $(date +%s) + 1000 ))" \
        GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted RUNNER_OS=Linux ImageOS=ubuntu24 \
        AB_UNIT_TASK="${workspace}/unit_task" \
        "$@" bash --noprofile --norc -c "${library}"'
capture_note() { :; }
mkdir -p "$RUNNER_TEMP" "$EVIDENCE_DIR"
PREPARE_RESULT=NOT_ATTEMPTED metric_collect > /dev/null
M_CODE="" M_REASON="" M_FAIL_POINT=NONE
if [[ -n "${AB_CHECK_FIRST:-}" ]]; then
    metric_fail COMMAND_FAILURE "$AB_CHECK_FIRST" > /dev/null
fi
TASK_TEMP="$(mktemp -d "${RUNNER_TEMP}/m3-metric-collection.XXXXXXXX")"
mkdir -- "${TASK_TEMP}/case" "${TASK_TEMP}/config" "${TASK_TEMP}/logs"
printf "%s\n" "$TASK_TEMP" > "$AB_UNIT_TASK"
if [[ -n "${AB_CHECK_HIDDEN:-}" ]]; then
    setsid python3 -c "import ctypes, os, sys, time
os.chdir(sys.argv[1])
if ctypes.CDLL(None).prctl(4, 0, 0, 0, 0) != 0:
    raise SystemExit(2)
print(os.getpid(), flush=True)
time.sleep(30)" "${TASK_TEMP}/case" < /dev/null > "$AB_CHECK_HIDDEN" 2> /dev/null &
    for (( tick = 0; tick < 200; tick++ )); do
        [[ -s "$AB_CHECK_HIDDEN" ]] && break
        sleep 0.01
    done
fi
M_END_MS=$(( $(metric_now_ms) + ${AB_CHECK_END_IN_MS:-60000} ))
metric_cleanup
metric_write_result UNAVAILABLE "${M_CODE:-NONE}" "${M_REASON:-none}"
' > "${workspace}/unit.out" 2>&1 && status=0 || status=$?
    printf 'status=%s\n' "$status"
}

# ab_check_value <workspace> <key> - one value of the result of ab_check_cleanup.
ab_check_value() {
    ab_file_value "${1}/runner_temp/evidence/m3-mean-speed/result.env" "$2"
}

# ab_check_refused <label> <workspace> <reason-text> [NAME=value ...] - run
# ab_check_cleanup. The cleanup must refuse with REFUSED_PROCESS_CHECK and a
# reason that has <reason-text>, and keep the task directory.
ab_check_refused() {
    local label="$1" workspace="$2" reason="$3"
    shift 3
    ab_check_cleanup "$workspace" "$@" > /dev/null
    [[ "$(ab_check_value "$workspace" CLEANUP_RESULT)" == REFUSED_PROCESS_CHECK ]] ||
        _fail "${label}: the cleanup refuses with REFUSED_PROCESS_CHECK" \
              "actual: $(ab_check_value "$workspace" CLEANUP_RESULT)" \
              "reason: $(ab_check_value "$workspace" MEAN_SPEED_REASON)" "$(tail -n 5 "${workspace}/unit.out")"
    assert_eq "CLEANUP_FAILURE" "$(ab_check_value "$workspace" MEAN_SPEED_REASON_CODE)" "${label}: the refusal is a cleanup failure"
    assert_contains "$(ab_check_value "$workspace" MEAN_SPEED_REASON)" "$reason" "${label}: the reason names the cause"
    [[ -d "$(cat "${workspace}/unit_task")" ]] || _fail "${label}: the task directory stays"
}

# ab_collect_fake_du <workspace> - a du that gives one controlled task-size
# measurement: FAKE_DU=<label>=<bytes|fail|malformed>, where <label> is the
# measurement whose output file the call writes. Other calls run the real du.
ab_collect_fake_du() {
    local real
    real="$(command -v du)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'real=%q\n' "$real"
        cat <<'FAKE_DU'
out="$(readlink -f "/proc/$$/fd/1" 2>/dev/null || true)"
label="${out##*/}"
label="${label%.out}"
if [[ -n "${FAKE_DU:-}" && "$label" == "${FAKE_DU%%=*}" ]]; then
    case "${FAKE_DU#*=}" in
        fail) echo "du: simulated failure" >&2; exit 1 ;;
        malformed) printf 'x\t%s\n' "${!#}"; exit 0 ;;
        *) printf '%s\t%s\n' "${FAKE_DU#*=}" "${!#}"; exit 0 ;;
    esac
fi
exec "$real" "$@"
FAKE_DU
    } > "${1}/fakebin/du"
    chmod +x "${1}/fakebin/du"
}

# ab_check_slow_readlink <workspace> - a readlink that waits
# FAKE_READLINK_DELAY seconds before each call.
ab_check_slow_readlink() {
    local real
    real="$(command -v readlink)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'real=%q\n' "$real"
        printf '%s\n' 'sleep "${FAKE_READLINK_DELAY:-0}"' 'exec "$real" "$@"'
    } > "${1}/fakebin/readlink"
    chmod +x "${1}/fakebin/readlink"
}

# ab_check_parent_clock <workspace> - the collector reads the two boot clocks of
# the process check (before the launch and after the return) from
# <workspace>/parent_uptime, a link to /proc/uptime. FAKE_CHECK_CLOCK of the
# fake sudo changes that file after the check. The fixed source (its read ends
# with "|| return 1") and the metric start keep /proc/uptime. A second call
# only restores the link.
ab_check_parent_clock() {
    local workspace="$1" step="${1}/capture_step.sh"
    rm -f -- "${workspace}/parent_uptime"
    ln -s /proc/uptime "${workspace}/parent_uptime"
    sed -i -e "/|| return 1\$/!s#{ read -r up rest < /proc/uptime; }#{ read -r up rest < ${workspace}/parent_uptime; }#" "$step"
    assert_eq "2" "$(grep -cF "< ${workspace}/parent_uptime;" "$step")" \
        "the collector reads the two boot clocks of the process check from the test file"
}

# ab_check_partial_clock <file> - the current boot clock with no line end, so a
# read of the file sets the valid first field and returns status 1.
ab_check_partial_clock() {
    local up idle
    read -r up idle < /proc/uptime
    rm -f -- "$1"
    printf '%s %s' "$up" "$idle" > "$1"
}

# ab_check_parse <block> <frame-file> <return-cs> - the extracted
# metric_check_frame of the collection block on one controlled frame, with the
# request values of review 5476930073: token abcdefgh12, the launch at 500, the
# absolute end at 1200, and 100 clock ticks each second. The frame is data
# only: no process starts or gets a signal. Prints the problem, empty for one
# complete valid frame.
ab_check_parse() {
    bash --noprofile --norc -c "${1}"'
CHECK_TOKEN=abcdefgh12 TASK_TEMP=/tmp/m3-metric-collection.AbCd1234 ORIGINAL_RUNNER_UID=1000
CHECK_END_BOOT_CS=1200 M_CHECK_LAUNCH_CS=500 M_CHECK_CLK=100
M_GROUPS=()
metric_check_frame "$1" "$2"
printf "%s" "$C_PROBLEM"' parse "$2" "$3"
}

# ab_check_full_refused <label> <workspace> <reason-text> [<check> <stopped>] -
# a complete collection with a failed process check: REFUSED_PROCESS_CHECK as
# the first failure with a reason that has <reason-text>, the check result
# <check> (default INCOMPLETE) and stop record <stopped> (default YES, a
# verified stop), no removal, the task directory kept, no accepted value, and
# an incomplete capture.
ab_check_full_refused() {
    local label="$1" workspace="$2" reason="$3" check="${4:-INCOMPLETE}" stopped="${5:-YES}"
    assert_eq "REFUSED_PROCESS_CHECK" "$(ab_collect_value "$workspace" CLEANUP_RESULT)" \
        "${label}: the cleanup refuses with REFUSED_PROCESS_CHECK"
    assert_eq "CLEANUP_FAILURE" "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" \
        "${label}: the refusal is the first failure"
    assert_contains "$(ab_collect_value "$workspace" MEAN_SPEED_REASON)" "$reason" "${label}: the reason names the cause"
    assert_eq "$check" "$(ab_collect_value "$workspace" PROCESS_CHECK_RESULT)" "${label}: the check result is ${check}"
    assert_eq "$stopped" "$(ab_collect_value "$workspace" PROCESS_CHECK_STOPPED)" "${label}: the stop record is ${stopped}"
    assert_eq "" "$(awk -F '\t' '$2 == "remove"' "${workspace}/runner_temp/evidence/m3-mean-speed/commands.tsv")" \
        "${label}: no removal starts"
    [[ -n "$(ab_collect_tasks "$workspace")" ]] || _fail "${label}: the task directory stays"
    assert_eq "UNAVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" "${label}: no value is accepted"
    assert_eq "UNAVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VALUE)" "${label}: no numeric value"
    assert_eq "UNAVAILABLE" "$(ab_env_last "$workspace" MEAN_SPEED_VERDICT)" "${label}: GITHUB_ENV has the verdict"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "${label}: the capture is incomplete"
    assert_contains "$(cat "${workspace}/runner_temp/evidence/capture-work-notes.txt" 2>/dev/null || true)" \
        "M3 mean speed: CLEANUP_FAILURE" "${label}: the capture note names the reason"
}

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
    # Outside the hosted runner, the process check gets the fake boundary.
    if [[ "$AB_CHECK_HOSTED" != yes ]]; then
        ab_collect_root_fake "$workspace"
    fi
}

# ab_collect_flow <workspace> - the Case 7 flow result directory.
ab_collect_flow() {
    printf '%s\n' "${1}/checkout/src/batch_9/case_7/flow"
}

# ab_collect_run <workspace> [NAME=value ...] - run the extracted capture step
# as GitHub runs it on the hosted runner, after a successful product run, with
# the fake OpenFOAM tree and a far deadline. The arguments override the
# environment. Prints status= and elapsed= lines.
ab_collect_run() {
    local workspace="$1" start status
    shift
    ab_check_guard "$workspace"
    start="$(date +%s)"
    env PATH="${workspace}/fakebin:${PATH}" \
        GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted RUNNER_OS=Linux ImageOS=ubuntu24 \
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
    # A GitHub-hosted runner runs the real admitted check here, never the fake
    # boundary, so a pass there proves the root monitor assertions below.
    if [[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]]; then
        assert_eq "yes" "$AB_CHECK_HOSTED" "S72: the GitHub-hosted runner runs the real admitted check (ImageOS '${ImageOS:-}')"
    fi
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
    # The cleanup process check (contract 6084196797, Section 4): the one
    # admitted privileged vector, the original runner UID as the selector, a
    # complete frame from a monitor in its own process group, a verified stop,
    # and an unprivileged removal and evidence.
    ab_check_vector_once "$workspace" "S72"
    ab_check_complete "$workspace" "S72"
    assert_eq "rm -rf -- ${task}" "$(awk -F '\t' '$2 == "remove" { print $12 }' "${evidence}/commands.tsv")" \
        "S72: the removal is the unprivileged bounded rm vector"
    assert_eq "" "$(find "$evidence" ! -user "$(id -u)" -print)" "S72: every evidence file belongs to the runner user"
    # On the hosted runner, the job summary shows the real check evidence of
    # this run: the frame records, the check values, the executables, the
    # check operations, and the measurements. It asserts nothing.
    if [[ "$AB_CHECK_HOSTED" == yes && -n "${GITHUB_STEP_SUMMARY:-}" && -w "${GITHUB_STEP_SUMMARY:-}" ]] &&
        ! grep -qF '/rootfake/' "${workspace}/capture_step.sh"; then
        {
            printf '### S72 hosted read-only root check\n\n```text\n'
            grep -vE '^(MATCH|UNCERTAIN|OLDER_UNREADABLE) ' "${evidence}/process-check.txt" | head -n 12 || true
            grep -E '^(ORIGINAL_RUNNER_UID|PROCESS_CHECK_|CLEANUP_|TASK_MEASURED_|TASK_[A-Z]+_FILE_LIMIT_BYTES)=' \
                "${evidence}/result.env" || true
            awk -F '\t' '$2 ~ /^(process-check|process-check-tools|remove)$/ { print $2, $4, $6, $7, $8, $9 }' \
                "${evidence}/commands.tsv" || true
            cat "${evidence}/process-check-tools.tsv" "${evidence}/task-bytes.tsv" 2>/dev/null || true
            printf '```\n'
        } >> "$GITHUB_STEP_SUMMARY" || true
    fi
    # The five task-size measurements with their times (contract Section 3).
    ab_check_measurements "$workspace" "S72"
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
        # The workspace path stays inside the safe RUNNER_TEMP characters.
        workspace="$(new_workspace "s77_value_${value//[^A-Za-z0-9_.-]/_}")"
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
        # The task directory exists, so the cleanup runs the one admitted
        # process-check vector, and no other privileged vector runs.
        ab_check_vector_once "$AB_COLLECT_LAST" "S78 ${label}"
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
    [[ "$pid" =~ ^[0-9]+$ ]] || _fail "S79: the process that leaves the group must start"
    kill -0 "$pid" 2>/dev/null || _fail "S79: the process check sends no signal to a process that it finds"
    kill -KILL "$pid" 2>/dev/null || true
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
    assert_eq $'on:\n  workflow_dispatch:\n    inputs:\n      validation_only:\n        description: Validate workflow only. Run no product job.\n        type: boolean\n        required: false\n        default: false' \
        "$(awk '/^on:/ { on = 1; print; next } on && /^[^ ]/ { exit } on && NF { print }' "$WORKFLOW")" \
        "S81: workflow_dispatch with only the optional Boolean validation_only input (default false) is the only trigger"
    assert_contains "$(cat "$WORKFLOW")" $'permissions:\n  contents: read' "S81: the token can only read contents"
    assert_contains "$(cat "$WORKFLOW")" $'  evidence:\n    name: OpenFOAM v2512 four-Stage evidence\n    runs-on: ubuntu-24.04\n    timeout-minutes: 120' \
        "S81: the job, runner, and 120-minute setting stay"
    # evidence is the only job. Its one job-level condition makes it ineligible
    # for a true validation_only input, before runner assignment.
    assert_eq "  evidence:" "$(awk '/^jobs:/ { jobs = 1; next } jobs && /^[^ ]/ { exit } jobs && /^  [^ #]/ { print }' "$WORKFLOW")" \
        "S81: evidence is the only job"
    assert_contains "$(cat "$WORKFLOW")" $'\njobs:\n  evidence:\n    name: OpenFOAM v2512 four-Stage evidence\n    runs-on: ubuntu-24.04\n    timeout-minutes: 120\n    if: ${{ !inputs.validation_only }}\n    defaults:\n' \
        "S81: the job-level validation_only condition follows the 120-minute setting in the evidence job header"
    assert_eq $'      validation_only:\n    if: ${{ !inputs.validation_only }}' "$(grep -F -- 'validation_only' "$WORKFLOW")" \
        "S81: only the input and the one job-level condition name validation_only"
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
    # F2 single-file RLIMIT_FSIZE check: one file above the file allowance of
    # the calculation is stopped by the kernel file-size limit, so the task
    # directory never holds that file. (S88 has the multi-file limitation.)
    workspace="$(new_workspace s83_transient)"
    ab_collect_fixture "$workspace"
    ab_collect_run "$workspace" FAKE_TRANSIENT_BYTES=4294967297 \
        FAKE_TRANSIENT_RECORD="${workspace}/observed_task_bytes" > /dev/null
    observed="$(cat "${workspace}/observed_task_bytes" 2>/dev/null || true)"
    if [[ "$observed" =~ ^[0-9]+$ ]] && (( observed > 4294967296 )); then
        _fail "S83: RLIMIT_FSIZE stops the single file above its allowance, so the task directory never holds it" \
              "observed: ${observed}"
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
    # the task directory. The failures come at the fixed check boundary: the
    # find of the fixed check source fails, and a read is denied even there.
    workspace="$(new_workspace s84_failed_scan)"
    ab_collect_fixture "$workspace"
    ab_collect_root_fake "$workspace" fail
    ab_collect_run "$workspace" > /dev/null
    assert_eq "CLEANUP_FAILURE" "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" \
        "S84: a failed process check stops the removal"
    assert_eq "REFUSED_PROCESS_CHECK" "$(ab_collect_value "$workspace" CLEANUP_RESULT)" \
        "S84: the refusal names the process check"
    assert_contains "$(ab_check_frame "$workspace")" "UNCERTAIN find: simulated read failure" \
        "S84: the frame keeps the exact scan error"
    [[ -n "$(ab_collect_tasks "$workspace")" ]] || _fail "S84: the task directory stays after a failed process check"
    workspace="$(new_workspace s84_hidden_user)"
    ab_collect_fixture "$workspace"
    ab_collect_root_fake "$workspace"
    ab_collect_run "$workspace" FAKE_HIDDEN_USER="${workspace}/hidden_user" FAKE_CHECK=user > /dev/null
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

# ab_collect_host_unreadable - the live processes of the test user whose /proc
# fd entry the test user cannot read, as "<count>: <name>(<pid>) ...". Such a
# process makes every cleanup refuse, so a test that expects a removed task
# directory needs a host without one.
ab_collect_host_unreadable() {
    local status proc item uid name state count=0 list=""
    local -a lines=()
    uid="$(id -u)"
    for status in /proc/[0-9]*/status; do
        proc="${status%/status}"
        { mapfile -t lines < "$status"; } 2>/dev/null || continue
        name="" state="" item=""
        for item in "${lines[@]}"; do
            case "$item" in
                Name:*) name="${item#Name:}"; name="${name//[[:space:]]/}" ;;
                State:*) state="${item#State:}"; state="${state//[[:space:]]/}"; state="${state:0:1}" ;;
                Uid:*) item=" ${item#Uid:} "; item="${item//[[:space:]]/ }"; break ;;
            esac
        done
        [[ "$item" == *" ${uid} "* && "$state" != Z && "$state" != X ]] || continue
        if [[ ! -r "${proc}/fd" && -e "$proc" ]]; then
            count=$(( count + 1 ))
            list="${list} ${name}(${proc#/proc/})"
        fi
    done
    printf '%s:%s\n' "$count" "${list:- none}"
}

# ab_collect_older_run <workspace> <dumpable> [NAME=value ...] - start a process
# of the test user before the capture step, so it starts before the metric
# clock. During the fake calculation, it gets the Case path, enters the Case,
# and, for dumpable 0, makes its /proc entries unreadable (PR_SET_DUMPABLE 0).
# Then run the capture step with the other arguments. Sets AB_OLDER_PID.
ab_collect_older_run() {
    local workspace="$1" dumpable="$2" fifo_fd tick
    shift 2
    AB_OLDER_PID=""
    mkfifo -- "${workspace}/older.fifo"
    exec {fifo_fd}<>"${workspace}/older.fifo"
    setsid python3 -u -c 'import ctypes, os, sys, time
print(os.getpid(), flush=True)
target = sys.stdin.readline().rstrip("\n")
if not target.startswith(sys.argv[1] + "/runner_temp/m3-metric-collection.") or not target.endswith("/case"):
    raise SystemExit(2)
os.chdir(target)
if sys.argv[2] == "0" and ctypes.CDLL(None).prctl(4, 0, 0, 0, 0) != 0:
    raise SystemExit(3)
print("READY", flush=True)
time.sleep(30)' "$workspace" "$dumpable" <&"$fifo_fd" > "${workspace}/older.out" 2> /dev/null &
    for (( tick = 0; tick < 200; tick++ )); do
        [[ -s "${workspace}/older.out" ]] && break
        sleep 0.01
    done
    AB_OLDER_PID="$(head -n 1 "${workspace}/older.out")"
    ab_collect_run "$workspace" FAKE_OLDER_FIFO="${workspace}/older.fifo" \
        FAKE_OLDER_OUT="${workspace}/older.out" "$@" > /dev/null
    exec {fifo_fd}>&-
}

s87_collect_older_process_in_the_case_keeps_it() {
    local workspace rows dumpable boundary entry result
    local -a cases=("0 user" "1 default")
    # F3 (review 5466999244): the start time of a process does not prove that
    # it does not use the task directory. A read that is denied even at the
    # admitted boundary stays uncertain (the fake boundary in user mode). On
    # the hosted runner, the complete root read of the same unreadable older
    # process finds it, and that never permits the removal.
    printf 'HOST_UNREADABLE_TEST_USER_PROCESSES=%s\n' "$(ab_collect_host_unreadable)"
    if [[ "$AB_CHECK_HOSTED" == yes ]]; then
        cases+=("0 root")
    fi
    for entry in "${cases[@]}"; do
        read -r dumpable boundary <<< "$entry"
        workspace="$(new_workspace "s87_older_${dumpable}_${boundary}")"
        ab_collect_fixture "$workspace"
        if [[ "$boundary" == user ]]; then
            ab_collect_root_fake "$workspace"
            ab_collect_older_run "$workspace" "$dumpable" FAKE_CHECK=user
        else
            ab_collect_older_run "$workspace" "$dumpable"
        fi
        rows="$(ab_check_frame "$workspace")"
        if [[ "$AB_OLDER_PID" =~ ^[0-9]+$ ]]; then
            kill -KILL "$AB_OLDER_PID" 2>/dev/null || true
        else
            _fail "S87: the older process must start" "$(tail -n 5 "${workspace}/capture_step.out")"
        fi
        [[ "$(tail -n 1 "${workspace}/older.out")" == READY ]] ||
            _fail "S87: the older process must enter the task Case during the calculation"
        if [[ "$boundary" == user ]]; then
            result=REFUSED_PROCESS_CHECK
            assert_contains "$rows" "OLDER_UNREADABLE /proc/${AB_OLDER_PID}" \
                "S87: the test process started before the metric clock and is unreadable"
            assert_contains "$rows" "UNCERTAIN /usr/bin/find: '/proc/${AB_OLDER_PID}/" \
                "S87: the unreadable older process makes the process check uncertain"
        else
            result=REFUSED_PROCESS_ACTIVE
            assert_contains "$rows" "MATCH /proc/${AB_OLDER_PID}/" "S87: the older process in the Case is found"
        fi
        assert_eq "$result" "$(ab_collect_value "$workspace" CLEANUP_RESULT)" \
            "S87 dumpable ${dumpable}: the cleanup refusal is ${result}"
        assert_eq "CLEANUP_FAILURE" "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" \
            "S87 dumpable ${dumpable}: the removal stops"
        assert_eq "UNAVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" "S87: no value is accepted"
        assert_eq "UNAVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VALUE)" "S87: no numeric value"
        assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "S87: the capture is incomplete"
        [[ -n "$(ab_collect_tasks "$workspace")" ]] || _fail "S87 dumpable ${dumpable}: the task directory stays"
    done
}

# ---- S88 to S92: the corrected collection contract (#80, 6084196797) -------
#
# S88 covers the settled F2 task-byte contract (Section 3): measured totals at
# five checkpoints, a positive file allowance before the copy and the
# calculation, and an honest probe of the transient multi-file limitation. S89
# to S92 cover the bounded read-only root check of the cleanup (Section 4): the
# fixed source and its arguments, the failures that keep the task directory,
# the self-termination of the check, and the one cleanup clock. These checks
# use the controlled fake boundary of ab_collect_root_fake also on the hosted
# runner; there, S72 to S87 run the real admitted vector.

s88_collect_task_measurements_and_allowances() {
    local workspace evidence observed max allowance
    # A zero allowance before the copy or the calculation starts neither.
    ab_collect_expect "S88 zero copy allowance" RESOURCE_LIMIT ab_collect_fake_du \
        FAKE_DU=task-bytes-before-copy=4294967296
    evidence="${AB_COLLECT_LAST}/runner_temp/evidence/m3-mean-speed"
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" MEAN_SPEED_REASON)" "no file allowance" \
        "S88: the reason names the zero copy allowance"
    assert_eq "" "$(awk -F '\t' '$2 == "copy"' "${evidence}/commands.tsv")" "S88: no copy starts with a zero allowance"
    ab_collect_no_calculation "$AB_COLLECT_LAST" "S88 zero copy allowance"
    ab_collect_expect "S88 zero calculation allowance" RESOURCE_LIMIT ab_collect_fake_du \
        FAKE_DU=task-bytes-before-calculation=4294967296
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" MEAN_SPEED_REASON)" "no file allowance" \
        "S88: the reason names the zero calculation allowance"
    ab_collect_no_calculation "$AB_COLLECT_LAST" "S88 zero calculation allowance"
    # A failed or a malformed measurement keeps its exact first reason.
    ab_collect_expect "S88 failed measurement" COMMAND_FAILURE ab_collect_fake_du FAKE_DU=task-bytes-after-copy=fail
    assert_eq "the task-bytes-after-copy operation ended with status 1" \
        "$(ab_collect_value "$AB_COLLECT_LAST" MEAN_SPEED_REASON)" "S88: a failed measurement keeps its exact reason"
    assert_contains "$(cat "${AB_COLLECT_LAST}/runner_temp/evidence/m3-mean-speed/task-bytes.tsv" 2>/dev/null || true)" \
        $'task-bytes-after-copy\tUNAVAILABLE\t' "S88: the failed measurement is recorded"
    ab_collect_expect "S88 malformed measurement" COMMAND_FAILURE ab_collect_fake_du FAKE_DU=task-bytes-final=malformed
    assert_contains "$(ab_collect_value "$AB_COLLECT_LAST" MEAN_SPEED_REASON)" "task-bytes-final" \
        "S88: a malformed measurement names its checkpoint"
    # The transient multi-file limitation probe: two sparse files, each inside
    # the file allowance, exist together during the calculation with more than
    # 4294967296 apparent task bytes, and go before the next measurement. The
    # model does not bound that total continuously, and the result says so.
    workspace="$(new_workspace s88_transient_files)"
    ab_collect_fixture "$workspace"
    ab_collect_run "$workspace" FAKE_TRANSIENT_FILES=2 FAKE_TRANSIENT_BYTES=2147483648 \
        FAKE_TRANSIENT_RECORD="${workspace}/observed_task_bytes" > /dev/null
    observed="$(cat "${workspace}/observed_task_bytes" 2>/dev/null || true)"
    [[ "$observed" =~ ^[0-9]+$ ]] && (( observed > 4294967296 )) ||
        _fail "S88: the probe holds more than 4294967296 apparent task bytes at one moment" "observed: ${observed}"
    [[ "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" == AVAILABLE ]] ||
        _fail "S88: the probe hides no other failure and gives the complete result" \
              "code: $(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" \
              "reason: $(ab_collect_value "$workspace" MEAN_SPEED_REASON)"
    assert_eq "3.66666666666666652e+00" "$(ab_collect_value "$workspace" MEAN_SPEED_VALUE)" "S88: the probe gives the value"
    assert_eq "REMOVED" "$(ab_collect_value "$workspace" CLEANUP_RESULT)" "S88: the probe cleanup removes the task directory"
    assert_eq "COMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "S88: the probe capture is complete"
    ab_check_measurements "$workspace" "S88 probe"
    max="$(ab_collect_value "$workspace" TASK_MEASURED_MAX_BYTES)"
    [[ "$max" =~ ^[0-9]+$ ]] && (( max < 4294967296 )) ||
        _fail "S88: no measurement sees the transient total" "measured maximum: ${max}"
    allowance="$(ab_collect_value "$workspace" TASK_CALCULATION_FILE_LIMIT_BYTES)"
    [[ "$allowance" =~ ^[0-9]+$ ]] && (( allowance > 2147483648 )) ||
        _fail "S88: each transient file is inside the calculation allowance" "allowance: ${allowance}"
    assert_contains "$(ab_collect_value "$workspace" TASK_BYTES_CONTROL)" "not continuously bounded" \
        "S88: the result states the limitation"
    printf 'S88_TRANSIENT_PROBE observed=%s measured_max=%s calculation_allowance=%s\n' "$observed" "$max" "$allowance"
}

# ab_check_launch <source> <argument...> - run the fixed check source as its
# launch, as the test user, in the clean environment of the admitted vector.
# Prints the output and a status= line.
ab_check_launch() {
    local source="$1" status
    shift
    timeout --kill-after=2s 20s env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/bash --noprofile --norc -p \
        -c "$source" m3-process-check "$@" 2>&1 && status=0 || status=$?
    printf 'status=%s\n' "$status"
}

# ab_check_bad_launch <label> <source> <argument...> - the launch refuses the
# arguments with status 2 and a reason, and starts no monitor or scan.
ab_check_bad_launch() {
    local label="$1" source="$2" out
    shift 2
    out="$(ab_check_launch "$source" "$@")"
    assert_contains "$out" "status=2" "${label}: the launch refuses"
    assert_contains "$out" "m3 process check: " "${label}: the refusal has a reason"
    assert_not_contains "$out" "LAUNCH " "${label}: no monitor or scan starts"
}

s89_collect_root_check_source_and_arguments() {
    local workspace block source line runner task uid token up now out entry scan label
    # The fixed source: one read-only literal, the exact outer vector once, and
    # only the seven admitted installed executables in the source.
    workspace="$(new_workspace s89_source)"
    block="$(ab_step_run_body "Capture the evidence" | awk '/^# ---- M3 mean speed: begin ----$/ { inside = 1 }
        inside && !done { print } /^# ---- M3 mean speed: end ----$/ { done = 1 }')"
    source="$(bash --noprofile --norc -c "${block}"'
printf "%s" "${METRIC_ROOT_CHECK_SOURCE:-}"')"
    [[ -n "$source" ]] || _fail "S89: the collection block must define the fixed check source METRIC_ROOT_CHECK_SOURCE"
    assert_eq "1" "$(grep -cx 'readonly METRIC_ROOT_CHECK_SOURCE' <<< "$block")" "S89: the fixed source is read-only"
    (( $(grep -nx 'readonly METRIC_ROOT_CHECK_SOURCE' <<< "$block" | cut -d : -f 1) <
       $(grep -nF '"$METRIC_ROOT_CHECK_SOURCE"' <<< "$block" | head -n 1 | cut -d : -f 1) )) ||
        _fail "S89: the source is read-only before its first use"
    for line in '    metric_op process-check CLEANUP /usr/bin/sudo -n -- /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C \' \
                '        /usr/bin/bash --noprofile --norc -p -c "$METRIC_ROOT_CHECK_SOURCE" \' \
                '        m3-process-check "$TASK_TEMP" "$RUNNER_TEMP" "$ORIGINAL_RUNNER_UID" "$M_BOOT_CS" "$CHECK_END_BOOT_CS" "$CHECK_TOKEN"'; do
        assert_eq "1" "$(grep -cxF -- "$line" <<< "$block")" "S89: the exact outer vector has the line: ${line}"
    done
    assert_eq "2" "$(grep -v '^[[:space:]]*#' <<< "$block" | grep -c 'sudo')" \
        "S89: sudo is only in the admitted vector and in its executable check"
    assert_eq "/usr/bin/bash /usr/bin/find /usr/bin/getconf /usr/bin/grep /usr/bin/prlimit /usr/bin/sleep /usr/bin/timeout" \
        "$(grep -oE '/usr/bin/[a-z]+' <<< "$source" | LC_ALL=C sort -u | paste -sd ' ' -)" \
        "S89: the fixed source uses only the seven admitted installed executables"
    assert_eq "0" "$(grep -v '^[[:space:]]*#' <<< "$source" |
        grep -cE '(^|[^A-Za-z_-])(eval|source|setsid|kill|sudo|mktemp|nohup|disown)([^A-Za-z_-]|$)|--foreground|BASH_ENV')" \
        "S89: the fixed source loads no script, signals nothing, and makes no other group or session"
    for line in 'exec /usr/bin/prlimit --core=1 --fsize=1048577 -- \' \
                '/usr/bin/timeout --signal=TERM --kill-after=5s "$duration" \' \
                '/usr/bin/bash --noprofile --norc -p -c "$FIXED_GUARD_SOURCE" m3-process-guard "$@"'; do
        assert_eq "1" "$(grep -cF -- "$line" <<< "$source")" "S89: the monitor chain has: ${line}"
    done
    for line in 'METRIC_CHECK_MS=12000' 'METRIC_REMOVE_MS=8000'; do
        assert_eq "1" "$(grep -cx -- "$line" <<< "$block")" "S89: the cleanup sets ${line}"
    done
    # The launch repeats the argument checks, as the test user here.
    runner="${workspace}/rt"
    task="${runner}/m3-metric-collection.AbCd1234"
    mkdir -p "$task" "${runner}/sub/m3-metric-collection.AbCd1234" "${workspace}/-rt/m3-metric-collection.AbCd1234" \
        "${workspace}/r t/m3-metric-collection.AbCd1234"
    ln -s "$task" "${runner}/m3-metric-collection.LinkLink"
    ln -s "$runner" "${workspace}/rtlink"
    uid="$(id -u)"
    token=abcdefgh12
    read -r up _ < /proc/uptime
    now=$(( 10#${up/./} ))
    ab_check_bad_launch "S89 five arguments" "$source" "$task" "$runner" "$uid" 0 "$(( now + 2000 ))"
    ab_check_bad_launch "S89 seven arguments" "$source" "$task" "$runner" "$uid" 0 "$(( now + 2000 ))" "$token" extra
    ab_check_bad_launch "S89 root UID" "$source" "$task" "$runner" 0 0 "$(( now + 2000 ))" "$token"
    ab_check_bad_launch "S89 malformed UID" "$source" "$task" "$runner" "${uid}x" 0 "$(( now + 2000 ))" "$token"
    ab_check_bad_launch "S89 nested task" "$source" "${runner}/sub/m3-metric-collection.AbCd1234" "$runner" "$uid" 0 \
        "$(( now + 2000 ))" "$token"
    ab_check_bad_launch "S89 task name" "$source" "${runner}/m3-metric-collection.AbCd" "$runner" "$uid" 0 \
        "$(( now + 2000 ))" "$token"
    ab_check_bad_launch "S89 relative RUNNER_TEMP" "$source" "rt/m3-metric-collection.AbCd1234" rt "$uid" 0 \
        "$(( now + 2000 ))" "$token"
    ab_check_bad_launch "S89 dot-dot component" "$source" "${runner}/../rt/m3-metric-collection.AbCd1234" "${runner}/../rt" \
        "$uid" 0 "$(( now + 2000 ))" "$token"
    ab_check_bad_launch "S89 option-like component" "$source" "${workspace}/-rt/m3-metric-collection.AbCd1234" \
        "${workspace}/-rt" "$uid" 0 "$(( now + 2000 ))" "$token"
    ab_check_bad_launch "S89 whitespace component" "$source" "${workspace}/r t/m3-metric-collection.AbCd1234" \
        "${workspace}/r t" "$uid" 0 "$(( now + 2000 ))" "$token"
    ab_check_bad_launch "S89 malformed end" "$source" "$task" "$runner" "$uid" 0 12e3 "$token"
    ab_check_bad_launch "S89 end before start" "$source" "$task" "$runner" "$uid" "$(( now + 3000 ))" "$(( now + 2000 ))" "$token"
    ab_check_bad_launch "S89 short token" "$source" "$task" "$runner" "$uid" 0 "$(( now + 2000 ))" abc
    ab_check_bad_launch "S89 token with a separator" "$source" "$task" "$runner" "$uid" 0 "$(( now + 2000 ))" 'abcdefgh;x'
    ab_check_bad_launch "S89 linked task" "$source" "${runner}/m3-metric-collection.LinkLink" "$runner" "$uid" 0 \
        "$(( now + 2000 ))" "$token"
    ab_check_bad_launch "S89 linked RUNNER_TEMP" "$source" "${workspace}/rtlink/m3-metric-collection.AbCd1234" \
        "${workspace}/rtlink" "$uid" 0 "$(( now + 2000 ))" "$token"
    ab_check_bad_launch "S89 no scan time" "$source" "$task" "$runner" "$uid" 0 "$(( now + 550 ))" "$token"
    # The test bound runs in the foreground, so it is not a monitor that
    # leads its own process group.
    out="$(timeout --foreground --kill-after=2s 20s env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/bash --noprofile --norc -p \
        -c "$source" m3-process-guard "$task" "$runner" "$uid" 0 "$(( now + 2000 ))" "$token" 2>&1 && echo status=0 || echo "status=$?")"
    assert_contains "$out" "status=2" "S89: the guard refuses to run without its timeout monitor"
    assert_not_contains "$out" "FRAME " "S89: no scan starts without the monitor"
    # A parent that leads the process group of the guard, but is not the
    # timeout monitor, is refused too.
    out="$(timeout --foreground --kill-after=2s 20s setsid bash --noprofile --norc -c \
        'env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/bash --noprofile --norc -p -c "$1" m3-process-guard "${@:2}"; exit $?' \
        parent "$source" "$task" "$runner" "$uid" 0 "$(( now + 2000 ))" "$token" 2>&1 && echo status=0 || echo "status=$?")"
    assert_contains "$out" "status=2" "S89: the guard refuses a group leader that is not its timeout monitor"
    assert_not_contains "$out" "FRAME " "S89: no scan starts under another group leader"
    # A valid launch: the scan time comes from the absolute end, and the guard
    # runs under its monitor, in the monitor process group.
    read -r up _ < /proc/uptime
    now=$(( 10#${up/./} ))
    out="$(ab_check_launch "$source" "$task" "$runner" "$uid" 0 "$(( now + 700 ))" "$token")"
    [[ "$(head -n 1 <<< "$out")" =~ ^LAUNCH\ 1\ ${token}\ ([0-9]+)\ ([0-9]+)$ ]] ||
        _fail "S89: the launch writes its record first" "$out"
    entry="${BASH_REMATCH[1]}" scan="${BASH_REMATCH[2]}"
    assert_eq "$(( now + 700 - entry - 600 ))" "$scan" "S89: the scan time is the time to the absolute end less 600 centiseconds"
    assert_eq "FRAME 1 ${token} ${task} ${uid} $(( now + 700 ))" "$(sed -n -e 2p <<< "$out")" \
        "S89: the guard records the target, the original UID, and the absolute end"
    [[ "$(sed -n -e 3p <<< "$out")" =~ ^MONITOR\ ([0-9]+)\ ([0-9]+)\ [0-9]+\ ${uid}$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]] ||
        _fail "S89: the guard runs under its monitor, in the monitor process group" "$out"
    # The collector checks the hosted runner, RUNNER_TEMP, and the caller
    # environment before any elevation.
    for label in RUNNER_ENVIRONMENT=self-hosted ImageOS=ubuntu22; do
        workspace="$(new_workspace "s89_gate_${label%%=*}")"
        ab_check_fixture "$workspace"
        ab_check_refused "S89 ${label}" "$workspace" "GitHub-hosted ubuntu-24.04 runner" "$label"
        [[ ! -s "${workspace}/root_calls.tsv" ]] || _fail "S89 ${label}: no elevation starts off the hosted runner"
        assert_eq "NOT_RUN" "$(ab_check_value "$workspace" PROCESS_CHECK_RESULT)" "S89 ${label}: the check does not run"
    done
    workspace="$(new_workspace s89_option_temp)"
    ab_check_fixture "$workspace"
    ab_check_refused "S89 option-like RUNNER_TEMP" "$workspace" "RUNNER_TEMP" RUNNER_TEMP="${workspace}/-runner_temp"
    [[ ! -s "${workspace}/root_calls.tsv" ]] || _fail "S89: no elevation starts with an unsafe RUNNER_TEMP"
    workspace="$(new_workspace s89_linked_temp)"
    ab_check_fixture "$workspace"
    mkdir -p "${workspace}/real_temp"
    ln -s real_temp "${workspace}/linked_temp"
    ab_check_refused "S89 linked RUNNER_TEMP" "$workspace" "canonical" RUNNER_TEMP="${workspace}/linked_temp"
    [[ ! -s "${workspace}/root_calls.tsv" ]] || _fail "S89: no elevation starts with a linked RUNNER_TEMP"
    workspace="$(new_workspace s89_hook)"
    ab_check_fixture "$workspace"
    printf 'printf "%%s\\n" "$0" >> %q\n' "${workspace}/hook_calls" > "${workspace}/hook.sh"
    ab_check_cleanup "$workspace" BASH_ENV="${workspace}/hook.sh" ENV="${workspace}/hook.sh" > /dev/null
    assert_eq "REMOVED" "$(ab_check_value "$workspace" CLEANUP_RESULT)" "S89: the cleanup with a caller hook completes"
    assert_not_contains "$(cat "${workspace}/hook_calls" 2>/dev/null || true)" "m3-process-" \
        "S89: the caller BASH_ENV never runs in the fixed check"
}

s90_collect_root_check_failures_keep_the_task_directory() {
    local workspace kind pid
    # A denied privilege request in a complete collection.
    workspace="$(new_workspace s90_denied)"
    ab_collect_fixture "$workspace"
    ab_collect_root_fake "$workspace"
    ab_collect_run "$workspace" FAKE_CHECK=deny > /dev/null
    assert_eq "CLEANUP_FAILURE" "$(ab_collect_value "$workspace" MEAN_SPEED_REASON_CODE)" "S90: a denied check stops the removal"
    assert_eq "REFUSED_PROCESS_CHECK" "$(ab_collect_value "$workspace" CLEANUP_RESULT)" "S90: the refusal names the check"
    assert_contains "$(ab_collect_value "$workspace" MEAN_SPEED_REASON)" "status 1" "S90: the reason has the status"
    assert_contains "$(cat "${workspace}/runner_temp/evidence/m3-mean-speed/process-check.err" 2>/dev/null || true)" \
        "a password is required" "S90: the evidence keeps the refusal of the privilege request"
    assert_eq "INCOMPLETE" "$(ab_collect_value "$workspace" PROCESS_CHECK_RESULT)" "S90: the check is incomplete"
    assert_eq "UNAVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" "S90: no value is accepted"
    assert_eq "UNAVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VALUE)" "S90: no numeric value"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "S90: the capture is incomplete"
    [[ -n "$(ab_collect_tasks "$workspace")" ]] || _fail "S90: the task directory stays after a denied check"
    # A missing, writable, or not root-owned executable stops the check before
    # any elevation.
    workspace="$(new_workspace s90_missing)"
    ab_check_fixture "$workspace"
    sed -i -e "s|/usr/bin/getconf|${workspace}/rootfake/getconf|g" "${workspace}/capture_step.sh"
    ab_check_refused "S90 missing executable" "$workspace" "is missing"
    [[ ! -s "${workspace}/root_calls.tsv" ]] || _fail "S90: no elevation starts with a missing executable"
    workspace="$(new_workspace s90_writable)"
    ab_check_fixture "$workspace" fail
    chmod 775 "${workspace}/rootfake/find"
    ab_check_refused "S90 writable executable" "$workspace" "group- or world-writable"
    [[ ! -s "${workspace}/root_calls.tsv" ]] || _fail "S90: no elevation starts with a writable executable"
    workspace="$(new_workspace s90_owner)"
    ab_check_fixture "$workspace"
    ab_check_refused "S90 executable owner" "$workspace" "not owned by root" FAKE_CHECK_OWNER=keep
    [[ ! -s "${workspace}/root_calls.tsv" ]] || _fail "S90: no elevation starts with an executable of another owner"
    # A failed check, an output above the file limit, and a read that is
    # denied even at the admitted boundary.
    workspace="$(new_workspace s90_failed)"
    ab_check_fixture "$workspace"
    ab_check_refused "S90 failed check" "$workspace" "status 1" FAKE_CHECK=fail
    ab_check_refused "S90 output limit" "$workspace" "status 153" FAKE_CHECK=big
    ab_check_refused "S90 denied read" "$workspace" "is not complete for" FAKE_CHECK=user AB_CHECK_HIDDEN="${workspace}/hidden"
    pid="$(cat "${workspace}/hidden" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        kill -KILL "$pid" 2>/dev/null || true
    else
        _fail "S90: the unreadable process must start" "$(tail -n 5 "${workspace}/unit.out")"
    fi
    assert_contains "$(ab_check_frame "$workspace")" "UNCERTAIN /usr/bin/find: '/proc/${pid}/" \
        "S90: the denied read stays uncertain"
    # Controlled frames: a complete valid frame with a verified stop permits
    # the removal; each defect of the frame refuses it.
    ab_check_cleanup "$workspace" FAKE_CHECK=frame:valid > /dev/null
    assert_eq "REMOVED" "$(ab_check_value "$workspace" CLEANUP_RESULT)" \
        "S90: a complete valid frame and a verified stop permit the removal"
    for kind in unknown duplicate token target uid no-end truncated after-end scan-long terminated monitor-group; do
        ab_check_refused "S90 frame ${kind}" "$workspace" "not one complete valid frame" "FAKE_CHECK=frame:${kind}"
    done
    : > "${workspace}/root_children"
    ab_check_refused "S90 live monitor" "$workspace" "did not stop" FAKE_CHECK=frame:live-monitor
    assert_eq "NO" "$(ab_check_value "$workspace" PROCESS_CHECK_STOPPED)" "S90: a live monitor is not a verified stop"
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null || true
    done < "${workspace}/root_children"
}

s91_collect_root_check_stops_itself() {
    local mode workspace frame token start end status scan check_end
    # The root monitor owns TERM and KILL. A slow scan stops at its interval;
    # a check child that ignores SIGTERM keeps the guard alive until the
    # monitor sends SIGKILL, also after an early scanner exit. The metric end
    # is 15500 ms after the cleanup start, so the scan interval is short.
    for mode in slow ignore orphan; do
        workspace="$(new_workspace "s91_${mode}")"
        ab_check_fixture "$workspace" "$mode"
        ab_check_refused "S91 ${mode}" "$workspace" "process check" AB_CHECK_END_IN_MS=15500
        ab_check_children_stopped "$workspace" "S91 ${mode}"
        assert_eq "YES" "$(ab_check_value "$workspace" PROCESS_CHECK_STOPPED)" \
            "S91 ${mode}: the check group and its children are verified stopped"
        frame="$(ab_check_frame "$workspace")"
        token="$(ab_check_value "$workspace" PROCESS_CHECK_TOKEN)"
        assert_not_contains "$frame" "END 1 ${token} COMPLETE" "S91 ${mode}: no complete terminal record"
        # The outer status is 124 or 137, as the outer and the root timers
        # end; the elapsed time, the frame, and the stopped children show
        # which stop the root monitor used.
        read -r start end status <<< "$(awk -F '\t' '$2 == "process-check" { print $6, $7, $9 }' \
            "${workspace}/runner_temp/evidence/m3-mean-speed/commands.tsv")"
        assert_eq "TIMEOUT" "$status" "S91 ${mode}: the check operation ends as TIMEOUT"
        scan="$(ab_check_value "$workspace" PROCESS_CHECK_SCAN_CS)"
        check_end="$(ab_check_value "$workspace" PROCESS_CHECK_END_MS)"
        [[ "$end" =~ ^[0-9]+$ && "$scan" =~ ^[0-9]+$ && "$check_end" =~ ^[0-9]+$ ]] && (( end <= check_end )) ||
            _fail "S91 ${mode}: the check ends by the end of its part of the cleanup" "end: ${end}, check end: ${check_end}"
        if [[ "$mode" == slow ]]; then
            assert_contains "$frame" "END 1 ${token} TERMINATED " \
                "S91 slow: the root monitor stops the slow scan with SIGTERM, and the guard records it"
            (( end - start < scan * 10 + 5000 )) ||
                _fail "S91 slow: SIGTERM is enough, so no 5-second grace passes" \
                      "elapsed: $(( end - start )) ms, scan: ${scan} cs"
        else
            assert_not_contains "$frame" "END 1 " "S91 ${mode}: the guard writes no terminal record before SIGKILL"
            (( end - start >= scan * 10 + 5000 - 300 )) ||
                _fail "S91 ${mode}: the guard stays until the root monitor SIGKILL after the 5-second grace" \
                      "elapsed: $(( end - start )) ms, scan: ${scan} cs"
        fi
        if [[ "$mode" == orphan ]]; then
            assert_contains "$frame" $'\nSCAN_END\n' "S91 orphan: the scan ends before its child"
        fi
    done
}

s92_collect_root_check_keeps_one_cleanup_clock() {
    local workspace entry cleanup_end check_end start limit scan end_cs entry_cs launch_cs
    # Too little reserve: no check starts, and the removal keeps 8000 ms.
    workspace="$(new_workspace s92_reserve)"
    ab_check_fixture "$workspace"
    ab_check_refused "S92 reserve" "$workspace" "ms for the process check" AB_CHECK_END_IN_MS=13000
    [[ ! -s "${workspace}/root_calls.tsv" ]] || _fail "S92: no elevation starts without its reserve"
    assert_eq "" "$(awk -F '\t' '$2 ~ /^process-check/' "${workspace}/runner_temp/evidence/m3-mean-speed/commands.tsv")" \
        "S92: no check operation starts without its reserve"
    entry="$(ab_check_value "$workspace" CLEANUP_START_MS)"
    cleanup_end="$(ab_check_value "$workspace" CLEANUP_END_MS)"
    check_end="$(ab_check_value "$workspace" PROCESS_CHECK_END_MS)"
    [[ "$entry" =~ ^[0-9]+$ && "$cleanup_end" =~ ^[0-9]+$ ]] && (( cleanup_end - entry <= 13000 )) ||
        _fail "S92: the cleanup end is the earlier metric end" "entry: ${entry}, end: ${cleanup_end}"
    assert_eq "$(( cleanup_end - 8000 ))" "$check_end" "S92: the removal keeps 8000 ms of the cleanup"
    # A slow executable check before the launch uses the same check part: the
    # end stays 12000 ms after the cleanup entry, and the scan is shorter.
    workspace="$(new_workspace s92_delayed_launch)"
    ab_check_fixture "$workspace"
    ab_check_slow_readlink "$workspace"
    ab_check_cleanup "$workspace" FAKE_READLINK_DELAY=0.2 > /dev/null
    assert_eq "REMOVED" "$(ab_check_value "$workspace" CLEANUP_RESULT)" "S92: the delayed check still completes"
    entry="$(ab_check_value "$workspace" CLEANUP_START_MS)"
    check_end="$(ab_check_value "$workspace" PROCESS_CHECK_END_MS)"
    assert_eq "$(( entry + 12000 ))" "$check_end" "S92: the check part does not restart after the executable check"
    read -r limit start <<< "$(awk -F '\t' '$2 == "process-check" { print $4, $6 }' \
        "${workspace}/runner_temp/evidence/m3-mean-speed/commands.tsv")"
    [[ "$start" =~ ^[0-9]+$ ]] && (( start - entry >= 1500 && limit <= check_end - start )) ||
        _fail "S92: the delay before the launch reduces the check limit" "entry: ${entry}, start: ${start}, limit: ${limit}"
    scan="$(ab_check_value "$workspace" PROCESS_CHECK_SCAN_CS)"
    end_cs="$(ab_check_value "$workspace" PROCESS_CHECK_END_BOOT_CS)"
    entry_cs="$(ab_check_value "$workspace" PROCESS_CHECK_ENTRY_BOOT_CS)"
    [[ "$scan" =~ ^[0-9]+$ && "$end_cs" =~ ^[0-9]+$ && "$entry_cs" =~ ^[0-9]+$ ]] &&
        (( scan == end_cs - entry_cs - 600 && scan < 600 )) ||
        _fail "S92: the scan is the time left to the absolute end less 600 centiseconds" \
              "scan: ${scan}, end: ${end_cs}, entry: ${entry_cs}"
    # A late root entry cannot restart the clock or enlarge the scan.
    workspace="$(new_workspace s92_late_entry)"
    ab_check_fixture "$workspace"
    ab_check_cleanup "$workspace" FAKE_CHECK_DELAY=1.5 > /dev/null
    assert_eq "REMOVED" "$(ab_check_value "$workspace" CLEANUP_RESULT)" "S92: the late check still completes"
    scan="$(ab_check_value "$workspace" PROCESS_CHECK_SCAN_CS)"
    end_cs="$(ab_check_value "$workspace" PROCESS_CHECK_END_BOOT_CS)"
    entry_cs="$(ab_check_value "$workspace" PROCESS_CHECK_ENTRY_BOOT_CS)"
    launch_cs="$(ab_check_value "$workspace" PROCESS_CHECK_LAUNCH_BOOT_CS)"
    [[ "$scan" =~ ^[0-9]+$ && "$end_cs" =~ ^[0-9]+$ && "$entry_cs" =~ ^[0-9]+$ && "$launch_cs" =~ ^[0-9]+$ ]] &&
        (( entry_cs - launch_cs >= 150 && scan == end_cs - entry_cs - 600 && scan < 600 )) ||
        _fail "S92: the late root entry reduces the scan from the same absolute end" \
              "scan: ${scan}, end: ${end_cs}, entry: ${entry_cs}, launch: ${launch_cs}"
}

s93_collect_root_check_terminal_clock_records() {
    local workspace block frame row label ended back expect text status pid launch child problem kind token
    # The parser (review 5476930073, F6): the terminal time of a complete
    # frame is from the launch time to the earlier of the return time and the
    # absolute end. Each number of the frame is a decimal number without a
    # leading zero, because bash arithmetic reads such a number as octal. The
    # request values are those of the review: launch 500, absolute end 1200.
    workspace="$(new_workspace s93_parse)"
    block="$(ab_step_run_body "Capture the evidence" | awk '/^# ---- M3 mean speed: begin ----$/ { inside = 1 }
        inside && !done { print } /^# ---- M3 mean speed: end ----$/ { done = 1 }')"
    frame="${workspace}/frame.txt"
    for row in "valid|599|600|accept" "at the launch time|500|600|accept" "at the return time|600|600|accept" \
               "at the absolute end|1200|1300|accept" \
               "zero|0|600|reject|the terminal time" "backwards|499|600|reject|the terminal time" \
               "after the return|601|600|reject|the terminal time" \
               "after the absolute end|1201|1300|reject|the terminal time" \
               "after both ends|1201|600|reject|the terminal time" \
               "leading zero|0599|600|reject|the terminal record" "no return time|599||reject|the return time" \
               "clock failure|0|600|reject|the status CLOCK_UNAVAILABLE|CLOCK_UNAVAILABLE" \
               "monitor PID with a leading zero|599|600|reject|the monitor record|COMPLETE|0700000000" \
               "launch time with a leading zero|599|600|reject|the launch record|COMPLETE|900000000|0500" \
               "child PID with a leading zero|599|600|reject|the child record|COMPLETE|900000000|500|0900000001"; do
        IFS='|' read -r label ended back expect text status pid launch child <<< "$row"
        pid="${pid:-900000000}" launch="${launch:-500}" child="${child:-900000001}"
        printf '%s\n' "LAUNCH 1 abcdefgh12 ${launch} 100" "FRAME 1 abcdefgh12 /tmp/m3-metric-collection.AbCd1234 1000 1200" \
            "MONITOR ${pid} ${pid} 550 0" SCAN_END "CHILD ${child} 551" "END 1 abcdefgh12 ${status:-COMPLETE} ${ended}" \
            > "$frame"
        problem="$(ab_check_parse "$block" "$frame" "$back")"
        if [[ "$expect" == accept ]]; then
            assert_eq "" "$problem" "S93 parser ${label}: one complete valid frame is accepted"
        else
            assert_contains "$problem" "$text" "S93 parser ${label}: the frame is refused with its cause"
        fi
    done
    # The cleanup: each bad terminal time keeps the task directory, and a
    # valid frame is the control.
    workspace="$(new_workspace s93_frames)"
    ab_check_fixture "$workspace"
    ab_check_cleanup "$workspace" FAKE_CHECK=frame:valid > /dev/null
    assert_eq "REMOVED" "$(ab_check_value "$workspace" CLEANUP_RESULT)" "S93: one complete valid frame permits the removal"
    for kind in end-zero end-backwards end-after-return end-after-deadline end-leading-zero; do
        ab_check_refused "S93 frame ${kind}" "$workspace" "not one complete valid frame" "FAKE_CHECK=frame:${kind}"
        assert_eq "" "$(awk -F '\t' '$2 == "remove"' "${workspace}/runner_temp/evidence/m3-mean-speed/commands.tsv")" \
            "S93 frame ${kind}: no removal starts"
    done
    # The collector: a failed return clock read fails the check, also after
    # a valid frame. The fake sudo removes the clock file, or makes it
    # malformed, after the check. An earlier failure stays the first reason.
    workspace="$(new_workspace s93_return_clock)"
    ab_check_fixture "$workspace"
    ab_check_parent_clock "$workspace"
    ab_check_refused "S93 missing return clock" "$workspace" "the boot clock cannot be read after the process check" \
        FAKE_CHECK=frame:valid FAKE_CHECK_CLOCK=missing
    assert_eq "INCOMPLETE" "$(ab_check_value "$workspace" PROCESS_CHECK_RESULT)" "S93 missing return clock: the check is incomplete"
    ab_check_parent_clock "$workspace"
    ab_check_cleanup "$workspace" FAKE_CHECK=frame:valid FAKE_CHECK_CLOCK=malformed AB_CHECK_FIRST="an earlier failure" > /dev/null
    assert_eq "REFUSED_PROCESS_CHECK" "$(ab_check_value "$workspace" CLEANUP_RESULT)" \
        "S93 malformed return clock: the cleanup refuses with REFUSED_PROCESS_CHECK"
    assert_eq "COMMAND_FAILURE" "$(ab_check_value "$workspace" MEAN_SPEED_REASON_CODE)" \
        "S93 malformed return clock: the earlier failure stays the first reason code"
    assert_eq "an earlier failure" "$(ab_check_value "$workspace" MEAN_SPEED_REASON)" \
        "S93 malformed return clock: the earlier failure stays the first reason"
    [[ -d "$(cat "${workspace}/unit_task")" ]] || _fail "S93 malformed return clock: the task directory stays"
    # A failed read that sets a valid first field (the current clock with no
    # line end: read status 1) gives no time either (review 5478239999). First
    # the return read after a valid frame, then the launch read, which must
    # start no elevation.
    ab_check_parent_clock "$workspace"
    ab_check_refused "S93 partial return clock" "$workspace" "the boot clock cannot be read after the process check" \
        FAKE_CHECK=frame:valid FAKE_CHECK_CLOCK=partial
    assert_eq "INCOMPLETE" "$(ab_check_value "$workspace" PROCESS_CHECK_RESULT)" "S93 partial return clock: the check is incomplete"
    assert_eq "" "$(awk -F '\t' '$2 == "remove"' "${workspace}/runner_temp/evidence/m3-mean-speed/commands.tsv")" \
        "S93 partial return clock: no removal starts"
    workspace="$(new_workspace s93_launch_clock)"
    ab_check_fixture "$workspace"
    ab_check_parent_clock "$workspace"
    ab_check_partial_clock "${workspace}/parent_uptime"
    ab_check_refused "S93 partial launch clock" "$workspace" "the boot clock cannot be read, so the task directory stays" \
        FAKE_CHECK=frame:valid FAKE_CHECK_CLOCK=restore
    [[ ! -s "${workspace}/root_calls.tsv" ]] || _fail "S93 partial launch clock: no elevation starts"
    assert_eq "NOT_RUN" "$(ab_check_value "$workspace" PROCESS_CHECK_RESULT)" "S93 partial launch clock: the check does not run"
    ab_check_partial_clock "${workspace}/parent_uptime"
    ab_check_cleanup "$workspace" FAKE_CHECK=frame:valid FAKE_CHECK_CLOCK=restore AB_CHECK_FIRST="an earlier failure" > /dev/null
    assert_eq "REFUSED_PROCESS_CHECK" "$(ab_check_value "$workspace" CLEANUP_RESULT)" \
        "S93 partial launch clock: the cleanup refuses with REFUSED_PROCESS_CHECK after an earlier failure"
    assert_eq "COMMAND_FAILURE" "$(ab_check_value "$workspace" MEAN_SPEED_REASON_CODE)" \
        "S93 partial launch clock: the earlier failure stays the first reason code"
    assert_eq "an earlier failure" "$(ab_check_value "$workspace" MEAN_SPEED_REASON)" \
        "S93 partial launch clock: the earlier failure stays the first reason"
    [[ -d "$(cat "${workspace}/unit_task")" ]] || _fail "S93 partial launch clock: the task directory stays"
    # The same failed launch read in a complete collection.
    workspace="$(new_workspace s93_launch_collect)"
    ab_collect_fixture "$workspace"
    ab_collect_root_fake "$workspace"
    ab_check_parent_clock "$workspace"
    ab_check_partial_clock "${workspace}/parent_uptime"
    ab_collect_run "$workspace" FAKE_CHECK=frame:valid FAKE_CHECK_CLOCK=restore > /dev/null
    ab_check_full_refused "S93 launch clock" "$workspace" "the boot clock cannot be read, so the task directory stays" \
        NOT_RUN UNAVAILABLE
    [[ ! -s "${workspace}/root_calls.tsv" ]] || _fail "S93 launch clock: no elevation starts"
    # The same malformed return clock in a complete collection.
    workspace="$(new_workspace s93_return_collect)"
    ab_collect_fixture "$workspace"
    ab_collect_root_fake "$workspace"
    ab_check_parent_clock "$workspace"
    ab_collect_run "$workspace" FAKE_CHECK=frame:valid FAKE_CHECK_CLOCK=malformed > /dev/null
    ab_check_full_refused "S93 return clock" "$workspace" "the boot clock cannot be read after the process check"
    # The guard: a failed final clock read fails the check. The real guard
    # and scan run at the fake boundary; the fake find removes the clock file
    # of the fixed source in the scan, after the launch read.
    workspace="$(new_workspace s93_final_clock)"
    ab_collect_fixture "$workspace"
    ab_collect_root_fake "$workspace" clock
    ab_collect_run "$workspace" > /dev/null
    ab_check_full_refused "S93 final clock" "$workspace" "the boot clock cannot be read at the end"
    token="$(ab_collect_value "$workspace" PROCESS_CHECK_TOKEN)"
    assert_contains "$(ab_check_frame "$workspace")" $'SCAN_END\n' "S93 final clock: the scan ends"
    assert_contains "$(ab_check_frame "$workspace")" "END 1 ${token} CLOCK_UNAVAILABLE " \
        "S93 final clock: the guard records the failed clock read in its terminal record"
}

# ---- S94 to S99: the Case 7 functional-record capture (Issue #80) ------------
#
# The evidence workflow keeps the Case 7 functional records in the evidence
# subtree functional-receipt/ (admission 6136000731 of the approved contract
# 6127203837, Sections 4, 5, and 8 to 10). S94 runs the extracted capture step
# as GitHub runs it, with the completed two-cell collection of S72 and a
# complete set of controlled Case 7 records. S95 to S98 run the extracted
# receipt functions alone on the same controlled records, with one controlled
# fault in each run, so each run takes less than one second. S99 reads the
# workflow as text. No check installs OpenFOAM, runs a Stage, reads a VTU
# payload, or dispatches a workflow. A controlled record is capability evidence
# only. It is not an actual Case 7 receipt, and it is not M3 acceptance.
#
# Map to the ten controlled checks of contract Section 10: 1 S94 and S97; 2 S94;
# 3 S95; 4 S96 and S97; 5 S94; 6 S98; 7 S99 and the unchanged S72 to S93; 8 S94
# and S95; 9 S94; 10 S99 and the unchanged Scenarios.

# The six source records, relative to the Batch Workspace, in their order.
AB_FR_RECORDS=(case_7/flow/doe_row.csv case_7/flow/setup_metadata.env case_7/flow/flow.marker
               case_7/flow/restart.marker case_7/vtk/flow_latest_time.txt case_7/vtk/post_processing.complete)
AB_FR_RECORD_IDS=(DOE_ROW SETUP_METADATA FLOW_MARKER RESTART_MARKER LATEST_TIME POST_SIGNATURE)
AB_FR_EMPTY_SHA="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
AB_FR_ALL_PASS="F1=PASS;F2=PASS;F3=PASS;F4=NOT_VERIFIED;F5=PASS;F6=PASS;F7=PASS;F8=PASS;F9=PASS;F10=NOT_VERIFIED"

# The post-processing signature of a flow-only Case with latest time 2.
AB_FR_SIGNATURE=$'flow_latest=2\ntransport_ready=0\ntransport_times=\nscalar_field=T\nflow_zero_fields=(U p wallDistance)\nflow_result_fields=(U p)\nvtu_point_data=included'

# The 57 selected Setup entries and the values that Setup writes for the
# committed Case 7 row (WS 5.0, WD 180.0), the default Setup arguments, and the
# controlled geometry logs: rotation centre (1.5 2.5 0), bounds (-10 -20 0) to
# (10 20 40). Setup substitutes the blockMeshDict text with sed. Setup changes
# the other files with foamDictionary -set, which writes the complete file with
# the default precision of 6 significant digits. These literal values come from
# the Setup formulas, checked once with gawk and mawk; they are the oracle.
ab_fr_expected_entries() {
    local plant device side a b
    printf '%s\t%s\t%s\n' \
        case_7/flow/system/blockMeshDict xMin -698.500 \
        case_7/flow/system/blockMeshDict xMax 1101.500 \
        case_7/flow/system/blockMeshDict yMin -497.500 \
        case_7/flow/system/blockMeshDict yMax 502.500 \
        case_7/flow/system/blockMeshDict zMin 0 \
        case_7/flow/system/blockMeshDict zMax 360.000 \
        case_7/flow/system/blockMeshDict nx 45 \
        case_7/flow/system/blockMeshDict ny 25 \
        case_7/flow/system/blockMeshDict nz 9 \
        case_7/flow/system/snappyHexMeshDict snap off \
        case_7/flow/system/snappyHexMeshDict addLayers off \
        case_7/flow/system/snappyHexMeshDict geometry.refinementDomain.point1 "( 1.5 2.5 0 )" \
        case_7/flow/system/snappyHexMeshDict geometry.refinementDomain.point2 "( 1.5 2.5 80 )" \
        case_7/flow/system/snappyHexMeshDict geometry.refinementDomain.radius 300 \
        case_7/flow/system/snappyHexMeshDict geometry.refineGroundPlane.origin "( 1.5 2.5 0 )" \
        case_7/flow/system/snappyHexMeshDict geometry.refineGroundPlane.radius 300000 \
        case_7/flow/system/snappyHexMeshDict castellatedMeshControls.locationInMesh "( 1.5 2.5 80 )" \
        case_7/flow/system/decomposeParDict numberOfSubdomains 8 \
        case_7/flow/0/U boundaryField.inlet.Uref 5
    for plant in f18p1 f18p2 f18p3; do
        for device in seb aex sex voc; do
            for side in a b; do
                printf '%s\t%s\t%s\n' case_7/flow/0/U "boundaryField.${plant}_${device}_${side}.value" "uniform ( 0 0 10 )"
            done
        done
        if [[ "$plant" == f18p1 ]]; then
            a="-2.11309 4.53154" b="2.11309 -4.53154"
        else
            a="-4.53154 -2.11309" b="4.53154 2.11309"
        fi
        printf '%s\t%s\t%s\n' \
            case_7/flow/0/U "boundaryField.${plant}_oai_a1.value" "uniform ( ${a} 0 )" \
            case_7/flow/0/U "boundaryField.${plant}_oai_a2.value" "uniform ( ${a} 0 )" \
            case_7/flow/0/U "boundaryField.${plant}_oai_b1.value" "uniform ( ${b} 0 )" \
            case_7/flow/0/U "boundaryField.${plant}_oai_b2.value" "uniform ( ${b} 0 )"
    done
    printf '%s\t%s\t%s\n' \
        case_7/flow/0/k boundaryField.inlet.Uref 5 \
        case_7/flow/0/epsilon boundaryField.inlet.Uref 5
}

# ab_fr_foam_file <class> <object> - the banner and the header that
# foamDictionary writes before the dictionary entries. The body follows.
ab_fr_foam_file() {
    printf '/*--------------------------------*- C++ -*----------------------------------*\\\n'
    printf '| =========                 |                                                 |\n'
    printf '| \\\\      /  F ield         | OpenFOAM: The Open Source CFD Toolbox           |\n'
    printf '\\*---------------------------------------------------------------------------*/\n'
    printf 'FoamFile\n{\n    version         2;\n    format          ascii;\n'
    printf '    class           %s;\n    object          %s;\n}\n\n' "$1" "$2"
    printf '// * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * //\n\n'
}

# ab_fr_inlet <type> <value> - the inlet patch of 0/U, 0/k, or 0/epsilon with
# Uref 5, as foamDictionary writes it.
ab_fr_inlet() {
    printf '    inlet\n    {\n        type            %s;\n        flowDir         ( 1 0 0 );\n' "$1"
    printf '        zDir            ( 0 0 1 );\n        Uref            5;\n        Zref            10;\n'
    printf '        z0              uniform 0.1;\n        value           %s;\n    }\n' "$2"
}

# ab_fr_records <checkout> - a complete, consistent set of controlled Case 7
# records in <checkout>/src/batch_9, as the four Stages write them for the
# committed Case 7 row: the one-row DOE Batch CSV, the six source records, the
# two geometry logs, the six Setup dictionaries, the Stage summaries and logs,
# and the two flow VTU files of time 2.
ab_fr_records() {
    local checkout="$1" batch flow vtk csv plant patch device side a b value
    batch="${checkout}/src/batch_9"
    flow="${batch}/case_7/flow"
    vtk="${batch}/case_7/vtk"
    mkdir -p "${flow}/system" "${flow}/0" "$vtk" "${batch}/_mesh_logs" "${batch}/_flow_logs"
    cp -- "${REPO_ROOT}/src/output_batch_1.csv" "${checkout}/src/output_batch_1.csv"
    csv="${batch}/output_batch_9.csv"
    head -n 1 -- "${REPO_ROOT}/src/output_batch_1.csv" > "$csv"
    awk -F, '$1 == "7" { print; exit }' "${REPO_ROOT}/src/output_batch_1.csv" >> "$csv"
    tr -d '\r' < "$csv" > "${flow}/doe_row.csv"
    {
        printf 'case_type=flow\ncsv_file=%s/output_batch_9.csv\nrow_number=2\n' "$(cd -P -- "$batch" && pwd -P)"
        printf 'case_id=case_7\ncase_name=case_7/flow\nwd=180.000\nws=5.0\nws_for_setup=5.0\n'
        printf 'sim_type=RAS\nras_model=kEpsilon\n'
    } > "${flow}/setup_metadata.env"
    : > "${flow}/flow.marker"
    : > "${flow}/restart.marker"
    printf '2\n' > "${vtk}/flow_latest_time.txt"
    printf '%s\n' "$AB_FR_SIGNATURE" > "${vtk}/post_processing.complete"
    printf 'Transforming points\nSet centre of rotation to (1.5 2.5 0)\nEnd\n' > "${flow}/log.surfaceTransformPoints"
    printf 'Reading surface\nOverall bounds (-10 -20 0) (10 20 40)\nEnd\n' > "${flow}/log.surfaceCheck"
    sed -e 's#<xMin>#-698.500#g' -e 's#<xMax>#1101.500#g' -e 's#<yMin>#-497.500#g' \
        -e 's#<yMax>#502.500#g' -e 's#<zMin>#0#g' -e 's#<zMax>#360.000#g' \
        -e 's#<nx>#45#g' -e 's#<ny>#25#g' -e 's#<nz>#9#g' \
        "${MASTER_SRC_DIR}/simpleFoam_files/system/blockMeshDict" > "${flow}/system/blockMeshDict"
    {
        ab_fr_foam_file dictionary snappyHexMeshDict
        printf 'castellatedMesh true;\n\nsnap            off;\n\naddLayers       off;\n\ngeometry\n{\n'
        printf '    f18p1_main.stl\n    {\n        type            triSurfaceMesh;\n        name            f18p1_main;\n    }\n'
        printf '    refinementDomain\n    {\n        type            searchableCylinder;\n'
        printf '        point1          ( 1.5 2.5 0 );\n        point2          ( 1.5 2.5 80 );\n        radius          300;\n    }\n'
        printf '    refineGroundPlane\n    {\n        type            searchableDisk;\n'
        printf '        origin          ( 1.5 2.5 0 );\n        normal          ( 0 0 1 );\n        radius          300000;\n    }\n}\n\n'
        printf 'castellatedMeshControls\n{\n    maxGlobalCells  2000000;\n    features\n    (\n'
        printf '        {\n            file            "f18p1_main.eMesh";\n            level           3;\n        }\n    );\n\n'
        printf '    refinementRegions\n    {\n        refinementDomain\n        {\n'
        printf '            mode            inside;\n            levels          ( ( 1e+15 2 ) );\n        }\n    }\n\n'
        printf '    locationInMesh  ( 1.5 2.5 80 );\n}\n\nsnapControls\n{\n    nSmoothPatch    3;\n}\n\n'
        printf 'mergeTolerance  1e-06;\n\n'
        printf '// ************************************************************************* //\n'
    } > "${flow}/system/snappyHexMeshDict"
    {
        ab_fr_foam_file dictionary decomposeParDict
        printf 'numberOfSubdomains 8;\n\nmethod          scotch;\n\ndistributed     no;\n\nroots           ( );\n\n'
    } > "${flow}/system/decomposeParDict"
    {
        ab_fr_foam_file volVectorField U
        printf 'dimensions      [ 0 1 -1 0 0 0 0 ];\n\ninternalField   uniform ( 0 0 0 );\n\nboundaryField\n{\n'
        ab_fr_inlet atmBoundaryLayerInletVelocity "uniform ( 0 0 0 )"
        printf '    outlet\n    {\n        type            inletOutlet;\n        inletValue      uniform ( 0 0 0 );\n'
        printf '        value           uniform ( 0 0 0 );\n    }\n    ground\n    {\n        type            noSlip;\n    }\n'
        for plant in f18p1 f18p2 f18p3; do
            if [[ "$plant" == f18p1 ]]; then
                a="-2.11309 4.53154" b="2.11309 -4.53154"
            else
                a="-4.53154 -2.11309" b="4.53154 2.11309"
            fi
            printf '    %s_main\n    {\n        type            noSlip;\n    }\n' "$plant"
            for patch in oai_a1 oai_a2 oai_b1 oai_b2; do
                value="$a"
                if [[ "$patch" == oai_b* ]]; then
                    value="$b"
                fi
                printf '    %s_%s\n    {\n        type            fixedValue;\n        value           uniform ( %s 0 );\n    }\n' \
                    "$plant" "$patch" "$value"
            done
            for device in seb aex sex voc; do
                for side in a b; do
                    printf '    %s_%s_%s\n    {\n        type            fixedValue;\n        value           uniform ( 0 0 10 );\n    }\n' \
                        "$plant" "$device" "$side"
                done
            done
        done
        printf '}\n\n'
    } > "${flow}/0/U"
    {
        ab_fr_foam_file volScalarField k
        printf 'kInlet          1.5;\n\ndimensions      [ 0 2 -2 0 0 0 0 ];\n\ninternalField   uniform 1.5;\n\nboundaryField\n{\n'
        ab_fr_inlet atmBoundaryLayerInletK "uniform 1.5"
        printf '    outlet\n    {\n        type            inletOutlet;\n        inletValue      uniform 1.5;\n    }\n}\n\n'
    } > "${flow}/0/k"
    {
        ab_fr_foam_file volScalarField epsilon
        printf 'dimensions      [ 0 2 -3 0 0 0 0 ];\n\ninternalField   uniform 0.01;\n\nboundaryField\n{\n'
        ab_fr_inlet atmBoundaryLayerInletEpsilon "uniform 0.01"
        printf '    outlet\n    {\n        type            inletOutlet;\n        inletValue      uniform 0.01;\n    }\n}\n\n'
    } > "${flow}/0/epsilon"
    {
        printf 'csv_file,row_number,case_id,case_name,case_dir,status,message\n'
        printf '"%s","2","case_7","case_7/flow","%s","meshed","OK"\n' "$csv" "$flow"
    } > "${batch}/run_mesh_cases_summary.csv"
    {
        printf 'csv_file,row_number,case_id,case_name,case_dir,status,message\n'
        printf '"%s","2","case_7","case_7/flow","%s","solved","OK"\n' "$csv" "$flow"
    } > "${batch}/run_flow_cases_summary.csv"
    printf 'mesh log\n' > "${batch}/_mesh_logs/case_7_flow.log"
    printf 'flow log\n' > "${batch}/_flow_logs/case_7_flow.log"
    rm -f -- "${batch}/.run_flow_cases_failed" "${vtk}/flow_latest_100.vtu"
    ab_fr_vtu "${vtk}/flow_0.vtu" U p wallDistance
    ab_fr_vtu "${vtk}/flow_latest_2.vtu" U p
}

# ab_fr_vtu <file> <point-field>... - a foamToVTK-style VTU file with appended
# raw data and the named PointData arrays.
ab_fr_vtu() {
    local file="$1" name
    shift
    {
        printf '<?xml version="1.0"?>\n<VTKFile type="UnstructuredGrid" version="1.0">\n<UnstructuredGrid>\n'
        printf '<Piece NumberOfPoints="8" NumberOfCells="1">\n<PointData>\n'
        for name in "$@"; do
            printf '<DataArray type="Float32" Name="%s" format="appended" offset="0"/>\n' "$name"
        done
        printf '</PointData>\n</Piece>\n</UnstructuredGrid>\n<AppendedData encoding="raw">\n_payload\n'
        printf '</AppendedData>\n</VTKFile>\n'
    } > "$file"
}

# ab_fr_scanner_evidence <workspace> - the capture evidence that the receipt
# reads, as the earlier capture items write it for the controlled records: the
# Stage summaries and logs, and the VTU manifest and tags of the two flow VTU
# files.
ab_fr_scanner_evidence() {
    local workspace="$1" batch evidence vtu path sha bytes fields
    batch="${workspace}/checkout/src/batch_9"
    evidence="${workspace}/runner_temp/evidence"
    mkdir -p "${evidence}/summaries" "${evidence}/stage-logs/_mesh_logs" "${evidence}/stage-logs/_flow_logs"
    cp -- "${batch}/run_mesh_cases_summary.csv" "${batch}/run_flow_cases_summary.csv" "${evidence}/summaries/"
    cp -- "${batch}/_mesh_logs/case_7_flow.log" "${evidence}/stage-logs/_mesh_logs/"
    cp -- "${batch}/_flow_logs/case_7_flow.log" "${evidence}/stage-logs/_flow_logs/"
    {
        printf '== VTU point-data manifest ==\nSCALAR_FIELD=T\nVTK_DIRECTORY_COUNT=1\nVTU_TAG_EVIDENCE_FILE=vtu-tags.txt\n'
    } > "${evidence}/vtu-point-data.txt"
    : > "${evidence}/vtu-tags.txt"
    for vtu in flow_0 flow_latest_2; do
        path="case_7/vtk/${vtu}.vtu"
        sha="$(sha256sum < "${batch}/${path}" | cut -d ' ' -f 1)"
        bytes="$(wc -c < "${batch}/${path}" | tr -d ' ')"
        fields="U p"
        if [[ "$vtu" == flow_0 ]]; then
            fields="U p wallDistance"
        fi
        printf '\nVTU_PATH=%s\nVTU_BYTES=%s\nVTU_SHA256=%s\nVTU_EXPECTED_FIELDS=%s\nVTU_OBSERVED_FIELDS=%s\n' \
            "$path" "$bytes" "$sha" "$fields" "$fields" >> "${evidence}/vtu-point-data.txt"
        printf 'VTU_OBSERVED_CELL_FIELDS=\nVTU_MISSING_REQUIRED_FIELDS=\nVTU_REQUIRED_FIELDS_RESULT=MATCH\nVTU_TAG_EVIDENCE=COMPLETE\n' \
            >> "${evidence}/vtu-point-data.txt"
        {
            printf '== VTU_TAGS path=%s sha256=%s\n' "$path" "$sha"
            printf 'TAG offset=150 bytes=11 element=PointData context=Piece\n<PointData>\n'
            printf 'TAG offset=162 bytes=60 element=DataArray context=PointData\n<DataArray Name="U"/>\n'
            printf '== VTU_TAGS_END path=%s tag_evidence=COMPLETE\n' "$path"
        } >> "${evidence}/vtu-tags.txt"
    done
    printf '\nVTU_FILE_COUNT=2\nVTU_EVIDENCE=PRESENT\nVTU_REQUIRED_FIELDS_VERDICT=COMPLETE\n' >> "${evidence}/vtu-point-data.txt"
}

# ab_fr_metric_evidence <workspace> - the m3-mean-speed record of an available
# collection of time 2 by the same producer (the format of S72).
ab_fr_metric_evidence() {
    local workspace="$1" metric manifest turbulence
    metric="${workspace}/runner_temp/evidence/m3-mean-speed"
    mkdir -p "${metric}/logs" "${metric}/output"
    turbulence="$(printf 'simulationType RAS;\n' | sha256sum | cut -d ' ' -f 1)"
    manifest="$(printf 'path\tbytes\tsha256\n2/U\t307\t%s\nconstant/turbulenceProperties\t264\t%s\n' "$AB_FR_EMPTY_SHA" "$turbulence")"
    printf '%s\n' "$manifest" > "${metric}/source-before.tsv"
    printf '%s\n' "$manifest" > "${metric}/source-after.tsv"
    printf '%s\n' "$manifest" > "${metric}/snapshot-before.tsv"
    printf '%s\n' "$manifest" > "${metric}/snapshot-after.tsv"
    printf 'PACKAGE=openfoam2512-default\n' > "${metric}/identity.txt"
    printf 'seq\tlabel\n' > "${metric}/commands.tsv"
    printf 'kind\tbytes\tsha256\tpath\n' > "${metric}/inventory.txt"
    printf 'label\tbytes\ttime_ms\n' > "${metric}/task-bytes.tsv"
    printf 'LAUNCH 1\n' > "${metric}/process-check.txt"
    printf 'APPLICATION=simpleFoam\nSTART_FROM=latestTime\nSIMULATION_TYPE=RAS\nRAS_MODEL=kEpsilon\n' > "${metric}/logs/12-controls.out"
    printf '# Region : all region0\n' > "${metric}/output/volFieldValue.dat"
    # The approved 636-byte dictionary, from the extracted collection block.
    bash --noprofile --norc -c "$(ab_collect_block "$workspace")"'
printf "%s" "$METRIC_DICTIONARY"' > "${metric}/metric-functions"
    {
        printf 'MEAN_SPEED_VERDICT=AVAILABLE\nMEAN_SPEED_REASON_CODE=NONE\nMEAN_SPEED_VALUE=3.66666666666666652e+00\n'
        printf 'MEAN_SPEED_UNIT=m/s\nMAIN_SHA=%s\nRUN_ID=4545\nSOURCE_FLOW_CASE=src/batch_9/case_7/flow\n' "$AB_COLLECT_SHA"
        printf 'POST_PROCESSING_TIME=2\nSELECTED_TIME=2\nDICTIONARY_BYTES=636\nDICTIONARY_SHA256=%s\n' "$AB_COLLECT_DICTIONARY_SHA"
        printf 'INPUTS_UNCHANGED=YES\nOUTPUT_PATH=postProcessing/m3MeanSpeed/2/volFieldValue.dat\n'
        printf 'OUTPUT_SHA256=%s\nOUTPUT_TIME=2\nOUTPUT_REGION=all region0\n' \
            "$(sha256sum < "${metric}/output/volFieldValue.dat" | cut -d ' ' -f 1)"
        printf 'OUTPUT_FIELD=volAverage(m3MagU)\nOUTPUT_CELLS=2\nOUTPUT_VOLUME=3.00000000000000000e+00\n'
        printf 'OUTPUT_VALUE=3.66666666666666652e+00\nCLEANUP_RESULT=REMOVED\nPROCESS_CHECK_RESULT=COMPLETE\n'
        printf 'LOGS_RETAINED=YES\nINVENTORY=COMPLETE\n'
    } > "${metric}/result.env"
}

# ab_fr_library <workspace> - the capture work helpers before the VTU reader
# (notes_file, capture_note, bounded, and _bounded) and the functional-receipt
# block, from the extracted capture step.
ab_fr_library() {
    local step="${1}/capture_step.sh"
    awk '/<<.CAPTURE_WORK.$/ { inside = 1; next } inside && /^# Change 7\./ { exit } inside { print }' "$step"
    awk '/^# ---- Functional receipt: begin ----$/ { inside = 1 } inside && !done { print }
         /^# ---- Functional receipt: end ----$/ { done = 1 }' "$step"
}

# ab_fr_fixture <workspace> - the extracted capture step, the controlled
# records, the capture evidence of the earlier items, and an available
# collection record, for ab_fr_unit. The first call of an observation builds
# the fixture in its own workspace, and each call copies it, so each run starts
# from the same controlled bytes. The metadata then names the physical DOE
# Batch CSV path of the new workspace, as Setup writes it.
ab_fr_fixture() {
    local workspace="$1" batch
    if [[ -z "${AB_FR_TEMPLATE:-}" ]]; then
        AB_FR_TEMPLATE="$(new_workspace fr_template)"
        ab_capture_fixture "$AB_FR_TEMPLATE"
        ab_fr_records "${AB_FR_TEMPLATE}/checkout"
        ab_fr_scanner_evidence "$AB_FR_TEMPLATE"
        ab_fr_metric_evidence "$AB_FR_TEMPLATE"
    fi
    cp -a -- "${AB_FR_TEMPLATE}/." "${workspace}/"
    batch="${workspace}/checkout/src/batch_9"
    sed -i -e "s#^csv_file=.*#csv_file=$(cd -P -- "$batch" && pwd -P)/output_batch_9.csv#" \
        "${batch}/case_7/flow/setup_metadata.env"
}

# ab_fr_signature <workspace> <signature-text>... - the extracted fr_signature
# result for each retained signature text, one line each: the state, the
# flow_latest value, and the reason. No other receipt function runs. The first
# <NUL> in a text is written as a NUL byte. The retained byte count is the
# byte count of the written record.
ab_fr_signature() {
    local workspace="$1" library
    shift
    library="$(ab_fr_library "$workspace")"
    mkdir -p "${workspace}/signature/files/case_7/vtk"
    env FR_DIR="${workspace}/signature" EVIDENCE_DIR="${workspace}/runner_temp/evidence" \
        "${AB_STEP_BASH[@]}" -c "${library}"'
declare -A FR_REC_OUTCOME=([POST_SIGNATURE]=RETAINED) FR_REC_REASON=() FR_REC_BYTES=()
record="${FR_DIR}/files/case_7/vtk/post_processing.complete"
for text in "$@"; do
    if [[ "$text" == *"<NUL>"* ]]; then
        printf "%s\0%s" "${text%%<NUL>*}" "${text#*<NUL>}" > "$record"
    else
        printf "%s" "$text" > "$record"
    fi
    FR_REC_BYTES[POST_SIGNATURE]="$(stat -c %s -- "$record")"
    fr_signature
    printf "%s|%s|%s\n" "$SIG_STATE" "$SIG_TIME" "$SIG_WHY"
done' signature "$@"
}

# ab_fr_unit <workspace> [NAME=value ...] - run the extracted receipt functions
# alone, as the capture work calls them after the collection, with a far
# capture work end. The arguments override the environment. Prints status=.
ab_fr_unit() {
    local workspace="$1" library status
    shift
    library="$(ab_fr_library "$workspace")"
    [[ "$library" == *"# ---- Functional receipt: end ----"* ]] ||
        { _fail "the functional-receipt block of the capture work must be extracted"; return 1; }
    : > "${workspace}/runner_temp/evidence/capture-work-notes.txt"
    env PATH="${workspace}/fakebin:${PATH}" TMPDIR="${workspace}/tmp" \
        RUNNER_TEMP="${workspace}/runner_temp" EVIDENCE_DIR="${workspace}/runner_temp/evidence" \
        GITHUB_WORKSPACE="${workspace}/checkout" CAPTURE_WORK_END="$(( $(date +%s) + 1000 ))" \
        GITHUB_SHA="$AB_COLLECT_SHA" GITHUB_RUN_ID=4545 GITHUB_RUN_ATTEMPT=1 \
        GITHUB_REPOSITORY=derek-thl/ucfd_run_batch GITHUB_WORKFLOW=openfoam-evidence GITHUB_JOB=evidence \
        "$@" "${AB_STEP_BASH[@]}" -c "${library}"'
fr_capture' > "${workspace}/unit.out" 2>&1 && status=0 || status=$?
    printf 'status=%s\n' "$status"
}

# ab_fr_dir <workspace> - the functional-receipt subtree.
ab_fr_dir() {
    printf '%s\n' "${1}/runner_temp/evidence/functional-receipt"
}

# ab_fr_value <workspace> <key> - one value of functional-receipt/result.env.
ab_fr_value() {
    ab_file_value "$(ab_fr_dir "$1")/result.env" "$2"
}

# ab_fr_cell <file> <key-column> <key> <column> - one cell of a receipt TSV
# file: the named column of the first row whose key column holds the key.
ab_fr_cell() {
    awk -F '\t' -v kc="$2" -v key="$3" -v col="$4" '
        NR == 1 { for (i = 1; i <= NF; i++) index_of[$i] = i; next }
        $(index_of[kc]) == key { print $(index_of[col]); exit }' "$1" 2>/dev/null || true
}

# ab_fr_check <workspace> <check> [column] - one cell of the F1 to F10 row.
ab_fr_check() {
    ab_fr_cell "$(ab_fr_dir "$1")/checks.tsv" check "$2" "${3:-result}"
}

# ab_fr_record <workspace> <record> [column] - one cell of a records.tsv row.
ab_fr_record() {
    ab_fr_cell "$(ab_fr_dir "$1")/records.tsv" record "$2" "${3:-outcome}"
}

# ab_fr_entry <workspace> <entry> [column] [source] - one cell of the
# setup-entry-values row of one entry. The source, relative to the Batch
# Workspace, defaults to the first row of the entry.
ab_fr_entry() {
    awk -F '\t' -v entry="$2" -v col="${3:-result}" -v source="${4:-}" '
        NR == 1 { for (i = 1; i <= NF; i++) index_of[$i] = i; next }
        $3 == entry && (source == "" || $1 == source) { print $(index_of[col]); exit }' \
        "$(ab_fr_dir "$1")/setup-entry-values.tsv" 2>/dev/null || true
}

# ab_fr_tree_sha <directory> - one checksum line for each readable regular
# file, sorted. An unreadable file has no line before and after the run.
ab_fr_tree_sha() {
    (cd "$1" && find . -type f -readable -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) || true
}

# ab_fr_summary <workspace> - run the extracted summary step with the receipt
# values that the capture step published. Prints the job summary.
ab_fr_summary() {
    local workspace="$1"
    : > "${workspace}/step_summary"
    env GITHUB_STEP_SUMMARY="${workspace}/step_summary" \
        FUNCTIONAL_RECEIPT_RESULT="$(ab_env_last "$workspace" FUNCTIONAL_RECEIPT_RESULT)" \
        FUNCTIONAL_RECEIPT_CHECKS="$(ab_env_last "$workspace" FUNCTIONAL_RECEIPT_CHECKS)" \
        "${AB_STEP_BASH[@]}" "${workspace}/summary_step.sh" > /dev/null 2>&1 ||
        _fail "the extracted summary step must succeed"
    cat "${workspace}/step_summary"
}

# ab_fr_expect_unit <label> <workspace> <checks> - a unit run that ends with
# status 0 and gives the F1 to F10 results <checks>.
ab_fr_expect_unit() {
    local label="$1" workspace="$2" checks="$3" run
    shift 3
    run="$(ab_fr_unit "$workspace" "$@")"
    assert_contains "$run" "status=0" "${label}: the receipt work ends with status 0"
    [[ "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_CHECKS)" == "$checks" ]] ||
        _fail "${label}: the check results must be ${checks}" \
              "actual: $(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_CHECKS)" \
              "$(cut -f 1,3,5 "$(ab_fr_dir "$workspace")/checks.tsv" 2>/dev/null)" "$(tail -n 5 "${workspace}/unit.out")"
}

# ab_fr_case <label> <checks> <setup> [NAME=value ...] - one unit run in a new
# workspace after <setup> changes the controlled fixture. The construction must
# be COMPLETE, the source tree must stay unchanged, and no capture note is
# written. Sets AB_FR_LAST to the workspace.
ab_fr_case() {
    local label="$1" checks="$2" setup="$3" workspace before after
    shift 3
    workspace="$(new_workspace "${label//[^A-Za-z0-9_.-]/_}")"
    ab_fr_fixture "$workspace"
    "$setup" "$workspace"
    before="$(ab_fr_tree_sha "${workspace}/checkout/src")"
    ab_fr_expect_unit "$label" "$workspace" "$checks" "$@"
    after="$(ab_fr_tree_sha "${workspace}/checkout/src")"
    assert_eq "$before" "$after" "${label}: the receipt writes no source file"
    assert_eq "COMPLETE" "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_RESULT)" "${label}: the construction is complete"
    assert_eq "" "$(cat "${workspace}/runner_temp/evidence/capture-work-notes.txt")" \
        "${label}: a source-content gap gives no capture note"
    AB_FR_LAST="$workspace"
}

# ab_fr_assert_inventory <workspace> <label> - inventory.tsv lists each receipt
# file except itself and result.env with its exact byte count and SHA-256, and
# result.env binds the inventory by its SHA-256.
ab_fr_assert_inventory() {
    local workspace="$1" label="$2" dir expected
    dir="$(ab_fr_dir "$workspace")"
    expected="$(cd "$dir" && find . -type f ! -path ./inventory.tsv ! -path ./result.env -print0 | LC_ALL=C sort -z |
        while IFS= read -r -d '' file; do
            printf 'FILE\t%s\t%s\t%s\n' "$(stat -c %s -- "$file")" "$(sha256sum < "$file" | cut -d ' ' -f 1)" "${file#./}"
        done)"
    assert_eq "$expected" "$(grep '^FILE' "${dir}/inventory.tsv")" "${label}: the inventory lists each receipt file exactly"
    assert_eq "$(sha256sum < "${dir}/inventory.tsv" | cut -d ' ' -f 1)" "$(ab_fr_value "$workspace" INVENTORY_SHA256)" \
        "${label}: result.env binds the inventory by its SHA-256"
}

s94_receipt_complete_controlled_fixture() {
    local workspace run dir flow batch before after record id index row source expected file entry value line
    local listing decoded offset bytes count
    workspace="$(new_workspace s94_receipt)"
    ab_collect_fixture "$workspace"
    ab_fr_records "${workspace}/checkout"
    batch="${workspace}/checkout/src/batch_9"
    flow="$(ab_collect_flow "$workspace")"
    dir="$(ab_fr_dir "$workspace")"
    before="$(ab_collect_tree_sha "$batch")"
    run="$(ab_collect_run "$workspace")"
    after="$(ab_collect_tree_sha "$batch")"
    assert_contains "$run" "status=0" "S94: the capture step ends with status 0"
    assert_eq "$before" "$after" "S94: the receipt and the collection write no source file"
    # The unchanged collection, product, and capture results.
    assert_eq "AVAILABLE" "$(ab_collect_value "$workspace" MEAN_SPEED_VERDICT)" "S94: the collection stays available"
    assert_eq "3.66666666666666652e+00" "$(ab_collect_value "$workspace" MEAN_SPEED_VALUE)" "S94: the mean speed stays 11/3 m/s"
    assert_eq "COMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "S94: the capture is complete"
    [[ "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_RESULT)" == COMPLETE ]] ||
        _fail "S94: the receipt construction must be COMPLETE" \
              "reason: $(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_REASON)" "$(tail -n 8 "${workspace}/capture_step.out")"
    assert_eq "$AB_FR_ALL_PASS" "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_CHECKS)" \
        "S94: every supported check passes, and F4 and F10 stay NOT_VERIFIED"
    assert_eq "POST_ORCHESTRATOR_CAPTURE" "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_CHECKPOINT)" "S94: the checkpoint"
    # Check 9: a complete controlled receipt is evidence construction only.
    assert_contains "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_SCOPE)" "not M3 acceptance" \
        "S94: COMPLETE is construction only, not M3 acceptance"
    assert_eq "0" "$(grep -rhoE 'ACCEPTED|ACCEPTANCE=|CONVERGED|solution converged' "$dir" | grep -c . || true)" \
        "S94: the receipt states no acceptance and no solver convergence"
    # The producer identity.
    assert_eq "$AB_COLLECT_SHA" "$(ab_file_value "${dir}/identity.env" EXECUTION_SHA)" "S94: the execution SHA"
    assert_eq "4545" "$(ab_file_value "${dir}/identity.env" GITHUB_RUN_ID)" "S94: the run ID"
    assert_eq "case_7" "$(ab_file_value "${dir}/identity.env" CASE_ID)" "S94: the Case"
    assert_eq "9" "$(ab_file_value "${dir}/identity.env" BATCH_ID)" "S94: the Batch ID"
    assert_eq "src/batch_9" "$(ab_file_value "${dir}/identity.env" BATCH_WORKSPACE)" "S94: the Batch Workspace"
    assert_eq "src/output_batch_1.csv Case 7" "$(ab_file_value "${dir}/identity.env" APPROVED_ROW)" "S94: the approved row"
    # Checks 1 and 2: the six exact source records, with the raw bytes and
    # correct source and retained hashes; the empty markers stay zero-byte
    # records.
    assert_eq $'record\tsource\tsource_bytes_before\tsource_sha256_before\tsource_bytes_after\tsource_sha256_after\tretained\tretained_bytes\tretained_sha256\toutcome\treason' \
        "$(head -n 1 "${dir}/records.tsv")" "S94: the record columns"
    assert_eq "7" "$(grep -c '' "${dir}/records.tsv")" "S94: one row for each of the six records"
    for index in "${!AB_FR_RECORDS[@]}"; do
        record="${AB_FR_RECORDS[$index]}" id="${AB_FR_RECORD_IDS[$index]}"
        source="${batch}/${record}"
        expected="$(sha256sum < "$source" | cut -d ' ' -f 1)"
        bytes="$(stat -c %s -- "$source")"
        row="$(awk -F '\t' -v id="$id" '$1 == id' "${dir}/records.tsv")"
        assert_eq "${id}"$'\t'"${record}"$'\t'"${bytes}"$'\t'"${expected}"$'\t'"${bytes}"$'\t'"${expected}"$'\t'"files/${record}"$'\t'"${bytes}"$'\t'"${expected}"$'\tRETAINED' \
            "$(cut -f 1-10 <<< "$row")" "S94: ${id} is retained with its exact bytes and hashes"
        cmp -s -- "$source" "${dir}/files/${record}" || _fail "S94: ${id} keeps the raw source bytes"
    done
    for id in FLOW_MARKER RESTART_MARKER; do
        assert_eq "0" "$(ab_fr_record "$workspace" "$id" retained_bytes)" "S94: ${id} is a complete zero-byte record"
        assert_eq "$AB_FR_EMPTY_SHA" "$(ab_fr_record "$workspace" "$id" retained_sha256)" "S94: ${id} has the empty-file SHA-256"
    done
    # Check 1: every selected Setup entry, with its exact source bytes and value.
    assert_eq $'source\tsource_sha256\tentry\toutcome\toffset\tbytes\tentry_base64\tfragment_sha256\tvalue\texpected\tresult\treason' \
        "$(head -n 1 "${dir}/setup-entry-values.tsv")" "S94: the entry columns"
    assert_eq "$(ab_fr_expected_entries)" "$(awk -F '\t' 'NR > 1 { print $1 "\t" $3 "\t" $9 }' "${dir}/setup-entry-values.tsv")" \
        "S94: the 57 selected entries with the values that Setup writes"
    assert_eq "57" "$(awk -F '\t' 'NR > 1 && $4 == "FOUND" && $9 == $10 && $11 == "PASS"' "${dir}/setup-entry-values.tsv" | wc -l)" \
        "S94: each entry is found once, equals its expected value, and passes"
    while IFS=$'\t' read -r source sha entry _ offset count line fragment _; do
        [[ "$source" == source ]] && continue
        file="${batch}/${source}"
        assert_eq "$(sha256sum < "$file" | cut -d ' ' -f 1)" "$sha" "S94: ${entry} names its source SHA-256"
        decoded="$(base64 -d <<< "$line" | od -An -tx1 | tr -d ' \n')"
        assert_eq "$(tail -c "+$(( offset + 1 ))" -- "$file" | head -c "$count" | od -An -tx1 | tr -d ' \n')" "$decoded" \
            "S94: ${entry} keeps the exact source bytes at its offset"
        assert_eq "$(base64 -d <<< "$line" | sha256sum | cut -d ' ' -f 1)" "$fragment" "S94: ${entry} has its fragment SHA-256"
    done < "${dir}/setup-entry-values.tsv"
    # Check 5: only the selected fragments; no field payload, mesh, VTU, or
    # transport content enters the receipt.
    assert_eq "0" "$(awk -F '\t' 'NR > 1 { print $7 }' "${dir}/setup-entry-values.tsv" | while IFS= read -r line; do
        base64 -d <<< "$line"; printf '\n'; done | grep -cE 'internalField|nonuniform|dimensions|FoamFile' || true)" \
        "S94: no fragment holds an internal field, dimensions, or a file header"
    listing="$(cd "$dir" && find . -mindepth 1 | LC_ALL=C sort)"
    assert_eq $'./checks.tsv\n./files\n./files/case_7\n./files/case_7/flow\n./files/case_7/flow/doe_row.csv\n./files/case_7/flow/flow.marker\n./files/case_7/flow/restart.marker\n./files/case_7/flow/setup_metadata.env\n./files/case_7/vtk\n./files/case_7/vtk/flow_latest_time.txt\n./files/case_7/vtk/post_processing.complete\n./identity.env\n./inventory.tsv\n./records.tsv\n./result.env\n./setup-entry-values.tsv' \
        "$listing" "S94: the receipt holds only its text records and the six source records"
    if find "${workspace}/runner_temp/evidence" -name '*.vtu' -o -name polyMesh -o -name 'trd*' | grep -q .; then
        _fail "S94: no VTU, mesh, or transport content enters the evidence"
    fi
    (( $(du -sb --apparent-size "$dir" | cut -f 1) <= 262144 )) || _fail "S94: the receipt holds at most 262144 bytes"
    # The checks, with exact limits for F4, F8, and F10.
    assert_eq $'check\trequirement\tresult\tevidence\treason\tlimitation' "$(head -n 1 "${dir}/checks.tsv")" "S94: the check columns"
    assert_eq "F1 F2 F3 F4 F5 F6 F7 F8 F9 F10" "$(awk -F '\t' 'NR > 1 { print $1 }' "${dir}/checks.tsv" | paste -sd ' ' -)" \
        "S94: one row for each check, in order"
    # Check 8: a PointData MATCH and a whole-file hash are no payload readback.
    assert_contains "$(ab_fr_check "$workspace" F4 reason)" "payload-readback witness" \
        "S94: F4 names the absent payload-readback witness"
    assert_contains "$(ab_fr_check "$workspace" F4 evidence)" "case_7/vtk/flow_latest_2.vtu" "S94: F4 names the latest VTU file"
    assert_contains "$(ab_fr_check "$workspace" F8 limitation)" "not solver convergence" \
        "S94: a marker is Stage evidence, not solver convergence"
    assert_contains "$(ab_fr_check "$workspace" F10 reason)" "F4" "S94: F10 names the unresolved F4"
    assert_contains "$(ab_fr_check "$workspace" F7 evidence)" "m3-mean-speed/result.env" "S94: F7 names the collection record"
    ab_fr_assert_inventory "$workspace" "S94"
    # The published result and the summary row.
    assert_eq "COMPLETE" "$(ab_env_last "$workspace" FUNCTIONAL_RECEIPT_RESULT)" "S94: GITHUB_ENV has the receipt result"
    assert_eq "$AB_FR_ALL_PASS" "$(ab_env_last "$workspace" FUNCTIONAL_RECEIPT_CHECKS)" "S94: GITHUB_ENV has the check results"
    assert_contains "$(ab_fr_summary "$workspace")" "| Functional receipt | \`COMPLETE\` ${AB_FR_ALL_PASS} |" \
        "S94: the summary shows the receipt result"
}

# ---- S95: the time, signature, VTU, and producer checks ---------------------

s95_receipt_time_signature_and_producer_checks() {
    local workspace results record
    # The unit baseline equals the integrated result of S94.
    workspace="$(new_workspace s95_baseline)"
    ab_fr_fixture "$workspace"
    ab_fr_expect_unit "S95 baseline" "$workspace" "$AB_FR_ALL_PASS"
    ab_fr_assert_inventory "$workspace" "S95 baseline"
    # Check 3: each signature fault fails. One process checks each retained
    # signature text with the extracted signature check.
    results="$(ab_fr_signature "$workspace" "${AB_FR_SIGNATURE}"$'\n' "${AB_FR_SIGNATURE}"$'\nscalar_field=T\n' \
        "${AB_FR_SIGNATURE%$'\n'vtu_point_data=included}"$'\n' "${AB_FR_SIGNATURE/transport_ready=0/transport_ready=1}"$'\n' \
        $'flow_latest=2\ntransport_times=\ntransport_ready=0\nscalar_field=T\nflow_zero_fields=(U p wallDistance)\nflow_result_fields=(U p)\nvtu_point_data=included\n' \
        "$AB_FR_SIGNATURE" "${AB_FR_SIGNATURE/scalar_field=T/scalar_field=S}"$'\n')"
    assert_eq "OK|2|-
FAIL|2|the signature has the key scalar_field 2 times
FAIL|2|the signature has no vtu_point_data line
FAIL|2|the signature has transport_ready=1, not transport_ready=0
FAIL|2|the signature keys are not in the order flow_latest transport_ready transport_times scalar_field flow_zero_fields flow_result_fields vtu_point_data
FAIL|2|the signature does not end with a line end
FAIL|2|the signature has scalar_field=S, not scalar_field=T" "$results" \
        "S95: the exact signature passes, and a duplicate, missing, wrong, or reordered key or a missing line end fails"
    # R1: a NUL byte ends a shell read. An unknown or a duplicate key after a
    # NUL byte that follows the exact signature fails, and no part is parsed.
    results="$(ab_fr_signature "$workspace" "${AB_FR_SIGNATURE}"$'\n<NUL>unknown_key=invalid\n' \
        "${AB_FR_SIGNATURE}"$'\n<NUL>flow_latest=2\n')"
    assert_eq "FAIL||post_processing.complete has a NUL byte after 149 of its 170 bytes
FAIL||post_processing.complete has a NUL byte after 149 of its 164 bytes" "$results" \
        "S95: a signature with a NUL byte after the exact signature fails"
    # A wrong post time fails F3 and F6 in the complete receipt.
    ab_fr_case "S95 post time" "F1=PASS;F2=PASS;F3=FAIL;F4=NOT_VERIFIED;F5=PASS;F6=FAIL;F7=PASS;F8=PASS;F9=PASS;F10=FAIL" \
        ab_fr_post_time
    assert_contains "$(ab_fr_check "$AB_FR_LAST" F3 reason)" "flow_latest=3" "S95: a wrong post time is named"
    ab_fr_case "S95 zero time" "F1=PASS;F2=FAIL;F3=FAIL;F4=NOT_VERIFIED;F5=PASS;F6=FAIL;F7=PASS;F8=PASS;F9=PASS;F10=FAIL" \
        ab_fr_time_zero
    ab_fr_case "S95 time without line end" "F1=PASS;F2=FAIL;F3=NOT_VERIFIED;F4=NOT_VERIFIED;F5=PASS;F6=NOT_VERIFIED;F7=PASS;F8=PASS;F9=PASS;F10=FAIL" \
        ab_fr_time_no_end
    # R1: a time record of more than 64 bytes and a signature, each with a NUL
    # byte after a valid prefix, fail with their complete byte counts. Each
    # stays a retained record with all its bytes.
    ab_fr_case "S95 NUL records" "F1=PASS;F2=FAIL;F3=FAIL;F4=NOT_VERIFIED;F5=PASS;F6=NOT_VERIFIED;F7=PASS;F8=PASS;F9=PASS;F10=FAIL" \
        ab_fr_nul_records
    assert_contains "$(ab_fr_check "$AB_FR_LAST" F2 reason)" "flow_latest_time.txt has a NUL byte after 2 of its 74 bytes" \
        "S95: the time record with a NUL byte is named with its byte counts"
    assert_contains "$(ab_fr_check "$AB_FR_LAST" F3 reason)" "post_processing.complete has a NUL byte after 149 of its 170 bytes" \
        "S95: the signature with a NUL byte is named with its byte counts"
    assert_eq "74 RETAINED 170 RETAINED" "$(ab_fr_record "$AB_FR_LAST" LATEST_TIME retained_bytes) $(ab_fr_record "$AB_FR_LAST" LATEST_TIME) $(ab_fr_record "$AB_FR_LAST" POST_SIGNATURE retained_bytes) $(ab_fr_record "$AB_FR_LAST" POST_SIGNATURE)" \
        "S95: the records with a NUL byte stay retained with their complete byte counts"
    for record in case_7/vtk/flow_latest_time.txt case_7/vtk/post_processing.complete; do
        cmp -s -- "${AB_FR_LAST}/checkout/src/batch_9/${record}" "$(ab_fr_dir "$AB_FR_LAST")/files/${record}" ||
            _fail "S95: the retained ${record} keeps every byte"
    done
    # R1: a retained record that a read cannot give completely is not used.
    # The checks that need it stay NOT_VERIFIED, and the construction is
    # INCOMPLETE with a capture note.
    workspace="$(new_workspace s95_short_read)"
    ab_fr_fixture "$workspace"
    ab_fr_fake_truncating_hash "$workspace"
    ab_fr_expect_unit "S95 short read" "$workspace" \
        "F1=PASS;F2=NOT_VERIFIED;F3=NOT_VERIFIED;F4=NOT_VERIFIED;F5=PASS;F6=NOT_VERIFIED;F7=PASS;F8=PASS;F9=PASS;F10=NOT_VERIFIED"
    assert_eq "INCOMPLETE" "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_RESULT)" "S95 short read: the construction is incomplete"
    assert_contains "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_REASON)" "flow_latest_time.txt gives 1 of its 2 bytes" \
        "S95 short read: the reason names the incomplete read"
    assert_contains "$(ab_fr_check "$workspace" F3 reason)" "post_processing.complete gives 148 of its 149 bytes" \
        "S95 short read: F3 names the incomplete signature read"
    assert_contains "$(cat "${workspace}/runner_temp/evidence/capture-work-notes.txt")" "functional receipt" \
        "S95 short read: the incomplete read is a capture note"
    assert_contains "$(cat "${workspace}/runner_temp/evidence/capture-work-notes.txt")" \
        "functional receipt: the signature cannot be read completely" "S95 short read: the incomplete signature read is a capture note"
    ab_fr_case "S95 collector time" "F1=PASS;F2=FAIL;F3=FAIL;F4=NOT_VERIFIED;F5=PASS;F6=FAIL;F7=FAIL;F8=PASS;F9=PASS;F10=FAIL" \
        ab_fr_metric_time
    ab_fr_case "S95 no collection" "F1=NOT_VERIFIED;F2=NOT_VERIFIED;F3=NOT_VERIFIED;F4=NOT_VERIFIED;F5=PASS;F6=NOT_VERIFIED;F7=NOT_VERIFIED;F8=PASS;F9=NOT_VERIFIED;F10=NOT_VERIFIED" \
        ab_fr_no_metric
    # A mixed producer identity cannot pass.
    ab_fr_case "S95 other producer" "F1=NOT_VERIFIED;F2=NOT_VERIFIED;F3=NOT_VERIFIED;F4=NOT_VERIFIED;F5=PASS;F6=NOT_VERIFIED;F7=FAIL;F8=PASS;F9=FAIL;F10=FAIL" \
        ab_fr_metric_producer
    assert_contains "$(ab_fr_check "$AB_FR_LAST" F7 reason)" "producer" "S95: the mixed producer is named"
    # Check 8: a missing latest VTU file fails F4 and F6, and a CellData-only
    # time-0 field fails F5, in one run; an incomplete tag record stays
    # NOT_VERIFIED.
    ab_fr_case "S95 missing VTU and CellData" "F1=PASS;F2=PASS;F3=PASS;F4=FAIL;F5=FAIL;F6=FAIL;F7=PASS;F8=PASS;F9=PASS;F10=FAIL" \
        ab_fr_vtu_missing_and_cell_only
    assert_contains "$(ab_fr_check "$AB_FR_LAST" F4 reason)" "case_7/vtk/flow_latest_2.vtu" "S95: the missing latest VTU file is named"
    assert_contains "$(ab_fr_check "$AB_FR_LAST" F5 reason)" "SOURCE_POINTDATA_ABSENT" "S95: CellData only is not PointData"
    ab_fr_case "S95 tag limit" "F1=PASS;F2=PASS;F3=PASS;F4=NOT_VERIFIED;F5=NOT_VERIFIED;F6=PASS;F7=PASS;F8=PASS;F9=PASS;F10=NOT_VERIFIED" \
        ab_fr_vtu_tag_limit
}
ab_fr_post_time() {
    printf '%s\n' "${AB_FR_SIGNATURE/flow_latest=2/flow_latest=3}" > "${1}/checkout/src/batch_9/case_7/vtk/post_processing.complete"
}
ab_fr_time_zero() { printf '0\n' > "${1}/checkout/src/batch_9/case_7/vtk/flow_latest_time.txt"; }
ab_fr_time_no_end() { printf '2' > "${1}/checkout/src/batch_9/case_7/vtk/flow_latest_time.txt"; }
ab_fr_nul_records() {
    local vtk="${1}/checkout/src/batch_9/case_7/vtk"
    { printf '2\n\0'; head -c 70 /dev/zero | tr '\0' 'x'; printf '\n'; } > "${vtk}/flow_latest_time.txt"
    printf '%s\n\0unknown_key=invalid\n' "$AB_FR_SIGNATURE" > "${vtk}/post_processing.complete"
}

# ab_fr_fake_truncating_hash <workspace> - a sha256sum that, when it hashes the
# earlier evidence (the first operation of the checks), first removes the last
# byte of the retained time record and the retained signature, as another
# writer would after the record copy.
ab_fr_fake_truncating_hash() {
    local real
    real="$(command -v sha256sum)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'real=%q\n' "$real"
        cat <<'FAKE_HASH'
for argument in "$@"; do
    case "$argument" in
        */runner_temp/evidence/vtu-point-data.txt)
            for record in case_7/vtk/flow_latest_time.txt case_7/vtk/post_processing.complete; do
                truncate -s -1 -- "${argument%/vtu-point-data.txt}/functional-receipt/files/${record}"
            done ;;
    esac
done
exec "$real" "$@"
FAKE_HASH
    } > "${1}/fakebin/sha256sum"
    chmod +x "${1}/fakebin/sha256sum"
}
ab_fr_metric_time() {
    sed -i -e 's/^SELECTED_TIME=2$/SELECTED_TIME=3/' "${1}/runner_temp/evidence/m3-mean-speed/result.env"
}
ab_fr_no_metric() { rm -rf -- "${1:?}/runner_temp/evidence/m3-mean-speed"; }
ab_fr_metric_producer() {
    sed -i -e 's/^MAIN_SHA=.*/MAIN_SHA=0000000000000000000000000000000000000000/' \
        "${1}/runner_temp/evidence/m3-mean-speed/result.env"
}
ab_fr_vtu_missing_and_cell_only() {
    sed -i -e '/^VTU_PATH=case_7\/vtk\/flow_latest_2.vtu$/,/^VTU_TAG_EVIDENCE=/{
        s/^VTU_REQUIRED_FIELDS_RESULT=MATCH$/VTU_REQUIRED_FIELDS_RESULT=MISSING_FILE/
        s/^VTU_TAG_EVIDENCE=COMPLETE$/VTU_TAG_EVIDENCE=UNAVAILABLE/
    }' -e '/^VTU_PATH=case_7\/vtk\/flow_0.vtu$/,/^VTU_TAG_EVIDENCE=/{
        s/^VTU_REQUIRED_FIELDS_RESULT=MATCH$/VTU_REQUIRED_FIELDS_RESULT=SOURCE_POINTDATA_ABSENT/
    }' "${1}/runner_temp/evidence/vtu-point-data.txt"
}
ab_fr_vtu_tag_limit() {
    sed -i -e 's#^== VTU_TAGS_END path=case_7/vtk/flow_0.vtu tag_evidence=COMPLETE$#== VTU_TAGS_END path=case_7/vtk/flow_0.vtu tag_evidence=OUTPUT_LIMIT#' \
        "${1}/runner_temp/evidence/vtu-tags.txt"
}

# ---- S96: the source records stay distinct ----------------------------------

s96_receipt_source_records_stay_distinct() {
    local workspace unreadable=UNREADABLE id
    # Check 4: one run with five distinct record faults: a missing record, an
    # unreadable record, a link, a FIFO, and an oversized record. No part of a
    # failed record is kept, and the FIFO read never blocks.
    [[ "$(id -u)" != 0 ]] || unreadable=RETAINED
    ab_fr_case "S96 records" "F1=NOT_VERIFIED;F2=PASS;F3=NOT_VERIFIED;F4=NOT_VERIFIED;F5=PASS;F6=NOT_VERIFIED;F7=PASS;F8=NOT_VERIFIED;F9=PASS;F10=NOT_VERIFIED" \
        ab_fr_record_faults
    chmod 644 "${AB_FR_LAST}/checkout/src/batch_9/case_7/flow/setup_metadata.env"
    assert_eq "MISSING ${unreadable} LINK NOT_REGULAR RETAINED OVERSIZED" "$(for id in "${AB_FR_RECORD_IDS[@]}"; do
        ab_fr_record "$AB_FR_LAST" "$id"; done | paste -sd ' ' -)" "S96: each record fault has its own result"
    assert_eq "65537" "$(ab_fr_record "$AB_FR_LAST" POST_SIGNATURE source_bytes_before)" "S96: the oversized size is recorded"
    for id in doe_row.csv flow.marker restart.marker; do
        assert_file_missing "$(ab_fr_dir "$AB_FR_LAST")/files/case_7/flow/${id}" "S96: no copy of the failed record ${id} is kept"
    done
    assert_file_missing "$(ab_fr_dir "$AB_FR_LAST")/files/case_7/vtk/post_processing.complete" "S96: no part of an oversized record is kept"
    ab_fr_case "S96 linked Case" "F1=NOT_VERIFIED;F2=PASS;F3=PASS;F4=NOT_VERIFIED;F5=PASS;F6=PASS;F7=PASS;F8=NOT_VERIFIED;F9=PASS;F10=NOT_VERIFIED" \
        ab_fr_link_flow
    assert_eq "LINK LINK LINK LINK" "$(for id in DOE_ROW SETUP_METADATA FLOW_MARKER RESTART_MARKER; do
        ab_fr_record "$AB_FR_LAST" "$id"; done | paste -sd ' ' -)" "S96: a linked Case directory gives LINK for each of its records"
    assert_eq "LINK" "$(ab_fr_entry "$AB_FR_LAST" numberOfSubdomains outcome)" \
        "S96: no entry is read through a linked Case directory"
    assert_contains "$(ab_fr_check "$AB_FR_LAST" F1 evidence)" "src/batch_9/case_7/flow/log.surfaceTransformPoints:LINK" \
        "S96: F1 names the linked geometry log with its status"
    # A record that changes during the capture is CHANGED, and no copy stays.
    workspace="$(new_workspace s96_changed)"
    ab_fr_fixture "$workspace"
    ab_fr_fake_changing_hash "$workspace"
    ab_fr_expect_unit "S96 changed" "$workspace" \
        "F1=PASS;F2=NOT_VERIFIED;F3=NOT_VERIFIED;F4=NOT_VERIFIED;F5=PASS;F6=NOT_VERIFIED;F7=PASS;F8=PASS;F9=PASS;F10=NOT_VERIFIED"
    assert_eq "CHANGED" "$(ab_fr_record "$workspace" LATEST_TIME)" "S96: a changed record is CHANGED"
    assert_ne "$(ab_fr_record "$workspace" LATEST_TIME source_sha256_before)" \
        "$(ab_fr_record "$workspace" LATEST_TIME source_sha256_after)" "S96: the changed hashes are both recorded"
    assert_file_missing "$(ab_fr_dir "$workspace")/files/case_7/vtk/flow_latest_time.txt" "S96: no stale copy of a changed record stays"
    # No record or entry text runs: a command in a record or a dictionary
    # directive leaves no marker file. A record with a NUL byte stays a
    # complete record with its exact bytes.
    ab_fr_case "S96 no execution" "F1=FAIL;F2=PASS;F3=PASS;F4=NOT_VERIFIED;F5=PASS;F6=PASS;F7=PASS;F8=PASS;F9=PASS;F10=FAIL" \
        ab_fr_command_text
    assert_file_missing "${AB_FR_LAST}/executed" "S96: no record or entry text runs"
    assert_eq "RETAINED" "$(ab_fr_record "$AB_FR_LAST" DOE_ROW)" "S96: a record with a NUL byte is retained"
    cmp -s -- "${AB_FR_LAST}/checkout/src/batch_9/case_7/flow/doe_row.csv" "$(ab_fr_dir "$AB_FR_LAST")/files/case_7/flow/doe_row.csv" ||
        _fail "S96: the retained record keeps the NUL byte and every other byte"
    assert_eq "AMBIGUOUS" "$(ab_fr_entry "$AB_FR_LAST" boundaryField.inlet.Uref outcome case_7/flow/0/k)" \
        "S96: a directive at a keyword position makes the entries of its dictionary AMBIGUOUS"
    assert_contains "$(ab_fr_check "$AB_FR_LAST" F1 reason)" "is AMBIGUOUS" \
        "S96: F1 names the NOT_VERIFIED entries after its FAIL parts"
}
ab_fr_record_faults() {
    local flow="${1}/checkout/src/batch_9/case_7/flow"
    rm -f -- "${flow}/doe_row.csv" "${flow}/flow.marker" "${flow}/restart.marker"
    if [[ "$(id -u)" != 0 ]]; then
        chmod 000 "${flow}/setup_metadata.env"
    fi
    printf 'other\n' > "${1}/checkout/src/other.marker"
    ln -s ../../../other.marker "${flow}/flow.marker"
    mkfifo "${flow}/restart.marker"
    head -c 65537 /dev/zero | tr '\0' 'x' > "${1}/checkout/src/batch_9/case_7/vtk/post_processing.complete"
}
ab_fr_link_flow() {
    local case_dir="${1}/checkout/src/batch_9/case_7"
    mv -- "${case_dir}/flow" "${1}/checkout/src/flow_elsewhere"
    ln -s ../../flow_elsewhere "${case_dir}/flow"
}
ab_fr_command_text() {
    local flow="${1}/checkout/src/batch_9/case_7/flow"
    printf 'x\0y\n' >> "${flow}/doe_row.csv"
    sed -i -e "s#^ws=5.0\$#ws=\$(touch ${1}/executed)#" "${flow}/setup_metadata.env"
    sed -i -e "s#^boundaryField\$#\#codeStream { code \#{ system(\"touch ${1}/executed\"); \#}; }\nboundaryField#" "${flow}/0/k"
}

# ab_fr_fake_changing_hash <workspace> - a sha256sum that, after its first
# hash of the post-processing time record, appends one byte to that record, as
# another writer would between the hash before and the copy.
ab_fr_fake_changing_hash() {
    local real
    real="$(command -v sha256sum)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'real=%q\nonce=%q\n' "$real" "${1}/changed_once"
        cat <<'FAKE_HASH'
"$real" "$@"
status=$?
for argument in "$@"; do
    case "$argument" in
        */checkout/src/batch_9/case_7/vtk/flow_latest_time.txt)
            if [[ ! -e "$once" ]]; then
                : > "$once"
                printf '0' >> "$argument"
            fi ;;
    esac
done
exit "$status"
FAKE_HASH
    } > "${1}/fakebin/sha256sum"
    chmod +x "${1}/fakebin/sha256sum"
}

# ab_fr_fake_hanging_copy_hash <workspace> - a sha256sum that records its
# process ID and blocks when it hashes the post-processing time record together
# with a copy in the work directory (the hash after the copy), and that runs
# the real command otherwise.
ab_fr_fake_hanging_copy_hash() {
    local real
    real="$(command -v sha256sum)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'real=%q\npids=%q\n' "$real" "${1}/fake_pids"
        cat <<'FAKE_HASH'
record=0 copy=0
for argument in "$@"; do
    case "$argument" in
        */checkout/src/batch_9/case_7/vtk/flow_latest_time.txt) record=1 ;;
        */functional-receipt-work.*) copy=1 ;;
    esac
done
if (( record && copy )); then
    printf '%s\n' "$$" >> "$pids"
    exec sleep 300
fi
exec "$real" "$@"
FAKE_HASH
    } > "${1}/fakebin/sha256sum"
    chmod +x "${1}/fakebin/sha256sum"
}

# ---- S97: the selected Setup entries fail closed ----------------------------

s97_receipt_setup_entries_fail_closed() {
    local workspace evidence reason before after
    # Checks 1 and 4: one run with a distinct fault in each of the six
    # dictionaries: a non-ASCII byte, an oversized file, a duplicate entry, a
    # pattern keyword, a macro value, and a truncated file.
    ab_fr_case "S97 entries" "F1=NOT_VERIFIED;F2=PASS;F3=PASS;F4=NOT_VERIFIED;F5=PASS;F6=PASS;F7=PASS;F8=PASS;F9=PASS;F10=NOT_VERIFIED" \
        ab_fr_entry_faults
    assert_eq "UNSUPPORTED OVERSIZED DUPLICATE AMBIGUOUS AMBIGUOUS UNSUPPORTED UNSUPPORTED" \
        "$(ab_fr_entry "$AB_FR_LAST" xMin outcome) $(ab_fr_entry "$AB_FR_LAST" snap outcome) $(ab_fr_entry "$AB_FR_LAST" numberOfSubdomains outcome) $(ab_fr_entry "$AB_FR_LAST" boundaryField.f18p1_oai_a1.value outcome) $(ab_fr_entry "$AB_FR_LAST" boundaryField.inlet.Uref outcome) $(ab_fr_entry "$AB_FR_LAST" boundaryField.inlet.Uref outcome case_7/flow/0/k) $(ab_fr_entry "$AB_FR_LAST" boundaryField.inlet.Uref outcome case_7/flow/0/epsilon)" \
        "S97: a byte, an oversized file, a duplicate, a pattern, a macro, and a truncated file each have their own result"
    assert_eq "57" "$(awk -F '\t' 'NR > 1 && $11 == "NOT_VERIFIED" && $7 == "-"' "$(ab_fr_dir "$AB_FR_LAST")/setup-entry-values.tsv" | wc -l)" \
        "S97: no entry of a faulty dictionary is used"
    # Wrong required values fail, and the actual values are kept.
    ab_fr_case "S97 wrong values" "F1=FAIL;F2=PASS;F3=PASS;F4=NOT_VERIFIED;F5=PASS;F6=PASS;F7=PASS;F8=PASS;F9=PASS;F10=FAIL" \
        ab_fr_wrong_values
    assert_eq "FAIL 4 FAIL <nx>" "$(ab_fr_entry "$AB_FR_LAST" numberOfSubdomains) $(ab_fr_entry "$AB_FR_LAST" numberOfSubdomains value) $(ab_fr_entry "$AB_FR_LAST" nx) $(ab_fr_entry "$AB_FR_LAST" nx value)" \
        "S97: a wrong rank count and an unresolved placeholder fail with their actual values"
    ab_fr_case "S97 no geometry log" "F1=NOT_VERIFIED;F2=PASS;F3=PASS;F4=NOT_VERIFIED;F5=PASS;F6=PASS;F7=PASS;F8=PASS;F9=PASS;F10=NOT_VERIFIED" \
        ab_fr_no_geometry_log
    assert_eq "NOT_VERIFIED PASS" "$(ab_fr_entry "$AB_FR_LAST" xMin) $(ab_fr_entry "$AB_FR_LAST" numberOfSubdomains)" \
        "S97: only the geometry entries lose their expected value"
    ab_fr_case "S97 metadata" "F1=FAIL;F2=PASS;F3=PASS;F4=NOT_VERIFIED;F5=PASS;F6=PASS;F7=PASS;F8=PASS;F9=PASS;F10=FAIL" \
        ab_fr_wrong_model
    assert_contains "$(ab_fr_check "$AB_FR_LAST" F1 reason)" "ras_model" "S97: the wrong metadata value is named"
    ab_fr_case "S97 row" "F1=FAIL;F2=PASS;F3=PASS;F4=NOT_VERIFIED;F5=PASS;F6=PASS;F7=PASS;F8=PASS;F9=PASS;F10=FAIL" \
        ab_fr_other_row
    assert_contains "$(ab_fr_check "$AB_FR_LAST" F1 reason)" "doe_row.csv" "S97: a row that differs from the DOE Batch CSV is named"
    # R2: a reference source that changes between its hash before and its hash
    # after the entry read gives no supported expected value. The first run
    # changes the approved CSV and the transform log, the second run the Batch
    # Workspace DOE Batch CSV and the surface-check log. Each dependent check
    # stays NOT_VERIFIED, the other checks keep their results and their
    # evidence, and F1 names each reference source with its SHA-256 or change.
    ab_fr_changed_sources "S97 changed approved CSV and transform log" \
        src/output_batch_1.csv src/batch_9/case_7/flow/log.surfaceTransformPoints
    workspace="$AB_FR_LAST"
    assert_eq "NOT_VERIFIED NOT_VERIFIED PASS PASS PASS" "$(ab_fr_entry "$workspace" xMin) $(ab_fr_entry "$workspace" geometry.refinementDomain.point1) $(ab_fr_entry "$workspace" boundaryField.inlet.Uref) $(ab_fr_entry "$workspace" boundaryField.f18p1_seb_a.value) $(ab_fr_entry "$workspace" numberOfSubdomains)" \
        "S97 changed approved CSV and transform log: only the geometry entries lose their expected value"
    assert_eq "13" "$(awk -F '\t' 'NR > 1 && $11 == "NOT_VERIFIED"' "$(ab_fr_dir "$workspace")/setup-entry-values.tsv" | wc -l)" \
        "S97 changed approved CSV and transform log: the 13 geometry entries are NOT_VERIFIED"
    assert_eq "FOUND|-698.500|-" "$(ab_fr_entry "$workspace" xMin outcome)|$(ab_fr_entry "$workspace" xMin value)|$(ab_fr_entry "$workspace" xMin expected)" \
        "S97 changed approved CSV and transform log: the entry keeps its actual value, and no expected value from the changed log is kept"
    assert_contains "$(ab_fr_entry "$workspace" xMin reason)" "src/batch_9/case_7/flow/log.surfaceTransformPoints changed during the capture" \
        "S97 changed approved CSV and transform log: the entry names the changed log"
    reason="$(ab_fr_check "$workspace" F1 reason)"
    assert_contains "$reason" "doe_row.csv: the reference src/output_batch_1.csv changed during the capture" \
        "S97 changed approved CSV and transform log: F1 names the changed approved CSV of the DOE row check"
    assert_contains "$reason" "xMin is FOUND: the reference src/batch_9/case_7/flow/log.surfaceTransformPoints changed during the capture" \
        "S97 changed approved CSV and transform log: F1 names the changed log of the geometry entries"
    assert_not_contains "$reason" "setup_metadata.env" \
        "S97 changed approved CSV and transform log: the metadata check keeps its result"
    evidence="$(ab_fr_check "$workspace" F1 evidence)"
    before="$(sha256sum < "${REPO_ROOT}/src/output_batch_1.csv" | cut -d ' ' -f 1)"
    after="$(sha256sum < "${workspace}/checkout/src/output_batch_1.csv" | cut -d ' ' -f 1)"
    assert_contains "$evidence" "src/output_batch_1.csv:CHANGED:${before}:${after}" \
        "S97 changed approved CSV and transform log: F1 keeps both SHA-256 values of the changed CSV"
    assert_contains "$evidence" "src/batch_9/output_batch_9.csv:$(sha256sum < "${workspace}/checkout/src/batch_9/output_batch_9.csv" | cut -d ' ' -f 1)" \
        "S97 changed approved CSV and transform log: F1 names the unchanged DOE Batch CSV with its SHA-256"
    assert_contains "$evidence" "src/batch_9/case_7/flow/log.surfaceTransformPoints:CHANGED:" \
        "S97 changed approved CSV and transform log: F1 names the changed log"
    assert_contains "$evidence" "src/batch_9/case_7/flow/log.surfaceCheck:$(sha256sum < "${workspace}/checkout/src/batch_9/case_7/flow/log.surfaceCheck" | cut -d ' ' -f 1)" \
        "S97 changed approved CSV and transform log: F1 names the unchanged log with its SHA-256"
    ab_fr_changed_sources "S97 changed DOE Batch CSV and surface-check log" \
        src/batch_9/output_batch_9.csv src/batch_9/case_7/flow/log.surfaceCheck
    workspace="$AB_FR_LAST"
    assert_eq "NOT_VERIFIED NOT_VERIFIED NOT_VERIFIED NOT_VERIFIED PASS PASS" "$(ab_fr_entry "$workspace" xMin) $(ab_fr_entry "$workspace" geometry.refinementDomain.point1) $(ab_fr_entry "$workspace" boundaryField.inlet.Uref) $(ab_fr_entry "$workspace" boundaryField.f18p1_seb_a.value) $(ab_fr_entry "$workspace" numberOfSubdomains) $(ab_fr_entry "$workspace" snap)" \
        "S97 changed DOE Batch CSV and surface-check log: the geometry and the row entries lose their expected value"
    assert_eq "52" "$(awk -F '\t' 'NR > 1 && $11 == "NOT_VERIFIED"' "$(ab_fr_dir "$workspace")/setup-entry-values.tsv" | wc -l)" \
        "S97 changed DOE Batch CSV and surface-check log: the 13 geometry and the 39 row entries are NOT_VERIFIED"
    reason="$(ab_fr_check "$workspace" F1 reason)"
    assert_contains "$reason" "doe_row.csv: the reference src/batch_9/output_batch_9.csv changed during the capture" \
        "S97 changed DOE Batch CSV and surface-check log: F1 names the changed CSV of the DOE row check"
    assert_contains "$reason" "setup_metadata.env: the reference src/batch_9/output_batch_9.csv changed during the capture" \
        "S97 changed DOE Batch CSV and surface-check log: F1 names the changed CSV of the metadata check"
    assert_contains "$reason" "xMin is FOUND: the reference src/batch_9/case_7/flow/log.surfaceCheck changed during the capture" \
        "S97 changed DOE Batch CSV and surface-check log: F1 names the changed log of the geometry entries"
    evidence="$(ab_fr_check "$workspace" F1 evidence)"
    assert_contains "$evidence" "src/batch_9/output_batch_9.csv:CHANGED:" \
        "S97 changed DOE Batch CSV and surface-check log: F1 names the changed CSV"
    assert_contains "$evidence" "src/batch_9/case_7/flow/log.surfaceCheck:CHANGED:" \
        "S97 changed DOE Batch CSV and surface-check log: F1 names the changed log"
}

# ab_fr_changed_sources <label> <source>... - one unit run in a new workspace in
# which each named source, relative to the checkout, changes after the entry
# read and before its hash after. The construction stays COMPLETE with no
# capture note, and the checks are the baseline with F1 NOT_VERIFIED. Sets
# AB_FR_LAST to the workspace.
ab_fr_changed_sources() {
    local label="$1" workspace
    shift
    workspace="$(new_workspace "${label//[^A-Za-z0-9_.-]/_}")"
    ab_fr_fixture "$workspace"
    ab_fr_fake_changing_sources "$workspace" "$@"
    ab_fr_expect_unit "$label" "$workspace" \
        "F1=NOT_VERIFIED;F2=PASS;F3=PASS;F4=NOT_VERIFIED;F5=PASS;F6=PASS;F7=PASS;F8=PASS;F9=PASS;F10=NOT_VERIFIED"
    assert_eq "COMPLETE" "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_RESULT)" "${label}: the construction is complete"
    assert_eq "" "$(cat "${workspace}/runner_temp/evidence/capture-work-notes.txt")" \
        "${label}: a changed source gives no capture note"
    AB_FR_LAST="$workspace"
}

# ab_fr_fake_changing_sources <workspace> <source>... - a sha256sum that, in its
# second run that hashes a named source (the hash after the entry read), first
# appends one line to each named source of that run, as another writer would
# after the read.
ab_fr_fake_changing_sources() {
    local workspace="$1" real
    shift
    real="$(command -v sha256sum)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'real=%q\ncount=%q\nsources=(' "$real" "${workspace}/source_hashes"
        printf ' %q' "$@"
        printf ' )\n'
        cat <<'FAKE_HASH'
named=()
for argument in "$@"; do
    for source in "${sources[@]}"; do
        [[ "$argument" != */checkout/"$source" ]] || named+=("$argument")
    done
done
if (( ${#named[@]} > 0 )); then
    printf 'run\n' >> "$count"
    if (( $(wc -l < "$count") == 2 )); then
        for argument in "${named[@]}"; do
            printf 'changed\n' >> "$argument"
        done
    fi
fi
exec "$real" "$@"
FAKE_HASH
    } > "${workspace}/fakebin/sha256sum"
    chmod +x "${workspace}/fakebin/sha256sum"
}
ab_fr_dictionary() { printf '%s\n' "${1}/checkout/src/batch_9/case_7/flow/${2}"; }
ab_fr_entry_faults() {
    printf '// \351\n' >> "$(ab_fr_dictionary "$1" system/blockMeshDict)"
    head -c 1048600 /dev/zero | tr '\0' ' ' >> "$(ab_fr_dictionary "$1" system/snappyHexMeshDict)"
    printf 'numberOfSubdomains 8;\n' >> "$(ab_fr_dictionary "$1" system/decomposeParDict)"
    sed -i -e 's#^boundaryField$#boundaryField\n{\n    ".*_oai_.*"\n    {\n        type            fixedValue;\n    }\n}\nboundaryField#' \
        "$(ab_fr_dictionary "$1" 0/U)"
    sed -i -e 's#^        Uref            5;$#        Uref            $UrefValue;#' "$(ab_fr_dictionary "$1" 0/k)"
    sed -i -e '$d' "$(ab_fr_dictionary "$1" 0/epsilon)"
    sed -i -e '$d' "$(ab_fr_dictionary "$1" 0/epsilon)"
}
ab_fr_wrong_values() {
    sed -i -e 's/^numberOfSubdomains 8;$/numberOfSubdomains 4;/' "$(ab_fr_dictionary "$1" system/decomposeParDict)"
    sed -i -e 's/^nx    45;/nx    <nx>;/' "$(ab_fr_dictionary "$1" system/blockMeshDict)"
}
ab_fr_no_geometry_log() { rm -f -- "$(ab_fr_dictionary "$1" log.surfaceCheck)"; }
ab_fr_wrong_model() { sed -i -e 's/^ras_model=kEpsilon$/ras_model=kOmega/' "$(ab_fr_dictionary "$1" setup_metadata.env)"; }
ab_fr_other_row() { sed -i -e '2s/^7,/8,/' "$(ab_fr_dictionary "$1" doe_row.csv)"; }

# ---- S98: the time and byte limits fail closed -------------------------------

s98_receipt_limits_fail_closed() {
    local workspace run start elapsed dir
    # The time limit: an operation that blocks (the hash of the time record
    # after its copy) stops before the receipt end. The records before it stay,
    # no partial copy stays, and the stop is a capture note.
    workspace="$(new_workspace s98_time)"
    ab_fr_fixture "$workspace"
    ab_fr_fake_hanging_copy_hash "$workspace"
    dir="$(ab_fr_dir "$workspace")"
    start="$(date +%s)"
    run="$(ab_fr_unit "$workspace" CAPTURE_WORK_END="$(( start + 15 ))")"
    elapsed=$(( $(date +%s) - start ))
    assert_contains "$run" "status=0" "S98 time: the receipt work ends with status 0"
    (( elapsed <= 5 )) || _fail "S98 time: the receipt work ends by its end, 10 seconds before the capture work end" "elapsed: ${elapsed}"
    ab_assert_fakes_stopped "$workspace" "S98 time"
    assert_eq "INCOMPLETE" "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_RESULT)" "S98 time: the construction is incomplete"
    assert_contains "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_REASON)" "time" "S98 time: the reason names the time limit"
    assert_contains "$(cat "${workspace}/runner_temp/evidence/capture-work-notes.txt")" "functional receipt" \
        "S98 time: the stop is a capture note"
    assert_eq "RETAINED RETAINED RETAINED RETAINED" "$(for id in DOE_ROW SETUP_METADATA FLOW_MARKER RESTART_MARKER; do
        ab_fr_record "$workspace" "$id"; done | paste -sd ' ' -)" "S98 time: the records before the stop stay"
    assert_file_missing "${dir}/files/case_7/vtk/flow_latest_time.txt" "S98 time: no partial record stays"
    assert_eq "" "$(find "$dir" -name '*.part' -print)" "S98 time: no part file stays in the receipt"
    # The receipt subtree limit: four records of 65000 bytes do not fit with
    # the text records and the result reserve.
    workspace="$(new_workspace s98_tree)"
    ab_fr_fixture "$workspace"
    ab_fr_big_records "$workspace"
    run="$(ab_fr_unit "$workspace")"
    assert_contains "$run" "status=0" "S98 tree: the receipt work ends with status 0"
    assert_eq "INCOMPLETE" "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_RESULT)" "S98 tree: the construction is incomplete"
    assert_eq "OUTPUT_LIMIT" "$(ab_fr_record "$workspace" RESTART_MARKER)" "S98 tree: the record above the subtree limit is OUTPUT_LIMIT"
    assert_file_missing "$(ab_fr_dir "$workspace")/files/case_7/flow/restart.marker" "S98 tree: no part of it is kept"
    (( $(du -sb --apparent-size "$(ab_fr_dir "$workspace")" | cut -f 1) <= 262144 )) ||
        _fail "S98 tree: the receipt holds at most 262144 bytes"
    assert_contains "$(cat "${workspace}/runner_temp/evidence/capture-work-notes.txt")" "functional receipt" \
        "S98 tree: the limit is a capture note"
    # The combined limit, in the capture step: the collection evidence and the
    # receipt share the 10485760-byte ceiling. The earlier failed Stage copy
    # stays the first note, and the summary and the upload stay eligible.
    workspace="$(new_workspace s98_combined)"
    ab_capture_fixture "$workspace"
    ab_fr_records "${workspace}/checkout"
    ab_fake_fail "$workspace" cp '*_flow_logs/case_7_flow.log'
    mkdir -p "${workspace}/runner_temp/evidence/m3-mean-speed"
    truncate -s 10470000 "${workspace}/runner_temp/evidence/m3-mean-speed/large-record"
    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))")"
    assert_contains "$run" "status=0" "S98 combined: the capture step ends with status 0"
    assert_eq "INCOMPLETE" "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_RESULT)" "S98 combined: the construction is incomplete"
    assert_contains "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_REASON)" "10485760" "S98 combined: the reason names the ceiling"
    assert_eq "RETAINED" "$(ab_fr_record "$workspace" DOE_ROW)" "S98 combined: the small records fit the rest of the ceiling"
    assert_file_missing "$(ab_fr_dir "$workspace")/setup-entry-values.tsv" "S98 combined: the entry record above the rest is not written"
    (( $(find "${workspace}/runner_temp/evidence/m3-mean-speed" "$(ab_fr_dir "$workspace")" -type f -printf '%s\n' |
        awk '{ s += $1 } END { printf "%d", s }') <= 10485760 )) || _fail "S98 combined: the shared ceiling holds"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "S98 combined: the capture is incomplete"
    assert_contains "$(ab_env_last "$workspace" CAPTURE_REASON)" "_flow_logs/case_7_flow.log" \
        "S98 combined: the earlier failure stays the capture reason"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" FUNCTIONAL_RECEIPT_RESULT)" "S98 combined: GITHUB_ENV has the receipt result"
    assert_contains "$(ab_fr_summary "$workspace")" "| Functional receipt | \`INCOMPLETE\`" \
        "S98 combined: the summary shows the receipt result"
    # R3: a result.env that cannot be written (a directory in its place) makes
    # the construction INCOMPLETE in the capture note, the result outside the
    # evidence directory, GITHUB_ENV, and the summary. The check results stay,
    # the step ends with status 0, and no file goes into that directory.
    workspace="$(new_workspace s98_result)"
    ab_capture_fixture "$workspace"
    ab_fr_records "${workspace}/checkout"
    dir="$(ab_fr_dir "$workspace")"
    mkdir -p "${dir}/result.env"
    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100000 ))")"
    assert_contains "$run" "status=0" "S98 result: the capture step ends with status 0"
    assert_eq "INCOMPLETE" "$(ab_file_value "${workspace}/runner_temp/functional-receipt-result.env" FUNCTIONAL_RECEIPT_RESULT)" \
        "S98 result: the result outside the evidence directory is INCOMPLETE"
    assert_contains "$(ab_file_value "${workspace}/runner_temp/functional-receipt-result.env" FUNCTIONAL_RECEIPT_REASON)" \
        "result.env cannot be written" "S98 result: the reason names the result write"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" FUNCTIONAL_RECEIPT_RESULT)" "S98 result: GITHUB_ENV has the INCOMPLETE result"
    assert_ne "UNAVAILABLE" "$(ab_env_last "$workspace" FUNCTIONAL_RECEIPT_CHECKS)" "S98 result: GITHUB_ENV keeps the check results"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "S98 result: the capture is incomplete"
    assert_contains "$(ab_env_last "$workspace" CAPTURE_REASON)" "functional receipt: result.env cannot be written" \
        "S98 result: the capture note names the result write"
    assert_eq "" "$(ls -A -- "${dir}/result.env")" "S98 result: no file goes into the directory in place of result.env"
    assert_contains "$(ab_fr_summary "$workspace")" "| Functional receipt | \`INCOMPLETE\`" \
        "S98 result: the summary shows INCOMPLETE"
    # R3: a partial result.env, as a receipt that stops in its result write
    # leaves it, is no result: its first line is not complete evidence. The
    # explicit INCOMPLETE result replaces it.
    workspace="$(new_workspace s98_partial)"
    ab_capture_fixture "$workspace"
    dir="$(ab_fr_dir "$workspace")"
    mkdir -p "$dir"
    printf 'FUNCTIONAL_RECEIPT_RESULT=COMPLETE\n' > "${dir}/result.env"
    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100 ))")"
    assert_contains "$run" "status=0" "S98 partial: the capture step ends with status 0"
    assert_eq "SKIPPED_NO_BUDGET" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "S98 partial: the capture work does not run"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" FUNCTIONAL_RECEIPT_RESULT)" "S98 partial: GITHUB_ENV has the INCOMPLETE result"
    assert_eq "INCOMPLETE" "$(ab_fr_value "$workspace" FUNCTIONAL_RECEIPT_RESULT)" \
        "S98 partial: the INCOMPLETE result replaces the partial result.env"
    assert_eq "1" "$(grep -c '^FUNCTIONAL_RECEIPT_RESULT=' "${dir}/result.env")" "S98 partial: result.env has one result line"
    assert_contains "$(ab_fr_summary "$workspace")" "| Functional receipt | \`INCOMPLETE\`" \
        "S98 partial: the summary shows INCOMPLETE"
    # R3: a receipt that started (its empty result copy exists) and gave no
    # result is INCOMPLETE, not NOT_ATTEMPTED.
    workspace="$(new_workspace s98_started)"
    ab_capture_fixture "$workspace"
    : > "${workspace}/runner_temp/functional-receipt-result.env"
    run="$(ab_run_capture "$workspace" "$(( $(date +%s) + 100 ))")"
    assert_contains "$run" "status=0" "S98 started: the capture step ends with status 0"
    assert_eq "INCOMPLETE" "$(ab_env_last "$workspace" FUNCTIONAL_RECEIPT_RESULT)" "S98 started: GITHUB_ENV has the INCOMPLETE result"
    assert_dir_missing "$(ab_fr_dir "$workspace")" "S98 started: no receipt directory is made"
    # R3: a result write that keeps only the first 34 bytes (as a full disk
    # would) is not a written result: the construction is INCOMPLETE, and no
    # partial result.env stays.
    workspace="$(new_workspace s98_partial_write)"
    ab_fr_fixture "$workspace"
    ab_fr_partial_result_write "$workspace"
    run="$(ab_fr_unit "$workspace" BASH_ENV="${workspace}/partial_write.sh")"
    assert_contains "$run" "status=0" "S98 partial write: the receipt work ends with status 0"
    assert_eq "INCOMPLETE" "$(ab_file_value "${workspace}/runner_temp/functional-receipt-result.env" FUNCTIONAL_RECEIPT_RESULT)" \
        "S98 partial write: the result outside the evidence directory is INCOMPLETE"
    assert_contains "$(ab_file_value "${workspace}/runner_temp/functional-receipt-result.env" FUNCTIONAL_RECEIPT_REASON)" \
        "result.env cannot be written completely" "S98 partial write: the reason names the result write"
    assert_file_missing "$(ab_fr_dir "$workspace")/result.env" "S98 partial write: no partial result.env stays"
    assert_contains "$(cat "${workspace}/runner_temp/evidence/capture-work-notes.txt")" "functional receipt: result.env" \
        "S98 partial write: the partial write is a capture note"
}

# ab_fr_partial_result_write <workspace> - partial_write.sh, a BASH_ENV file
# for ab_fr_unit: each printf whose output goes to functional-receipt/result.env
# writes only the first 34 bytes and ends with status 0. Every other printf is
# the builtin.
ab_fr_partial_result_write() {
    cat > "${1}/partial_write.sh" <<'PARTIAL_WRITE'
printf() {
    if [[ "${1:-}" != -v && "$(readlink "/proc/$$/fd/1")" == */functional-receipt/result.env ]]; then
        builtin printf "$@" | head -c 34
    else
        builtin printf "$@"
    fi
}
PARTIAL_WRITE
}
ab_fr_big_records() {
    local flow="${1}/checkout/src/batch_9/case_7/flow" name
    for name in doe_row.csv setup_metadata.env flow.marker restart.marker; do
        head -c 65000 /dev/zero | tr '\0' 'y' > "${flow}/${name}"
    done
}

# ---- S99: the frozen blocks and the unchanged interface ----------------------

# ab_fr_frozen_block <name> - the byte count and the SHA-256 of one frozen block
# of the workflow file, from its begin marker line through its end marker line
# and the line ending.
ab_fr_frozen_block() {
    local block
    block="$(awk -v begin="          # ---- ${1}: begin ----" -v end="          # ---- ${1}: end ----" '
        $0 == begin { inside = 1 } inside { print } $0 == end { exit }' "$WORKFLOW")"$'\n'
    printf '%s %s' "$(printf '%s' "$block" | wc -c | tr -d ' ')" "$(printf '%s' "$block" | sha256sum | cut -d ' ' -f 1)"
}

s99_receipt_keeps_the_frozen_blocks_and_interface() {
    local text block body
    text="$(cat "$WORKFLOW")"
    # The two frozen blocks, from the begin marker line through the end marker
    # line and its line ending.
    assert_eq "15340 92068ccc692900bcb8ee41f2a721d6e7b4bea408e78e30ba786df0ed7a819d3f" "$(ab_fr_frozen_block "VTU header reader")" \
        "S99: the VTU header reader block is unchanged"
    assert_eq "107529 9154d83f22b1304381048ca115d9d678f64b7ec2e215b68059b77f8aad92ec29" "$(ab_fr_frozen_block "M3 mean speed")" \
        "S99: the M3 mean-speed block is unchanged"
    # The receipt runs once, after the collection, as the last capture item.
    body="$(ab_step_run_body "Capture the evidence")"
    assert_eq $'metric_collect\nfr_capture' \
        "$(grep -xE '[[:space:]]*(metric_collect|fr_capture)' <<< "$body" | tr -d ' ')" \
        "S99: the receipt work runs once, after the collection"
    block="$(awk '/^# ---- Functional receipt: begin ----$/ { inside = 1 } inside { print } /^# ---- Functional receipt: end ----$/ { exit }' <<< "$body")"
    [[ -n "$block" ]] || _fail "S99: the capture work holds the functional-receipt block"
    # The receipt adds no OpenFOAM command, privilege, package, network, Case
    # template, or reader.
    if grep -v '^[[:space:]]*#' <<< "$block" |
            grep -nE 'foamDictionary|foamListTimes|simpleFoam -|sudo|apt-get|curl|wget|foamToVTK|vtk[A-Z]|python|eval '; then
        _fail "S99: the receipt runs no OpenFOAM command, privilege, package, network, template, or reader"
    fi
    for constant in 'FR_WORK_SECONDS=30' 'FR_FILE_LIMIT=65536' 'FR_TREE_LIMIT=262144' 'FR_SCAN_LIMIT=1048576' \
                    'FR_COMBINED_LIMIT=10485760'; do
        assert_eq "1" "$(grep -cx -- "$constant" <<< "$block")" "S99: the receipt sets ${constant}"
    done
    # The unchanged interface and CI limits.
    assert_eq "1" "$(grep -cF -- "bash -c 'bash src/run_batch.sh --stage setup,mesh,flow,post-processing -j 1 \"\$1\" \\" "$WORKFLOW")" \
        "S99: the Orchestrator vector stays"
    assert_eq "10" "$(awk '/^      - name: Capture the evidence$/ { found = 1; next } found && /^        timeout-minutes:/ { print $2; exit }' "$WORKFLOW")" \
        "S99: the capture step guard stays 10 minutes"
    assert_eq "10 18" "$(awk '/^    timeout-minutes:/ { print $2 }' "${REPO_ROOT}/.github/workflows/batch-contract.yml" | sort -n | paste -sd ' ' -)" \
        "S99: the ShellCheck job keeps its 10-minute limit, and the contract-tests job has its 18-minute limit (Owner decision 6170198169)"
    assert_contains "$text" "include-hidden-files: true" "S99: the upload keeps the hidden files"
    assert_contains "$text" 'path: ${{ runner.temp }}/evidence' "S99: the upload keeps the evidence directory"
}

# ---- S100 to S103: the M3 VTU reader provision (Issue #80) -----------------

# The controlled provision step of the contract-tests job.
AB_VP_STEP="Provision the M3 VTU reader dependencies"

# ab_vp_expected_manifest - the header and the thirteen fixed artifact rows of
# dependency addendum 6158946927, Section 2: role, distribution, version, file,
# HTTPS URL, registered bytes, registered SHA-256, and the bytes and SHA-256 of
# the exact-wheel core metadata.
ab_vp_expected_manifest() {
    local p='https://files.pythonhosted.org/packages'
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        role distribution version file url bytes sha256 metadata_bytes metadata_sha256 \
        runtime vtk 9.5.2 vtk-9.5.2-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.whl \
        "${p}/c5/6c/e5544c77b568bfbcc3592fb5e23a5dee8e84df9ee316230509362fb6d432/vtk-9.5.2-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.whl" \
        112292112 454711c51038824ddc75f955e1064c4e214b452c2e67083f01a8b43fc0ed62cb \
        5560 94f35aa687ac84fb560902a2d5bcc2d38d8ab00f3bef2a18295014d808d5ef48 \
        runtime matplotlib 3.10.7 matplotlib-3.10.7-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.whl \
        "${p}/7d/18/95ae2e242d4a5c98bd6e90e36e128d71cf1c7e39b0874feaed3ef782e789/matplotlib-3.10.7-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.whl" \
        8696996 d5f256d49fea31f40f166a5e3131235a5d2f4b7f44520b1cf0baf1ce568ccff0 \
        11264 fd8befb2181fe3d11f6477c359d8f452b4fbc90f6969a6893e09046d935e1677 \
        runtime contourpy 1.3.3 contourpy-1.3.3-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl \
        "${p}/cc/8f/ec6289987824b29529d0dfda0d74a07cec60e54b9c92f3c9da4c0ac732de/contourpy-1.3.3-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl" \
        362601 4d00e655fcef08aba35ec9610536bfe90267d7ab5ba944f7032549c55a146da1 \
        5461 c43cef86baef09cff9c77975e578fa8cca0c9454df40dc176938b499a63de54a \
        runtime cycler 0.12.1 cycler-0.12.1-py3-none-any.whl \
        "${p}/e7/05/c19819d5e3d95294a6f5947fb9b9629efb316b96de511b418c53d245aae6/cycler-0.12.1-py3-none-any.whl" \
        8321 85cef7cff222d8644161529808465972e51340599459b8ac3ccbac5a854e0d30 \
        3779 23289e19b76f1e01394227696e6af2b6cd1ce79e89731209bf9195148b18ed36 \
        runtime fonttools 4.60.1 fonttools-4.60.1-cp312-cp312-manylinux1_x86_64.manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_5_x86_64.whl \
        "${p}/c0/ca/4bb48a26ed95a1e7eba175535fe5805887682140ee0a0d10a88e1de84208/fonttools-4.60.1-cp312-cp312-manylinux1_x86_64.manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_5_x86_64.whl" \
        4923716 8177ec9676ea6e1793c8a084a90b65a9f778771998eb919d05db6d4b1c0b114c \
        112334 0886770f170aaa482341521aebc9dd59b7a8e073fecab90194e2eef9d999ca03 \
        runtime kiwisolver 1.4.9 kiwisolver-1.4.9-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.whl \
        "${p}/70/90/6d240beb0f24b74371762873e9b7f499f1e02166a2d9c5801f4dbf8fa12e/kiwisolver-1.4.9-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.whl" \
        1474756 f6008a4919fdbc0b0097089f67a1eb55d950ed7e90ce2cc3e640abadd2757a04 \
        6260 cad34a37b5cb66cfa1b9676f33721037ae2d850b9b0c71377478a1d6bf0c7d40 \
        runtime numpy 2.3.4 numpy-2.3.4-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl \
        "${p}/f9/58/30a85127bfee6f108282107caf8e06a1f0cc997cb6b52cdee699276fcce4/numpy-2.3.4-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl" \
        16641271 4121c5beb58a7f9e6dfdee612cb24f4df5cd4db6e8261d7f4d7450a997a65d6a \
        62117 02d05671e1cb75fe80fda9cfd9e7210872ba35b5d54be6e295493ef22a8080a8 \
        runtime packaging 25.0 packaging-25.0-py3-none-any.whl \
        "${p}/20/12/38679034af332785aac8774540895e234f4d07f7545804097de4b666afd8/packaging-25.0-py3-none-any.whl" \
        66469 29572ef2b1f17581046b3a2227d5c611fb25ec70ca1ba8554b24b0e69331a484 \
        3281 5b611a609c38fefc3d616bf45d20aec98fb7d53f245daca9e2c30fc85c7ac282 \
        runtime pillow 11.3.0 pillow-11.3.0-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.whl \
        "${p}/8d/33/e9200d2bd7ba00dc3ddb78df1198a6e80d7669cce6c2bdbeb2530a74ec58/pillow-11.3.0-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.whl" \
        7644652 67172f2944ebba3d4a7b54f2e95c786a3a50c21b88456329314caaa28cda70f6 \
        9023 d53d4d78f8a8efe182396711ef76840386d2ba4ccdad421f58cc00c3b3401f73 \
        runtime pyparsing 3.2.5 pyparsing-3.2.5-py3-none-any.whl \
        "${p}/10/5e/1aa9a93198c6b64513c9d7752de7422c06402de6600a8767da1524f9570b/pyparsing-3.2.5-py3-none-any.whl" \
        113890 e38a4f02064cf41fe6593d328d0512495ad1f3d8a91c4f73fc401b3079a59a5e \
        5030 cd543f26f0f59ac7b446f57cc91e8def7a3eb735fdd5e91c4e402b8725696eba \
        runtime python-dateutil 2.9.0.post0 python_dateutil-2.9.0.post0-py2.py3-none-any.whl \
        "${p}/ec/57/56b9bcc3c9c6a792fcbaf139543cee77261f3651ca9da0c93f5c1221264b/python_dateutil-2.9.0.post0-py2.py3-none-any.whl" \
        229892 a8b2bc7bffae282281c8140a97d3aa9c14da0b136dfe83f850eea9a5f7470427 \
        8354 a9d436da322be808332f98d88325998e87cb693a678a9969feb4cfad729a6e93 \
        runtime six 1.17.0 six-1.17.0-py2.py3-none-any.whl \
        "${p}/b7/ce/149a00dd41f10bc29e5921b496af8b574d8413afcd5e30dfa0ed46c2cc5e/six-1.17.0-py2.py3-none-any.whl" \
        11050 4721f391ed90541fddacab5acf947aa0d3dc7d27b2e1e8eda2be8970586c3274 \
        1658 562042078c2752549f6d8a7c86dbc5dd708088a7be6d80672ec7b07100b72468 \
        installer pip 25.2 pip-25.2-py3-none-any.whl \
        "${p}/b7/3f/945ef7ab14dc4f9d7f40288d2df998d1837ee0888ec3659c813487572faa/pip-25.2-py3-none-any.whl" \
        1752557 6d67a2b4e7f14d8b31b8b52648866fa717f45a1eb70e83002f4331d07e953717 \
        4744 97a3ad14d71fd8914a38f24af5b31a1f9faeb05aea66a4af40d979d6d7ad229f
}

# ab_vp_expected_lock - the exact twelve-line runtime lock of the addendum,
# Section 4.
ab_vp_expected_lock() {
    printf '%s\n' \
        'vtk==9.5.2 --hash=sha256:454711c51038824ddc75f955e1064c4e214b452c2e67083f01a8b43fc0ed62cb' \
        'matplotlib==3.10.7 --hash=sha256:d5f256d49fea31f40f166a5e3131235a5d2f4b7f44520b1cf0baf1ce568ccff0' \
        'contourpy==1.3.3 --hash=sha256:4d00e655fcef08aba35ec9610536bfe90267d7ab5ba944f7032549c55a146da1' \
        'cycler==0.12.1 --hash=sha256:85cef7cff222d8644161529808465972e51340599459b8ac3ccbac5a854e0d30' \
        'fonttools==4.60.1 --hash=sha256:8177ec9676ea6e1793c8a084a90b65a9f778771998eb919d05db6d4b1c0b114c' \
        'kiwisolver==1.4.9 --hash=sha256:f6008a4919fdbc0b0097089f67a1eb55d950ed7e90ce2cc3e640abadd2757a04' \
        'numpy==2.3.4 --hash=sha256:4121c5beb58a7f9e6dfdee612cb24f4df5cd4db6e8261d7f4d7450a997a65d6a' \
        'packaging==25.0 --hash=sha256:29572ef2b1f17581046b3a2227d5c611fb25ec70ca1ba8554b24b0e69331a484' \
        'pillow==11.3.0 --hash=sha256:67172f2944ebba3d4a7b54f2e95c786a3a50c21b88456329314caaa28cda70f6' \
        'pyparsing==3.2.5 --hash=sha256:e38a4f02064cf41fe6593d328d0512495ad1f3d8a91c4f73fc401b3079a59a5e' \
        'python-dateutil==2.9.0.post0 --hash=sha256:a8b2bc7bffae282281c8140a97d3aa9c14da0b136dfe83f850eea9a5f7470427' \
        'six==1.17.0 --hash=sha256:4721f391ed90541fddacab5acf947aa0d3dc7d27b2e1e8eda2be8970586c3274'
}

# ab_vp_expected_requires - the mandatory default requirement of each declaring
# distribution, as the exact embedded core metadata states it (addendum,
# Section 2). No other selected distribution has a mandatory requirement.
ab_vp_expected_requires() {
    printf '%s\t%s\n' declaring requirement \
        vtk 'matplotlib>=2.0.0' \
        matplotlib 'contourpy>=1.0.1' matplotlib 'cycler>=0.10' matplotlib 'fonttools>=4.22.0' \
        matplotlib 'kiwisolver>=1.3.1' matplotlib 'numpy>=1.23' matplotlib 'packaging>=20.0' \
        matplotlib 'pillow>=8' matplotlib 'pyparsing>=3' matplotlib 'python-dateutil>=2.7' \
        contourpy 'numpy>=1.25' \
        python-dateutil 'six >=1.5'
}

# ab_vp_block <workflow> <step> - the provision block of one step, as the step
# runs it: from the begin marker line through the end marker line and its line
# end. The awk program reads to the end, so pipefail sees no SIGPIPE.
ab_vp_block() {
    ab_step_run_body "$2" "$1" | awk '
        done { next }
        $0 == "# ---- M3 VTU provision: begin ----" { inside = 1 }
        inside { print }
        inside && $0 == "# ---- M3 VTU provision: end ----" { inside = 0; done = 1 }'
}

# ab_vp_heredoc <file> <name> - the body of the quoted here-document <name>,
# which the block reads into the variable <name>.
ab_vp_heredoc() {
    awk -v start="IFS= read -r -d '' ${2} <<'${2}' || true" -v end="$2" '
        $0 == start { inside = 1; next }
        inside && $0 == end { exit }
        inside { print }' "$1"
}

# ab_vp_code <workspace> - write the provision block of the contract-tests step
# to block.sh, and its three fixed Python programs to fetch.py, install.py,
# and verify.py.
ab_vp_code() {
    local name
    ab_vp_block "$CONTRACT_WORKFLOW" "$AB_VP_STEP" > "${1}/block.sh"
    [[ -s "${1}/block.sh" ]] || _fail "the contract-tests step must hold the provision block"
    for name in fetch install verify; do
        ab_vp_heredoc "${1}/block.sh" "VP_${name^^}_PY" > "${1}/${name}.py"
        [[ -s "${1}/${name}.py" ]] || _fail "the provision block must hold VP_${name^^}_PY"
    done
}

# ab_vp_script <workspace> <file> - a script that holds the provision block
# and then the lines on standard input. The block identity comes from the
# script file itself, as in the workflow step.
ab_vp_script() {
    {
        printf 'set -euo pipefail\n'
        ab_vp_block "$CONTRACT_WORKFLOW" "$AB_VP_STEP"
        cat
    } > "${1}/${2}"
}

# ab_vp_step_without <workflow> <step> <first> <last> - the YAML text of one
# step without the lines from <first> through <last>, which must exist.
ab_vp_step_without() {
    awk -v want="      - name: $2" -v first="$3" -v last="$4" '
        $0 == want { inside = 1; print; next }
        inside && /^      - name: / { exit }
        !inside { next }
        skip == 0 && $0 == first { skip = 1; next }
        skip == 1 { if ($0 == last) skip = 2; next }
        { print }' "$1"
}

# The contract-tests job cap of S100 (Owner decision 6170198169, contract
# 6170722644, Section 4). The job must hold exactly one job-level cap line,
# "    timeout-minutes: 18", before its steps. Only that validated line goes
# back to 15 for the comparison with the admitted base file; S100 normalizes
# no other byte.

# ab_vc_guard <workflow> <base> - the cap guard of S100. Print one result:
# "REJECT_BEFORE_NORMALIZATION: <reason>" when the workflow does not end with
# an LF (AWK would add that byte, Owner decision 6173182935) or the
# contract-tests job does not hold the one authorized cap line. Else write
# <base>, the workflow with that line set back to 15 and without the provision
# step, and print "ACCEPT" when <base> is the admitted base file or
# "REJECT_AT_BASE_HASH" when it is not. A missing workflow or a tool error
# prints no result and returns 1, so it is never an expected rejection. A cap
# line is a contract-tests line with "timeout-minutes" and less than 8 leading
# spaces, that is, not a step line.
ab_vc_guard() {
    local workflow="$1" base="$2" verdict hash last
    rm -f -- "$base" || { _fail "S100: the cap guard cannot remove ${base}"; return 1; }
    [[ -f "$workflow" ]] || { _fail "S100: the cap guard has no workflow file ${workflow}"; return 1; }
    last="$(tail -c 1 -- "$workflow" | od -An -tx1 | tr -d ' \n')" ||
        { _fail "S100: the cap guard cannot read the last byte of ${workflow}"; return 1; }
    if [[ "$last" != 0a ]]; then
        printf 'REJECT_BEFORE_NORMALIZATION: the workflow has no final LF\n'
        return 0
    fi
    verdict="$(awk '
        /^[^ #]/ { jobs = ($0 == "jobs:"); job = "" }
        jobs && /^  [^ #]/ { job = $0; steps = 0; if (job == "  contract-tests:") count++ }
        job != "  contract-tests:" { next }
        $0 == "    steps:" { steps = 1 }
        /timeout-minutes/ { match($0, /^ */); if (RLENGTH < 8) { n++; line = NR; text = $0; late = steps } }
        END {
            if (count != 1) print "REJECT the workflow has " count + 0 " contract-tests jobs"
            else if (n == 0) print "REJECT the contract-tests job has no job-level cap line"
            else if (n > 1) print "REJECT the contract-tests job has " n " job-level cap lines"
            else if (text != "    timeout-minutes: 18") print "REJECT the job-level cap line of contract-tests is [" text "], not [    timeout-minutes: 18]"
            else if (late) print "REJECT the job-level cap line of contract-tests comes after its steps"
            else print "LINE " line
        }' "$workflow")" || { _fail "S100: the cap guard cannot read ${workflow}"; return 1; }
    case "$verdict" in
        "REJECT "*) printf 'REJECT_BEFORE_NORMALIZATION: %s\n' "${verdict#REJECT }"; return 0 ;;
        "LINE "*) ;;
        *) _fail "S100: the cap guard gives no result for ${workflow}" "$verdict"; return 1 ;;
    esac
    awk -v cap="${verdict#LINE }" 'NR == cap { print "    timeout-minutes: 15"; next } { print }' "$workflow" |
        awk -v want="      - name: ${AB_VP_STEP}" '
        $0 == want { skip = 1; next }
        skip && /^      - name: / { skip = 0 }
        !skip { print }' > "$base" || { _fail "S100: the cap guard cannot write ${base}"; return 1; }
    hash="$(sha256sum < "$base" | cut -d ' ' -f 1)" || { _fail "S100: the cap guard cannot hash ${base}"; return 1; }
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || { _fail "S100: the cap guard has no SHA-256 of ${base}" "$hash"; return 1; }
    if [[ "$hash" == e46b7315c16a777e62cff9c64ac32eede0f24d99dec58de87de09293f5e9a478 ]]; then
        printf 'ACCEPT\n'
    else
        printf 'REJECT_AT_BASE_HASH\n'
    fi
}

# ab_vc_input <mode> - one focused input of S100: batch-contract.yml with its
# job-level contract-tests cap line changed for <mode>, and no other change.
# legal: "    timeout-minutes: 18"; old_15; missing; duplicate: two 18-minute
# lines; step: the 18-minute line moves to the step "Run the v4 contract
# tests"; shellcheck: it moves to the ShellCheck job, in place of the 10-minute
# line; cap_19; job_name: the legal line and a changed contract-tests job name.
# Returns 1 when the workflow has no single such line or the edit has no place.
ab_vc_input() {
    awk -v mode="$1" '
        BEGIN {
            bad = (mode !~ /^(legal|old_15|missing|duplicate|step|shellcheck|cap_19|job_name)$/)
            need = (mode == "step" || mode == "shellcheck" || mode == "job_name")
        }
        /^[^ #]/ { jobs = ($0 == "jobs:"); job = "" }
        jobs && /^  [^ #]/ { job = $0; steps = 0 }
        job == "  contract-tests:" && $0 == "    steps:" { steps = 1 }
        job == "  contract-tests:" && !steps && /^    timeout-minutes: / {
            caps++
            if (mode == "legal" || mode == "job_name") print "    timeout-minutes: 18"
            else if (mode == "old_15") print "    timeout-minutes: 15"
            else if (mode == "cap_19") print "    timeout-minutes: 19"
            else if (mode == "duplicate") { print "    timeout-minutes: 18"; print "    timeout-minutes: 18" }
            next
        }
        mode == "step" && job == "  contract-tests:" && $0 == "      - name: Run the v4 contract tests" {
            print; print "        timeout-minutes: 18"; edits++; next
        }
        mode == "shellcheck" && job == "  shellcheck:" && /^    timeout-minutes: / {
            print "    timeout-minutes: 18"; edits++; next
        }
        mode == "job_name" && job == "  contract-tests:" && $0 == "    name: v4 batch-runner contract tests" {
            print "    name: v4 batch-runner contract tests, changed"; edits++; next
        }
        { print }
        END { exit (bad || caps != 1 || edits != need) }' "$CONTRACT_WORKFLOW"
}

s100_provision_block_is_identical_in_both_workflows() {
    local workspace constant vector name pattern mode result base actual
    workspace="$(new_workspace s100_provision)"
    ab_vp_block "$CONTRACT_WORKFLOW" "$AB_VP_STEP" > "${workspace}/contract.block"
    ab_vp_block "$WORKFLOW" "Run the Orchestrator" > "${workspace}/evidence.block"
    [[ -s "${workspace}/contract.block" ]] ||
        _fail "S100: the contract-tests provision step holds the provision block"
    [[ -s "${workspace}/evidence.block" ]] ||
        _fail "S100: the Orchestrator step of the evidence workflow holds the provision block"
    assert_eq "$(tail -n 1 "${workspace}/contract.block")" "# ---- M3 VTU provision: end ----" \
        "S100: the contract-tests block is complete"
    assert_eq "$(sha256sum < "${workspace}/contract.block")" "$(sha256sum < "${workspace}/evidence.block")" \
        "S100: both workflows embed the same provision block, so the manifest and the provision code have the same SHA-256"
    assert_eq "1 1" "$(grep -cx '          # ---- M3 VTU provision: begin ----' "$CONTRACT_WORKFLOW") $(grep -cx '          # ---- M3 VTU provision: begin ----' "$WORKFLOW")" \
        "S100: each workflow holds the block once"

    # The fixed artifact set, lock, and mandatory closure.
    ab_vp_heredoc "${workspace}/contract.block" VP_MANIFEST > "${workspace}/manifest.tsv"
    assert_eq "$(ab_vp_expected_manifest)" "$(cat "${workspace}/manifest.tsv")" \
        "S100: the manifest holds exactly the thirteen approved artifacts"
    assert_eq "152465726 154218283" \
        "$(awk -F '\t' 'NR > 1 { all += $6; if ($1 == "runtime") run += $6 } END { print run, all }' "${workspace}/manifest.tsv")" \
        "S100: the runtime archives have 152465726 bytes, and all archives 154218283 bytes"
    assert_eq "$(ab_vp_expected_lock)" "$(ab_vp_heredoc "${workspace}/contract.block" VP_LOCK)" \
        "S100: the requirement lock is the exact twelve-line runtime lock"
    assert_eq "$(ab_vp_expected_requires)" "$(ab_vp_heredoc "${workspace}/contract.block" VP_REQUIRES)" \
        "S100: the mandatory default closure is the approved one"

    # The approved limits.
    for constant in VP_TOTAL_MS=90000 VP_FETCH_MS=30000 VP_INSTALL_MS=35000 VP_VERIFY_MS=10000 VP_RESERVE_MS=15000 \
                    VP_KILL_GRACE_MS=5000 VP_ARCHIVE_LIMIT=154218283 VP_EXPANDED_LIMIT=1073741824 \
                    VP_TASK_LIMIT=3221225472 VP_AS_LIMIT=4294967296 VP_CPU_SECONDS=60 VP_TEXT_LIMIT=65536 \
                    VP_PYTHON=/usr/bin/python3.12; do
        assert_eq "1" "$(grep -cx -- "$constant" "${workspace}/contract.block")" "S100: the block sets ${constant}"
    done
    # The three fixed vectors of the addendum, Section 4.
    for vector in \
        'timeout --signal=TERM --kill-after=5s "${DEP_FETCH_SECONDS}s" \' \
        '/usr/bin/python3.12 -I - "$M3_VTU_DEP_ROOT"' \
        'PIP_CONFIG_FILE=/dev/null TMPDIR="${M3_VTU_DEP_ROOT}/tmp" \' \
        'timeout --signal=TERM --kill-after=5s "${DEP_INSTALL_SECONDS}s" \' \
        '/usr/bin/python3.12 -I - \' \
        '"${M3_VTU_DEP_ROOT}/installer/pip-25.2-py3-none-any.whl" \' \
        '--isolated --disable-pip-version-check install --no-index \' \
        '--find-links="${M3_VTU_DEP_ROOT}/wheels" --require-hashes \' \
        '--only-binary=:all: --no-cache-dir --no-compile \' \
        '--target="${M3_VTU_DEP_ROOT}/site" \' \
        '--requirement="${M3_VTU_DEP_ROOT}/requirements.lock"' \
        'timeout --signal=TERM --kill-after=5s "${DEP_VERIFY_SECONDS}s" \' \
        '/usr/bin/python3.12 -I - "${M3_VTU_DEP_ROOT}/site"'; do
        assert_eq "1" "$(grep -cxF -- "$vector" <(sed -e 's/^[[:space:]]*//' "${workspace}/contract.block"))" \
            "S100: the block holds the fixed vector line [${vector}] once"
    done
    # No privilege, system package, resolver, source build, or fallback.
    for pattern in 'sudo' 'apt-get' 'apt ' 'curl ' 'wget ' '--no-deps' '--ignore-requires-python' '--break-system-packages' \
                   '--index-url' '--extra-index-url' '--user' '--editable' 'setup.py' 'addsitedir' 'PYTHONPATH' \
                   'LD_LIBRARY_PATH' 'urllib.request' 'getproxies' 'ssl._create_unverified_context' 'CERT_NONE'; do
        assert_eq "0" "$(grep -cF -- "$pattern" "${workspace}/contract.block")" \
            "S100: the block holds no [${pattern}]"
    done

    # The contract-tests job: one explicit provision step before the suite, the
    # one authorized cap line, and no other change.
    assert_eq "Check out the repository|Report the runner environment|Check the contract-test harness syntax|${AB_VP_STEP}|Run the v4 contract tests|Confirm that the working tree is unchanged|Check out the repository|Install ShellCheck|Run the ShellCheck baseline gate" \
        "$(sed -n -e 's/^      - name: //p' "$CONTRACT_WORKFLOW" | paste -sd '|' -)" \
        "S100: the provision step comes before the suite, and the other steps stay"
    # The cap guard on nine focused copies of this workflow text, each with one
    # change, and then on the workflow itself. A rejected copy passes only with
    # its expected reason. Before normalization, the guard writes no base file.
    actual=''
    for mode in legal old_15 missing duplicate step shellcheck cap_19 job_name; do
        ab_vc_input "$mode" > "${workspace}/cap.${mode}.yml" ||
            _fail "S100: the focused input ${mode} has the one job-level contract-tests cap line to change"
        result="$(ab_vc_guard "${workspace}/cap.${mode}.yml" "${workspace}/cap.${mode}.base.yml")"
        base='-'
        [[ ! -e "${workspace}/cap.${mode}.base.yml" ]] || base='base'
        actual+="${mode} ${result} ${base}|"
    done
    assert_eq "legal ACCEPT base|old_15 REJECT_BEFORE_NORMALIZATION: the job-level cap line of contract-tests is [    timeout-minutes: 15], not [    timeout-minutes: 18] -|missing REJECT_BEFORE_NORMALIZATION: the contract-tests job has no job-level cap line -|duplicate REJECT_BEFORE_NORMALIZATION: the contract-tests job has 2 job-level cap lines -|step REJECT_BEFORE_NORMALIZATION: the contract-tests job has no job-level cap line -|shellcheck REJECT_BEFORE_NORMALIZATION: the contract-tests job has no job-level cap line -|cap_19 REJECT_BEFORE_NORMALIZATION: the job-level cap line of contract-tests is [    timeout-minutes: 19], not [    timeout-minutes: 18] -|job_name REJECT_AT_BASE_HASH base|" \
        "$actual" \
        "S100: the cap guard accepts only the one authorized 18-minute cap line of the contract-tests job, and rejects each changed copy for its reason"
    # The ninth copy (Owner decision 6173182935): a byte copy of the legal input
    # without its final LF, and no other change. The guard normalizes no other
    # byte, so it rejects this copy before normalization.
    cp -- "${workspace}/cap.legal.yml" "${workspace}/cap.no_final_lf.yml" ||
        _fail "S100: the focused input no_final_lf is a byte copy of the legal input"
    truncate -s -1 -- "${workspace}/cap.no_final_lf.yml" ||
        _fail "S100: the focused input no_final_lf loses its last byte"
    { cat -- "${workspace}/cap.no_final_lf.yml" && printf '\n'; } | cmp -s -- - "${workspace}/cap.legal.yml" ||
        _fail "S100: the legal input ends with its final LF, and the focused input no_final_lf is the legal input without only that byte"
    result="$(ab_vc_guard "${workspace}/cap.no_final_lf.yml" "${workspace}/cap.no_final_lf.base.yml")"
    base='-'
    [[ ! -e "${workspace}/cap.no_final_lf.base.yml" ]] || base='base'
    assert_eq "no_final_lf REJECT_BEFORE_NORMALIZATION: the workflow has no final LF -" "no_final_lf ${result} ${base}" \
        "S100: the cap guard rejects the legal copy without its final LF before normalization, and writes no base file"
    result="$(ab_vc_guard "$CONTRACT_WORKFLOW" "${workspace}/batch-contract-base.yml")"
    [[ "$result" != REJECT_BEFORE_NORMALIZATION* ]] ||
        _fail "S100: the contract-tests job holds the one authorized cap line, [    timeout-minutes: 18], before its steps" "$result"
    assert_eq "e46b7315c16a777e62cff9c64ac32eede0f24d99dec58de87de09293f5e9a478" \
        "$(sha256sum < "${workspace}/batch-contract-base.yml" | cut -d ' ' -f 1)" \
        "S100: with that cap line set back to 15 and without the provision step, batch-contract.yml is the admitted base file"
    assert_eq "ACCEPT" "$result" "S100: the cap guard accepts batch-contract.yml"
    assert_eq "$(printf '        timeout-minutes: 2\n        run: |\n          set -euo pipefail\n          # ---- M3 VTU provision: begin ----')" \
        "$(awk -v want="      - name: ${AB_VP_STEP}" '$0 == want { inside = 1; next } inside { print; if (++n == 4) exit }' "$CONTRACT_WORKFLOW")" \
        "S100: the provision step has no condition, a 2-minute guard, and starts with the block"
    assert_eq "$(printf '%s\n' '# ---- M3 VTU provision: end ----' 'vp_provision' \
                  'if [[ "$VP_RESULT" != PROVISION_AVAILABLE ]]; then' \
                  '    echo "M3 VTU provision: ${VP_RESULT}: ${VP_REASON}" >&2' '    exit 1' 'fi')" \
        "$(ab_step_run_body "$AB_VP_STEP" "$CONTRACT_WORKFLOW" | sed -n -e '/^# ---- M3 VTU provision: end ----$/,$p')" \
        "S100: a provision that is not PROVISION_AVAILABLE fails the step"

    # The evidence workflow: the block and its gate come first in the
    # Orchestrator step, before the OpenFOAM environment; the step is otherwise
    # the admitted step, with the unchanged Orchestrator vector.
    ab_vp_step_without "$WORKFLOW" "Run the Orchestrator" '          # ---- M3 VTU provision: begin ----' \
        '          # ---- M3 VTU provision gate: end ----' > "${workspace}/orchestrator-base.yml"
    assert_eq "7e0297ba4c57e6f3c4a42b8970258c958a4d388f1592d51c36d84b59eb3629bc" \
        "$(sha256sum < "${workspace}/orchestrator-base.yml" | cut -d ' ' -f 1)" \
        "S100: without the provision block and gate, the Orchestrator step is the admitted step"
    assert_eq "$(printf '%s\n' '# ---- M3 VTU provision: end ----' \
                  '# The provision-success gate: the Orchestrator never starts after a failed' \
                  '# provision, and the Stage results stay NOT_ATTEMPTED.' \
                  'vp_provision "$(( ${CAPTURE_DEADLINE:-0} - ${CAPTURE_START_GUARD_SECONDS:-60} - 60 ))"' \
                  'if [[ "$VP_RESULT" != PROVISION_AVAILABLE ]]; then' \
                  '    echo "M3 VTU provision: ${VP_RESULT}: ${VP_REASON}" >&2' '    exit 1' 'fi' \
                  '# ---- M3 VTU provision gate: end ----' 'source "$LIB"')" \
        "$(ab_step_run_body "Run the Orchestrator" | sed -n -e '/^# ---- M3 VTU provision: end ----$/,/^source "\$LIB"$/p')" \
        "S100: the gate comes after the block and before the bounded-runner library and the OpenFOAM environment"
    assert_eq "set -euo pipefail" "$(ab_step_run_body "Run the Orchestrator" | head -n 1)" \
        "S100: the Orchestrator step starts with the strict shell options"
    assert_eq "2" "$(ab_step_run_body "Run the Orchestrator" | grep -n -m 1 -x '# ---- M3 VTU provision: begin ----' | cut -d : -f 1)" \
        "S100: the provision block is the first work of the Orchestrator step"
    assert_eq "always() && env.PREPARE_RESULT == 'SUCCEEDED'" \
        "$(ab_workflow_step_block "Run the Orchestrator" | sed -n -e 's/^        if: //p')" \
        "S100: the Orchestrator step condition stays"
    # The job summary shows the provision result.
    assert_eq "1" "$(grep -cF -- '| VTU provision | \`${M3_VTU_PROVISION_RESULT:-NOT_ATTEMPTED}\` |' "$WORKFLOW")" \
        "S100: the job summary shows the provision result"
    for name in "Start the evidence clock" "Check out the repository" "Prepare the one-Case DOE Batch CSV" "Capture the evidence"; do
        assert_eq "0" "$(ab_workflow_step_block "$name" | grep -c 'M3 VTU provision: begin')" \
            "S100: the step '${name}' holds no provision block"
    done
}

# ab_vp_foreign_group - print one live process group that the test user may
# not signal: kill -0 gives EPERM and sends no signal. Fails when the host has
# none, for example when the tests run as root.
ab_vp_foreign_group() {
    local group text
    while read -r group; do
        [[ "$group" =~ ^[0-9]+$ ]] && (( group > 1 )) || continue
        text="$(LC_ALL=C kill -0 -- "-${group}" 2>&1)" || true
        if [[ "$text" == *"Operation not permitted"* ]]; then
            printf '%s\n' "$group"
            return 0
        fi
    done < <(ps -eo pgid=,stat= | awk '$2 !~ /^Z/ { print $1 }' | sort -un)
    _fail "the host must have a process group of another user for the stop check"
}

s101_provision_gate_and_bounded_operations() {
    local workspace out status start elapsed group pids line
    workspace="$(new_workspace s101_gate)"
    mkdir -p "${workspace}/runner_temp" "${workspace}/real_temp"
    ln -s "${workspace}/real_temp" "${workspace}/linked_temp"

    # No provision time: no task root, no command, and NOT_ATTEMPTED in GITHUB_ENV.
    ab_vp_script "$workspace" no_time.sh <<'EOF'
vp_provision "$(( EPOCHSECONDS - 1 ))"
printf 'result=%s\nroot=%s\nreason=%s\n' "$VP_RESULT" "${VP_ROOT:-}" "$VP_REASON"
EOF
    : > "${workspace}/github_env"
    out="$(env RUNNER_TEMP="${workspace}/runner_temp" GITHUB_ENV="${workspace}/github_env" \
        bash "${workspace}/no_time.sh" 2>&1)" || _fail "S101: vp_provision returns 0 without time" "$out"
    assert_contains "$out" "result=NOT_ATTEMPTED" "S101: no provision time gives NOT_ATTEMPTED"
    assert_contains "$out" $'root=\n' "S101: no provision time makes no task root"
    assert_eq "" "$(ls -A "${workspace}/runner_temp")" "S101: no provision time writes nothing below RUNNER_TEMP"
    assert_eq "M3_VTU_PROVISION_RESULT=NOT_ATTEMPTED" "$(cat "${workspace}/github_env")" \
        "S101: GITHUB_ENV gets only the result, and no root path"

    # An unsafe RUNNER_TEMP: no task root and NOT_VERIFIED, before any network
    # access.
    ab_vp_script "$workspace" linked.sh <<'EOF'
vp_provision
printf 'result=%s\nroot=%s\nreason=%s\n' "$VP_RESULT" "${VP_ROOT:-}" "$VP_REASON"
EOF
    : > "${workspace}/github_env"
    out="$(env RUNNER_TEMP="${workspace}/linked_temp" GITHUB_ENV="${workspace}/github_env" \
        bash "${workspace}/linked.sh" 2>&1)" || _fail "S101: vp_provision returns 0 with a linked RUNNER_TEMP" "$out"
    assert_contains "$out" "result=NOT_VERIFIED" "S101: a linked RUNNER_TEMP gives NOT_VERIFIED"
    assert_contains "$out" "RUNNER_TEMP" "S101: the reason names RUNNER_TEMP"
    assert_eq "" "$(ls -A "${workspace}/real_temp")" "S101: a linked RUNNER_TEMP gets no task root"
    assert_eq "M3_VTU_PROVISION_RESULT=NOT_VERIFIED" "$(cat "${workspace}/github_env")" \
        "S101: GITHUB_ENV gets NOT_VERIFIED and no root path"

    # The contract-tests step fails on a failed provision, so the suite and the
    # required check fail.
    ab_step_run_body "$AB_VP_STEP" "$CONTRACT_WORKFLOW" > "${workspace}/contract_step.sh"
    : > "${workspace}/github_env"
    env RUNNER_TEMP="${workspace}/linked_temp" GITHUB_ENV="${workspace}/github_env" \
        bash -eo pipefail "${workspace}/contract_step.sh" > "${workspace}/contract_step.out" 2>&1 && status=0 || status=$?
    assert_eq "1" "$status" "S101: the contract-tests provision step fails after a failed provision"
    assert_contains "$(cat "${workspace}/contract_step.out")" "M3 VTU provision: NOT_VERIFIED: " \
        "S101: the failed step names the result and the reason"

    # The evidence workflow: a failed provision fails the Orchestrator step
    # before the bounded-runner library, the OpenFOAM environment, and the
    # Orchestrator. ORCHESTRATOR_STARTED, OVERALL_RESULT, and the Stage results
    # keep the values of the clock step.
    ab_step_run_body "Run the Orchestrator" > "${workspace}/orchestrator_step.sh"
    printf 'printf "sourced\\n" > %q\n' "${workspace}/lib_sourced" > "${workspace}/lib.sh"
    : > "${workspace}/github_env"
    env RUNNER_TEMP="${workspace}/runner_temp" GITHUB_ENV="${workspace}/github_env" LIB="${workspace}/lib.sh" \
        EVIDENCE_DIR="${workspace}/runner_temp/evidence" CAPTURE_DEADLINE="$(( EPOCHSECONDS + 60 ))" \
        CAPTURE_START_GUARD_SECONDS=60 OPENFOAM_BASHRC="${workspace}/no_bashrc" \
        bash -eo pipefail "${workspace}/orchestrator_step.sh" > "${workspace}/orchestrator_step.out" 2>&1 && status=0 || status=$?
    assert_eq "1" "$status" "S101: the Orchestrator step fails when no provision time is left"
    assert_eq "M3_VTU_PROVISION_RESULT=NOT_ATTEMPTED" "$(cat "${workspace}/github_env")" \
        "S101: the step writes only the provision result: no ORCHESTRATOR_STARTED, OVERALL_RESULT, or Stage line"
    assert_file_missing "${workspace}/lib_sourced" "S101: the step stops before the bounded-runner library"
    assert_contains "$(cat "${workspace}/orchestrator_step.out")" "M3 VTU provision: NOT_ATTEMPTED: " \
        "S101: the failed gate names the result and the reason"

    # The job summary shows the provision result.
    ab_step_run_body "Write the job summary" > "${workspace}/summary_step.sh"
    : > "${workspace}/step_summary"
    env GITHUB_STEP_SUMMARY="${workspace}/step_summary" M3_VTU_PROVISION_RESULT=NOT_VERIFIED \
        bash -eo pipefail "${workspace}/summary_step.sh" > /dev/null 2>&1 || _fail "S101: the summary step succeeds"
    assert_contains "$(cat "${workspace}/step_summary")" "| VTU provision | \`NOT_VERIFIED\` |" \
        "S101: the summary row shows the provision result"
    : > "${workspace}/step_summary"
    env GITHUB_STEP_SUMMARY="${workspace}/step_summary" bash -eo pipefail "${workspace}/summary_step.sh" > /dev/null 2>&1 ||
        _fail "S101: the summary step succeeds without a provision"
    assert_contains "$(cat "${workspace}/step_summary")" "| VTU provision | \`NOT_ATTEMPTED\` |" \
        "S101: a missing provision result is NOT_ATTEMPTED in the summary"

    # vp_op: a command that does not end in its limit gets SIGTERM at the
    # limit, and its process group is empty before vp_op returns.
    mkdir -p "${workspace}/op_root/records"
    ab_vp_script "$workspace" op.sh <<'EOF'
VP_ROOT="$1"
VP_END_MS=$(( $(vp_now_ms) + 30000 ))
start=$(vp_now_ms)
VP_OP_STDIN=""
vp_op slow 1000 bash -c 'sleep 30 & printf "%s\n" "$!" > "$1/child"; wait' _ "$VP_ROOT"
printf 'outcome=%s status=%s stop=%s limit=%s elapsed=%s group=%s\n' "$VP_OP_OUTCOME" "$VP_OP_STATUS" "$VP_STOP" \
    "$VP_OP_LIMIT_MS" "$(( $(vp_now_ms) - start ))" "$VP_OP_GROUP"
# No time: the command never starts.
VP_END_MS=$(( $(vp_now_ms) + VP_RESERVE_MS ))
vp_op late 1000 bash -c ': > "$1/late"' _ "$VP_ROOT"
printf 'late=%s status=%s\n' "$VP_OP_OUTCOME" "$VP_OP_STATUS"
EOF
    out="$(bash "${workspace}/op.sh" "${workspace}/op_root" 2>&1)" || _fail "S101: the operation script runs" "$out"
    assert_contains "$out" "outcome=TIMEOUT status=124" "S101: a command past its limit is a TIMEOUT"
    [[ "$out" =~ elapsed=([0-9]+) ]] && (( BASH_REMATCH[1] < 3000 )) ||
        _fail "S101: the operation ends shortly after its 1-second limit" "$out"
    assert_contains "$out" "limit=1000 " "S101: the operation limit is the phase limit when the provision end is later"
    if kill -0 "$(cat "${workspace}/op_root/child")" 2>/dev/null; then
        kill -KILL "$(cat "${workspace}/op_root/child")" 2>/dev/null || true
        _fail "S101: the child of the stopped command is gone" "$out"
    fi
    assert_contains "$out" "late=NOT_STARTED status=124" "S101: without time before the reserve, no command starts"
    assert_file_missing "${workspace}/op_root/late" "S101: the late command never ran"
    line="$(awk -F '\t' '$2 == "slow"' "${workspace}/op_root/records/commands.tsv")"
    assert_contains "$line" $'\tTIMEOUT\t' "S101: commands.tsv records the outcome"
    assert_contains "$line" "bash -c" "S101: commands.tsv records the vector"

    # vp_stop_group: a TERM-ignoring process gets SIGKILL before the deadline;
    # a group that the user may not signal stays NOT_STOPPED, by the deadline.
    ab_vp_script "$workspace" stop.sh <<'EOF'
setsid bash -c 'trap "" TERM; while :; do sleep 0.1; done' &
leader=$!
sleep 0.2
start=$(vp_now_ms)
vp_stop_group "$leader" $(( start + 1500 )) && status=0 || status=$?
printf 'own=%s status=%s elapsed=%s\n' "$VP_STOP" "$status" "$(( $(vp_now_ms) - start ))"
wait "$leader" 2>/dev/null || true
kill -0 "$leader" 2>/dev/null && printf 'own_alive\n'
start=$(vp_now_ms)
vp_stop_group "$1" $(( start + 1500 )) && status=0 || status=$?
printf 'foreign=%s status=%s elapsed=%s\n' "$VP_STOP" "$status" "$(( $(vp_now_ms) - start ))"
vp_stop_group 1 $(( $(vp_now_ms) + 1500 )) && status=0 || status=$?
printf 'one=%s status=%s\n' "$VP_STOP" "$status"
EOF
    group="$(ab_vp_foreign_group)"
    out="$(bash "${workspace}/stop.sh" "$group" 2>&1)" || _fail "S101: the stop script runs" "$out"
    assert_contains "$out" "own=STOPPED status=0" "S101: a TERM-ignoring group is stopped"
    assert_not_contains "$out" "own_alive" "S101: the TERM-ignoring process is gone"
    assert_contains "$out" "foreign=NOT_STOPPED status=1" "S101: a group that cannot be signaled is NOT_STOPPED"
    [[ "$out" =~ foreign=NOT_STOPPED\ status=1\ elapsed=([0-9]+) ]] && (( BASH_REMATCH[1] <= 1700 )) ||
        _fail "S101: the stop check ends by its deadline" "$out"
    assert_contains "$out" "one=NOT_STOPPED status=1" "S101: a group ID below 2 is refused"
}

# ab_vp_fakes_py <file> - the shared Python test helpers of S102: small
# controlled wheels, a controlled task root with its own manifest, and a
# controlled site directory. They never reach a network or the real artifacts.
ab_vp_fakes_py() {
    cat > "$1" <<'PY'
import base64, csv, hashlib, io, os, stat, zipfile

URL = "https://files.pythonhosted.org/packages/aa/bb/" + "c" * 60 + "/"

def sha(data):
    return hashlib.sha256(data).hexdigest()

def record_hash(data):
    return "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()

def metadata(name, version, requires=()):
    lines = ["Metadata-Version: 2.1", "Name: " + name, "Version: " + version]
    lines += ["Requires-Dist: " + r for r in requires]
    lines += ["Requires-Dist: unused>=1; extra == \"docs\""]
    return ("\n".join(lines) + "\n").encode()

def wheel(name, version, requires=(), files=None, tag="py3-none-any", bad=None, meta=None):
    """One small wheel: (file name, bytes, METADATA bytes). bad selects one unsafe member."""
    stem = name.replace("-", "_") + "-" + version
    info = stem + ".dist-info/"
    files = dict(files if files is not None else {name.replace("-", "_") + "/__init__.py": b"VALUE = 1\n"})
    meta = meta if meta is not None else metadata(name, version, requires)
    wheel_text = ("Wheel-Version: 1.0\nGenerator: ab-test\nRoot-Is-Purelib: true\nTag: " + tag + "\n").encode()
    members = list(files.items()) + [(info + "METADATA", meta), (info + "WHEEL", wheel_text)]
    extra = []
    if bad == "escape":
        extra = [("../escape.py", b"x = 1\n")]
    elif bad == "absolute":
        extra = [("/absolute.py", b"x = 1\n")]
    elif bad == "duplicate":
        extra = [(members[0][0], b"VALUE = 2\n")]
    record = io.StringIO()
    writer = csv.writer(record, lineterminator="\n")
    for member, data in members + extra:
        writer.writerow([member, record_hash(data), len(data)])
    writer.writerow([info + "RECORD", "", ""])
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for member, data in members + extra + [(info + "RECORD", record.getvalue().encode())]:
            entry = zipfile.ZipInfo(member, (2020, 1, 1, 0, 0, 0))
            entry.external_attr = (stat.S_IFREG | 0o644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)
        if bad == "link":
            entry = zipfile.ZipInfo(name.replace("-", "_") + "/link.py", (2020, 1, 1, 0, 0, 0))
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, b"/etc/passwd")
    return "%s-%s.whl" % (stem, tag), out.getvalue(), meta

def task_root(base, rows, lock=None, requires=None, mode=0o700):
    """A task root with the given manifest rows: (role, name, version, file, data, meta)."""
    os.makedirs(base, mode=0o700)
    for sub in ("installer", "wheels", "site", "tmp", "records"):
        os.mkdir(os.path.join(base, sub), 0o700)
    lines = ["role\tdistribution\tversion\tfile\turl\tbytes\tsha256\tmetadata_bytes\tmetadata_sha256"]
    locks = []
    for role, name, version, file, data, meta in rows:
        lines.append("\t".join([role, name, version, file, URL + file, str(len(data)), sha(data), str(len(meta)), sha(meta)]))
        if role == "runtime":
            locks.append("%s==%s --hash=sha256:%s" % (name, version, sha(data)))
    with open(os.path.join(base, "manifest.tsv"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(base, "requirements.lock"), "w") as f:
        f.write((lock if lock is not None else "\n".join(locks)) + "\n")
    with open(os.path.join(base, "requires.tsv"), "w") as f:
        f.write("declaring\trequirement\n" + "".join("%s\t%s\n" % pair for pair in (requires or [])))
    os.chmod(base, mode)
    return base

def env_file(path):
    values = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep:
                    values[key] = value
    except OSError:
        pass
    return values
PY
}

# ab_vp_fetch_driver <file> - the in-process downloader cases. Each case loads
# the fixed downloader of the workflow, replaces only its HTTPS connection class
# (and, in two cases, its interpreter facts or its expanded-byte limit), and
# runs it on a new controlled task root. Prints one line for each case:
# case, FETCH_RESULT, FETCH_REASON, and the number of requests.
ab_vp_fetch_driver() {
    cat > "$1" <<'PY'
import errno, os, ssl, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[0])))
from vp_fakes import wheel, task_root, env_file, URL, metadata

code = compile(open(sys.argv[1], encoding="utf-8").read(), "vp-fetch", "exec")
work = sys.argv[2]

class Response:
    def __init__(self, status, headers, body):
        self.status, self.headers, self.body, self.offset = status, headers, body, 0
    def getheader(self, name, default=None):
        for key, value in self.headers.items():
            if key.lower() == name.lower():
                return value
        return default
    def read(self, amount=None):
        end = len(self.body) if amount is None else min(len(self.body), self.offset + amount)
        chunk = self.body[self.offset:end]
        self.offset = end
        return chunk
    def close(self):
        pass

class Connection:
    served = {}
    calls = []
    def __init__(self, host, port=None, timeout=None, context=None, **extra):
        Connection.calls.append(("connect", host, port, getattr(context, "verify_mode", None),
                                 getattr(context, "check_hostname", None), sorted(extra)))
    def request(self, method, path, body=None, headers=None):
        Connection.calls.append((method, path, sorted((headers or {}).items())))
        self.path = path
        entry = Connection.served.get(path)
        if isinstance(entry, BaseException):
            raise entry
    def getresponse(self):
        status, headers, body = Connection.served[self.path]
        return Response(status, headers, body)
    def close(self):
        pass

NS = {"__name__": "vp_unit"}
exec(code, NS)
NS["HTTPSConnection"] = Connection

def run_case(label, rows, serve=None, lock=None, requires=None, mode=0o700, patch=None, prepare=None):
    ns = NS
    saved = dict(ns)
    if patch:
        patch(ns)
    root = task_root(os.path.join(work, label), rows, lock=lock, requires=requires, mode=mode)
    if prepare:
        prepare(root)
    Connection.calls = []
    Connection.served = {}
    for role, name, version, file, data, meta in rows:
        Connection.served["/packages/aa/bb/" + "c" * 60 + "/" + file] = (200, {"Content-Length": str(len(data))}, data)
    if serve:
        serve(Connection.served, rows)
    status = ns["run"](root)
    ns.clear()
    ns.update(saved)
    values = env_file(os.path.join(root, "records", "fetch.env"))
    requests = [c for c in Connection.calls if c[0] == "GET"]
    print("\t".join([label, values.get("FETCH_RESULT", "MISSING"), values.get("FETCH_REASON", "MISSING"),
                     str(len(requests)), str(status)]))
    return root, Connection.calls

def path_of(file):
    return "/packages/aa/bb/" + "c" * 60 + "/" + file

def base_rows(**changes):
    alpha = wheel("alpha", "1.0", **dict({"requires": ["beta>=1.5"]}, **changes.get("alpha", {})))
    beta = wheel("beta", "2.0", **changes.get("beta", {}))
    pip = wheel("pip", "25.2", files={"pip/__init__.py": b"", "pip/__main__.py": b""})
    return [("runtime", "alpha", "1.0") + alpha, ("runtime", "beta", "2.0") + beta, ("installer", "pip", "25.2") + pip]

REQUIRES = [("alpha", "beta>=1.5")]

# A complete controlled set: three requests, TLS verification, exact paths.
root, calls = run_case("ok", base_rows(), requires=REQUIRES)
connects = [c for c in calls if c[0] == "connect"]
print("ok-connect\t" + ";".join(sorted({"%s:%s:%s:%s:%s" % (c[1], c[2], int(c[3]), c[4], ",".join(c[5])) for c in connects})))
print("ok-paths\t" + ";".join(c[1] for c in calls if c[0] == "GET"))
print("ok-headers\t" + ";".join(",".join(k for k, v in c[2]) for c in calls if c[0] == "GET"))
print("ok-files\t" + ";".join(sorted(os.listdir(os.path.join(root, "wheels")))) + "|" +
      ";".join(sorted(os.listdir(os.path.join(root, "installer")))))
print("ok-tsv\t%d\t%d" % (sum(1 for line in open(os.path.join(root, "records", "fetch.tsv")) if "\tPASS\t" in line),
                          sum(1 for line in open(os.path.join(root, "records", "wheels.tsv")) if "\tPASS\t" in line)))

def serve_body(change):
    def serve(served, rows):
        status, headers, body = served[path_of(rows[0][3])]
        served[path_of(rows[0][3])] = change(status, headers, body)
    return serve

run_case("long_body", base_rows(), requires=REQUIRES,
         serve=serve_body(lambda s, h, b: (s, {}, b + b"x")))
run_case("short_body", base_rows(), requires=REQUIRES,
         serve=serve_body(lambda s, h, b: (s, {}, b[:-1])))
run_case("changed_bytes", base_rows(), requires=REQUIRES,
         serve=serve_body(lambda s, h, b: (s, h, bytes([b[0] ^ 1]) + b[1:])))
run_case("redirect", base_rows(), requires=REQUIRES,
         serve=serve_body(lambda s, h, b: (302, {"Location": "https://mirror.example/x.whl", "Content-Length": "0"}, b"")))
def deny(served, rows):
    served[path_of(rows[0][3])] = OSError(errno.ENETUNREACH, "Network is unreachable")
run_case("network_denied", base_rows(), requires=REQUIRES, serve=deny)
run_case("content_encoding", base_rows(), requires=REQUIRES,
         serve=serve_body(lambda s, h, b: (s, dict(h, **{"Content-Encoding": "gzip"}), b)))

def foreign_url(root):
    path = os.path.join(root, "manifest.tsv")
    os.chmod(root, 0o700)
    text = open(path).read().replace("https://files.pythonhosted.org/", "https://mirror.example/", 1)
    open(path, "w").write(text)
run_case("foreign_url", base_rows(), requires=REQUIRES, prepare=foreign_url)
run_case("lock_mismatch", base_rows(), requires=REQUIRES, lock="alpha==1.0 --hash=sha256:" + "0" * 64 + "\nbeta==2.0 --hash=sha256:" + "0" * 64)
run_case("escape_member", base_rows(alpha={"bad": "escape"}), requires=REQUIRES)
run_case("absolute_member", base_rows(alpha={"bad": "absolute"}), requires=REQUIRES)
run_case("link_member", base_rows(alpha={"bad": "link"}), requires=REQUIRES)
run_case("duplicate_member", base_rows(alpha={"bad": "duplicate"}), requires=REQUIRES)
rows = base_rows()
rows[0] = rows[0][:5] + (metadata("alpha", "1.0", ["beta>=1.6"]),)
run_case("metadata_differs", rows, requires=REQUIRES)
run_case("unlisted_requirement", base_rows(alpha={"requires": ["beta>=1.5", "gamma>=1"]}), requires=REQUIRES)
run_case("missing_requirement", base_rows(alpha={"requires": []}), requires=REQUIRES)
run_case("unsatisfied_requirement", base_rows(alpha={"requires": ["beta>=3"]}), requires=[("alpha", "beta>=3")])
run_case("marker_requirement", base_rows(alpha={"requires": ["beta>=1.5; python_version < \"3.9\""]}),
         requires=[("alpha", "beta>=1.5; python_version < \"3.9\"")])
run_case("path_collision", base_rows(alpha={"files": {"shared/x.py": b"a = 1\n"}}, beta={"files": {"shared/x.py": b"b = 1\n"}}),
         requires=REQUIRES)
run_case("name_differs", base_rows(alpha={"meta": metadata("alpha-other", "1.0", ["beta>=1.5"])}), requires=REQUIRES)
run_case("unsupported_tag", base_rows(beta={"tag": "cp311-cp311-manylinux_2_17_aarch64"}), requires=REQUIRES)
def small_limit(ns):
    ns["EXPANDED_LIMIT"] = 10
run_case("expanded_limit", base_rows(), requires=REQUIRES, patch=small_limit)
def old_interpreter(ns):
    facts = ns["interpreter_facts"]()
    facts["version"] = "3.11.9"
    ns["interpreter_facts"] = lambda: dict(facts)
run_case("interpreter", base_rows(), requires=REQUIRES, patch=old_interpreter)
def busy(root):
    os.chmod(root, 0o700)
    open(os.path.join(root, "wheels", "left.whl"), "wb").close()
run_case("root_not_empty", base_rows(), requires=REQUIRES, prepare=busy)
run_case("root_mode", base_rows(), requires=REQUIRES, mode=0o755)
PY
}

# ab_vp_fake_site <python-file> - write a script that builds controlled task
# roots with a pip-style --target site of two distributions, alpha and beta,
# and a pure-Python vtkmodules of alpha. Arguments: <directory> <case>...; each
# root is <directory>/verify_<case>.
ab_vp_fake_site() {
    cat > "$1" <<'PY'
import csv, io, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[0])))
from vp_fakes import task_root, metadata, record_hash, wheel

def make(root, case):
    alpha_meta = metadata("alpha", "1.0", ["beta>=1.5"])
    beta_meta = metadata("beta", "2.0")
    manifest_alpha = metadata("alpha", "1.0", ["beta>=1.6"]) if case == "metadata" else alpha_meta
    rows = [("runtime", "alpha", "1.0", "alpha-1.0-py3-none-any.whl", b"a", manifest_alpha),
            ("runtime", "beta", "2.0", "beta-2.0-py3-none-any.whl", b"b", beta_meta),
            ("installer", "pip", "25.2", "pip-25.2-py3-none-any.whl", b"p", metadata("pip", "25.2"))]
    task_root(root, rows, requires=[("alpha", "beta>=1.5")])
    site = os.path.join(root, "site")
    core = (b"import os\n"
            b"limits = os.environ.get('AB_FAKE_LIMITS')\n"
            b"if limits:\n"
            b"    open(limits, 'w').write(open('/proc/self/limits').read())\n"
            b"class vtkVersion:\n"
            b"    @staticmethod\n"
            b"    def GetVTKVersion():\n"
            b"        return os.environ.get('AB_FAKE_VTK_VERSION', '9.5.2')\n")
    alpha_files = {"alpha/__init__.py": b"VALUE = 1\n", "../../bin/alpha-tool": b"#!/bin/sh\n"}
    if case != "no_module":
        alpha_files.update({"vtkmodules/__init__.py": b"", "vtkmodules/vtkCommonCore.py": core,
                            "vtkmodules/vtkIOXML.py": b"class vtkXMLUnstructuredGridReader:\n    pass\n"})
    dists = [("alpha", "1.0", alpha_meta, alpha_files), ("beta", "2.0", beta_meta, {"beta/__init__.py": b"VALUE = 2\n"})]
    if case == "no_dist":
        dists = dists[:1]
    for name, version, meta, files in dists:
        info = "%s-%s.dist-info/" % (name, version)
        files = dict(files, **{info + "METADATA": meta, info + "INSTALLER": b"pip\n"})
        record = io.StringIO()
        writer = csv.writer(record, lineterminator="\n")
        for rel, data in files.items():
            path = os.path.join(site, rel[len("../../"):] if rel.startswith("../../") else rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(data)
            writer.writerow([rel, record_hash(data), len(data)])
        writer.writerow([info + "RECORD", "", ""])
        with open(os.path.join(site, info + "RECORD"), "w") as f:
            f.write(record.getvalue())
    if case == "link":
        os.symlink("/etc/hostname", os.path.join(site, "alpha", "link.py"))
    elif case == "unlisted":
        open(os.path.join(site, "alpha", "extra.py"), "w").write("x = 1\n")
    elif case == "changed":
        open(os.path.join(site, "alpha", "__init__.py"), "w").write("VALUE = 3\n")

for case in sys.argv[2:]:
    make(os.path.join(sys.argv[1], "verify_" + case), case)
PY
}

s102_provision_programs_fail_closed() {
    local workspace out line label result reason requests status kind root pip args case_result case_reason case_requests case_status
    workspace="$(new_workspace s102_programs)"
    ab_vp_code "$workspace"
    ab_vp_fakes_py "${workspace}/vp_fakes.py"
    ab_vp_fetch_driver "${workspace}/fetch_driver.py"
    out="$(/usr/bin/python3.12 -I "${workspace}/fetch_driver.py" "${workspace}/fetch.py" "${workspace}/fetch_cases" 2>&1)" ||
        _fail "S102: the downloader cases run" "$out"
    printf '%s\n' "$out" > "${workspace}/fetch_cases.txt"

    # case, expected result, reason keyword, and expected requests
    while read -r label result reason requests; do
        line="$(awk -F '\t' -v want="$label" '$1 == want' "${workspace}/fetch_cases.txt")"
        [[ -n "$line" ]] || _fail "S102: the downloader case ${label} ran" "$out"
        IFS=$'\t' read -r _ case_result case_reason case_requests case_status <<< "$line"
        assert_eq "$result" "$case_result" "S102: ${label} gives ${result} (${case_reason})"
        [[ "${case_reason,,}" == *"${reason//_/ }"* ]] ||
            _fail "S102: the ${label} reason names '${reason//_/ }'" "$line"
        [[ "$requests" == "-" ]] || assert_eq "$requests" "$case_requests" "S102: ${label} makes ${requests} requests"
        if [[ "$result" == PASS ]]; then
            assert_eq "0" "$case_status" "S102: ${label} returns status 0"
        else
            assert_ne "0" "$case_status" "S102: ${label} returns a non-zero status"
        fi
    done <<'EOF'
ok PASS - 3
long_body FAIL longer -
short_body NOT_VERIFIED ended -
changed_bytes FAIL sha-256 -
redirect NOT_VERIFIED 302 1
network_denied NOT_VERIFIED network 1
content_encoding NOT_VERIFIED content-encoding 1
foreign_url FAIL url 0
lock_mismatch FAIL lock 0
escape_member FAIL unsafe_member -
absolute_member FAIL unsafe_member -
link_member FAIL link -
duplicate_member FAIL duplicate -
metadata_differs FAIL metadata -
unlisted_requirement FAIL requirement -
missing_requirement FAIL requirement -
unsatisfied_requirement FAIL requirement -
marker_requirement NOT_VERIFIED marker -
path_collision FAIL installed_path -
name_differs FAIL name -
unsupported_tag NOT_VERIFIED tag -
expanded_limit NOT_VERIFIED expanded -
interpreter NOT_VERIFIED interpreter 0
root_not_empty NOT_VERIFIED not_empty 0
root_mode NOT_VERIFIED mode 0
EOF
    assert_eq "files.pythonhosted.org:443:2:True:" "$(awk -F '\t' '$1 == "ok-connect" { print $2 }' <<< "$out")" \
        "S102: each request uses files.pythonhosted.org on port 443 with certificate and host-name verification"
    assert_contains "$out" $'ok-paths\t/packages/aa/bb/' "S102: the requests use the exact manifest paths"
    assert_not_contains "$(grep '^ok-headers' <<< "$out")" "Authorization" "S102: no request sends a credential"
    assert_contains "$out" $'ok-files\talpha-1.0-py3-none-any.whl;beta-2.0-py3-none-any.whl|pip-25.2-py3-none-any.whl' \
        "S102: the verified wheels and the installer are in their two directories, with no partial file"
    assert_contains "$out" $'ok-tsv\t3\t3' "S102: fetch.tsv and wheels.tsv record PASS for each artifact"

    # The bounded streams: 65536 bytes are kept on each stream and the rest is
    # counted, so a producer never blocks and no record grows past the limit.
    cat > "${workspace}/streams.py" <<'PY'
import os, sys
ns = {"__name__": "vp_unit"}
exec(compile(open(sys.argv[1]).read(), "vp-fetch", "exec"), ns)
state = ns["bound_streams"]()
sys.stdout.write("o" * 200000)
sys.stderr.write("e" * 100000)
counts = ns["close_streams"](state)
open(sys.argv[2], "w").write("%(out_kept)d %(out_dropped)d %(err_kept)d %(err_dropped)d" % counts)
PY
    /usr/bin/python3.12 -I "${workspace}/streams.py" "${workspace}/fetch.py" "${workspace}/streams.counts" \
        > "${workspace}/streams.out" 2> "${workspace}/streams.err" || _fail "S102: the stream check runs"
    assert_eq "65536 134464 65536 34464" "$(cat "${workspace}/streams.counts")" "S102: each stream keeps 65536 bytes"
    assert_eq "65536 65536" "$(wc -c < "${workspace}/streams.out") $(wc -c < "${workspace}/streams.err")" \
        "S102: the two log files hold 65536 bytes each"

    # The installer bootstrap, with the exact vector and a controlled pip wheel
    # that records what it gets. The bootstrap checks the wheel and the vector
    # before pip runs.
    cat > "${workspace}/fake_pip.py" <<'PY'
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(sys.argv[0])))
from vp_fakes import task_root, wheel, metadata
def make(root, kind):
  main = (b"import json, os, resource, sys\n"
        b"target = [a for a in sys.argv if a.startswith('--target=')][0][len('--target='):]\n"
        b"limits = {n: resource.getrlimit(getattr(resource, n))[0] for n in ('RLIMIT_AS', 'RLIMIT_CPU', 'RLIMIT_CORE', 'RLIMIT_FSIZE')}\n"
        b"json.dump({'argv': sys.argv[1:], 'config': os.environ.get('PIP_CONFIG_FILE'), 'tmpdir': os.environ.get('TMPDIR'),\n"
        b"           'limits': limits, 'path': sys.path, 'bytecode': sys.dont_write_bytecode},\n"
        b"          open(os.path.join(target, 'fake-pip.json'), 'w'))\n"
        b"if os.environ.get('AB_FAKE_PIP_FLOOD'):\n"
        b"    sys.stdout.write('p' * 100000)\n"
        b"sys.exit(0)\n")
  file, data, meta = wheel("pip", "25.2", files={"pip/__init__.py": b"", "pip/__main__.py": main})
  pip_row = ("installer", "pip", "25.2", file, b"wrong" if kind == "hash" else data, meta)
  task_root(root, [("runtime", "alpha", "1.0", "alpha-1.0-py3-none-any.whl", b"a", metadata("alpha", "1.0")), pip_row])
  open(os.path.join(root, "installer", file), "wb").write(data)
for kind in sys.argv[2:]:
  make(os.path.join(sys.argv[1], "install_" + kind), kind)
PY
    /usr/bin/python3.12 -I "${workspace}/fake_pip.py" "$workspace" ok flood hash vector config ||
        _fail "S102: the installer roots are made"
    for kind in ok flood hash vector config; do
        root="${workspace}/install_${kind}"
        pip="${root}/installer/pip-25.2-py3-none-any.whl"
        args=(--isolated --disable-pip-version-check install --no-index "--find-links=${root}/wheels" --require-hashes
              --only-binary=:all: --no-cache-dir --no-compile "--target=${root}/site" "--requirement=${root}/requirements.lock")
        [[ "$kind" != vector ]] || args+=(--no-deps)
        if [[ "$kind" == config ]]; then
            env -u PIP_CONFIG_FILE TMPDIR="${root}/tmp" /usr/bin/python3.12 -I - "$pip" "${args[@]}" \
                < "${workspace}/install.py" > "${root}/records/install.out" 2> "${root}/records/install.err" && status=0 || status=$?
        else
            env PIP_CONFIG_FILE=/dev/null TMPDIR="${root}/tmp" AB_FAKE_PIP_FLOOD="$([[ "$kind" == flood ]] && echo 1)" \
                /usr/bin/python3.12 -I - "$pip" "${args[@]}" \
                < "${workspace}/install.py" > "${root}/records/install.out" 2> "${root}/records/install.err" && status=0 || status=$?
        fi
        result="$(ab_file_value "${root}/records/install.env" INSTALL_RESULT)"
        case "$kind" in
            ok)
                assert_eq "0 PASS" "${status} ${result}" "S102: the controlled install passes"
                assert_eq "0" "$(ab_file_value "${root}/records/install.env" PIP_EXIT)" "S102: install.env records the pip status"
                /usr/bin/python3.12 -I - "${root}/site/fake-pip.json" "$root" > "${workspace}/pip_seen.txt" <<'PY' ||
import json, sys
seen = json.load(open(sys.argv[1]))
root = sys.argv[2]
print("argv=" + " ".join(seen["argv"]))
print("config=%s tmpdir=%s" % (seen["config"], seen["tmpdir"]))
print("limits=%(RLIMIT_AS)s %(RLIMIT_CPU)s %(RLIMIT_CORE)s %(RLIMIT_FSIZE)s" % seen["limits"])
print("first=" + seen["path"][0])
print("third_party=" + str(sum(1 for p in seen["path"] if "packages" in p)))
print("bytecode=%s" % seen["bytecode"])
PY
                    _fail "S102: the fake pip record is readable"
                assert_contains "$(cat "${workspace}/pip_seen.txt")" "argv=${args[*]}" "S102: pip gets the exact approved vector"
                assert_contains "$(cat "${workspace}/pip_seen.txt")" "config=/dev/null tmpdir=${root}/tmp" \
                    "S102: pip gets PIP_CONFIG_FILE=/dev/null and the task TMPDIR"
                assert_contains "$(cat "${workspace}/pip_seen.txt")" "limits=4294967296 60 0 1073741824" \
                    "S102: the installer has the address-space, CPU, core, and file-size limits"
                assert_contains "$(cat "${workspace}/pip_seen.txt")" "first=${pip}" "S102: the verified pip wheel is first on the path"
                assert_contains "$(cat "${workspace}/pip_seen.txt")" "third_party=0" "S102: no third-party path is on the installer path"
                assert_contains "$(cat "${workspace}/pip_seen.txt")" "bytecode=True" "S102: the installer writes no bytecode"
                ;;
            flood)
                assert_eq "NOT_VERIFIED" "$result" "S102: installer output past the stream limit is NOT_VERIFIED"
                assert_eq "65536" "$(wc -c < "${root}/records/install.out")" "S102: the installer log keeps 65536 bytes"
                ;;
            hash|vector|config)
                assert_ne "0" "$status" "S102: the ${kind} install fails"
                assert_eq "FAIL" "$result" "S102: the ${kind} install is FAIL"
                assert_file_missing "${root}/site/fake-pip.json" "S102: pip never runs after the ${kind} check"
                ;;
        esac
    done

    # The distribution and import check, with the exact vector on a controlled
    # site. A pure-Python vtkmodules is not the native consumer.
    ab_vp_fake_site "${workspace}/fake_site.py"
    /usr/bin/python3.12 -I "${workspace}/fake_site.py" "$workspace" native version no_module link unlisted changed no_dist metadata ||
        _fail "S102: the controlled sites are made"
    while read -r kind result reason; do
        root="${workspace}/verify_${kind}"
        env AB_FAKE_LIMITS="${workspace}/limits_${kind}" AB_FAKE_VTK_VERSION="$([[ "$kind" == version ]] && echo 9.4.0 || echo 9.5.2)" \
            /usr/bin/python3.12 -I - "${root}/site" < "${workspace}/verify.py" \
            > "${root}/records/verify.out" 2> "${root}/records/verify.err" && status=0 || status=$?
        assert_eq "$result" "$(ab_file_value "${root}/records/verify.env" VERIFY_RESULT)" \
            "S102: the ${kind} site gives ${result} ($(ab_file_value "${root}/records/verify.env" VERIFY_REASON))"
        line="$(ab_file_value "${root}/records/verify.env" VERIFY_REASON)"
        [[ "${line,,}" == *"${reason//_/ }"* ]] || _fail "S102: the ${kind} reason names '${reason//_/ }'" "$line"
        assert_ne "0" "$status" "S102: the ${kind} check returns a non-zero status"
    done <<'EOF'
native NOT_VERIFIED native
version NOT_VERIFIED 9.4.0
no_module NOT_VERIFIED vtkmodules
link FAIL link
unlisted FAIL not_listed
changed FAIL sha-256
no_dist FAIL beta
metadata FAIL metadata
EOF
    assert_contains "$(cat "${workspace}/limits_native")" "Max address space         4294967296" \
        "S102: the import check has the address-space limit"
    assert_contains "$(cat "${workspace}/limits_native")" "Max cpu time              60" "S102: the import check has the CPU limit"
    assert_contains "$(cat "${workspace}/limits_native")" "Max core file size        0" "S102: the import check writes no core file"
    assert_not_contains "$(ab_file_value "${workspace}/verify_no_module/records/verify.env" VERIFY_REASON)" "/usr/lib/python3" \
        "S102: a system vtkmodules is never a fallback"
}

# ab_vp_value <file> <key> - the one value of <key>, or DUPLICATE or MISSING.
ab_vp_value() {
    awk -v key="$2" 'index($0, key "=") == 1 { n++; value = substr($0, length(key) + 2) }
                     END { if (n == 1) print value; else if (n > 1) print "DUPLICATE"; else print "MISSING" }' "$1"
}

s103_provision_ci_consumer_is_available() {
    local root workspace records file key bytes name value row
    root="${AB_VTU_DEP_ROOT:-}"
    [[ -n "$root" ]] || _fail "S103: the native tests need the task root of the contract-tests provision step in M3_VTU_DEP_ROOT, and none is set. A local run needs a separately authorized pre-provisioned environment with the same manifest; no test installs a package."
    workspace="$(new_workspace s103_ci_root)"
    records="${root}/records"
    assert_dir_exists "$records" "S103: the provision records exist"
    for file in "$records"/*; do
        bytes="$(wc -c < "$file")"
        (( bytes <= 65536 )) || _fail "S103: the record ${file##*/} holds at most 65536 bytes" "bytes: ${bytes}"
    done

    # The receipt binds the root, the block, the manifest, and the result.
    ab_vp_block "$CONTRACT_WORKFLOW" "$AB_VP_STEP" > "${workspace}/block.sh"
    ab_vp_expected_manifest > "${workspace}/manifest.tsv"
    ab_vp_expected_lock > "${workspace}/requirements.lock"
    ab_vp_expected_requires > "${workspace}/requires.tsv"
    for key in PROVISION_SCHEMA=m3-vtu-provision/1 PROVISION_RESULT=PROVISION_AVAILABLE "PROVISION_ROOT=${root}" \
               "PROVISION_PARENT=${root%/*}" PROVISION_FETCH_RESULT=PASS PROVISION_INSTALL_RESULT=PASS \
               PROVISION_VERIFY_RESULT=PASS PROVISION_CLEANUP=REMOVED PROVISION_PYTHON=/usr/bin/python3.12 \
               "PROVISION_BLOCK_SHA256=$(sha256sum < "${workspace}/block.sh" | cut -d ' ' -f 1)" \
               "PROVISION_MANIFEST_SHA256=$(sha256sum < "${workspace}/manifest.tsv" | cut -d ' ' -f 1)" \
               "PROVISION_LOCK_SHA256=$(sha256sum < "${workspace}/requirements.lock" | cut -d ' ' -f 1)" \
               "PROVISION_REQUIRES_SHA256=$(sha256sum < "${workspace}/requires.tsv" | cut -d ' ' -f 1)"; do
        assert_eq "${key#*=}" "$(ab_vp_value "${records}/result.env" "${key%%=*}")" "S103: result.env has ${key}"
    done
    [[ "$(tail -n 1 "${records}/result.env")" =~ ^WORK_FINISH=[0-9]+$ ]] || _fail "S103: result.env ends with WORK_FINISH"
    (( $(ab_vp_value "${records}/result.env" PROVISION_FINISH_MS) - $(ab_vp_value "${records}/result.env" PROVISION_START_MS) <= 90000 )) ||
        _fail "S103: the provision ended within 90 seconds"
    assert_eq "" "$(cmp "${workspace}/manifest.tsv" "${root}/manifest.tsv" 2>&1)" "S103: the task manifest is the approved manifest"
    assert_eq "" "$(cmp "${workspace}/requirements.lock" "${root}/requirements.lock" 2>&1)" "S103: the task lock is the approved lock"

    # Each of the thirteen archives has the registered bytes and SHA-256, and
    # its embedded METADATA is the published core metadata.
    assert_eq "13" "$(awk -F '\t' 'NR > 1 && $11 == "PASS" && $6 == $8 && $7 == $9 && $10 == 200' "${records}/fetch.tsv" | wc -l)" \
        "S103: all thirteen downloads have the registered bytes and SHA-256"
    assert_eq "$(cut -f 2-7 "${workspace}/manifest.tsv" | tail -n +2)" \
        "$(awk -F '\t' 'NR > 1 { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 }' "${records}/fetch.tsv")" \
        "S103: fetch.tsv covers exactly the manifest rows"
    assert_eq "13" "$(awk -F '\t' 'NR > 1 && $8 == "PASS"' "${records}/wheels.tsv" | wc -l)" \
        "S103: all thirteen archives pass the ZIP, METADATA, tag, and closure checks"
    assert_eq "$(cut -f 8,9 "${workspace}/manifest.tsv" | tail -n +2)" \
        "$(awk -F '\t' 'NR > 1 { print $4 "\t" $5 }' "${records}/wheels.tsv")" \
        "S103: each embedded METADATA has the published bytes and SHA-256"
    for key in FETCH_RESULT=PASS ARCHIVES=13 ARCHIVE_BYTES=154218283 PYTHON_EXECUTABLE=/usr/bin/python3.12 \
               PYTHON_IMPLEMENTATION=cpython PYTHON_SOABI=cpython-312-x86_64-linux-gnu PYTHON_MACHINE=x86_64; do
        assert_eq "${key#*=}" "$(ab_vp_value "${records}/fetch.env" "${key%%=*}")" "S103: fetch.env has ${key}"
    done
    (( $(ab_vp_value "${records}/fetch.env" EXPANDED_BYTES) <= 1073741824 )) || _fail "S103: the declared expanded bytes are in the limit"
    [[ "$(ab_vp_value "${records}/fetch.env" PYTHON_VERSION)" == 3.12.* ]] || _fail "S103: the interpreter is CPython 3.12"
    assert_eq "PASS 0" "$(ab_vp_value "${records}/install.env" INSTALL_RESULT) $(ab_vp_value "${records}/install.env" PIP_EXIT)" \
        "S103: the offline install passed"

    # The installed closure and the native consumer.
    for key in VERIFY_RESULT=PASS VTK_VERSION=9.5.2 \
               "DISTRIBUTIONS=$(awk -F '\t' 'NR > 1 && $1 == "runtime" { printf "%s%s==%s", sep, $2, $3; sep = " " }' "${workspace}/manifest.tsv")"; do
        assert_eq "${key#*=}" "$(ab_vp_value "${records}/verify.env" "${key%%=*}")" "S103: verify.env has ${key}"
    done
    assert_eq "12" "$(awk -F '\t' 'NR > 1 && $6 == "PASS"' "${records}/installed.tsv" | wc -l)" \
        "S103: all twelve distributions have a complete RECORD"
    [[ "$(ab_vp_value "${records}/verify.env" VTK_MODULE)" == "${root}/site/vtkmodules/"* ]] ||
        _fail "S103: the consumer module comes from the task site"
    assert_ne "0" "$(awk -F '\t' 'NR > 1 && $2 == "site" && $1 ~ /libvtkCommonCore/' "${records}/libraries.tsv" | wc -l)" \
        "S103: libraries.tsv records the loaded native VTK library"
    (( $(ab_vp_value "${records}/verify.env" TASK_BYTES) <= 3221225472 )) || _fail "S103: the task bytes are in the checkpoint limit"

    # The commands: the three fixed vectors, each in its limit, each group
    # stopped.
    assert_eq "fetch install verify" "$(awk -F '\t' 'NR > 1 && $7 == "COMPLETED" && $6 == 0 && $9 != "NOT_STOPPED" { printf "%s%s", sep, $2; sep = " " }' "${records}/commands.tsv")" \
        "S103: the fetch, install, and verify operations completed with status 0"
    while IFS=$'\t' read -r name value; do
        assert_eq "1" "$(awk -F '\t' -v n="$name" -v l="$value" 'NR > 1 && $2 == n && $3 <= l' "${records}/commands.tsv" | wc -l)" \
            "S103: the ${name} limit is at most ${value} ms"
    done <<'EOF'
fetch	30000
install	35000
verify	10000
EOF
    assert_contains "$(awk -F '\t' '$2 == "install" { print $11 }' "${records}/commands.tsv")" \
        "PIP_CONFIG_FILE=/dev/null TMPDIR=${root}/tmp timeout --signal=TERM --kill-after=5s" \
        "S103: commands.tsv records the expanded install vector"

    # The cleanup: the archives and the installer data are gone; the site stays.
    assert_eq "installer manifest.tsv records requirements.lock requires.tsv site tmp wheels" "$(ls "$root" | paste -sd ' ' -)" \
        "S103: the task root holds only the named paths"
    assert_eq "" "$(ls -A "${root}/wheels" "${root}/installer" "${root}/tmp" | grep -v -e '^$' -e ':$' || true)" \
        "S103: the verified archives and the installer data are removed"
    assert_ne "" "$(ls -A "${root}/site")" "S103: the site directory stays for the consumer"
}


# ---- S104 to S107: the focused VTU readback (Issue #80) --------------------

# ab_vr_block - the readback block of the capture work, from the begin marker
# line through the end marker line and its line end. The awk program reads to
# the end, so pipefail sees no SIGPIPE.
ab_vr_block() {
    ab_step_run_body "Capture the evidence" | awk '
        done { next }
        $0 == "# ---- VTU readback: begin ----" { inside = 1 }
        inside { print }
        inside && $0 == "# ---- VTU readback: end ----" { inside = 0; done = 1 }'
}

# ab_vr_constant <name> - the value of the one VR_<name>= line of the block.
ab_vr_constant() {
    ab_vr_block | awk -v key="VR_${1}=" 'index($0, key) == 1 { n++; value = substr($0, length(key) + 1) }
                                        END { if (n == 1) print value }'
}

# ab_vr_reader <file> - write the fixed reader program VR_READER_PY.
ab_vr_reader() {
    ab_vr_block > "${1}.block"
    ab_vp_heredoc "${1}.block" VR_READER_PY > "$1"
    [[ -s "$1" ]] || _fail "the capture work must hold the reader program VR_READER_PY"
}

# ab_vr_need_root <label> - the provisioned task root of the contract-tests job.
ab_vr_need_root() {
    [[ -n "${AB_VTU_DEP_ROOT:-}" ]] ||
        _fail "${1}: the native readback tests need the task root of the contract-tests provision step in M3_VTU_DEP_ROOT, and none is set. A local run needs a separately authorized pre-provisioned environment with the same manifest; no test installs a package."
}

# ab_vr_vtus <directory> - write the controlled VTU files and cases.tsv (label,
# role, file). One hexahedron of 8 points (a VTK_POLYHEDRON cube in poly) with
# PointData U (3 components), p, and, for time 0, wallDistance, and CellData
# cellId. The writer uses only the Python standard library and the VTK 9.5.2
# XML layout: inline ASCII, inline base64 binary, appended raw and base64 with
# a UInt64 header, zlib compression, and the legacy faces and faceoffsets
# arrays. The bad files each change one thing.
ab_vr_vtus() {
    mkdir -p "$1"
    cat > "${1}/make.py" <<'PY'
import base64, os, struct, sys, zlib

out = sys.argv[1]
CODE = {"Float32": "f", "Int32": "i", "Int64": "q", "UInt8": "B"}
POINTS = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0), (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]
FACES = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]]

def arrays(time_zero=True, poly=False, drop=(), cell_u=False, u_components=3, p_values=8):
    stream = [len(FACES)] + [v for f in FACES for v in [len(f)] + f]
    a = [("Points", "Points", "Float32", 3, [float(c) for p in POINTS for c in p]),
         ("Cells", "connectivity", "Int64", 1, list(range(8))), ("Cells", "offsets", "Int64", 1, [8]),
         ("Cells", "types", "UInt8", 1, [42 if poly else 12])]
    if poly:
        a += [("Cells", "faces", "Int64", 1, stream), ("Cells", "faceoffsets", "Int64", 1, [len(stream)])]
    a += [("CellData", "cellId", "Int32", 1, [7])]
    if cell_u:
        a += [("CellData", "U", "Float32", 3, [1.0, 2.0, 3.0])]
    else:
        u = [float(i % 5) for i in range(8 * u_components)]
        a += [("PointData", "U", "Float32", u_components, u)]
    a += [("PointData", "p", "Float32", 1, [float(i) for i in range(p_values)])]
    if time_zero:
        a += [("PointData", "wallDistance", "Float32", 1, [0.5] * 8)]
    return [x for x in a if x[1] not in drop]

def vtu(arrs, fmt="appended", encoding="raw", compress=False, pieces=1, kind="UnstructuredGrid", marker=True):
    hs, hcode = 8, "Q"
    chunks, offset = [], 0
    def block(raw):
        if compress:
            packed = zlib.compress(raw)
            return struct.pack("<4" + hcode, 1, 32768, len(raw), len(packed)), packed
        return struct.pack("<" + hcode, len(raw)), raw
    lines = ['<?xml version="1.0"?>',
             '<VTKFile type="%s" version="1.0" byte_order="LittleEndian" header_type="UInt64"%s>'
             % (kind, ' compressor="vtkZLibDataCompressor"' if compress else ""), "<%s>" % kind]
    for _ in range(pieces):
        lines.append('<Piece NumberOfPoints="8" NumberOfCells="1">')
        for group in ("Points", "Cells", "CellData", "PointData"):
            members = [x for x in arrs if x[0] == group]
            if not members:
                continue
            lines.append("<%s>" % group)
            for _, name, typ, comps, values in members:
                head = 'type="%s" Name="%s" NumberOfComponents="%d"' % (typ, name, comps)
                raw = struct.pack("<%d%s" % (len(values), CODE[typ]), *values)
                if fmt == "ascii":
                    text = " ".join(repr(v) if isinstance(v, float) else str(v) for v in values)
                    lines.append('<DataArray %s format="ascii">%s</DataArray>' % (head, text))
                elif fmt == "binary":
                    header, data = block(raw)
                    lines.append('<DataArray %s format="binary">%s</DataArray>' % (head, base64.b64encode(header + data).decode()))
                else:
                    header, data = block(raw)
                    if encoding == "raw":
                        chunk = header + data
                    else:
                        chunk = (base64.b64encode(header) + base64.b64encode(data)) if compress else base64.b64encode(header + data)
                    lines.append('<DataArray %s format="appended" offset="%d"/>' % (head, offset))
                    chunks.append(chunk)
                    offset += len(chunk)
            lines.append("</%s>" % group)
        lines.append("</Piece>")
    lines.append("</%s>" % kind)
    text = ("\n".join(lines) + "\n").encode()
    payload = b"".join(chunks)
    if fmt == "appended":
        text += ('<AppendedData encoding="%s">\n' % encoding).encode() + (b"_" if marker else b"") + payload
        text += b"\n</AppendedData>\n"
    return text + b"</VTKFile>\n"

def write(name, data):
    with open(os.path.join(out, name), "wb") as f:
        f.write(data)

cases = []
def case(label, role, data):
    write(label + ".vtu", data)
    cases.append("%s\t%s\t%s.vtu" % (label, role, label))

case("valid_ascii", "time0", vtu(arrays(), fmt="ascii"))
case("valid_binary", "time0", vtu(arrays(), fmt="binary"))
case("valid_raw", "time0", vtu(arrays()))
case("valid_base64", "time0", vtu(arrays(), encoding="base64"))
case("valid_zlib", "time0", vtu(arrays(), compress=True))
case("valid_poly", "time0", vtu(arrays(poly=True)))
case("latest_raw", "latest", vtu(arrays(time_zero=False)))
whole = vtu(arrays())
end = whole.index(b"\n</AppendedData>")
case("truncated_raw", "time0", whole[:end - 10])
zipped = vtu(arrays(), compress=True)
start = zipped.index(b"_", zipped.index(b"<AppendedData")) + 1 + 8 * 4 + 2
case("corrupt_zlib", "time0", zipped[:start] + bytes([zipped[start] ^ 0xFF]) + zipped[start + 1:])
case("missing_u", "time0", vtu(arrays(drop=("U",)), fmt="ascii"))
case("celldata_u", "time0", vtu(arrays(cell_u=True), fmt="ascii"))
case("wrong_components", "time0", vtu(arrays(u_components=1), fmt="ascii"))
case("short_p", "time0", vtu(arrays(p_values=7), fmt="ascii"))
case("no_points", "time0", vtu(arrays(drop=("Points",)), fmt="ascii"))
case("incomplete_cells", "time0", vtu(arrays(drop=("offsets",)), fmt="ascii"))
text = vtu(arrays(), fmt="ascii")
case("bad_xml", "time0", text.replace(b"</Piece>", b"</Piec>"))
case("poly_no_faces", "time0", vtu([x for x in arrays(poly=True) if x[1] not in ("faces", "faceoffsets")], fmt="ascii"))
case("no_wall_distance", "time0", vtu(arrays(time_zero=False), fmt="ascii"))
case("multi_piece", "time0", vtu(arrays(), fmt="ascii", pieces=2))
case("not_unstructured", "time0", vtu(arrays(), fmt="ascii", kind="PolyData"))
case("no_marker", "time0", vtu(arrays(), marker=False))
with open(os.path.join(out, "cases.tsv"), "w") as f:
    f.write("\n".join(cases) + "\n")
PY
    /usr/bin/python3.12 -I "${1}/make.py" "$1" || _fail "the controlled VTU files must be written"
}

# ab_vr_env <root> - print the environment of a reader run with <root>.
ab_vr_env() {
    printf '%s\n' "M3_VTU_DEP_ROOT=$1" "RUNNER_TEMP=${1%/*}" \
        "VR_PROVISION_BLOCK_SHA256=$(ab_vr_constant PROVISION_BLOCK_SHA256)" \
        "VR_MANIFEST_SHA256=$(ab_vr_constant MANIFEST_SHA256)"
}

s104_readback_native_reads_controlled_vtus() {
    local workspace out line label result reason keyword expected
    ab_vr_need_root S104
    workspace="$(new_workspace s104_native)"
    ab_vr_reader "${workspace}/reader.py"
    ab_vr_vtus "${workspace}/vtus"
    cat > "${workspace}/driver.py" <<'PY'
import os, sys
ns = {"__name__": "vr_unit"}
exec(compile(open(sys.argv[1]).read(), "vr-reader", "exec"), ns)
identity = ns["consumer"]()
print("identity\t" + "\t".join("%s=%s" % pair for pair in sorted(identity.items())))
vtus = sys.argv[2]
for line in open(os.path.join(vtus, "cases.tsv")):
    label, role, file = line.rstrip("\n").split("\t")
    r = ns["read_one"](os.path.join(vtus, file), role)
    print("\t".join([label, r["result"], r["reason"], str(r["points"]), str(r["cells"]), str(len(r["messages"])), r["extent"]]))
    print("arrays\t%s\t%s" % (label, ";".join("%(association)s:%(name)s:%(components)s:%(tuples)s" % a for a in r["arrays"])))
# A diagnostic only: the plain native consumer on the truncated payload.
from vtkmodules.vtkIOXML import vtkXMLUnstructuredGridReader
from vtkmodules.vtkCommonCore import vtkCommand
reader, events = vtkXMLUnstructuredGridReader(), []
reader.AddObserver(vtkCommand.ErrorEvent, lambda *a: events.append(1))
reader.SetFileName(os.path.join(vtus, "truncated_raw.vtu"))
reader.Update()
print("diagnostic\ttruncated_raw\tnative_error_events=%d\terror_code=%d\tpoints=%d" % (
    len(events), reader.GetErrorCode(), reader.GetOutput().GetNumberOfPoints()))
PY
    out="$(env $(ab_vr_env "$AB_VTU_DEP_ROOT") /usr/bin/python3.12 -I "${workspace}/driver.py" \
        "${workspace}/reader.py" "${workspace}/vtus" 2> "${workspace}/driver.err")" ||
        _fail "S104: the reader functions run with the provisioned consumer" "$out" "$(tail -n 20 "${workspace}/driver.err")"
    printf '%s\n' "$out" > "${workspace}/results.tsv"
    printf '%s\n' "$out" | grep -E '^(identity|diagnostic)' || true
    assert_contains "$(grep '^identity' <<< "$out")" "VTK_VERSION=9.5.2" "S104: the consumer is VTK 9.5.2"
    assert_contains "$(grep '^identity' <<< "$out")" "CONSUMER=vtkmodules.vtkIOXML.vtkXMLUnstructuredGridReader" \
        "S104: the consumer is the native XML unstructured-grid reader"
    assert_contains "$(grep '^identity' <<< "$out")" "VTK_MODULE=${AB_VTU_DEP_ROOT}/site/vtkmodules/" \
        "S104: the consumer comes from the provisioned site"

    while read -r label expected keyword; do
        line="$(awk -F '\t' -v want="$label" '$1 == want' <<< "$out")"
        [[ -n "$line" ]] || _fail "S104: the case ${label} ran" "$out"
        IFS=$'\t' read -r _ result reason _ <<< "$line"
        assert_eq "$expected" "$result" "S104: ${label} gives ${expected} (${reason})"
        [[ "$keyword" == - || "${reason,,}" == *"${keyword//_/ }"* ]] ||
            _fail "S104: the ${label} reason names '${keyword//_/ }'" "$line"
    done <<'EOF'
valid_ascii PASS -
valid_binary PASS -
valid_raw PASS -
valid_base64 PASS -
valid_zlib PASS -
valid_poly PASS -
latest_raw PASS -
truncated_raw FAIL appended
corrupt_zlib FAIL error
missing_u FAIL required_pointdata_u
celldata_u FAIL celldata
wrong_components FAIL components
short_p FAIL error
no_points FAIL error
incomplete_cells FAIL error
bad_xml FAIL xml
poly_no_faces FAIL polyhedron
no_wall_distance FAIL walldistance
multi_piece NOT_VERIFIED piece
not_unstructured NOT_VERIFIED unstructuredgrid
no_marker NOT_VERIFIED warning
EOF
    # Complete loaded-array evidence of a full read.
    assert_eq "POINTS:Points:3:8;CELLS:connectivity:1:8;CELLS:offsets:1:1;CELLS:types:1:1;CELL_DATA:cellId:1:1;POINT_DATA:U:3:8;POINT_DATA:p:1:8;POINT_DATA:wallDistance:1:8" \
        "$(awk -F '\t' '$1 == "arrays" && $2 == "valid_raw" { print $3 }' <<< "$out")" \
        "S104: the full read records the geometry and each array with its components and tuples"
    assert_contains "$(awk -F '\t' '$1 == "arrays" && $2 == "valid_poly" { print $3 }' <<< "$out")" \
        "POLYHEDRON:faces:1:" "S104: the polyhedron read records the loaded face data"
    assert_eq "8 1 CHECKED" "$(awk -F '\t' '$1 == "valid_raw" { print $4, $5, $7 }' <<< "$out")" \
        "S104: the appended raw read has 8 points, 1 cell, and a checked appended extent"
    assert_eq "NATIVE" "$(awk -F '\t' '$1 == "valid_zlib" { print $7 }' <<< "$out")" \
        "S104: a compressed payload is checked by the native block sizes"
}

# ab_vr_library <workspace> - the capture work helpers before the VTU reader,
# the functional-receipt block, and the readback block, from the extracted
# capture step.
ab_vr_library() {
    local step="${1}/capture_step.sh"
    ab_fr_library "$1"
    awk '/^# ---- VTU readback: begin ----$/ { inside = 1 } inside && !done { print }
         /^# ---- VTU readback: end ----$/ { done = 1 }' "$step"
}

# ab_vr_template <workspace> <time0-vtu> <latest-vtu> - the controlled receipt
# fixture of S94 with the two given flow VTU files of time 2, their scanner
# evidence, and one receipt run. Each readback case copies this template.
ab_vr_template() {
    local workspace="$1" vtk run
    ab_fr_fixture "$workspace"
    vtk="${workspace}/checkout/src/batch_9/case_7/vtk"
    cp -- "$2" "${vtk}/flow_0.vtu"
    cp -- "$3" "${vtk}/flow_latest_2.vtu"
    ab_fr_scanner_evidence "$workspace"
    run="$(ab_fr_unit "$workspace")"
    assert_contains "$run" "status=0" "the template receipt run ends with status 0"
    assert_eq "PASS PASS" "$(ab_fr_check "$workspace" F2) $(ab_fr_check "$workspace" F3)" \
        "the template receipt binds the latest time 2"
}

# ab_vr_unit <workspace> [NAME=value ...] - run the extracted readback alone,
# as the capture work calls it after the receipt, with a far capture work end,
# the product result SUCCEEDED, and the producer of the receipt template. The
# arguments override the environment. The library is a script file, because
# it is longer than one command-line argument can be. Prints status=.
ab_vr_unit() {
    local workspace="$1" status
    shift
    { ab_vr_library "$workspace"; printf '\nvr_capture\n'; } > "${workspace}/vr_unit.sh"
    grep -qx '# ---- VTU readback: end ----' "${workspace}/vr_unit.sh" ||
        { _fail "the readback block of the capture work must be extracted"; return 1; }
    env PATH="${workspace}/fakebin:${PATH}" TMPDIR="${workspace}/tmp" \
        RUNNER_TEMP="${workspace}/runner_temp" EVIDENCE_DIR="${workspace}/runner_temp/evidence" \
        GITHUB_WORKSPACE="${workspace}/checkout" CAPTURE_WORK_END="$(( $(date +%s) + 1000 ))" \
        GITHUB_SHA="$AB_COLLECT_SHA" GITHUB_RUN_ID=4545 GITHUB_RUN_ATTEMPT=1 \
        GITHUB_REPOSITORY=derek-thl/ucfd_run_batch GITHUB_WORKFLOW=openfoam-evidence GITHUB_JOB=evidence \
        PREPARE_RESULT=SUCCEEDED OVERALL_RESULT=SUCCEEDED M3_VTU_PROVISION_RESULT=PROVISION_AVAILABLE \
        "$@" "${AB_STEP_BASH[@]}" "${workspace}/vr_unit.sh" > "${workspace}/vr_unit.out" 2>&1 && status=0 || status=$?
    printf 'status=%s\n' "$status"
}

# ab_vr_dir <workspace> - the readback subtree.
ab_vr_dir() {
    printf '%s\n' "${1}/runner_temp/evidence/vtu-readback"
}

# ab_vr_value <workspace> <key> - the one value of vtu-readback/result.env.
ab_vr_value() {
    ab_vp_value "$(ab_vr_dir "$1")/result.env" "$2"
}

# ab_vr_case <template> <label> - a new workspace with a copy of the template.
ab_vr_case() {
    local workspace
    workspace="$(new_workspace "s10x_${2}")"
    cp -a -- "${1}/." "${workspace}/"
    printf '%s\n' "$workspace"
}

# ab_vr_native_rows <workspace> - the readback rows of commands.tsv.
ab_vr_native_rows() {
    awk -F '\t' '$1 == "readback"' "$(ab_vr_dir "$1")/commands.tsv" 2>/dev/null || true
}

# ab_vr_assert_records <workspace> <label> - the seven bounded text records,
# an inventory of the other six with their bytes and SHA-256, and no capture
# note.
ab_vr_assert_records() {
    local dir name bytes total=0 line
    dir="$(ab_vr_dir "$1")"
    assert_eq "arrays.tsv commands.tsv errors.txt files.tsv identity.env inventory.tsv result.env" \
        "$(ls "$dir" | paste -sd ' ' -)" "${2}: the readback keeps exactly the seven text records"
    for name in arrays.tsv commands.tsv errors.txt files.tsv identity.env inventory.tsv result.env; do
        bytes="$(wc -c < "${dir}/${name}")"
        (( bytes <= 65536 )) || _fail "${2}: ${name} holds at most 65536 bytes" "bytes: ${bytes}"
        total=$(( total + bytes ))
    done
    (( total <= 262144 )) || _fail "${2}: the readback subtree holds at most 262144 bytes" "bytes: ${total}"
    for name in arrays.tsv commands.tsv errors.txt files.tsv identity.env result.env; do
        line="$(awk -F '\t' -v n="$name" '$1 == n { print $2 "\t" $3 }' "${dir}/inventory.tsv")"
        assert_eq "$(wc -c < "${dir}/${name}" | tr -d ' ')"$'\t'"$(sha256sum < "${dir}/${name}" | cut -d ' ' -f 1)" "$line" \
            "${2}: inventory.tsv binds ${name}"
    done
    [[ "$(tail -n 1 "${dir}/result.env")" =~ ^WORK_FINISH=[0-9]+$ ]] || _fail "${2}: result.env ends with WORK_FINISH"
    assert_eq "" "$(cat "${1}/runner_temp/evidence/capture-work-notes.txt")" "${2}: a readback result gives no capture note"
}

s105_readback_capture_binds_the_two_files() {
    local base vtus template workspace root before after native line
    ab_vr_need_root S105
    root="$AB_VTU_DEP_ROOT"
    base="$(new_workspace s105_base)"
    vtus="${base}/vtus"
    ab_vr_vtus "$vtus"
    template="$(new_workspace s105_template)"
    ab_vr_template "$template" "${vtus}/valid_raw.vtu" "${vtus}/latest_raw.vtu"

    # Two full native reads of the same producer, time, and sources: PASS.
    workspace="$(ab_vr_case "$template" pass)"
    before="$(ab_fr_tree_sha "${workspace}/checkout/src")"
    assert_contains "$(ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$root" RUNNER_TEMP="${root%/*}")" "status=0" \
        "S105: the readback ends with status 0"
    after="$(ab_fr_tree_sha "${workspace}/checkout/src")"
    assert_eq "$before" "$after" "S105: the readback writes no source file"
    assert_eq "PASS PASS PASS 2" "$(ab_vr_value "$workspace" VTU_READBACK_RESULT) $(ab_vr_value "$workspace" VTU_READBACK_TIME0_RESULT) $(ab_vr_value "$workspace" VTU_READBACK_LATEST_RESULT) $(ab_vr_value "$workspace" VTU_READBACK_SELECTED_TIME)" \
        "S105: both files read completely, so the readback is PASS for time 2 ($(ab_vr_value "$workspace" VTU_READBACK_REASON))"
    ab_vr_assert_records "$workspace" "S105 pass"
    line="$(ab_vr_native_rows "$workspace")"
    assert_eq "1" "$(grep -c . <<< "$line")" "S105: one native command ran"
    assert_contains "$line" "/usr/bin/python3.12 -I - ${workspace}/checkout/src/batch_9/case_7/vtk/flow_0.vtu ${workspace}/checkout/src/batch_9/case_7/vtk/flow_latest_2.vtu $(ab_vr_dir "$workspace")" \
        "S105: commands.tsv records the exact native vector with the two sources and the evidence directory"
    assert_contains "$line" "timeout --signal=TERM --kill-after=5s " "S105: the native command has the 5-second kill grace"
    ab_vr_reader "${base}/reader.py"
    assert_contains "$line" $'\t'"$( { cat "${base}/reader.py"; printf '\n'; } | sha256sum | cut -d ' ' -f 1)"$'\t' \
        "S105: commands.tsv records the SHA-256 of the exact standard input: the reader code and the here-string line end"
    assert_eq "fetch install verify" "$(awk -F '\t' '$1 == "provision" { printf "%s%s", sep, $3; sep = " " }' "$(ab_vr_dir "$workspace")/commands.tsv")" \
        "S105: commands.tsv keeps the three provision operations"
    for line in "VTK_VERSION=9.5.2" "CONSUMER=vtkmodules.vtkIOXML.vtkXMLUnstructuredGridReader" "PROVISION_RESULT=PROVISION_AVAILABLE" \
                "PROVISION_ROOT=${root}" "PROVISION_BLOCK_SHA256=$(ab_vr_constant PROVISION_BLOCK_SHA256)" "SELECTED_TIME=2" \
                "EXECUTION_SHA=${AB_COLLECT_SHA}" "CAPABILITY_SHA=${AB_COLLECT_SHA}" "CASE_ID=case_7" "BATCH_ID=9" \
                "CHECKPOINT=POST_ORCHESTRATOR_CAPTURE"; do
        assert_eq "${line#*=}" "$(ab_vp_value "$(ab_vr_dir "$workspace")/identity.env" "${line%%=*}")" "S105: identity.env has ${line}"
    done
    assert_eq "time0 latest" "$(awk -F '\t' 'NR > 1 && $5 == $10 && $5 == $3 && $6 == $11 && $6 == $4 { printf "%s%s", sep, $1; sep = " " }' "$(ab_vr_dir "$workspace")/files.tsv")" \
        "S105: each source has the scanner bytes and SHA-256 before and after the native read"
    assert_contains "$(cat "$(ab_vr_dir "$workspace")/arrays.tsv")" $'time0\tPOINT_DATA\twallDistance\tFloat32\t1\t8\t8\tPASS' \
        "S105: arrays.tsv records the loaded wallDistance of time 0"
    assert_eq "" "$(ls -A "${root%/*}" | grep '^m3-vtu-readback\.' || true)" "S105: the readback removes its task directory"

    # One file fails: FAIL with each file result.
    workspace="$(ab_vr_case "$template" one_file)"
    cp -- "${vtus}/truncated_raw.vtu" "${workspace}/checkout/src/batch_9/case_7/vtk/flow_latest_2.vtu"
    ab_fr_scanner_evidence "$workspace"
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$root" RUNNER_TEMP="${root%/*}" > /dev/null
    assert_eq "FAIL PASS FAIL" "$(ab_vr_value "$workspace" VTU_READBACK_RESULT) $(ab_vr_value "$workspace" VTU_READBACK_TIME0_RESULT) $(ab_vr_value "$workspace" VTU_READBACK_LATEST_RESULT)" \
        "S105: a truncated latest payload fails, and time 0 keeps its PASS ($(ab_vr_value "$workspace" VTU_READBACK_REASON))"
    ab_vr_assert_records "$workspace" "S105 one file"

    # A source that changes during the native read: FAIL. The fake sha256sum
    # appends one byte to the latest file after its first readback hash.
    workspace="$(ab_vr_case "$template" changed_during)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'real=%q\n' "$(command -v sha256sum)"
        printf '"$real" "$@" && status=0 || status=$?\n'
        printf 'for argument in "$@"; do\n'
        printf '    if [[ "$argument" == *flow_latest_2.vtu && ! -e %q ]]; then\n' "${workspace}/changed"
        printf '        : > %q\n' "${workspace}/changed"
        printf '        printf "x" >> "$argument"\n'
        printf '    fi\n'
        printf 'done\n'
        printf 'exit "$status"\n'
    } > "${workspace}/fakebin/sha256sum"
    chmod +x "${workspace}/fakebin/sha256sum"
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$root" RUNNER_TEMP="${root%/*}" > /dev/null
    assert_eq "FAIL" "$(ab_vr_value "$workspace" VTU_READBACK_RESULT)" "S105: a source change during the read fails"
    assert_contains "$(ab_vr_value "$workspace" VTU_READBACK_REASON)" "changed" "S105: the reason names the changed source"
    assert_file_exists "${workspace}/changed" "S105: the source changed after its first readback hash"

    # A source that differs from its scanner record: FAIL before the native read.
    workspace="$(ab_vr_case "$template" changed_before)"
    printf 'x' >> "${workspace}/checkout/src/batch_9/case_7/vtk/flow_0.vtu"
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$root" RUNNER_TEMP="${root%/*}" > /dev/null
    assert_eq "FAIL" "$(ab_vr_value "$workspace" VTU_READBACK_RESULT)" "S105: a source that differs from the scanner record fails"
    assert_contains "$(ab_vr_value "$workspace" VTU_READBACK_REASON)" "changed" "S105: the reason names the changed source"
    assert_eq "" "$(ab_vr_native_rows "$workspace")" "S105: no native command runs on a changed source"

    # A failed product run: NOT_ATTEMPTED, and no command.
    workspace="$(ab_vr_case "$template" product)"
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$root" RUNNER_TEMP="${root%/*}" OVERALL_RESULT=FAILED_EXIT_1 > /dev/null
    assert_eq "NOT_ATTEMPTED" "$(ab_vr_value "$workspace" VTU_READBACK_RESULT)" "S105: a failed product run gives NOT_ATTEMPTED"
    assert_eq "" "$(ab_vr_native_rows "$workspace")" "S105: no native command runs after a failed product run"
    ab_vr_assert_records "$workspace" "S105 product"

    # No provision: NOT_VERIFIED, and no command.
    workspace="$(ab_vr_case "$template" no_provision)"
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT= M3_VTU_PROVISION_RESULT= > /dev/null
    assert_eq "NOT_VERIFIED" "$(ab_vr_value "$workspace" VTU_READBACK_RESULT)" "S105: no provision gives NOT_VERIFIED"
    assert_contains "$(ab_vr_value "$workspace" VTU_READBACK_REASON)" "provision" "S105: the reason names the provision"
    assert_eq "" "$(ab_vr_native_rows "$workspace")" "S105: no native command runs without the provision"

    # A missing latest witness: NOT_VERIFIED, and no command.
    workspace="$(ab_vr_case "$template" missing)"
    rm -f -- "${workspace}/checkout/src/batch_9/case_7/vtk/flow_latest_2.vtu"
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$root" RUNNER_TEMP="${root%/*}" > /dev/null
    assert_eq "NOT_VERIFIED" "$(ab_vr_value "$workspace" VTU_READBACK_RESULT)" "S105: a missing latest file gives NOT_VERIFIED"
    assert_eq "" "$(ab_vr_native_rows "$workspace")" "S105: no native command runs without both witnesses"

    # Mixed time: the signature names time 3, so the receipt does not bind the
    # latest time, and no witness is selected.
    workspace="$(ab_vr_case "$template" mixed_time)"
    sed -i -e 's/^flow_latest=2$/flow_latest=3/' "${workspace}/checkout/src/batch_9/case_7/vtk/post_processing.complete"
    rm -rf -- "$(ab_fr_dir "$workspace")"
    ab_fr_unit "$workspace" > /dev/null
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$root" RUNNER_TEMP="${root%/*}" > /dev/null
    assert_eq "NOT_VERIFIED" "$(ab_vr_value "$workspace" VTU_READBACK_RESULT)" "S105: a mixed latest time gives NOT_VERIFIED"
    assert_contains "$(ab_vr_value "$workspace" VTU_READBACK_REASON)" "time" "S105: the reason names the time binding"
    assert_eq "" "$(ab_vr_native_rows "$workspace")" "S105: no native command runs without a bound time"
}

# ab_vr_fake_root <workspace> <kind> [<parent>] - a controlled provision task
# root below <parent> (default <workspace>/runner_temp) with a complete receipt
# that names the approved block and manifest SHA-256, the approved manifest,
# and a site with a pure-Python fake vtkmodules of <kind>: hang (the import
# blocks), flood (the import writes 200000 bytes), memory (the import asks for
# 5 GiB), version (VTK 9.4.0), native (VTK 9.5.2, not native), or none (no
# vtkmodules). A fake can test the guards only; it is never the consumer.
# Prints the root.
ab_vr_fake_root() {
    local root="${3:-${1}/runner_temp}/m3-vtu-deps.Fake0001" dir
    mkdir -p "${3:-${1}/runner_temp}"
    mkdir -m 700 -- "$root"
    for dir in installer wheels site tmp records; do
        mkdir -m 700 -- "${root}/${dir}"
    done
    ab_vp_expected_manifest > "${root}/manifest.tsv"
    printf 'seq\tlabel\tlimit_ms\tstart_ms\tend_ms\tstatus\toutcome\tgroup\tstop\tcode_sha256\tvector\n1\tfetch\t30000\t1\t2\t0\tCOMPLETED\t9\tEMPTY\t-\tcontrolled\n' \
        > "${root}/records/commands.tsv"
    {
        printf 'PROVISION_SCHEMA=m3-vtu-provision/1\nPROVISION_RESULT=PROVISION_AVAILABLE\nPROVISION_REASON=controlled\n'
        printf 'PROVISION_ROOT=%s\nPROVISION_BLOCK_SHA256=%s\nPROVISION_MANIFEST_SHA256=%s\nWORK_FINISH=1\n' \
            "$root" "$(ab_vr_constant PROVISION_BLOCK_SHA256)" "$(ab_vr_constant MANIFEST_SHA256)"
    } > "${root}/records/result.env"
    if [[ "$2" != none ]]; then
        mkdir -p "${root}/site/vtkmodules"
        case "$2" in
            hang) printf 'import time\ntime.sleep(30)\n' ;;
            flood) printf 'import sys\nsys.stdout.write("v" * 200000)\nsys.stdout.flush()\n' ;;
            memory) printf 'blob = bytearray(5 * 1024 ** 3)\n' ;;
            *) printf '' ;;
        esac > "${root}/site/vtkmodules/__init__.py"
        printf 'class vtkVersion:\n    @staticmethod\n    def GetVTKVersion():\n        return "%s"\n' \
            "$([[ "$2" == version ]] && echo 9.4.0 || echo 9.5.2)" > "${root}/site/vtkmodules/vtkCommonCore.py"
    fi
    printf '%s\n' "$root"
}

# ab_vr_guard <template> <label> <kind> [NAME=value ...] - a readback unit run
# on a copy of the receipt template with a fake root of <kind>. Prints the
# workspace.
ab_vr_guard() {
    local template="$1" label="$2" kind="$3" workspace root
    shift 3
    workspace="$(ab_vr_case "$template" "$label")"
    root="$(ab_vr_fake_root "$workspace" "$kind")"
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$root" RUNNER_TEMP="${workspace}/runner_temp" "$@" > "${workspace}/guard.status"
    printf '%s\n' "$workspace"
}

# ab_vr_expect <workspace> <label> <result> <keyword> - the readback result and
# a keyword of its reason.
ab_vr_expect() {
    local reason
    reason="$(ab_vr_value "$1" VTU_READBACK_REASON)"
    assert_eq "$3" "$(ab_vr_value "$1" VTU_READBACK_RESULT)" "${2}: the readback is ${3} (${reason})"
    [[ "${reason,,}" == *"${4//_/ }"* ]] || _fail "${2}: the reason names '${4//_/ }'" "$reason" "$(tail -n 5 "${1}/vr_unit.out")"
}

s106_readback_guards_fail_closed() {
    local template workspace start elapsed group out line
    template="$(new_workspace s106_template)"
    ab_fr_fixture "$template"
    assert_contains "$(ab_fr_unit "$template")" "status=0" "S106: the template receipt run ends with status 0"

    # A native command that does not end in its limit: TIMEOUT, NOT_VERIFIED,
    # and the stopped group. The capture work end leaves at most 4 seconds for
    # it, less the time of the case setup.
    start="$(date +%s)"
    workspace="$(ab_vr_guard "$template" hang hang CAPTURE_WORK_END="$(( $(date +%s) + 29 ))")"
    elapsed=$(( $(date +%s) - start ))
    ab_vr_expect "$workspace" "S106 hang" NOT_VERIFIED "did_not_complete"
    (( elapsed <= 12 )) || _fail "S106: the readback ends shortly after the native limit" "elapsed: ${elapsed} s"
    line="$(ab_vr_native_rows "$workspace")"
    assert_contains "$line" $'\tTIMEOUT\t' "S106: commands.tsv records the TIMEOUT"
    [[ "$(cut -f 4 <<< "$line")" =~ ^[0-9]+$ ]] && (( $(cut -f 4 <<< "$line") <= 4000 )) ||
        _fail "S106: the native limit shrinks to the time left less the kill and receipt reserves" "$line"
    if pgrep -f -- "$(ab_vr_dir "$workspace")" > /dev/null 2>&1; then
        _fail "S106: no reader process of the stopped command remains"
    fi
    ab_vr_assert_records "$workspace" "S106 hang"

    workspace="$(ab_vr_guard "$template" flood flood)"
    ab_vr_expect "$workspace" "S106 flood" NOT_VERIFIED "output"
    workspace="$(ab_vr_guard "$template" memory memory)"
    ab_vr_expect "$workspace" "S106 memory" NOT_VERIFIED "memory"
    workspace="$(ab_vr_guard "$template" version version)"
    ab_vr_expect "$workspace" "S106 version" NOT_VERIFIED "9.4.0"
    workspace="$(ab_vr_guard "$template" native native)"
    ab_vr_expect "$workspace" "S106 native" NOT_VERIFIED "native"
    workspace="$(ab_vr_guard "$template" none none)"
    ab_vr_expect "$workspace" "S106 none" NOT_VERIFIED "vtkmodules"
    assert_not_contains "$(ab_vr_value "$workspace" VTU_READBACK_REASON)" "/usr/lib/python3" \
        "S106: a system vtkmodules is never a fallback"

    # Provision gaps stop the readback before any command.
    workspace="$(ab_vr_case "$template" receipt)"
    out="$(ab_vr_fake_root "$workspace" native)"
    sed -i -e "s/^PROVISION_BLOCK_SHA256=.*/PROVISION_BLOCK_SHA256=$(printf '0%.0s' {1..64})/" "${out}/records/result.env"
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$out" RUNNER_TEMP="${workspace}/runner_temp" > /dev/null
    ab_vr_expect "$workspace" "S106 receipt" NOT_VERIFIED "provision"
    assert_eq "" "$(ab_vr_native_rows "$workspace")" "S106: no native command runs with another provision block"
    workspace="$(ab_vr_case "$template" outside)"
    out="$(ab_vr_fake_root "$workspace" native "${workspace}/elsewhere")"
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$out" RUNNER_TEMP="${workspace}/runner_temp" > /dev/null
    ab_vr_expect "$workspace" "S106 outside" NOT_VERIFIED "provision"
    assert_eq "" "$(ab_vr_native_rows "$workspace")" "S106: no native command runs with a root outside RUNNER_TEMP"

    # No time for the native command: NOT_VERIFIED, and no command.
    workspace="$(ab_vr_guard "$template" no_time native CAPTURE_WORK_END="$(( $(date +%s) + 20 ))")"
    ab_vr_expect "$workspace" "S106 no time" NOT_VERIFIED "time"
    assert_eq "" "$(ab_vr_native_rows "$workspace")" "S106: no native command starts without its time and reserves"
    ab_vr_assert_records "$workspace" "S106 no time"

    # A source above the 268435456-byte limit: NOT_VERIFIED before any hash.
    workspace="$(ab_vr_case "$template" source_limit)"
    truncate -s 268435457 "${workspace}/checkout/src/batch_9/case_7/vtk/flow_latest_2.vtu"
    sed -i -e '/^VTU_PATH=case_7\/vtk\/flow_latest_2.vtu$/,/^VTU_TAG_EVIDENCE=/ s/^VTU_BYTES=.*/VTU_BYTES=268435457/' \
        "${workspace}/runner_temp/evidence/vtu-point-data.txt"
    {
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "${workspace}/hash_calls"
        printf 'exec %q "$@"\n' "$(command -v sha256sum)"
    } > "${workspace}/fakebin/sha256sum"
    chmod +x "${workspace}/fakebin/sha256sum"
    out="$(ab_vr_fake_root "$workspace" native)"
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$out" RUNNER_TEMP="${workspace}/runner_temp" > /dev/null
    ab_vr_expect "$workspace" "S106 source limit" NOT_VERIFIED "268435456"
    assert_not_contains "$(cat "${workspace}/hash_calls" 2>/dev/null)" "flow_latest_2.vtu" "S106: the oversized source is never hashed"
    assert_eq "" "$(ab_vr_native_rows "$workspace")" "S106: no native command reads an oversized source"

    # A linked vtk directory: NOT_VERIFIED, and no command.
    workspace="$(ab_vr_case "$template" linked)"
    mv -- "${workspace}/checkout/src/batch_9/case_7/vtk" "${workspace}/checkout/vtk_real"
    ln -s -- "${workspace}/checkout/vtk_real" "${workspace}/checkout/src/batch_9/case_7/vtk"
    out="$(ab_vr_fake_root "$workspace" native)"
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$out" RUNNER_TEMP="${workspace}/runner_temp" > /dev/null
    ab_vr_expect "$workspace" "S106 linked" NOT_VERIFIED "link"
    assert_eq "" "$(ab_vr_native_rows "$workspace")" "S106: no native command reads through a link"

    # The combined added-evidence limit: with the collection evidence at the
    # 10485760-byte ceiling, no readback record fits, and the gap is a capture
    # note.
    workspace="$(ab_vr_case "$template" combined)"
    truncate -s 10485760 "${workspace}/runner_temp/evidence/m3-mean-speed/big.bin"
    out="$(ab_vr_fake_root "$workspace" native)"
    ab_vr_unit "$workspace" M3_VTU_DEP_ROOT="$out" RUNNER_TEMP="${workspace}/runner_temp" > /dev/null
    assert_contains "$(cat "${workspace}/runner_temp/evidence/capture-work-notes.txt")" "VTU readback:" \
        "S106: a readback record that does not fit the combined ceiling is a capture note"
    assert_contains "$(cat "${workspace}/runner_temp/evidence/capture-work-notes.txt")" "10485760" \
        "S106: the note names the combined ceiling"
    assert_eq "" "$(ls -A "$(ab_vr_dir "$workspace")" 2>/dev/null)" "S106: no readback record is written past the ceiling"

    # The stop check of the readback: a group that cannot be signaled stays
    # NOT_STOPPED by its deadline.
    workspace="$(new_workspace s106_stop)"
    {
        printf 'set -euo pipefail\n'
        ab_vr_block
        printf '%s\n' 'start=$(vr_now_ms)' 'vr_stop_group "$1" $(( start + 1500 )) && status=0 || status=$?' \
            'printf "stop=%s status=%s elapsed=%s\n" "$VR_STOP" "$status" "$(( $(vr_now_ms) - start ))"'
    } > "${workspace}/stop.sh"
    group="$(ab_vp_foreign_group)"
    out="$(bash "${workspace}/stop.sh" "$group" 2>&1)" || _fail "S106: the stop script runs" "$out"
    assert_contains "$out" "stop=NOT_STOPPED status=1" "S106: a group that cannot be signaled is NOT_STOPPED"
    [[ "$out" =~ elapsed=([0-9]+) ]] && (( BASH_REMATCH[1] <= 1700 )) || _fail "S106: the stop check ends by its deadline" "$out"
}

s107_readback_keeps_the_frozen_blocks_and_interface() {
    local workspace body block constant vector pattern reader summary deadline bytes
    workspace="$(new_workspace s107_interface)"
    assert_eq "15340 92068ccc692900bcb8ee41f2a721d6e7b4bea408e78e30ba786df0ed7a819d3f" "$(ab_fr_frozen_block "VTU header reader")" \
        "S107: the VTU header reader block is unchanged"
    assert_eq "107529 9154d83f22b1304381048ca115d9d678f64b7ec2e215b68059b77f8aad92ec29" "$(ab_fr_frozen_block "M3 mean speed")" \
        "S107: the M3 mean-speed block is unchanged"
    body="$(ab_step_run_body "Capture the evidence")"
    assert_eq $'metric_collect\nfr_capture\nvr_capture' \
        "$(grep -xE '[[:space:]]*(metric_collect|fr_capture|vr_capture)' <<< "$body" | tr -d ' ')" \
        "S107: the readback runs once, after the collection and the receipt"
    block="$(ab_vr_block)"
    [[ "$block" == *"# ---- VTU readback: end ----" ]] || _fail "S107: the capture work holds the complete readback block"
    assert_eq "1" "$(grep -cx '# ---- VTU readback: begin ----' <<< "$body")" "S107: the readback block is in the capture work once"
    for constant in VR_WORK_SECONDS=90 VR_NATIVE_SECONDS=60 VR_KILL_GRACE_SECONDS=5 VR_RECEIPT_RESERVE_SECONDS=10 \
                    VR_SOURCE_LIMIT=268435456 VR_SOURCES_LIMIT=536870912 VR_AS_LIMIT=4294967296 VR_CPU_SECONDS=60 \
                    VR_FILE_LIMIT=65536 VR_TREE_LIMIT=262144 VR_PROVISION_TEXT_LIMIT=65536 VR_COMBINED_LIMIT=10485760 \
                    VR_PYTHON=/usr/bin/python3.12; do
        assert_eq "1" "$(grep -cx -- "$constant" <<< "$block")" "S107: the readback sets ${constant}"
    done
    ab_vp_block "$CONTRACT_WORKFLOW" "$AB_VP_STEP" > "${workspace}/provision.block"
    assert_eq "$(sha256sum < "${workspace}/provision.block" | cut -d ' ' -f 1)" "$(ab_vr_constant PROVISION_BLOCK_SHA256)" \
        "S107: the readback names the SHA-256 of the provision block of both workflows"
    assert_eq "$(ab_vp_expected_manifest | sha256sum | cut -d ' ' -f 1)" "$(ab_vr_constant MANIFEST_SHA256)" \
        "S107: the readback names the SHA-256 of the approved manifest"
    # The fixed native vector of proposal Section 4.
    for vector in 'timeout --signal=TERM --kill-after=5s "${READBACK_RUN_SECONDS}s" \' '/usr/bin/python3.12 -I - \' \
                  '"$READBACK_SOURCE_0" "$READBACK_SOURCE_LATEST" "$READBACK_EVIDENCE_DIR"'; do
        assert_eq "1" "$(sed -e 's/^[[:space:]]*//' <<< "$block" | grep -cxF -- "$vector")" \
            "S107: the readback holds the fixed vector line [${vector}] once"
    done
    # The reader: the one native consumer, no installation, network, process,
    # writer, or value calculation.
    ab_vr_reader "${workspace}/reader.py"
    reader="$(cat "${workspace}/reader.py")"
    assert_contains "$reader" "vtkXMLUnstructuredGridReader" "S107: the reader uses the native XML unstructured-grid reader"
    for pattern in subprocess socket http urllib 'import pip' os.system Popen Writer numpy vtkmodules.all \
                   GetRange GetTuple GetComponent; do
        assert_eq "0" "$(grep -cF -- "$pattern" <<< "$reader")" "S107: the reader holds no [${pattern}]"
    done
    for pattern in 'pip ' 'sudo' 'apt-get' 'curl ' 'wget ' 'PYTHONPATH' 'LD_LIBRARY_PATH'; do
        assert_eq "0" "$(grep -cF -- "$pattern" <<< "$block")" "S107: the readback block holds no [${pattern}]"
    done
    # The job summary and the interface.
    summary="$(ab_step_run_body "Write the job summary")"
    assert_contains "$summary" '| VTU readback | \`${VTU_READBACK_RESULT:-UNAVAILABLE}\` ${VTU_READBACK_REASON:-UNAVAILABLE} |' \
        "S107: the job summary shows the readback result and reason"
    assert_eq "Start the evidence clock|Create the bounded-runner library|Check out the repository|Record the checkout phase result|Resolve the OpenFOAM baseline|Install OpenFOAM v2512|Record the OpenFOAM version|Prepare the one-Case DOE Batch CSV|Run the Orchestrator|Capture the evidence|Write the job summary|Upload the evidence artifacts" \
        "$(sed -n -e 's/^      - name: //p' "$WORKFLOW" | paste -sd '|' -)" "S107: the step list stays"
    assert_eq "1" "$(grep -cF -- "bash -c 'bash src/run_batch.sh --stage setup,mesh,flow,post-processing -j 1 \"\$1\" \\" "$WORKFLOW")" \
        "S107: the Orchestrator vector stays"
    assert_eq "10" "$(awk '/^      - name: Capture the evidence$/ { found = 1; next } found && /^        timeout-minutes:/ { print $2; exit }' "$WORKFLOW")" \
        "S107: the capture step guard stays 10 minutes"
    # The evidence workflow stays below the GitHub workflow file limit (500 KB):
    # at most 510000 raw bytes, the ceiling of Owner decision 6173182935.
    bytes="$(wc -c < "$WORKFLOW")" || _fail "S107: the evidence workflow can be read"
    bytes="${bytes//[[:space:]]/}"
    [[ "$bytes" =~ ^(0|[1-9][0-9]*)$ ]] || _fail "S107: the evidence workflow has a valid byte count" "bytes: [${bytes}]"
    (( bytes <= 510000 )) ||
        _fail "S107: the evidence workflow has at most 510000 raw bytes" "ceiling: 510000" "actual:  ${bytes}"

    # The capture step publishes the readback result. A failed product run gives
    # NOT_ATTEMPTED; a capture with no work budget never reaches the readback.
    ab_capture_fixture "$workspace"
    deadline=$(( $(date +%s) + 6000 ))
    ab_run_capture "$workspace" "$deadline" > /dev/null
    assert_eq "NOT_ATTEMPTED" "$(ab_vr_value "$workspace" VTU_READBACK_RESULT)" \
        "S107: after a failed product run, the readback result is NOT_ATTEMPTED"
    assert_eq "NOT_ATTEMPTED" "$(ab_env_last "$workspace" VTU_READBACK_RESULT)" "S107: GITHUB_ENV gets the readback result"
    : > "${workspace}/step_summary"
    env GITHUB_STEP_SUMMARY="${workspace}/step_summary" VTU_READBACK_RESULT="$(ab_env_last "$workspace" VTU_READBACK_RESULT)" \
        VTU_READBACK_REASON="$(ab_env_last "$workspace" VTU_READBACK_REASON)" \
        bash -eo pipefail "${workspace}/summary_step.sh" > /dev/null 2>&1 || _fail "S107: the summary step succeeds"
    assert_contains "$(cat "${workspace}/step_summary")" "| VTU readback | \`NOT_ATTEMPTED\` " "S107: the summary shows the readback result"
    workspace="$(new_workspace s107_no_budget)"
    ab_capture_fixture "$workspace"
    ab_run_capture "$workspace" "$(( $(date +%s) + 180 ))" > /dev/null
    assert_eq "SKIPPED_NO_BUDGET" "$(ab_env_last "$workspace" CAPTURE_RESULT)" "S107: the capture had no work budget"
    assert_eq "NOT_ATTEMPTED" "$(ab_env_last "$workspace" VTU_READBACK_RESULT)" \
        "S107: a capture that never reaches the readback publishes NOT_ATTEMPTED"
    assert_contains "$(ab_env_last "$workspace" VTU_READBACK_REASON)" "SKIPPED_NO_BUDGET" "S107: the reason names the capture result"
}

# ab_vr_record_run <workspace> <time0> <latest> <end> - one readback unit run
# with a fake root of the native kind whose vtkmodules import writes one
# complete reader record to file descriptor 3: the file results <time0> and
# <latest> (PASS or FAIL), and the reader result PASS when both are PASS, or
# FAIL. The import then ends the reader with <end>: an exit status, or the name
# of a signal that the reader sends to itself. The record drives the outcome
# and record guards only; it never proves a native read.
ab_vr_record_run() {
    local root result=PASS
    root="$(ab_vr_fake_root "$1" native)"
    [[ "$2 $3" == "PASS PASS" ]] || result=FAIL
    {
        printf 'import os, signal\n'
        printf 'record = "READER_SCHEMA=vtu-readback-reader/1\\nREADER_RESULT=%s\\nREADER_REASON=a controlled record\\n"\n' "$result"
        printf 'record += "FILE_time0_RESULT=%s\\nFILE_time0_REASON=controlled\\n"\n' "$2"
        printf 'record += "FILE_latest_RESULT=%s\\nFILE_latest_REASON=controlled\\n"\n' "$3"
        printf 'os.write(3, (record + "READER_FINISH=1\\n").encode())\n'
        if [[ "$4" =~ ^[0-9]+$ ]]; then
            printf 'os._exit(%s)\n' "$4"
        else
            printf 'os.kill(os.getpid(), signal.%s)\n' "$4"
        fi
    } > "${root}/site/vtkmodules/__init__.py"
    ab_vr_unit "$1" M3_VTU_DEP_ROOT="$root" RUNNER_TEMP="${1}/runner_temp" > "${1}/guard.status"
}

# ab_vr_result_of <file> - the VTU_READBACK_RESULT of one result file, or - when
# it is not a regular file.
ab_vr_result_of() {
    if [[ -f "$1" && ! -L "$1" ]]; then
        ab_vp_value "$1" VTU_READBACK_RESULT
    else
        printf -- '-\n'
    fi
}

# ab_vr_side <workspace> - the side result file of the readback.
ab_vr_side() {
    printf '%s\n' "${1}/runner_temp/vtu-readback-result.env"
}

# ab_vr_publish <workspace> - run the readback-result publication of the capture
# step, from its "The VTU readback result." comment through the evidence
# verdicts that go to GITHUB_ENV, as the capture step runs it after the capture
# work. Prints the published VTU_READBACK_RESULT.
ab_vr_publish() {
    local workspace="$1" out
    ab_step_run_body "Capture the evidence" | awk '
        done { next }
        index($0, "# The VTU readback result. ") == 1 { inside = 1 }
        inside { print }
        inside && $0 == "} | tee -a \"$GITHUB_ENV\"" { inside = 0; done = 1 }' > "${workspace}/publish.sh"
    [[ "$(tail -n 1 "${workspace}/publish.sh")" == '} | tee -a "$GITHUB_ENV"' ]] ||
        { _fail "the readback-result publication of the capture step must be extracted"; return 1; }
    : > "${workspace}/github_env"
    out="$(env EVIDENCE_DIR="${workspace}/runner_temp/evidence" GITHUB_ENV="${workspace}/github_env" \
        capture_result=COMPLETE capture_reason="a controlled capture" \
        metric_result="${workspace}/no_metric" receipt_result="${workspace}/no_receipt" \
        "${AB_STEP_BASH[@]}" "${workspace}/publish.sh" 2>&1)" ||
        { _fail "the readback-result publication runs" "$out"; return 1; }
    ab_env_last "$workspace" VTU_READBACK_RESULT
}

# ab_vr_inventory_gaps <workspace> - each inventory.tsv row with a SHA-256 that
# does not bind its record: other bytes or SHA-256, or no regular file. A row
# with - and UNAVAILABLE binds nothing. Prints nothing when every row binds.
ab_vr_inventory_gaps() {
    local dir name bytes sha
    dir="$(ab_vr_dir "$1")"
    while IFS=$'\t' read -r name bytes sha; do
        [[ "$name" != name && "$sha" != UNAVAILABLE ]] || continue
        if [[ ! -f "${dir}/${name}" || -L "${dir}/${name}" ]] ||
                [[ "$(wc -c < "${dir}/${name}" | tr -d ' ') $(sha256sum < "${dir}/${name}" | cut -d ' ' -f 1)" != "${bytes} ${sha}" ]]; then
            printf '%s ' "$name"
        fi
    done < "${dir}/inventory.tsv"
}

s108_readback_pass_needs_a_clean_native_exit() {
    local template workspace case name time0 latest end results="" outcome
    local -A ws=()
    template="$(new_workspace s108_template)"
    ab_fr_fixture "$template"
    assert_contains "$(ab_fr_unit "$template")" "status=0" "S108: the template receipt run ends with status 0"

    # Each case first, so one comparison shows every outcome: label, result,
    # time-0 result, latest result.
    for case in exit_0:PASS:PASS:0 exit_3:PASS:PASS:3 exit_1:PASS:PASS:1 signal:PASS:PASS:SIGUSR1 \
                fail_signal:PASS:FAIL:SIGUSR1; do
        IFS=: read -r name time0 latest end <<< "$case"
        ws[$name]="$(ab_vr_case "$template" "s108_${name}")"
        ab_vr_record_run "${ws[$name]}" "$time0" "$latest" "$end"
        workspace="${ws[$name]}"
        results+="${name} $(ab_vr_value "$workspace" VTU_READBACK_RESULT) $(ab_vr_value "$workspace" VTU_READBACK_TIME0_RESULT)"
        results+=" $(ab_vr_value "$workspace" VTU_READBACK_LATEST_RESULT)|"
    done
    assert_eq "exit_0 PASS PASS PASS|exit_3 NOT_VERIFIED NOT_VERIFIED NOT_VERIFIED|exit_1 NOT_VERIFIED NOT_VERIFIED NOT_VERIFIED|signal NOT_VERIFIED NOT_VERIFIED NOT_VERIFIED|fail_signal FAIL NOT_VERIFIED FAIL|" \
        "$results" "S108: only a native command that ends with status 0 after a complete PASS record gives PASS, and a FAIL record stays FAIL"

    # The recorded native outcome and the reason of each case.
    for case in exit_0:0:COMPLETED exit_3:3:FAILED exit_1:1:COMPLETED signal:138:FAILED fail_signal:138:FAILED; do
        IFS=: read -r name end outcome <<< "$case"
        workspace="${ws[$name]}"
        assert_eq "${end} ${outcome}" "$(ab_vr_native_rows "$workspace" | cut -f 7,8 | tr '\t' ' ')" \
            "S108 ${name}: commands.tsv records the native status and outcome"
        ab_vr_assert_records "$workspace" "S108 ${name}"
        [[ "$name" != exit_0 ]] || continue
        assert_contains "$(ab_vr_value "$workspace" VTU_READBACK_REASON)" "status ${end}" \
            "S108 ${name}: the reason names the native status"
        assert_eq "NOT_VERIFIED" "$(awk -F '\t' '$1 == "time0" { print $18 }' "$(ab_vr_dir "$workspace")/files.tsv")" \
            "S108 ${name}: files.tsv keeps no time-0 PASS of the failed native command"
    done
    assert_contains "$(ab_vr_value "${ws[fail_signal]}" VTU_READBACK_REASON)" "a controlled record" \
        "S108: the FAIL keeps the reason of its reader record"
}

s109_readback_pass_needs_the_final_records() {
    local template complete workspace name results="" real notes
    local -A ws=()
    template="$(new_workspace s109_template)"
    ab_fr_fixture "$template"
    assert_contains "$(ab_fr_unit "$template")" "status=0" "S109: the template receipt run ends with status 0"

    # complete: a status-0 PASS record and every final record.
    complete="$(ab_vr_case "$template" s109_complete)"
    ab_vr_record_run "$complete" PASS PASS 0
    ws[complete]="$complete"
    # result_write: result.env cannot be written.
    ws[result_write]="$(ab_vr_case "$template" s109_result_write)"
    mkdir -p -- "$(ab_vr_dir "${ws[result_write]}")/result.env"
    ab_vr_record_run "${ws[result_write]}" PASS PASS 0
    # inventory_write: inventory.tsv cannot be written.
    ws[inventory_write]="$(ab_vr_case "$template" s109_inventory_write)"
    mkdir -p -- "$(ab_vr_dir "${ws[inventory_write]}")/inventory.tsv"
    ab_vr_record_run "${ws[inventory_write]}" PASS PASS 0
    # final_hash: the fake sha256sum gives the inventory no SHA-256 of result.env.
    ws[final_hash]="$(ab_vr_case "$template" s109_final_hash)"
    real="$(command -v sha256sum)"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for argument in "$@"; do\n'
        printf '    if [[ "$argument" == result.env ]]; then\n'
        printf '        : > %q\n' "${ws[final_hash]}/hash_dropped"
        printf '        %q "$@" | grep -v -- %q\n' "$real" '  result[.]env$'
        printf '        exit 0\n'
        printf '    fi\n'
        printf 'done\n'
        printf 'exec %q "$@"\n' "$real"
    } > "${ws[final_hash]}/fakebin/sha256sum"
    chmod +x "${ws[final_hash]}/fakebin/sha256sum"
    ab_vr_record_run "${ws[final_hash]}" PASS PASS 0
    # stopped: the capture work stopped after a complete PASS result.env and
    # before inventory.tsv, so the side result keeps its first text.
    ws[stopped]="$(ab_vr_case "$complete" s109_stopped)"
    rm -f -- "$(ab_vr_dir "${ws[stopped]}")/inventory.tsv"
    printf 'VTU_READBACK_RESULT=INCOMPLETE\nVTU_READBACK_REASON=the readback work did not reach its end\nWORK_START=1\n' \
        > "$(ab_vr_side "${ws[stopped]}")"
    # side_only: no result.env, and the side result keeps the PASS text.
    ws[side_only]="$(ab_vr_case "$complete" s109_side_only)"
    rm -f -- "$(ab_vr_dir "${ws[side_only]}")/result.env"

    # Each case first, so one comparison shows every outcome: label, retained
    # result.env and side result after the readback, published result, and
    # retained result.env after the publication.
    for name in complete result_write inventory_write final_hash stopped side_only; do
        results+="${name} $(ab_vr_result_of "$(ab_vr_dir "${ws[$name]}")/result.env") $(ab_vr_result_of "$(ab_vr_side "${ws[$name]}")")"
        results+=" $(ab_vr_publish "${ws[$name]}") $(ab_vr_result_of "$(ab_vr_dir "${ws[$name]}")/result.env")|"
    done
    assert_eq "complete PASS PASS PASS PASS|result_write - NOT_VERIFIED NOT_VERIFIED -|inventory_write NOT_VERIFIED NOT_VERIFIED NOT_VERIFIED NOT_VERIFIED|final_hash NOT_VERIFIED NOT_VERIFIED NOT_VERIFIED NOT_VERIFIED|stopped PASS INCOMPLETE INCOMPLETE INCOMPLETE|side_only - PASS NOT_VERIFIED NOT_VERIFIED|" \
        "$results" "S109: a final record failure gives no retained, side, or published PASS"

    # The complete case keeps every record, and the publication keeps it.
    ab_vr_assert_records "$complete" "S109 complete"
    # Each final record failure is one exact capture note, and the inventory
    # binds the retained records.
    notes="$(cat "${ws[result_write]}/runner_temp/evidence/capture-work-notes.txt")"
    assert_eq "VTU readback: result.env cannot be written completely" "$notes" "S109: a result.env that cannot be written is one capture note"
    assert_eq $'result.env\t-\tUNAVAILABLE' "$(grep '^result\.env' "$(ab_vr_dir "${ws[result_write]}")/inventory.tsv")" \
        "S109: the inventory binds no result.env that was not written"
    notes="$(cat "${ws[inventory_write]}/runner_temp/evidence/capture-work-notes.txt")"
    assert_eq "VTU readback: inventory.tsv cannot be written completely" "$notes" "S109: an inventory.tsv that cannot be written is one capture note"
    assert_contains "$(ab_vr_value "${ws[inventory_write]}" VTU_READBACK_REASON)" "records are not complete" \
        "S109: the retained result names the incomplete records"
    assert_file_exists "${ws[final_hash]}/hash_dropped" "S109: the inventory hash of result.env was dropped"
    notes="$(cat "${ws[final_hash]}/runner_temp/evidence/capture-work-notes.txt")"
    assert_eq "VTU readback: inventory.tsv has no SHA-256 of result.env" "$notes" "S109: a missing final SHA-256 is one capture note"
    for name in result_write final_hash side_only; do
        assert_eq "" "$(ab_vr_inventory_gaps "${ws[$name]}")" "S109 ${name}: inventory.tsv binds the retained records"
    done
    assert_eq "" "$(grep -v '^name' "$(ab_vr_dir "${ws[side_only]}")/inventory.tsv" | grep UNAVAILABLE)" \
        "S109: after the publication, the inventory binds the retained result.env"
    assert_contains "$(ab_vr_value "${ws[side_only]}" VTU_READBACK_REASON)" "inventory" \
        "S109: the published result names the missing inventory binding"
    assert_eq "MISSING" "$(ab_vr_value "${ws[stopped]}" VTU_READBACK_TIME0_RESULT)" \
        "S109: a stopped readback keeps no file PASS in the retained result"
}

# ---- S110: the M3 identity diagnostic carrier (Issue #80) -------------------

# S110 (admission 6209387364, amended by 6213339238, of approved proposal
# 6207516357): the manual M3 identity diagnostic carrier. Pure checks of the
# workflow, the closed helper, the two CI path filters, and the frozen source
# at M; then exactly one --self-test call, which runs the four synthetic
# identity guards (CONTROL_ONLY) and the pure negative checks. S110 never calls
# the normal entry, a package provision, a Case, or a Stage. A guard PASS is
# instrumentation evidence only: it is no reproduction of the historical
# identity TIMEOUT and no M3 evidence.
s110_identity_diagnostic_carrier() {
    local carrier helper workspace temp root guard receipt out status secret key name text bytes driver pattern
    local observed retained state
    carrier="${REPO_ROOT}/.github/workflows/m3-identity-diagnostic.yml"
    helper="${REPO_ROOT}/.github/scripts/m3-identity-diagnostic.py"
    # Without the carrier, S110 stops here, before any helper call.
    assert_file_exists "$carrier" "S110: the identity diagnostic workflow exists"
    assert_file_exists "$helper" "S110: the identity diagnostic helper exists"
    workspace="$(new_workspace s110_carrier)"

    # The frozen source at M: the evidence workflow, the baseline file, and two
    # blocks cut here without the helper (ten leading spaces removed).
    assert_eq "509823 65446acba49eac2b371c6dc8afabceac052a1b9a90fae870f6af6b4b191ecb92" \
        "$(wc -c < "$WORKFLOW") $(sha256sum < "$WORKFLOW" | cut -d ' ' -f 1)" "S110: the evidence workflow keeps its bytes of M"
    assert_eq "f45ab757cb0d9b2d18eac5e0208643a6d43a32a634a35ff1d0456857b95129f5" \
        "$(sha256sum < "${REPO_ROOT}/.openfoam-version" | cut -d ' ' -f 1)" "S110: .openfoam-version keeps v2512"
    sed -e 's/^ \{10\}//' "$WORKFLOW" > "${workspace}/dedented.yml"
    awk '$0 == "# ---- M3 mean speed: end ----" { stop = 1 }
         $0 == "# ---- M3 mean speed: begin ----" { on = 1 }
         on && !stop' "${workspace}/dedented.yml" > "${workspace}/definitions.sh"
    awk -v q="'" '$0 == q { on = 0 } on { print } $0 == "METRIC_IDENTITY_SCRIPT=" q { on = 1; print "" }' \
        "${workspace}/dedented.yml" > "${workspace}/identity.sh"
    for text in "definitions.sh 88598 2c8682abfe8dd8a1cf89b9a268f7fc361b6b6180dde4374a2a318bcfe6899661" \
                "identity.sh 956 9a43acb03f1fc7d7008be6236a5d8b8e48125646395c10879b7c0945e9387b7b"; do
        name="${text%% *}"
        assert_eq "${text#* }" "$(wc -c < "${workspace}/${name}") $(sha256sum < "${workspace}/${name}" | cut -d ' ' -f 1)" \
            "S110: the frozen ${name%.sh} block of M has its bytes and SHA-256"
    done

    # The CI filters: the two new paths in both the push and the pull_request
    # filter, and no other change of the file of M.
    assert_eq "2cf81f8299d6c0ae0e9bf2b67692bd593478a3e03a9fa0c61f7188610e0e2f96" \
        "$(grep -vxF -e "      - '.github/workflows/m3-identity-diagnostic.yml'" \
            -e "      - '.github/scripts/m3-identity-diagnostic.py'" "$CONTRACT_WORKFLOW" | sha256sum | cut -d ' ' -f 1)" \
        "S110: without the two new paths, batch-contract.yml is the file of M"
    assert_eq "push 2 pull_request 2" "$(awk -v a="      - '.github/workflows/m3-identity-diagnostic.yml'" \
        -v b="      - '.github/scripts/m3-identity-diagnostic.py'" '
            /^  push:$/ { e = "push" } /^  pull_request:$/ { e = "pull_request" } /^  workflow_dispatch:$/ { e = "" }
            e != "" && ($0 == a || $0 == b) { n[e]++ }
            END { printf "push %d pull_request %d", n["push"], n["pull_request"] }' "$CONTRACT_WORKFLOW")" \
        "S110: the push filter and the pull_request filter each hold the two new paths"
    assert_eq "121506 d52c15e694af2312bd4e8aa20d4ed15d9c8453559a97f21e609538acde2be647" \
        "$(wc -c < "$CONTRACT_WORKFLOW") $(sha256sum < "$CONTRACT_WORKFLOW" | cut -d ' ' -f 1)" \
        "S110: batch-contract.yml is the approved file with the four entries at their places"

    # The SP1 to SP4 correction cases (contract 6219483894, Sections 3 and 4; admission
    # 6220510488): nineteen pure cases by finding, before the changed expectations and the
    # self-test. Fakes replace each process start, signal, stop, record, and run binding.
    cat > "${workspace}/correction.py" <<'PY'
import contextlib, hashlib, io, os, re, socket, stat, subprocess, sys, tempfile, types
from pathlib import Path

HELPER, WORKFLOW, BASE = sys.argv[1], sys.argv[2], os.path.realpath(sys.argv[3])
CODE = compile(open(HELPER, 'rb').read(), 'm3d-helper', 'exec')
LINES = open(WORKFLOW, encoding='utf-8').read().split('\n')
S, R = ' ' * 10, 'm3-identity-diagnostic'
GATE, CALLS, N, BLOCK, TEXT, END = S + 'python3 -I - "$RUNNER_TEMP" <<\'M3D_PACKET\'', [], [0], None, '', 0

def forbidden(*args, **kwargs):
  CALLS.append(args[:1])
  raise AssertionError('a real call')

subprocess.Popen = os.killpg = os.kill = os.fork = os.system = socket.socket = forbidden

def step(name):
  i = LINES.index('      - name: ' + name)
  return LINES[i:next((k for k in range(i + 1, len(LINES)) if LINES[k].startswith('      - name: ')), len(LINES))]

UPLOAD = next((x[16:] for x in step('Upload the diagnostic evidence') if x.startswith(S + 'path: ')), '')
SUMMARY = step('Write the job summary')
if GATE in SUMMARY and S + 'M3D_PACKET' in SUMMARY:
  END = SUMMARY.index(S + 'M3D_PACKET', SUMMARY.index(GATE))
  TEXT = ''.join(x[10:] + '\n' for x in SUMMARY[SUMMARY.index(GATE) + 1:END])
  BLOCK = compile(TEXT, 'm3d-packet', 'exec')

def sha(data): return hashlib.sha256(data).hexdigest()
def rec(**v): return ''.join(f'{k}={x}\n' for k, x in v.items()) + 'RECORD_END=COMPLETE\n'
def count(calls, kind): return [c[0] for c in calls].count(kind)
def visible(temp): return Path(UPLOAD.replace('${{ runner.temp }}', str(temp)))

def write(path, data):
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_bytes(data.encode() if isinstance(data, str) else data)

def kvf(path):
  data = path.read_bytes() if path.is_file() and not path.is_symlink() else b''
  ok = data.endswith(b'\nRECORD_END=COMPLETE\n')
  return dict(x.partition('=')[::2] for x in data.decode().split('\n') if ok and '=' in x)

def fresh(name):
  N[0] += 1
  temp = Path(BASE, f'{N[0]:02d}-{name}')
  temp.mkdir(mode=0o700)
  os.environ['RUNNER_TEMP'] = str(temp)
  return temp

def helper():
  h = {'__name__': 'm3d_pure', '__file__': HELPER}
  exec(CODE, h)
  return h

def quiet(call):
  with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    return call()

def throw(value):
  if isinstance(value, BaseException):
    raise value
  return value

LIB = helper()['blocks_of']((Path(HELPER).parents[2] / '.github/workflows/openfoam-evidence.yml').read_bytes())['bounded_runner']

def fakes(h, wait=0, stop='EMPTY', driver=None, stat_fault=False):
  calls, real = [], h['read']
  def popen(args, **kwargs):
    calls.append(('popen', 5000001 + count(calls, 'popen')))
    driver and driver(Path(args[5]))
    return types.SimpleNamespace(pid=calls[-1][1], wait=lambda timeout=None: throw(wait), poll=lambda: 0)
  h.update(read=lambda p: throw(OSError('fake PID/stat read fault')) if stat_fault and str(p)[:6] == '/proc/' else real(p),
           stop=lambda group, seconds=6.0: calls.append(('stop', group)) or throw(stop),
           subprocess=types.SimpleNamespace(**{**vars(subprocess), 'Popen': popen}))
  return calls

def driver(outcome, status, code, ret):
  def files(pdir):
    write(pdir / 'driver.env', f'IDENTITY_RETURN={ret}\nM_OUTCOME={outcome}\nM_STATUS={status}\nM_CODE={code}\n'
          'M_LIMIT=89921\nM_GROUP=5100001\nM_STOP=EMPTY\nDRIVER_END=COMPLETE\n')
    write(pdir / 'commands.tsv', 'seq\n3\tidentity\tWORK\t89921\n')
    write(pdir / '03-identity.out', 'PACKAGE=x\n')
  return files

def prepare(work):
  def make(temp, got):
    work.append(Path(tempfile.mkdtemp(prefix='m3-identity-work.', dir=temp)))
    write(work[0] / 'definitions.sh', ': fake\n')
    return work[0], []
  return make

def native(name, outcomes=None, **fake):  # fake binding, source, work root, and provision
  h, temp, work, probes = helper(), fresh(name), [], []
  (temp / R / 'guard').mkdir(parents=True)
  write(temp / 'm3-identity-keep/own.txt', 'keep\n')
  h.update(binding=lambda g: h['now_ms'](), check_source=lambda *a: {}, prepare=prepare(work), provision=lambda r, s: 'f' * 64)
  if outcomes:
    h['native_probe'] = lambda w, r, mode, s: probes.append(mode) or outcomes[mode]
  calls = fakes(h, **fake)
  status = quiet(h['native'])
  return status, kvf(temp / R / 'result.env'), probes, calls, work[0], temp

def a(name, outcomes, observation):
  status, r, probes = native(name, outcomes)[:3]
  got = (r.get('TERMINAL_CLASSIFICATION'), r.get('OBSERVATION'), probes, status)
  return got[:3] == ('EVIDENCE_LIMIT', observation, list(outcomes)) and status != 0, got, r

def a1(): return a('a1', {'B': 'ORIGINAL_TIMEOUT', 'T': 'ORIGINAL_TIMEOUT'}, 'STOP_LOCATION_OBSERVED')[:2]
def a2(): return a('a2', {'B': 'COMPLETED'}, 'NOT_REPRODUCED')[:2]
def a3(): return a('a3', {'B': 'DIFFERENT_FAILURE'}, 'DIFFERENT_FAILURE')[:2]

def a4():
  runs = [a('a4' + t[0], {'B': 'ORIGINAL_TIMEOUT', 'T': t}, o)
          for t, o in (('COMPLETED', 'TRACE_PERTURBED'), ('DIFFERENT_FAILURE', 'TRACE_DIFFERENT_FAILURE'))]
  return all(x[0] for x in runs), [x[1] for x in runs]

TICKS, GROUP, BASHRC = int(1000.0 * os.sysconf('SC_CLK_TCK')), 4242, b'export WM_PROJECT_VERSION=v2512\n'
OLD = [(1, 'S', 0, 1, 1, 0, 'init'), (2, 'S', 0, 0, 2, 0, 'kthreadd'), (900, 'S', 1, 900, 5, 0, 'cron')]
NEW = [(5000, 'I', 2, 0, TICKS + 50, 0, 'kworker'), (5001, 'S', 1, 5001, TICKS + 60, 1001, 'bash'),
       (5002, 'Z', 1, 5002, TICKS + 70, 0, 'dpkg')]
LEADER = (GROUP, 'S', 1, GROUP, TICKS + 1, 1001, 'bash')
INSTALL = rec(START_MS=1, START_UPTIME='1000.00', END_MS=2, CHILD_GROUP=GROUP, INSTALL_RESULT='SUCCEEDED')
NO = ('NOT_VERIFIED', 'INSTALL_STOP_UNVERIFIED', False)

def provision(name, before, after, child='STOPPED', env=INSTALL):  # after: records after the stop
  h, temp, calls = helper(), fresh(name), []
  for rel, data in (('install/install.env', env), ('install/lib.sh', LIB), ('bashrc', BASHRC)):
    write(temp / R / rel, data)
  h.update(stop=lambda group, seconds=6.0: calls.append('stop') or child, BASHRC=str(temp / R / 'bashrc'),
           procs=lambda: calls.append('procs') or (after if 'stop' in calls else before))
  st = {'stopped': True}
  try:
    value, code = h['provision'](temp / R, st), ''
  except h['Stop'] as x:
    value, code = '', x.args[0]
  r = kvf(temp / R / 'install/stop.env')
  return (r.get('INSTALL_STOP'), code, st['stopped']), value, calls, r.get('NEW_ROOT_PROCESSES')

def b1():
  proof, value, calls, new = provision('b1', OLD + [LEADER] + NEW[:1], OLD + NEW)
  return proof == ('VERIFIED', '', True) and value == sha(BASHRC) and calls == ['stop', 'procs'], (proof, calls)

def b2():
  rows = OLD + [(6100, 'S', 1, 7777, TICKS + 30, 0, 'python3')]
  proof, value, calls, new = provision('b2', rows, rows, child='EMPTY')
  return proof == NO and '6100' in (new or ''), (proof, new)

def b3():
  start = provision('b3s', OLD, OLD, env=INSTALL.replace('START_UPTIME=1000.00\n', ''))[0]
  reuse = provision('b3r', OLD + [LEADER], OLD + [(GROUP, 'S', 1, 8888, TICKS + 90, 0, 'reused')])[0]
  return start == reuse == NO, ('start', start, 'reuse', reuse)

def b4():
  proof, value, calls, new = provision('b4', OLD, None)
  return proof == NO and new == 'UNREADABLE', (proof, new)

def finalize(temp):  # the fixed packet block, or nothing
  if BLOCK is None:
    return None
  g = {'__name__': 'm3d_packet'}
  exec(BLOCK, g)
  return quiet(lambda: g['main']([str(temp)]))

def walk(top):
  return sorted((os.path.relpath(p, top), os.lstat(p)) for d, ds, fs in os.walk(top)
                for p in (os.path.join(d, n) for n in ds + fs) if os.path.islink(p) or not os.path.isdir(p))

def inventory(top):
  path = top / 'packet.tsv'
  text = path.read_text() if path.is_file() and not path.is_symlink() else ''
  return {f[0]: f for f in (x.split('\t') for x in text.split('\n')[1:]) if len(f) == 6}

def bounded(top, raw):  # each broken bound of the upload-visible tree
  files, inv, env = walk(top) if top.is_dir() else [], inventory(top), kvf(top / 'packet.env')
  size = sum(s.st_size for _, s in files)
  why = ['raw evidence tree'] * (top == raw) + [f'{len(files)} files, {size} bytes'] * (not 0 < len(files) <= 256 or size > 8388608)
  why += ['no NO_CASE packet.env'] * ((env.get('DIAGNOSTIC_CONTEXT'), env.get('M3_ACCEPTANCE_EVIDENCE')) != ('NO_CASE', 'false'))
  return why + [r for r, s in files if not stat.S_ISREG(s.st_mode) or s.st_size > (65536 if '/' not in r or r.endswith('.env')
                else 1048576) or r != 'packet.tsv' and inv.get(r, [''] * 6)[2:4] != [str(s.st_size), sha(Path(top, r).read_bytes())]]

def layout(temp, stop='VERIFIED', result='EVIDENCE_LIMIT', extra={}, probes={}):
  files = {'guard/receipt.env': rec(CLEANUP='REMOVED'), 'guard/a/case.env': rec(CASE='a'),
           'install/install.env': rec(INSTALL_RESULT='SUCCEEDED'), 'install/install.log': 'Setting up\n'}
  files.update({'install/stop.env': rec(INSTALL_STOP=stop)} if stop else {})
  files.update({'result.env': rec(TERMINAL_CLASSIFICATION=result), 'inventory.tsv': 'path\n'} if result else {})
  files.update({f'probe-{m}/probe.env': rec(DRIVER_GROUP_STOP='EMPTY', OPERATION_GROUP_STOP=o) for m, o in probes.items()})
  for rel, data in {**files, **extra}.items():
    write(temp / R / rel, data)

def packet(temp):  # bounded with a non-success status, inventory, record, tree, detail
  status, top = finalize(temp), visible(temp)
  why = bounded(top, temp / R)
  return not why and status not in (None, 0), inventory(top), kvf(top / 'packet.env'), top, (status, why[:3])

def c1():
  h, temp, big = helper(), fresh('c1'), b'apt output line\n' * 196608
  layout(temp, None, None, {'install/install.log': big})
  run = dict(x.split('=', 1) for x in ('GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/main '
             'GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 RUNNER_OS=Linux RUNNER_ARCH=X64 GITHUB_WORKFLOW_REF=o/r/.github/workflows/'
             f'{R}.yml@refs/heads/main M3D_T0_MS={h["now_ms"]() - 601000}').split())
  calls = fakes(h)
  os.environ.update(run)
  try:
    code = quiet(h['native'])
  finally:
    for key in run: del os.environ[key]
  limit = kvf(temp / R / 'result.env').get('EVIDENCE_LIMIT', '')
  ok, inv, env, top, said = packet(temp)
  row = inv.get('install/install.log', [''] * 6)[1:5]
  return ok and code != 0 and not calls and limit.startswith('TIME_LIMIT') and row == [
    '3145728', '1048576', sha(big[:1048576]), 'PARTIAL_PREFIX'], (code, limit[:24], row[:2], said)

def c2():
  temp, log = fresh('c2'), b'Reading package lists...\n' * 120
  layout(temp, 'NOT_VERIFIED', extra={'install/install.env': 'START_MS=1\n', 'install/install.log': log})
  ok, inv, env, top, said = packet(temp)
  row, got = inv.get('install/install.log', [''] * 6)[1:5], (env.get('PACKET_RESULT'), env.get('DIAGNOSTIC_TERMINAL'))
  return ok and row[:3] == ['3000', '3000', sha(log)] and row[3] != 'COMPLETE' and got == (
    'SEALED_WITH_LIMITS', 'EVIDENCE_LIMIT'), (row, got, said)

def c3():
  temp = fresh('c3')
  layout(temp, None, None, {'install/install.log': 'Get:1 partial\n'})
  ok, inv, env, top, said = packet(temp)
  gate = BLOCK is not None and SUMMARY[END + 1:END + 2] + SUMMARY[-2:] == [S + 'sealed=$?', S + 'exit "$sealed"', '']
  return ok and gate and UPLOAD == '${{ runner.temp }}/' + R + '/packet' and env.get('DIAGNOSTIC_TERMINAL') == 'MISSING' \
    and {'install/stop.env', 'result.env'} <= set(env.get('MISSING_RECORDS', '').split()), (UPLOAD, gate, said)

def c4():
  temp = fresh('c4')
  want = {'probe-B/03-identity.out': (b'o' * 1048576, 1048576, 'COMPLETE', 'VERIFIED'),
          'probe-B/03-identity.err': (b'e' * 1048577, 1048576, 'PARTIAL_PREFIX', 'VERIFIED'),
          'probe-T/03-identity.out': (b'PACKAGE=x\n', 10, 'STOP_UNVERIFIED', 'UNVERIFIED')}
  layout(temp, extra={k: v[0] for k, v in want.items()}, probes={'B': 'EMPTY', 'T': 'NOT_STOPPED'})
  ok, inv, env, top, said = packet(temp)
  bad = [k for k, (data, kept, state, stop) in want.items()
         if inv.get(k, [''])[1:] != [str(len(data)), str(kept), sha(data[:kept]), state, stop]]
  return ok and not bad, (bad, said)

def c5():
  temp = fresh('c5')
  layout(temp, extra={k: b'z' * 2200000 for k in ('install/install.log', 'probe-B/trace.txt', 'probe-T/trace.txt',
                                                   'guard/b/03-identity.out')}, probes={'B': 'EMPTY', 'T': 'EMPTY'})
  raw = sum(s.st_size for _, s in walk(temp / R))
  ok, inv, env, top, said = packet(temp)
  size = sum(s.st_size for _, s in walk(top)) if top.is_dir() else 0
  cut = sum(v[4] == 'PARTIAL_PREFIX' for v in inv.values())
  return ok and raw > 8388608 and 0 < size <= 8388608 and cut == 4, (raw, size, cut, said)

def c6():
  temp = fresh('c6')
  layout(temp, extra={f'guard/a/f{i:03d}.out': f'{i}\n' for i in range(257)})
  raw = len(walk(temp / R))
  ok, inv, env, top, said = packet(temp)
  files, out = len(walk(top)) if top.is_dir() else 0, sum(v[4][:8] == 'EXCLUDED' for v in inv.values())
  return ok and raw > 256 and 0 < files <= 256 and out, (raw, files, out, said)

def c7():
  temp, bad = fresh('c7'), {'identities.env': b'A=' + b'r' * 65514 + b'\nRECORD_END=COMPLETE\n', 'install/bad name.log': 'x\n'}
  layout(temp, extra=bad)
  os.symlink('install.env', temp / R / 'install/link.log')
  ok, inv, env, top, said = packet(temp)
  entered = sorted({*bad, 'install/link.log'} & {r for r, _ in (walk(top) if top.is_dir() else [])})
  out = sum(v[4][:8] == 'EXCLUDED' for v in inv.values())
  return ok and not entered and out >= 3, (entered, out, said)

SAFE = (1, 'CLEANUP_UNVERIFIED', True)

def d(name, **fake):
  status, r, probes, calls, work, temp = native(name, **fake)
  return (count(calls, 'stop'), count(calls, 'popen'), r.get('CLEANUP'), work.is_dir()), r, calls, temp

def d1():
  proof, h, temp, work = d('d1', stat_fault=True)[0], helper(), fresh('d1g'), []
  h.update(check_source=lambda *a: {}, prepare=prepare(work))
  calls = fakes(h, stat_fault=True)
  try:
    code = quiet(h['self_test'])
  finally:
    os.environ.pop('M3D_FIXTURE_SECRET', None)
  guard = (count(calls, 'stop'), count(calls, 'popen'), kvf(temp / R / 'guard/receipt.env').get('CLEANUP'), work[0].is_dir())
  return proof[0] and guard[0] and proof[1:] == guard[1:] == SAFE and code != 0, ('native', proof, 'guard', guard)

def d2():
  proof, r = d('d2', wait=RuntimeError('fake wait fault'))[:2]
  return proof[0] and proof[1:] == SAFE and r.get('B_RESULT') == 'NOT_RUN', proof

def d3():
  raised = d('d3r', stop=OSError('unreadable stop evidence'))[0][1:]
  unread = d('d3u', stop='NOT_STOPPED', driver=driver('TIMEOUT', 124, 'TIMEOUT', 1))[0][1:]
  return raised == unread == SAFE, ('stop raises', raised, 'stop unreadable', unread)

def d4():
  proof, r, calls, temp = d('d4', driver=driver('COMPLETED', 0, '', 0))
  groups = [c[1] for c in calls if c[0] == 'stop']
  return (proof[1:] == (1, 'REMOVED', False) and r.get('B_RESULT') == 'COMPLETED' and 5100001 in groups
          and 'definitions.sh' in (temp / R / 'work-removed.tsv').read_text() and (temp / R / 'probe-B/probe.env').is_file()
          and (temp / 'm3-identity-keep/own.txt').is_file()), (proof, groups)

results = {}
for name in [f'{x}{i}' for x, n in zip('ABCD', (4, 4, 7, 4)) for i in range(1, n + 1)]:
  try:
    ok, detail = globals()[name.lower()]()
  except Exception as error:
    ok, detail = False, f'stopped with {error!r}'
  results[name] = bool(ok)
  print(f"S110 CASE {name} {'PASS' if ok else 'FAIL'}: {detail}"[:600])
for family, x in zip(('SP1', 'SP2', 'SP3', 'SP4'), 'ABCD'):
  bad = [n for n in results if n[0] == x and not results[n]]
  print(f'S110 FAMILY {family}', ' '.join(['FAIL'] + bad) if bad else 'PASS')
failed = list(results.values()).count(False)
print(f'S110 CORRECTION GROUP: {len(results)} cases, {failed} failed, {len(CALLS)} real calls')
sys.exit(1 if failed or CALLS or len(results) != 19 else 0)
PY
    mkdir -m 700 -- "${workspace}/correction"
    status=0
    out="$(env -i PATH="$PATH" LC_ALL=C python3 -I -B "${workspace}/correction.py" "$helper" "$carrier" \
        "${workspace}/correction" 2>&1)" || status=$?
    [[ "$status" == 0 ]] || _fail "S110: the nineteen SP1 to SP4 correction cases pass" "$out"

    # The workflow: manual only with no input, read-only contents, one 15-minute
    # job, the fixed steps, the two fixed helper calls, the pinned provision
    # through the bounded runner of M, and an always eligible summary and upload.
    bytes="$(wc -c < "$carrier")"
    (( bytes <= 16384 )) || _fail "S110: the workflow has at most 16384 bytes" "actual: ${bytes}"
    assert_eq "name on permissions jobs" "$(grep -oE '^[a-z]+:' "$carrier" | tr -d ':' | paste -sd ' ' -)" \
        "S110: the workflow has only the four top-level keys"
    assert_eq "$(printf '%s\n' 'on:' '  workflow_dispatch:' '' 'permissions:' '  contents: read' '' 'jobs:' \
        '  identity-diagnostic:' '    name: M3 identity diagnostic' '    runs-on: ubuntu-24.04' '    timeout-minutes: 15' \
        '    defaults:' '      run:' '        shell: bash' '    steps:')" \
        "$(sed -n -e '/^on:$/,/^    steps:$/p' "$carrier")" \
        "S110: one manual trigger with no input, read-only contents, and one 15-minute job"
    assert_eq "1" "$(awk '/^jobs:$/ { j = 1; next } j && /^  [^ ]/ { n++ } END { print n + 0 }' "$carrier")" \
        "S110: the workflow has one job"
    assert_eq "Start the diagnostic clock|Check out the repository|Run the synthetic identity guards|Provision the pinned OpenFOAM package|Run the identity diagnostic|Write the job summary|Upload the diagnostic evidence" \
        "$(sed -n -e 's/^      - name: //p' "$carrier" | paste -sd '|' -)" "S110: the fixed step list"
    for text in \
        "Check out the repository|        uses: actions/checkout@v5|        with:|          persist-credentials: false|          fetch-depth: 1" \
        "Run the synthetic identity guards|        id: guards|        run: python3 .github/scripts/m3-identity-diagnostic.py --self-test" \
        "Run the identity diagnostic|        if: \${{ !cancelled() && steps.guards.outcome == 'success' }}|        run: python3 .github/scripts/m3-identity-diagnostic.py" \
        "Upload the diagnostic evidence|        if: \${{ always() }}|        uses: actions/upload-artifact@v4|        with:|          name: m3-identity-diagnostic|          path: \${{ runner.temp }}/m3-identity-diagnostic/packet|          include-hidden-files: true|          if-no-files-found: error|          retention-days: 90"; do
        name="${text%%|*}"
        assert_eq "      - name: ${text}" \
            "$(awk -v n="$name" '$0 == "      - name: " n { on = 1; print; next } /^      - name: / { on = 0 } on && NF' "$carrier" |
                paste -sd '|' -)" "S110: the step [${name}] is exact"
    done
    assert_eq "        if: \${{ always() }}" \
        "$(awk '$0 == "      - name: Write the job summary" { getline; print }' "$carrier")" "S110: the summary is always eligible"
    for text in "            curl -fsSL https://dl.openfoam.com/add-debian-repo.sh | sudo bash" \
                "            sudo apt-get update" "            sudo apt-get install -y --no-install-recommends \"\$1\"" \
                "          ' _ openfoam2512-default=2512.0-2 > \"\${idir}/install.log\" 2>&1" \
                "          run_bounded \"\${idir}/status\" \"\${idir}/timeout.log\" 15 \"\$seconds\" bash -c '" \
                "          (( seconds <= 165 )) || seconds=165" "          source \"\${idir}/lib.sh\""; do
        assert_eq "1" "$(grep -cxF -- "$text" "$carrier")" "S110: the provision holds the line [${text}] once"
    done
    for text in "3 python3" "4 sudo" "1 f7a1f172248b7c744d25cfbd3f00102c00b9e5ca793b403e654112478a480bf5" \
                "0 secrets." "0 id-token" "0 : write" "0 inputs" "0 pull_request" "0 push:" "0 schedule" "0 workflow_call" \
                "0 continue-on-error" "0 token" "0 GITHUB_TOKEN"; do
        assert_eq "${text%% *}" "$(grep -cF -- "${text#* }" "$carrier")" "S110: the workflow holds [${text#* }] ${text%% *} times"
    done

    # The helper: at most 32768 bytes, standard-library imports only, the frozen
    # source hashes, the two fixed entries, no provision vector, and a driver that
    # calls metric_identity only.
    bytes="$(wc -c < "$helper")"
    (( bytes <= 32768 )) || _fail "S110: the helper has at most 32768 bytes" "actual: ${bytes}"
    assert_eq "import hashlib|import os|import re|import resource|import shlex|import shutil|import signal|import subprocess|import sys|import tempfile|import time|from pathlib import Path" \
        "$(grep -E '^[[:space:]]*(import|from)[[:space:]]' "$helper" | paste -sd '|' -)" "S110: the helper imports only the standard library"
    for text in 65446acba49eac2b371c6dc8afabceac052a1b9a90fae870f6af6b4b191ecb92 \
                f45ab757cb0d9b2d18eac5e0208643a6d43a32a634a35ff1d0456857b95129f5 \
                2c8682abfe8dd8a1cf89b9a268f7fc361b6b6180dde4374a2a318bcfe6899661 \
                9a43acb03f1fc7d7008be6236a5d8b8e48125646395c10879b7c0945e9387b7b \
                8ba5373049732316ad06dacb08ec8ee4081330efa6542b51b4901f0fc06714ba \
                89214fbad0e5d2d65243562fb87cb551cbeae7bc29111d1af863c55111654612 \
                2578396818831bd18856bf7735682cf127f1cbfc9709fd5afba6ba37f2ee1b83 \
                f7a1f172248b7c744d25cfbd3f00102c00b9e5ca793b403e654112478a480bf5 \
                "{(): 'native', ('--self-test',): 'self-test'}.get(tuple(argv))"; do
        assert_eq "1" "$(grep -cF -- "$text" "$helper")" "S110: the helper holds [${text}] once"
    done
    for text in shell=True os.system 'eval(' 'exec(' __import__ importlib urllib socket http.client ctypes pickle \
                add-debian-repo 'apt-get install' postProcess run_batch foamToVTK vtk; do
        assert_eq "0" "$(grep -ciF -- "$text" "$helper")" "S110: the helper holds no [${text}]"
    done
    assert_eq "metric_compare metric_foam_op metric_identity metric_now_ms metric_require metric_source" \
        "$(grep -oE 'metric_[a-z_]+' "$helper" | sort -u | paste -sd ' ' -)" \
        "S110: the helper names no other collector function than its fixed source markers"
    driver="$(awk "/^DRIVER = r'''/ { on = 1 } on { print } on && /^'''\$/ { on = 0 }" "$helper")"
    assert_eq "metric_identity metric_now_ms" "$(grep -oE 'metric_[a-z_]+' <<< "$driver" | sort -u | paste -sd ' ' -)" \
        "S110: the driver calls metric_identity only"
    assert_eq "1 1 1 1" "$(grep -cxF 'source "$1"' <<< "$driver") $(grep -cxF '    export BASH_ENV="$7"' <<< "$driver") $(grep -cxF 'exec 3> "${M_DIR}/trace.txt"' <<< "$driver") $(grep -cxF 'metric_identity || status=$?' <<< "$driver")" \
        "S110: the driver loads the definitions first, has one trace descriptor, and sets BASH_ENV only for T"
    assert_eq "1 1" "$(grep -cxF 'BASH_XTRACEFD=3' "$helper") $(grep -cxF "PS4='+IDTRACE \${EPOCHREALTIME} \${BASHPID} \${LINENO} '" "$helper")" \
        "S110: the trace prelude writes the fixed frames to descriptor 3"

    # The one --self-test call, with a fixture-only token in its environment.
    temp="${workspace}/runner_temp"
    mkdir -p -- "$temp"
    secret="s110-fixture-token-${RANDOM}${RANDOM}${RANDOM}${RANDOM}"
    status=0
    out="$(cd -- "$REPO_ROOT" && RUNNER_TEMP="$temp" M3D_S110_TOKEN="$secret" \
        python3 .github/scripts/m3-identity-diagnostic.py --self-test 2>&1)" || status=$?
    [[ "$status" == 0 ]] || _fail "S110: the one --self-test call ends with status 0" "status: ${status}" "$out"
    assert_contains "$out" "GUARD_RESULT=PASS" "S110: the self-test reports the guard result"
    root="${temp}/m3-identity-diagnostic"
    guard="${root}/guard"
    receipt="${guard}/receipt.env"
    assert_eq "m3-identity-diagnostic" "$(ls -A -- "$temp")" "S110: the guards remove their work root"
    assert_eq "guard" "$(ls -A -- "$root")" "S110: the self-test writes only the guard evidence"
    assert_eq "RECORD_END=COMPLETE" "$(tail -n 1 -- "$receipt")" "S110: the guard receipt is complete"
    for key in GUARD_RESULT=PASS GUARD_LABEL=CONTROL_ONLY DIAGNOSTIC_CONTEXT=NO_CASE M3_ACCEPTANCE_EVIDENCE=false \
               COUNTER_MODEL=CONTROL_7000_MS SOURCE_RESULT=PASS GUARD_CASES=4 NEGATIVE_CHECKS=8 CLEANUP=REMOVED \
               SECRET_SCAN=CLEAN "CASE_success=0 COMPLETED 0 - B" "CASE_stalled=1 TIMEOUT 124 TIMEOUT T" \
               "CASE_nonzero=1 FAILED 7 ENVIRONMENT_MISMATCH T" "CASE_overflow=1 FILE_LIMIT 153 RESOURCE_LIMIT B" \
               "SOURCE_DEFINITIONS=88598 2c8682abfe8dd8a1cf89b9a268f7fc361b6b6180dde4374a2a318bcfe6899661" \
               "SOURCE_IDENTITY_SCRIPT=956 9a43acb03f1fc7d7008be6236a5d8b8e48125646395c10879b7c0945e9387b7b" \
               "SOURCE_CLOCK_STOP_OP=7863 8ba5373049732316ad06dacb08ec8ee4081330efa6542b51b4901f0fc06714ba" \
               "SOURCE_REQUIRE_VALUES=1083 89214fbad0e5d2d65243562fb87cb551cbeae7bc29111d1af863c55111654612" \
               "SOURCE_IDENTITY_FUNCTION=2521 2578396818831bd18856bf7735682cf127f1cbfc9709fd5afba6ba37f2ee1b83" \
               "SOURCE_BOUNDED_RUNNER=2722 f7a1f172248b7c744d25cfbd3f00102c00b9e5ca793b403e654112478a480bf5" \
               "HELPER_SHA256=$(sha256sum < "$helper" | cut -d ' ' -f 1)"; do
        assert_eq "1" "$(grep -cxF -- "$key" "$receipt")" "S110: the guard receipt holds [${key}]"
    done
    for name in ARGUMENTS SOURCE PATH RECORD CLASSIFY SECRET STOP CLEANUP; do
        assert_eq "1" "$(grep -cxF -- "NEG_${name}=PASS" "$receipt")" "S110: the pure negative check ${name} passes"
    done
    for name in success stalled nonzero overflow; do
        assert_eq "1 1 0" "$(grep -cxF -- "CASE_${name}_RESULT=PASS" "$receipt") $(grep -cxF RESULT=PASS "${guard}/${name}/case.env") $(grep -c '=FAIL$' "${guard}/${name}/case.env")" \
            "S110: the ${name} guard passes every check"
        assert_eq "LABEL=CONTROL_ONLY" "$(grep -x 'LABEL=.*' "${guard}/${name}/case.env")" "S110: the ${name} guard is CONTROL_ONLY"
        assert_eq $'1 3\tidentity\tWORK\t7000' "$(tail -n +2 "${guard}/${name}/commands.tsv" | wc -l) $(tail -n +2 "${guard}/${name}/commands.tsv" | cut -f 1-4)" \
            "S110: the ${name} guard runs one identity operation, sequence 3, with the 7000 ms control limit"
    done

    # The retained guard evidence, independent of the receipt.
    assert_eq $'PACKAGE=openfoam2512-default\nPACKAGE_VERSION=2512.0-2' "$(cat -- "${guard}/stalled/03-identity.out")" \
        "S110: the stalled guard keeps its partial output before the stalled query"
    text="$(tail -n 1 -- "${guard}/stalled/trace.txt")"
    pattern='^\++IDTRACE [0-9]+\.[0-9]+ [0-9]+ [0-9]+ dpkg-query .* openfoam2512$'
    [[ "$text" =~ $pattern ]] || _fail "S110: the last trace frame of the stalled guard is the stalled core-package query" "frame: ${text}"
    assert_eq "0 0" "$(wc -c < "${guard}/success/trace.txt") $(wc -c < "${guard}/overflow/trace.txt")" \
        "S110: the untraced guards leave the trace descriptor empty"
    assert_contains "$(cat -- "${guard}/nonzero/trace.txt")" ": M3D_SECRET_PROBE=absent" \
        "S110: the traced bashrc sees no fixture secret"
    assert_eq "" "$(cat -- "${guard}/stalled/trace.txt" "${guard}/nonzero/trace.txt" | grep -F M3D_FAKE_TOOL_SENTINEL || true)" \
        "S110: no fake tool outside the identity Bash is traced"
    read -r _ observed retained _ state <<< "$(grep '^FILE_STDOUT=' "${guard}/overflow/case.env" | cut -d '=' -f 2-)"
    (( observed > 1048576 && retained == 65536 )) && [[ "$state" == PARTIAL_PREFIX ]] ||
        _fail "S110: the overflow guard keeps a bounded prefix and no complete stream" "observed: ${observed}" "retained: ${retained}" "state: ${state}"
    assert_eq "" "$(grep -rlF -- "$secret" "$temp" || true)" "S110: the fixture token is in no retained file"
    assert_eq "" "$(find "$temp" \( -type l -o -name '*.csv' -o -name '*.vtu' -o -name '*.vtk' -o -name 'forbidden-ran' \) -print)" \
        "S110: no link, Case file, or forbidden-command marker is retained"
    assert_eq "" "$(find "${REPO_ROOT}/.github" -name '__pycache__' -print)" "S110: the self-test writes no bytecode"
    assert_eq "1" "$(( $(find "$guard" -type f | wc -l) <= 256 && $(find "$guard" -type f -printf '%s\n' | awk '{ s += $1 } END { print s + 0 }') <= 524288 ))" \
        "S110: the guard evidence has at most 256 files and 524288 bytes"
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
    s87_collect_older_process_in_the_case_keeps_it
    s88_collect_task_measurements_and_allowances
    s89_collect_root_check_source_and_arguments
    s90_collect_root_check_failures_keep_the_task_directory
    s91_collect_root_check_stops_itself
    s92_collect_root_check_keeps_one_cleanup_clock
    s93_collect_root_check_terminal_clock_records
    s94_receipt_complete_controlled_fixture
    s95_receipt_time_signature_and_producer_checks
    s96_receipt_source_records_stay_distinct
    s97_receipt_setup_entries_fail_closed
    s98_receipt_limits_fail_closed
    s99_receipt_keeps_the_frozen_blocks_and_interface
    s100_provision_block_is_identical_in_both_workflows
    s101_provision_gate_and_bounded_operations
    s102_provision_programs_fail_closed
    s103_provision_ci_consumer_is_available
    s104_readback_native_reads_controlled_vtus
    s105_readback_capture_binds_the_two_files
    s106_readback_guards_fail_closed
    s107_readback_keeps_the_frozen_blocks_and_interface
    s108_readback_pass_needs_a_clean_native_exit
    s109_readback_pass_needs_the_final_records
    s110_identity_diagnostic_carrier
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
