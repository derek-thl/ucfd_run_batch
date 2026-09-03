#!/usr/bin/env bash
# Section 23.X - shared Stage job-pool scheduling (Issue #49).
#
# This scenario characterizes the job-pool scheduling behavior of all five
# Stage Runners and then proves that they delegate to the shared helpers.
#
# Every assertion uses a direct Stage Runner CLI or the Orchestrator CLI, the
# process status, the console output, the fake command records, the Batch
# Workspace artifacts, or a test control record that lives outside the Batch
# Workspace. No assertion sources lib_batch_stage.sh, and no assertion calls a
# shared helper or a private Stage Runner function.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# Every Stage Runner invocation has a finite timeout. Status 124 is never an
# accepted result.
STAGE_TIMEOUT=180

CASE_COUNT=4
JOB_LIMIT=2

# Test control records live in a sibling directory of the Batch Workspaces,
# under CONTRACT_TEST_RUN_DIR, so no record enters a Batch Workspace.
CONTROL_ROOT="${CONTRACT_TEST_RUN_DIR}/x_controls"
mkdir -p "$CONTROL_ROOT"

# ---- helpers -----------------------------------------------------------------

# assert_file_bytes_exact <path> <expected> <label>
# The comparison appends one literal X to each side, so a trailing newline byte
# stays significant inside command substitution.
assert_file_bytes_exact() {
    assert_file_exists "$1" "${3}: the file exists"
    assert_eq "${2}X" "$(cat -- "$1"; printf X)" "${3}: the exact bytes"
}

# summary_rows_sorted <summary> - the sorted data rows.
# The concurrent completion order owns the row order, so a comparison sorts
# both sides and proves Case identity instead of position.
summary_rows_sorted() {
    awk 'NR > 1 && NF > 0' "$1" | sort
}

# new_control <name> - one control directory outside every Batch Workspace.
# The function sets control_dir, control_active, control_peaks, and
# control_events.
new_control() {
    control_dir="${CONTROL_ROOT}/${1}"
    rm -rf -- "$control_dir"
    mkdir -p "${control_dir}/active" "${control_dir}/seen"
    control_active="${control_dir}/active"
    control_seen="${control_dir}/seen"
    control_peaks="${control_dir}/peaks"
    control_events="${control_dir}/events"
    : > "$control_peaks"
    : > "$control_events"
}

# write_case_control <bin_dir> <command> <real_command> [<extra_body>]
# The control records Case-process entry and exit, holds each Case until two
# Case processes overlap or a finite deadline passes, records the observed
# active count, preserves the exact argument vector, and delegates to the real
# fake command.
write_case_control() {
    local bin_dir="$1" command_name="$2" real_command="$3" extra="${4:-}"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'control_active=%q\n' "$control_active"
    printf 'control_seen=%q\n' "$control_seen"
        printf 'control_peaks=%q\n' "$control_peaks"
        printf 'control_events=%q\n' "$control_events"
        printf 'real_command=%q\n' "$real_command"
        printf 'overlap_target=%q\n' "$JOB_LIMIT"
        cat <<'CONTROL'
active_count() { find "$control_active" -type f 2>/dev/null | wc -l; }

# The token identifies the Case, not one command invocation. A Stage Runner
# that calls the control more than once for the same Case therefore records one
# entry and holds once.
control_token=""
control_scan() {
    local text="$1" part
    local -a parts
    IFS='/' read -ra parts <<< "$text"
    for part in "${parts[@]}"; do
        case "$part" in
            case_*) control_token="$part" ;;
        esac
    done
}
control_scan "$PWD"
if [[ -z "$control_token" ]]; then
    for control_arg in "$@"; do
        control_scan "$control_arg"
        [[ -n "$control_token" ]] && break
    done
fi
if [[ -z "$control_token" ]]; then
    control_token="$(printf '%s' "$PWD" | tr '/' '_')"
fi
control_owner=0

# The seen marker persists, so a later invocation for the same Case records no
# second entry. The active marker exists only while the Case holds.
if ( set -o noclobber; : > "${control_seen}/${control_token}" ) 2>/dev/null; then
    control_owner=1
    printf 'enter %s\n' "$control_token" >> "$control_events"
    : > "${control_active}/${control_token}"

    # Bounded overlap hold. Every Case waits for a second concurrent Case
    # process, and the internal deadline releases every participant.
    waited=0
    while (( $(active_count) < overlap_target )); do
        sleep 0.05
        waited=$(( waited + 1 ))
        if (( waited > 60 )); then
            break
        fi
    done

    printf '%s\n' "$(active_count)" >> "$control_peaks"
fi
CONTROL
        printf '%s' "$extra"
        cat <<'CONTROL'

"$real_command" "$@"
delegated_status=$?

if (( control_owner == 1 )); then
    rm -f -- "${control_active}/${control_token}"
    printf 'exit %s %s\n' "$control_token" "$delegated_status" >> "$control_events"
fi
exit "$delegated_status"
CONTROL
    } > "${bin_dir}/${command_name}"
    chmod +x "${bin_dir}/${command_name}"
}

# control_peak - the largest observed number of concurrent Case processes.
control_peak() {
    sort -n "$control_peaks" | tail -n 1
}

# assert_pool_shape <label>
assert_pool_shape() {
    local label="$1" peak entries
    peak="$(control_peak)"
    entries="$(grep -c '^enter ' "$control_events" || true)"

    assert_eq "$CASE_COUNT" "$entries" \
        "${label}: every selected Case launches exactly once"
    assert_ne "" "$peak" "${label}: the control observed the Case processes"
    assert_eq 1 "$(( peak <= JOB_LIMIT ? 1 : 0 ))" \
        "${label}: no more than ${JOB_LIMIT} concurrent Case processes"
    assert_eq 1 "$(( peak >= 2 ? 1 : 0 ))" \
        "${label}: two Case processes overlap"
}

# ---- the scenario-local sleep control ---------------------------------------
#
# The control resolves the real sleep before it enters PATH, records each exact
# argument outside the Batch Workspace, delegates the same argument vector, and
# returns the exact delegated status.

SLEEP_CONTROL_DIR="${CONTROL_ROOT}/sleep"
mkdir -p "${SLEEP_CONTROL_DIR}/bin"
SLEEP_REAL="$(command -v sleep)"
assert_ne "${SLEEP_CONTROL_DIR}/bin/sleep" "$SLEEP_REAL" \
    "the sleep control resolves the real sleep first"

new_sleep_record() {
    SLEEP_RECORD="${SLEEP_CONTROL_DIR}/${1}.log"
    : > "$SLEEP_RECORD"
}

{
    printf '#!/usr/bin/env bash\n'
    printf 'real_sleep=%q\n' "$SLEEP_REAL"
    cat <<'CONTROL'
if [[ -n "${X_SLEEP_RECORD:-}" ]]; then
    printf '%s\n' "$*" >> "$X_SLEEP_RECORD"
fi
"$real_sleep" "$@"
exit $?
CONTROL
} > "${SLEEP_CONTROL_DIR}/bin/sleep"
chmod +x "${SLEEP_CONTROL_DIR}/bin/sleep"

# ---- fixtures ----------------------------------------------------------------

# make_setup_bases <root> - flow and transport base folders for a real setup run.
make_setup_bases() {
    local flow="${1}/simpleFoam_files" transport="${1}/scalarTransportDeffFoam_files"
    local field

    mkdir -p "${flow}/0" "${flow}/system" "${flow}/constant/triSurface"
    for field in U p k nut epsilon; do
        printf 'FoamFile { object %s; }\n' "$field" > "${flow}/0/${field}"
    done
    printf 'FoamFile { object controlDict; }\napplication simpleFoam;\nendTime 3000;\n' \
        > "${flow}/system/controlDict"
    printf 'FoamFile { object turbulenceProperties; }\nsimulationType RAS;\n' \
        > "${flow}/constant/turbulenceProperties"
    printf 'FoamFile { object blockMeshDict; }\nvertices ( <xMin> <yMin> <zMin> <xMax> <yMax> <zMax> );\nblocks ( hex ( <nx> <ny> <nz> ) );\n' \
        > "${flow}/system/blockMeshDict"
    printf 'FoamFile { object snappyHexMeshDict; }\nsnap <snap_ctrl>;\n' \
        > "${flow}/system/snappyHexMeshDict"
    printf 'solid f18p2\nendsolid f18p2\n' > "${flow}/constant/triSurface/f18p2_all.stl"

    mkdir -p "${transport}/0" "${transport}/system"
    printf 'FoamFile { object T; }\n' > "${transport}/0/T"
    printf 'FoamFile { object controlDict; }\napplication scalarTransportDeffFoam;\n' \
        > "${transport}/system/controlDict"
}

# make_setup_side_commands <bin_dir> - the setup commands that are not controls.
make_setup_side_commands() {
    cat > "${1}/surfaceCheck" <<'STUB'
#!/usr/bin/env bash
echo "Overall bounds (0 0 0) (10 10 10)"
exit 0
STUB

    cat > "${1}/foamDictionary" <<'STUB'
#!/usr/bin/env bash
entry=""; file=""; previous=""
for arg in "$@"; do
    case "$previous" in
        -entry) entry="$arg" ;;
        -value) file="$arg" ;;
    esac
    previous="$arg"
done
if [[ -n "$file" && -f "$file" ]]; then
    awk -v key="${entry##*.}" '
        $1 == key {
            line = $0
            sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", line)
            gsub(/;/, "", line)
            print line
            exit
        }' "$file"
fi
exit 0
STUB

    chmod +x "${1}/surfaceCheck" "${1}/foamDictionary"
}

# new_pool_workspace <name> - one workspace with four runnable Cases.
new_pool_workspace() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    assert_fakes_active
    make_csv "${workspace}/output_batch_1.csv" 0 1 2 3
}

# ---- mesh: the job pool keeps the exact limit and completes every Case ------

new_pool_workspace mesh_pool
for index in 0 1 2 3; do
    make_flow_case "${workspace}/case_${index}/flow" 2
done
new_control mesh_pool
mesh_bin="${workspace}/_control_bin"
mkdir -p "$mesh_bin"
write_case_control "$mesh_bin" blockMesh "${FAKE_BIN_DIR}/blockMesh"
new_sleep_record mesh_pool

pool_saved_path="$PATH"
PATH="${mesh_bin}:${SLEEP_CONTROL_DIR}/bin:${PATH}"
assert_eq "${mesh_bin}/blockMesh" "$(command -v blockMesh)" \
    "the mesh control resolves before the fake blockMesh"
out="$(cd "$workspace" && LC_ALL=C X_SLEEP_RECORD="$SLEEP_RECORD" \
        timeout "$STAGE_TIMEOUT" bash "$MESH_SCRIPT" \
        -i output_batch_1.csv -O . -j "$JOB_LIMIT" 2>&1)" && status=0 || status=$?
PATH="$pool_saved_path"

assert_ne 124 "$status" "the mesh pool run completes without an external kill"
assert_status 0 "$status" "the mesh pool run keeps exit status 0"
assert_pool_shape "mesh"

mesh_expected=""
for index in 0 1 2 3; do
    mesh_expected+="\"${workspace}/output_batch_1.csv\",\"$(( index + 2 ))\",\"case_${index}\",\"case_${index}/flow\",\"${workspace}/case_${index}/flow\",\"meshed\",\"OK\""$'\n'
done
assert_eq 'csv_file,row_number,case_id,case_name,case_dir,status,message' \
    "$(sed -n '1p' "${workspace}/run_mesh_cases_summary.csv")" \
    "the mesh pool run keeps its exact header"
assert_eq "$(printf '%s' "$mesh_expected" | sort)" \
    "$(summary_rows_sorted "${workspace}/run_mesh_cases_summary.csv")" \
    "the mesh pool run keeps one exact summary row for each Case"
assert_contains "$out" "All mesh jobs finished." \
    "the mesh pool run keeps its success message"
assert_file_missing "${workspace}/.run_mesh_cases_failed" \
    "the mesh pool run writes no Failure Artifact"
for index in 0 1 2 3; do
    assert_file_exists "${workspace}/case_${index}/flow/restart.marker" \
        "case_${index}/flow keeps its restart marker"
    assert_contains "$out" "MESH RUNNING [$(( index + 1 ))/4]: case_${index}/flow" \
        "the mesh pre-launch message for case_${index} keeps its DOE Batch CSV order"
done
assert_eq "$CASE_COUNT" "$(fake_call_count checkMesh)" \
    "every mesh Case runs checkMesh exactly once"
assert_eq "" "$(find "$workspace" -name 'run_*_cases_status.*' | sort | tr '\n' ' ')" \
    "no private accounting directory enters the mesh Batch Workspace"

# ---- flow: the job pool keeps the exact limit and completes every Case ------

new_pool_workspace flow_pool
for index in 0 1 2 3; do
    make_flow_case "${workspace}/case_${index}/flow" 2
    make_flow_mesh "${workspace}/case_${index}/flow"
    printf 'FoamFile { object wallDistance; }\n' \
        > "${workspace}/case_${index}/flow/0/wallDistance"
done
new_control flow_pool
flow_bin="${workspace}/_control_bin"
mkdir -p "$flow_bin"
write_case_control "$flow_bin" simpleFoam "${FAKE_BIN_DIR}/simpleFoam"
new_sleep_record flow_pool

pool_saved_path="$PATH"
PATH="${flow_bin}:${SLEEP_CONTROL_DIR}/bin:${PATH}"
assert_eq "${flow_bin}/simpleFoam" "$(command -v simpleFoam)" \
    "the flow control resolves before the fake simpleFoam"
out="$(cd "$workspace" && LC_ALL=C X_SLEEP_RECORD="$SLEEP_RECORD" \
        timeout "$STAGE_TIMEOUT" bash "$FLOW_SCRIPT" \
        -i output_batch_1.csv -O . -j "$JOB_LIMIT" 2>&1)" && status=0 || status=$?
PATH="$pool_saved_path"

assert_ne 124 "$status" "the flow pool run completes without an external kill"
assert_status 0 "$status" "the flow pool run keeps exit status 0"
assert_pool_shape "flow"

flow_expected=""
for index in 0 1 2 3; do
    flow_expected+="\"${workspace}/output_batch_1.csv\",\"$(( index + 2 ))\",\"case_${index}\",\"case_${index}/flow\",\"${workspace}/case_${index}/flow\",\"solved\",\"OK\""$'\n'
done
assert_eq 'csv_file,row_number,case_id,case_name,case_dir,status,message' \
    "$(sed -n '1p' "${workspace}/run_flow_cases_summary.csv")" \
    "the flow pool run keeps its exact header"
assert_eq "$(printf '%s' "$flow_expected" | sort)" \
    "$(summary_rows_sorted "${workspace}/run_flow_cases_summary.csv")" \
    "the flow pool run keeps one exact summary row for each Case"
assert_contains "$out" "All flow jobs finished." \
    "the flow pool run keeps its success message"
assert_file_missing "${workspace}/.run_flow_cases_failed" \
    "the flow pool run writes no Failure Artifact"
for index in 0 1 2 3; do
    assert_file_exists "${workspace}/case_${index}/flow/flow.marker" \
        "case_${index}/flow keeps its flow marker"
    assert_contains "$out" "Launching [$(( index + 1 ))/4]: case_${index}/flow" \
        "the flow pre-launch message for case_${index} keeps its DOE Batch CSV order"
done
assert_eq "$CASE_COUNT" "$(fake_call_count reconstructPar)" \
    "every flow Case runs reconstructPar exactly once"
assert_eq "" "$(find "$workspace" -name 'run_*_cases_status.*' | sort | tr '\n' ' ')" \
    "no private accounting directory enters the flow Batch Workspace"

# ---- transport: the job pool keeps the exact limit -------------------------

new_pool_workspace transport_pool
for index in 0 1 2 3; do
    make_flow_case "${workspace}/case_${index}/flow" 2
    make_flow_mesh "${workspace}/case_${index}/flow"
    make_flow_result "${workspace}/case_${index}/flow" 3000
    make_transport_case "${workspace}/case_${index}/trd" 2 T 300
done
new_control transport_pool
transport_bin="${workspace}/_control_bin"
mkdir -p "$transport_bin"
write_case_control "$transport_bin" scalarTransportDeffFoam \
    "${FAKE_BIN_DIR}/scalarTransportDeffFoam"
new_sleep_record transport_pool

pool_saved_path="$PATH"
PATH="${transport_bin}:${SLEEP_CONTROL_DIR}/bin:${PATH}"
assert_eq "${transport_bin}/scalarTransportDeffFoam" \
    "$(command -v scalarTransportDeffFoam)" \
    "the transport control resolves before the fake solver"
out="$(cd "$workspace" && LC_ALL=C X_SLEEP_RECORD="$SLEEP_RECORD" \
        timeout "$STAGE_TIMEOUT" bash "$TRANSPORT_SCRIPT" \
        -i output_batch_1.csv -O . -j "$JOB_LIMIT" --save-times 300 2>&1)" \
    && status=0 || status=$?
PATH="$pool_saved_path"

assert_ne 124 "$status" "the transport pool run completes without an external kill"
assert_status 0 "$status" "the transport pool run keeps exit status 0"
assert_pool_shape "transport"

transport_expected=""
for index in 0 1 2 3; do
    transport_expected+="\"${workspace}/output_batch_1.csv\",\"$(( index + 2 ))\",\"case_${index}\",\"case_${index}/flow|case_${index}/trd\",\"${workspace}/case_${index}/trd\",\"solved\",\"OK\""$'\n'
done
assert_eq 'csv_file,row_number,case_id,flow_case_transport_case,transport_case_dir,status,message' \
    "$(sed -n '1p' "${workspace}/run_transport_cases_summary.csv")" \
    "the transport pool run keeps its exact header"
assert_eq "$(printf '%s' "$transport_expected" | sort)" \
    "$(summary_rows_sorted "${workspace}/run_transport_cases_summary.csv")" \
    "the transport pool run keeps one exact summary row for each Case"
assert_contains "$out" "All transport jobs finished." \
    "the transport pool run keeps its success message"
assert_file_missing "${workspace}/.run_transport_cases_failed" \
    "the transport pool run writes no Failure Artifact"
for index in 0 1 2 3; do
    assert_file_exists "${workspace}/case_${index}/trd/transport.marker" \
        "case_${index}/trd keeps its transport marker"
    assert_contains "$out" "TRANSPORT RUNNING [$(( index + 1 ))/4]: case_${index}/trd" \
        "the transport pre-launch message for case_${index} keeps its DOE Batch CSV order"
done
assert_eq "" "$(find "$workspace" -name 'run_*_cases_status.*' | sort | tr '\n' ' ')" \
    "no private accounting directory enters the transport Batch Workspace"

# ---- post-processing: the job pool keeps the exact limit -------------------

new_pool_workspace post_pool
for index in 0 1 2 3; do
    make_flow_case "${workspace}/case_${index}/flow" 2
    make_flow_result "${workspace}/case_${index}/flow" 3000
    make_transport_case "${workspace}/case_${index}/trd" 2 T 300
done
new_control post_pool
post_bin="${workspace}/_control_bin"
mkdir -p "$post_bin"
write_case_control "$post_bin" foamToVTK "${FAKE_BIN_DIR}/foamToVTK"
new_sleep_record post_pool

pool_saved_path="$PATH"
PATH="${post_bin}:${SLEEP_CONTROL_DIR}/bin:${PATH}"
assert_eq "${post_bin}/foamToVTK" "$(command -v foamToVTK)" \
    "the post-processing control resolves before the fake foamToVTK"
out="$(cd "$workspace" && LC_ALL=C X_SLEEP_RECORD="$SLEEP_RECORD" \
        timeout "$STAGE_TIMEOUT" bash "$POST_SCRIPT" \
        -i output_batch_1.csv -O . -j "$JOB_LIMIT" 2>&1)" && status=0 || status=$?
PATH="$pool_saved_path"

assert_ne 124 "$status" \
    "the post-processing pool run completes without an external kill"
assert_status 0 "$status" "the post-processing pool run keeps exit status 0"
assert_pool_shape "post-processing"

post_expected=""
for index in 0 1 2 3; do
    post_expected+="\"case_${index}\",\"${workspace}/case_${index}\",\"completed\",\"flow and transport VTU files created\""$'\n'
done
assert_eq 'case_id,case_dir,status,message' \
    "$(sed -n '1p' "${workspace}/run_post_processing_cases_summary.csv")" \
    "the post-processing pool run keeps its exact header"
assert_eq "$(printf '%s' "$post_expected" | sort)" \
    "$(summary_rows_sorted "${workspace}/run_post_processing_cases_summary.csv")" \
    "the post-processing pool run keeps one exact summary row for each Case"
assert_contains "$out" "All post-processing jobs completed." \
    "the post-processing pool run keeps its success message"
assert_file_missing "${workspace}/.run_post_processing_cases_failed" \
    "the post-processing pool run writes no Failure Artifact"
for index in 0 1 2 3; do
    assert_contains "$out" "Launching [$(( index + 1 ))]: case_${index}" \
        "the post-processing pre-launch message for case_${index} keeps its order"
done
# Post-processing gives no aggregate progress output.
assert_not_contains "$out" "Progress: launched=" \
    "post-processing gives no aggregate progress output"

# ---- setup: the job pool keeps the exact limit -----------------------------
#
# Setup uses a configured non-dry-run path. The control point is a
# scenario-local surfaceTransformPoints executable, and every row reaches it.

new_pool_workspace setup_pool
make_setup_bases "$workspace"
new_control setup_pool
setup_bin="${workspace}/_control_bin"
mkdir -p "$setup_bin"
make_setup_side_commands "$setup_bin"
write_case_control "$setup_bin" surfaceTransformPoints "${SLEEP_REAL%/*}/true" \
    'echo "Set centre of rotation to (100 200 0)"
'
new_sleep_record setup_pool

pool_saved_path="$PATH"
PATH="${setup_bin}:${SLEEP_CONTROL_DIR}/bin:${PATH}"
for command_name in surfaceCheck surfaceTransformPoints foamDictionary; do
    assert_eq "${setup_bin}/${command_name}" "$(command -v "$command_name")" \
        "the setup ${command_name} resolves to the scenario directory"
done
out="$(cd "$workspace" && LC_ALL=C X_SLEEP_RECORD="$SLEEP_RECORD" \
        timeout "$STAGE_TIMEOUT" bash "$SETUP_SCRIPT" \
        -i output_batch_1.csv -O . -j "$JOB_LIMIT" 2>&1)" && status=0 || status=$?
PATH="$pool_saved_path"

assert_ne 124 "$status" "the setup pool run completes without an external kill"
assert_status 0 "$status" "the setup pool run keeps exit status 0"
assert_pool_shape "setup"

setup_expected=""
for index in 0 1 2 3; do
    setup_expected+="\"${workspace}/output_batch_1.csv\",\"$(( index + 2 ))\",\"case_${index}\",\"case_${index}/flow\",\"270.000\",\"3.5\",\"3.5\",\"${workspace}/case_${index}/flow\",\"created\",\"flow case created\""$'\n'
    setup_expected+="\"${workspace}/output_batch_1.csv\",\"$(( index + 2 ))\",\"case_${index}\",\"case_${index}/trd\",\"270.000\",\"3.5\",\"3.5\",\"${workspace}/case_${index}/trd\",\"created\",\"transport case created\""$'\n'
done
assert_eq 'csv_file,row_number,case_id,case_name,wd,ws,ws_for_setup,case_dir,status,message' \
    "$(sed -n '1p' "${workspace}/setup_cases_summary.csv")" \
    "the setup pool run keeps its exact header"
assert_eq "$(printf '%s' "$setup_expected" | sort)" \
    "$(summary_rows_sorted "${workspace}/setup_cases_summary.csv")" \
    "the setup pool run keeps one exact summary row for each created Case"
# Setup keeps its initialized Failure Artifact and never removes it, unlike the
# other Stage Runners. The successful run leaves it empty.
assert_file_bytes_exact "${workspace}/.setup_cases_failed" "" \
    "the setup pool run keeps an empty Failure Artifact"
assert_contains "$out" "Done." "the setup pool run keeps its success message"

# ---- shared-helper delegation through a copied deployment unit -------------
#
# The copied library keeps its production content and then receives compatible
# instrumented implementations of the four approved job-pool helpers. Each
# instrumented helper keeps the production scheduling behavior and records one
# call outside the Batch Workspace. A Stage Runner that keeps local scheduling
# loops produces no record, so this group fails before the extraction.
#
# The test never sources the library and never calls a helper.

HELPER_RECORD_DIR="${CONTROL_ROOT}/helpers"
mkdir -p "$HELPER_RECORD_DIR"

# make_instrumented_unit <master_dir>
make_instrumented_unit() {
    local master="$1" name
    mkdir -p "$master"
    for name in lib_batch_stage.sh setup_cases.sh run_mesh_cases.sh \
            run_flow_cases.sh run_transport_cases.sh run_post_processing_cases.sh; do
        cp -f -- "${MASTER_SRC_DIR}/${name}" "${master}/${name}"
    done

    cat >> "${master}/lib_batch_stage.sh" <<'INSTRUMENT'

# Test instrumentation. Each definition keeps the approved scheduling behavior
# and records one call outside the Batch Workspace.
__x_record() { printf '%s\n' "$1" >> "${X_HELPER_RECORD:-/dev/null}"; }

batch_stage_job_pool_running_count() {
    __x_record running_count
    jobs -rp | wc -l | tr -d ' '
}

batch_stage_job_pool_wait_n_supported() {
    __x_record wait_n_supported
    (( BASH_VERSINFO[0] > 4 ||
       (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) ))
}

batch_stage_job_pool_wait_for_slot() {
    local __batch_stage_job_pool_maximum="$1"
    local __batch_stage_job_pool_before="$2"
    local __batch_stage_job_pool_status="$3"
    local __batch_stage_job_pool_post_cycle_seconds="$4"
    local __batch_stage_job_pool_wait_status

    __x_record wait_for_slot
    while true; do
        if (( $(batch_stage_job_pool_running_count) < __batch_stage_job_pool_maximum )); then
            return 0
        fi
        "$__batch_stage_job_pool_before"
        if batch_stage_job_pool_wait_n_supported; then
            __x_record wait_n_selected
            __batch_stage_job_pool_wait_status=0
            wait -n || __batch_stage_job_pool_wait_status=$?
            "$__batch_stage_job_pool_status" "$__batch_stage_job_pool_wait_status"
        else
            __x_record fallback_poll
            sleep 0.5
        fi
        if [[ "$__batch_stage_job_pool_post_cycle_seconds" != "0" ]]; then
            sleep "$__batch_stage_job_pool_post_cycle_seconds"
        fi
    done
}

batch_stage_job_pool_wait_for_all() {
    local __batch_stage_job_pool_before="$1"
    local __batch_stage_job_pool_status="$2"
    local __batch_stage_job_pool_post_cycle_seconds="$3"
    local __batch_stage_job_pool_wait_status

    __x_record wait_for_all
    while true; do
        if (( $(batch_stage_job_pool_running_count) == 0 )); then
            return 0
        fi
        "$__batch_stage_job_pool_before"
        if batch_stage_job_pool_wait_n_supported; then
            __x_record wait_n_selected
            __batch_stage_job_pool_wait_status=0
            wait -n || __batch_stage_job_pool_wait_status=$?
            "$__batch_stage_job_pool_status" "$__batch_stage_job_pool_wait_status"
        else
            __x_record fallback_poll
            sleep 0.5
        fi
        if [[ "$__batch_stage_job_pool_post_cycle_seconds" != "0" ]]; then
            sleep "$__batch_stage_job_pool_post_cycle_seconds"
        fi
    done
}
INSTRUMENT
}

# assert_helper_delegation <stage> <record> <expect_wait_for_all>
assert_helper_delegation() {
    local stage="$1" record="$2" expect_all="$3"

    assert_file_exists "$record" \
        "the copied ${stage} deployment unit records shared-helper delegation"
    assert_ne 0 "$(grep -c '^running_count$' "$record" || true)" \
        "the copied ${stage} Stage Runner uses the shared running-count helper"
    assert_ne 0 "$(grep -c '^wait_for_slot$' "$record" || true)" \
        "the copied ${stage} Stage Runner uses the shared free-slot helper"
    if [[ "$expect_all" == "yes" ]]; then
        assert_ne 0 "$(grep -c '^wait_for_all$' "$record" || true)" \
            "the copied ${stage} Stage Runner uses the shared wait-for-all helper"
    fi
}

# run_copied_stage <stage> <record-name> <script> <args...>
run_copied_stage() {
    local stage="$1" record_name="$2"
    shift 2
    HELPER_RECORD="${HELPER_RECORD_DIR}/${record_name}.log"
    : > "$HELPER_RECORD"
    ( cd "$workspace" && X_HELPER_RECORD="$HELPER_RECORD" \
        LC_ALL=C timeout "$STAGE_TIMEOUT" bash "$@" ) >/dev/null 2>&1 || true
}

new_pool_workspace delegation
make_setup_bases "$workspace"
for index in 0 1; do
    make_flow_case "${workspace}/case_${index}/flow" 2
    make_flow_mesh "${workspace}/case_${index}/flow"
    printf 'FoamFile { object wallDistance; }\n' \
        > "${workspace}/case_${index}/flow/0/wallDistance"
    make_flow_result "${workspace}/case_${index}/flow" 3000
    make_transport_case "${workspace}/case_${index}/trd" 2 T 300
done
make_csv "${workspace}/output_batch_1.csv" 0 1
delegation_master="${workspace}/master_batch"
make_instrumented_unit "$delegation_master"
delegation_bin="${workspace}/_control_bin"
mkdir -p "$delegation_bin"
make_setup_side_commands "$delegation_bin"
printf '#!/usr/bin/env bash\necho "Set centre of rotation to (100 200 0)"\nexit 0\n' \
    > "${delegation_bin}/surfaceTransformPoints"
chmod +x "${delegation_bin}/surfaceTransformPoints"

pool_saved_path="$PATH"
PATH="${delegation_bin}:${PATH}"
run_copied_stage setup setup "${delegation_master}/setup_cases.sh" \
    -i output_batch_1.csv -O . -j 1
assert_helper_delegation setup "$HELPER_RECORD" no
run_copied_stage mesh mesh "${delegation_master}/run_mesh_cases.sh" \
    -i output_batch_1.csv -O . -j 1
assert_helper_delegation mesh "$HELPER_RECORD" yes
run_copied_stage flow flow "${delegation_master}/run_flow_cases.sh" \
    -i output_batch_1.csv -O . -j 1
assert_helper_delegation flow "$HELPER_RECORD" yes
run_copied_stage transport transport "${delegation_master}/run_transport_cases.sh" \
    -i output_batch_1.csv -O . -j 1 --save-times 300
assert_helper_delegation transport "$HELPER_RECORD" yes
run_copied_stage post post "${delegation_master}/run_post_processing_cases.sh" \
    -i output_batch_1.csv -O . -j 1
assert_helper_delegation post-processing "$HELPER_RECORD" yes
PATH="$pool_saved_path"
