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
        printf 'control_dir=%q\n' "$control_dir"
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

# The suppression control removes both record channels once, so only the
# caller-owned wait counter can keep the Stage result non-zero.
if [[ -n "${X_SUPPRESS_SUMMARY:-}" ]] && mkdir "${control_dir}/suppress_once" 2>/dev/null; then
    if [[ -f "$X_SUPPRESS_SUMMARY" ]]; then
        mv -- "$X_SUPPRESS_SUMMARY" "${control_dir}/summary_evidence"
        ln -s /proc/version "$X_SUPPRESS_SUMMARY"
    fi
    if [[ -n "${X_SUPPRESS_ARTIFACT:-}" && -f "$X_SUPPRESS_ARTIFACT" ]]; then
        mv -- "$X_SUPPRESS_ARTIFACT" "${control_dir}/artifact_evidence"
        ln -s /proc/version "$X_SUPPRESS_ARTIFACT"
    fi
    printf 'suppressed\n' >> "$control_events"
fi

# The selected Case fails while the parent shell is inside a job-pool wait. The
# control fails before any parseable output, so a Stage Runner that reads the
# command output also observes the failure.
if [[ -n "${X_FAIL_TOKEN:-}" && "$control_token" == "${X_FAIL_TOKEN}" ]]; then
    if (( control_owner == 1 )); then
        rm -f -- "${control_active}/${control_token}"
        printf 'exit %s 1\n' "$control_token" >> "$control_events"
    fi
    exit 1
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

# assert_sleep_argument <record> <argument> <expectation> <label>
# The scenario-local sleep control records every sleep argument. The Case
# control itself sleeps 0.05 seconds, so an assertion names only the exact
# production argument that it proves.
assert_sleep_argument() {
    local record="$1" argument="$2" expectation="$3" label="$4" count
    count="$(grep -c "^${argument}\$" "$record" || true)"

    if [[ "$expectation" == "present" ]]; then
        assert_ne 0 "$count" "${label}: the production sleep ${argument} runs"
    else
        assert_eq 0 "$count" "${label}: no production sleep ${argument} runs"
    fi
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
assert_sleep_argument "$SLEEP_RECORD" 0.1 present "mesh free-slot"
assert_sleep_argument "$SLEEP_RECORD" 0.5 absent "mesh on Bash 4.3 or later"
# The mesh final drain forces progress on every cycle, so more than one
# progress line appears inside the throttle window.
assert_eq 1 "$(( $(grep -c 'Mesh progress:' <<< "$out") >= 2 ? 1 : 0 ))" \
    "the mesh final drain keeps its forced progress call"

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
assert_sleep_argument "$SLEEP_RECORD" 0.1 present "flow free-slot"
assert_sleep_argument "$SLEEP_RECORD" 0.5 absent "flow on Bash 4.3 or later"
# The flow final drain resets the progress throttle before each callback.
assert_eq 1 "$(( $(grep -c 'Progress: launched=' <<< "$out") >= 2 ? 1 : 0 ))" \
    "the flow final drain resets the progress throttle"

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
assert_sleep_argument "$SLEEP_RECORD" 0.1 absent "transport"
assert_sleep_argument "$SLEEP_RECORD" 0.5 absent "transport on Bash 4.3 or later"
# The transport final drain resets the progress throttle before each callback.
assert_eq 1 "$(( $(grep -c 'Transport progress:' <<< "$out") >= 2 ? 1 : 0 ))" \
    "the transport final drain resets the progress throttle"

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
assert_sleep_argument "$SLEEP_RECORD" 0.1 absent "post-processing"
assert_sleep_argument "$SLEEP_RECORD" 0.5 absent "post-processing on Bash 4.3 or later"

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
assert_sleep_argument "$SLEEP_RECORD" 0.1 absent "setup"
assert_sleep_argument "$SLEEP_RECORD" 0.5 absent "setup on Bash 4.3 or later"

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

# The natural Bash 4.3-or-later path selects wait -n in every Stage Runner.
for stage in setup mesh flow transport post; do
    assert_ne 0 "$(grep -c '^wait_n_selected$' "${HELPER_RECORD_DIR}/${stage}.log" || true)" \
        "the copied ${stage} Stage Runner records that wait -n is selected"
    assert_eq 0 "$(grep -c '^fallback_poll$' "${HELPER_RECORD_DIR}/${stage}.log" || true)" \
        "the copied ${stage} Stage Runner does not use the fallback poll on this Bash"
done

# Every control record lives outside every Batch Workspace.
assert_eq "" "$(find "$CONTRACT_TEST_RUN_DIR" -path "${CONTROL_ROOT}" -prune -o \
        -name 'peaks' -print -o -name 'events' -print | grep -v "^${CONTROL_ROOT}" | sort | tr '\n' ' ')" \
    "no job-pool control record enters a Batch Workspace"

# ---- a controlled Case failure during a job-pool wait ----------------------
#
# One Case fails while the parent shell is inside a job-pool wait. Each Stage
# Runner must keep its exact current failed status, summary row, Failure
# Artifact bytes, marker behavior, and failure message.

FAIL_TOKEN="case_1"

# ---- mesh failure ----
new_pool_workspace mesh_fail_pool
for index in 0 1 2 3; do
    make_flow_case "${workspace}/case_${index}/flow" 2
done
new_control mesh_fail_pool
fail_bin="${workspace}/_control_bin"
mkdir -p "$fail_bin"
write_case_control "$fail_bin" blockMesh "${FAKE_BIN_DIR}/blockMesh"
new_sleep_record mesh_fail_pool
pool_saved_path="$PATH"
PATH="${fail_bin}:${SLEEP_CONTROL_DIR}/bin:${PATH}"
out="$(cd "$workspace" && LC_ALL=C X_FAIL_TOKEN="$FAIL_TOKEN" \
        X_SLEEP_RECORD="$SLEEP_RECORD" timeout "$STAGE_TIMEOUT" \
        bash "$MESH_SCRIPT" -i output_batch_1.csv -O . -j "$JOB_LIMIT" 2>&1)" \
    && status=0 || status=$?
PATH="$pool_saved_path"

assert_ne 124 "$status" "the mesh failure run completes without an external kill"
assert_failure "$status" "one failed mesh Case keeps a non-zero Stage status"
assert_pool_shape "mesh failure"
assert_eq 3 "$(summary_status_count "${workspace}/run_mesh_cases_summary.csv" meshed)" \
    "the mesh failure run keeps three meshed rows"
assert_eq 1 "$(summary_status_count "${workspace}/run_mesh_cases_summary.csv" failed)" \
    "the mesh failure run keeps one failed row"
assert_file_bytes_exact "${workspace}/.run_mesh_cases_failed" "case_1/flow"$'\n' \
    "the mesh failure run Failure Artifact"
assert_file_missing "${workspace}/case_1/flow/restart.marker" \
    "the failed mesh Case writes no restart marker"
assert_contains "$out" "One or more mesh jobs failed." \
    "the mesh failure run keeps its failure message"
assert_not_contains "$out" "All mesh jobs finished." \
    "the mesh failure run does not report success"

# ---- flow failure ----
new_pool_workspace flow_fail_pool
for index in 0 1 2 3; do
    make_flow_case "${workspace}/case_${index}/flow" 2
    make_flow_mesh "${workspace}/case_${index}/flow"
    printf 'FoamFile { object wallDistance; }\n' \
        > "${workspace}/case_${index}/flow/0/wallDistance"
done
new_control flow_fail_pool
fail_bin="${workspace}/_control_bin"
mkdir -p "$fail_bin"
write_case_control "$fail_bin" simpleFoam "${FAKE_BIN_DIR}/simpleFoam"
new_sleep_record flow_fail_pool
pool_saved_path="$PATH"
PATH="${fail_bin}:${SLEEP_CONTROL_DIR}/bin:${PATH}"
out="$(cd "$workspace" && LC_ALL=C X_FAIL_TOKEN="$FAIL_TOKEN" \
        X_SLEEP_RECORD="$SLEEP_RECORD" timeout "$STAGE_TIMEOUT" \
        bash "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j "$JOB_LIMIT" 2>&1)" \
    && status=0 || status=$?
PATH="$pool_saved_path"

assert_ne 124 "$status" "the flow failure run completes without an external kill"
assert_failure "$status" "one failed flow Case keeps a non-zero Stage status"
assert_pool_shape "flow failure"
assert_eq 3 "$(summary_status_count "${workspace}/run_flow_cases_summary.csv" solved)" \
    "the flow failure run keeps three solved rows"
assert_eq 1 "$(summary_status_count "${workspace}/run_flow_cases_summary.csv" failed)" \
    "the flow failure run keeps one failed row"
assert_file_bytes_exact "${workspace}/.run_flow_cases_failed" "case_1/flow"$'\n' \
    "the flow failure run Failure Artifact"
assert_file_missing "${workspace}/case_1/flow/flow.marker" \
    "the failed flow Case writes no flow marker"
assert_contains "$out" "One or more flow jobs failed." \
    "the flow failure run keeps its failure message"

# ---- transport failure ----
new_pool_workspace transport_fail_pool
for index in 0 1 2 3; do
    make_flow_case "${workspace}/case_${index}/flow" 2
    make_flow_mesh "${workspace}/case_${index}/flow"
    make_flow_result "${workspace}/case_${index}/flow" 3000
    make_transport_case "${workspace}/case_${index}/trd" 2 T 300
done
new_control transport_fail_pool
fail_bin="${workspace}/_control_bin"
mkdir -p "$fail_bin"
write_case_control "$fail_bin" scalarTransportDeffFoam \
    "${FAKE_BIN_DIR}/scalarTransportDeffFoam"
new_sleep_record transport_fail_pool
pool_saved_path="$PATH"
PATH="${fail_bin}:${SLEEP_CONTROL_DIR}/bin:${PATH}"
out="$(cd "$workspace" && LC_ALL=C X_FAIL_TOKEN="$FAIL_TOKEN" \
        X_SLEEP_RECORD="$SLEEP_RECORD" timeout "$STAGE_TIMEOUT" \
        bash "$TRANSPORT_SCRIPT" -i output_batch_1.csv -O . -j "$JOB_LIMIT" \
        --save-times 300 2>&1)" && status=0 || status=$?
PATH="$pool_saved_path"

assert_ne 124 "$status" \
    "the transport failure run completes without an external kill"
assert_failure "$status" "one failed transport Case keeps a non-zero Stage status"
assert_pool_shape "transport failure"
assert_eq 3 "$(summary_status_count "${workspace}/run_transport_cases_summary.csv" solved)" \
    "the transport failure run keeps three solved rows"
assert_eq 1 "$(summary_status_count "${workspace}/run_transport_cases_summary.csv" failed)" \
    "the transport failure run keeps one failed row"
assert_file_bytes_exact "${workspace}/.run_transport_cases_failed" "case_1/trd"$'\n' \
    "the transport failure run Failure Artifact"
assert_file_missing "${workspace}/case_1/trd/transport.marker" \
    "the failed transport Case writes no transport marker"
assert_contains "$out" "One or more transport jobs failed." \
    "the transport failure run keeps its failure message"

# ---- post-processing failure ----
new_pool_workspace post_fail_pool
for index in 0 1 2 3; do
    make_flow_case "${workspace}/case_${index}/flow" 2
    make_flow_result "${workspace}/case_${index}/flow" 3000
    make_transport_case "${workspace}/case_${index}/trd" 2 T 300
done
new_control post_fail_pool
fail_bin="${workspace}/_control_bin"
mkdir -p "$fail_bin"
write_case_control "$fail_bin" foamToVTK "${FAKE_BIN_DIR}/foamToVTK"
new_sleep_record post_fail_pool
pool_saved_path="$PATH"
PATH="${fail_bin}:${SLEEP_CONTROL_DIR}/bin:${PATH}"
out="$(cd "$workspace" && LC_ALL=C X_FAIL_TOKEN="$FAIL_TOKEN" \
        X_SLEEP_RECORD="$SLEEP_RECORD" timeout "$STAGE_TIMEOUT" \
        bash "$POST_SCRIPT" -i output_batch_1.csv -O . -j "$JOB_LIMIT" 2>&1)" \
    && status=0 || status=$?
PATH="$pool_saved_path"

assert_ne 124 "$status" \
    "the post-processing failure run completes without an external kill"
assert_failure "$status" \
    "one failed post-processing Case keeps a non-zero Stage status"
assert_pool_shape "post-processing failure"
assert_eq 3 "$(summary_status_count "${workspace}/run_post_processing_cases_summary.csv" completed 3)" \
    "the post-processing failure run keeps three completed rows"
assert_eq 1 "$(summary_status_count "${workspace}/run_post_processing_cases_summary.csv" failed 3)" \
    "the post-processing failure run keeps one failed row"
assert_file_bytes_exact "${workspace}/.run_post_processing_cases_failed" "case_1"$'\n' \
    "the post-processing failure run Failure Artifact"
assert_contains "$out" "One or more post-processing jobs failed." \
    "the post-processing failure run keeps its failure message"

# ---- setup failure ----
new_pool_workspace setup_fail_pool
make_setup_bases "$workspace"
new_control setup_fail_pool
fail_bin="${workspace}/_control_bin"
mkdir -p "$fail_bin"
make_setup_side_commands "$fail_bin"
write_case_control "$fail_bin" surfaceTransformPoints "${SLEEP_REAL%/*}/true" \
    'echo "Set centre of rotation to (100 200 0)"
'
new_sleep_record setup_fail_pool
pool_saved_path="$PATH"
PATH="${fail_bin}:${SLEEP_CONTROL_DIR}/bin:${PATH}"
out="$(cd "$workspace" && LC_ALL=C X_FAIL_TOKEN="$FAIL_TOKEN" \
        X_SLEEP_RECORD="$SLEEP_RECORD" timeout "$STAGE_TIMEOUT" \
        bash "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j "$JOB_LIMIT" 2>&1)" \
    && status=0 || status=$?
PATH="$pool_saved_path"

assert_ne 124 "$status" "the setup failure run completes without an external kill"
assert_failure "$status" "one failed setup row keeps a non-zero Stage status"
assert_pool_shape "setup failure"
# A setup row job that stops mid-way records no summary row. The Failure
# Artifact records the row, and the Stage status stays non-zero.
assert_eq 6 "$(summary_status_count "${workspace}/setup_cases_summary.csv" created 9)" \
    "the setup failure run keeps the created rows of the other Cases"
assert_eq 0 "$(summary_status_count "${workspace}/setup_cases_summary.csv" failed 9)" \
    "the failed setup row writes no summary row"
assert_file_bytes_exact "${workspace}/.setup_cases_failed" \
    "${workspace}/output_batch_1.csv,3"$'\n' \
    "the setup failure run Failure Artifact"
assert_contains "$out" "Some rows failed." \
    "the setup failure run keeps its failure message"

# ---- the Orchestrator keeps its failure propagation for each Stage ---------

# build_orchestrated <name> <runner-source> <runner-name>
build_orchestrated() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    assert_fakes_active
    use_stub_records "$workspace"
    master="${workspace}/master_batch"
    output="${workspace}/out"
    make_stub_master "$master" master
    cp -f -- "$2" "${master}/${3}"
    cp -f -- "${MASTER_SRC_DIR}/lib_batch_stage.sh" "${master}/lib_batch_stage.sh"
    mkdir -p "$output" "${output}/batch_1"
    make_csv "${workspace}/output_batch_1.csv" 0 1 2 3
    cp -f -- "${workspace}/output_batch_1.csv" "${output}/batch_1/output_batch_1.csv"
}

# assert_orchestrated_failure <runner-name> <output>
assert_orchestrated_failure() {
    assert_ne 124 "$status" "the orchestrated ${1} run completes without an external kill"
    assert_failure "$status" "the orchestrated ${1} run keeps a non-zero status"
    assert_contains "$2" "Stage failed  : ${1}" \
        "the Orchestrator names the failed ${1} Stage"
    assert_contains "$2" "Batch failed: batch_1" \
        "the Orchestrator marks the batch failed for ${1}"
    assert_not_contains "$2" "All requested batches and stages finished successfully." \
        "the Orchestrator reports no overall success for ${1}"
}

# ---- orchestrated mesh ----
build_orchestrated orch_mesh "$MESH_SCRIPT" run_mesh_cases.sh
for index in 0 1 2 3; do
    make_flow_case "${output}/batch_1/case_${index}/flow" 2
done
new_control orch_mesh
orch_bin="${workspace}/_control_bin"
mkdir -p "$orch_bin"
write_case_control "$orch_bin" blockMesh "${FAKE_BIN_DIR}/blockMesh"
pool_saved_path="$PATH"
PATH="${orch_bin}:${PATH}"
out="$(cd "$workspace" && LC_ALL=C X_FAIL_TOKEN="$FAIL_TOKEN" \
        timeout "$STAGE_TIMEOUT" bash "$RUN_BATCH" --stage mesh \
        -j "$JOB_LIMIT" -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?
PATH="$pool_saved_path"
assert_orchestrated_failure run_mesh_cases.sh "$out"
assert_pool_shape "orchestrated mesh"

# ---- orchestrated flow ----
build_orchestrated orch_flow "$FLOW_SCRIPT" run_flow_cases.sh
for index in 0 1 2 3; do
    make_flow_case "${output}/batch_1/case_${index}/flow" 2
    make_flow_mesh "${output}/batch_1/case_${index}/flow"
    printf 'FoamFile { object wallDistance; }\n' \
        > "${output}/batch_1/case_${index}/flow/0/wallDistance"
done
new_control orch_flow
orch_bin="${workspace}/_control_bin"
mkdir -p "$orch_bin"
write_case_control "$orch_bin" simpleFoam "${FAKE_BIN_DIR}/simpleFoam"
pool_saved_path="$PATH"
PATH="${orch_bin}:${PATH}"
out="$(cd "$workspace" && LC_ALL=C X_FAIL_TOKEN="$FAIL_TOKEN" \
        timeout "$STAGE_TIMEOUT" bash "$RUN_BATCH" --stage flow \
        -j "$JOB_LIMIT" -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?
PATH="$pool_saved_path"
assert_orchestrated_failure run_flow_cases.sh "$out"
assert_pool_shape "orchestrated flow"

# ---- orchestrated transport ----
build_orchestrated orch_transport "$TRANSPORT_SCRIPT" run_transport_cases.sh
for index in 0 1 2 3; do
    make_flow_case "${output}/batch_1/case_${index}/flow" 2
    make_flow_mesh "${output}/batch_1/case_${index}/flow"
    make_flow_result "${output}/batch_1/case_${index}/flow" 3000
    make_transport_case "${output}/batch_1/case_${index}/trd" 2 T 300
done
new_control orch_transport
orch_bin="${workspace}/_control_bin"
mkdir -p "$orch_bin"
write_case_control "$orch_bin" scalarTransportDeffFoam \
    "${FAKE_BIN_DIR}/scalarTransportDeffFoam"
pool_saved_path="$PATH"
PATH="${orch_bin}:${PATH}"
out="$(cd "$workspace" && LC_ALL=C X_FAIL_TOKEN="$FAIL_TOKEN" \
        timeout "$STAGE_TIMEOUT" bash "$RUN_BATCH" --stage transport \
        -j "$JOB_LIMIT" --save-times 300 -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?
PATH="$pool_saved_path"
assert_orchestrated_failure run_transport_cases.sh "$out"
assert_pool_shape "orchestrated transport"

# ---- orchestrated post-processing ----
build_orchestrated orch_post "$POST_SCRIPT" run_post_processing_cases.sh
for index in 0 1 2 3; do
    make_flow_case "${output}/batch_1/case_${index}/flow" 2
    make_flow_result "${output}/batch_1/case_${index}/flow" 3000
    make_transport_case "${output}/batch_1/case_${index}/trd" 2 T 300
done
new_control orch_post
orch_bin="${workspace}/_control_bin"
mkdir -p "$orch_bin"
write_case_control "$orch_bin" foamToVTK "${FAKE_BIN_DIR}/foamToVTK"
pool_saved_path="$PATH"
PATH="${orch_bin}:${PATH}"
out="$(cd "$workspace" && LC_ALL=C X_FAIL_TOKEN="$FAIL_TOKEN" \
        timeout "$STAGE_TIMEOUT" bash "$RUN_BATCH" --stage post \
        -j "$JOB_LIMIT" -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?
PATH="$pool_saved_path"
assert_orchestrated_failure run_post_processing_cases.sh "$out"
assert_pool_shape "orchestrated post-processing"

# ---- the caller-owned wait counters stay load-bearing ----------------------
#
# Neither the summary nor the Failure Artifact can record the failure, so only
# the caller-owned wait-status counter keeps the Stage result non-zero. Setup
# uses FAILED_ROW_JOBS and post-processing uses JOB_FAILURES.

# ---- setup: FAILED_ROW_JOBS ----
new_pool_workspace setup_counter
make_setup_bases "$workspace"
new_control setup_counter
counter_bin="${workspace}/_control_bin"
mkdir -p "$counter_bin"
make_setup_side_commands "$counter_bin"
write_case_control "$counter_bin" surfaceTransformPoints "${SLEEP_REAL%/*}/true" \
    'echo "Set centre of rotation to (100 200 0)"
'
pool_saved_path="$PATH"
PATH="${counter_bin}:${PATH}"
out="$(cd "$workspace" && LC_ALL=C X_FAIL_TOKEN="$FAIL_TOKEN" \
        X_SUPPRESS_SUMMARY="${workspace}/setup_cases_summary.csv" \
        X_SUPPRESS_ARTIFACT="${workspace}/.setup_cases_failed" \
        timeout "$STAGE_TIMEOUT" bash "$SETUP_SCRIPT" \
        -i output_batch_1.csv -O . -j "$JOB_LIMIT" 2>&1)" && status=0 || status=$?
PATH="$pool_saved_path"

assert_contains "$(cat "$control_events")" "suppressed" \
    "the setup suppression control replaced both record channels"
assert_eq "/proc/version" "$(readlink "${workspace}/.setup_cases_failed")" \
    "no setup Failure Artifact record is available to the final gate"
assert_ne 124 "$status" "the setup counter run completes without an external kill"
assert_failure "$status" \
    "FAILED_ROW_JOBS alone keeps the setup Stage result non-zero"

# ---- post-processing: JOB_FAILURES ----
# This observation uses one Case. A failed append inside the summary lock leaves
# the lock held, so a second Case would wait without a limit. That lock
# behavior is pre-existing, and I-G3 must not change it.
workspace="$(new_workspace post_counter)"
install_fakes "$workspace"
assert_fakes_active
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300
new_control post_counter
counter_bin="${workspace}/_control_bin"
mkdir -p "$counter_bin"
write_case_control "$counter_bin" foamToVTK "${FAKE_BIN_DIR}/foamToVTK"
pool_saved_path="$PATH"
PATH="${counter_bin}:${PATH}"
out="$(cd "$workspace" && LC_ALL=C \
        X_SUPPRESS_SUMMARY="${workspace}/run_post_processing_cases_summary.csv" \
        X_SUPPRESS_ARTIFACT="${workspace}/.run_post_processing_cases_failed" \
        timeout "$STAGE_TIMEOUT" bash "$POST_SCRIPT" \
        -i output_batch_1.csv -O . -j "$JOB_LIMIT" 2>&1)" && status=0 || status=$?
PATH="$pool_saved_path"

assert_contains "$(cat "$control_events")" "suppressed" \
    "the post-processing suppression control replaced both record channels"
assert_eq "/proc/version" \
    "$(readlink "${workspace}/.run_post_processing_cases_failed")" \
    "no post-processing Failure Artifact record is available to the final gate"
assert_ne 124 "$status" \
    "the post-processing counter run completes without an external kill"
assert_failure "$status" \
    "JOB_FAILURES alone keeps the post-processing Stage result non-zero"

# ---- the forced Bash 4.0 through 4.2 fallback path -------------------------
#
# A copied deployment unit overrides only batch_stage_job_pool_wait_n_supported
# so that it returns non-zero. Every Stage Runner must then use the
# 0.5-second polling path and must not call a wait-status callback.

new_pool_workspace fallback
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
fallback_master="${workspace}/master_batch"
make_instrumented_unit "$fallback_master"
cat >> "${fallback_master}/lib_batch_stage.sh" <<'OVERRIDE'

# Branch control. Only the support test changes, so every scheduling loop takes
# the Bash 4.0 through 4.2 fallback path.
batch_stage_job_pool_wait_n_supported() {
    return 1
}
OVERRIDE
fallback_bin="${workspace}/_control_bin"
mkdir -p "$fallback_bin"
make_setup_side_commands "$fallback_bin"
printf '#!/usr/bin/env bash\necho "Set centre of rotation to (100 200 0)"\nexit 0\n' \
    > "${fallback_bin}/surfaceTransformPoints"
chmod +x "${fallback_bin}/surfaceTransformPoints"

# run_fallback_stage <stage> <script> <args...>
run_fallback_stage() {
    local stage="$1"
    shift
    HELPER_RECORD="${HELPER_RECORD_DIR}/fallback_${stage}.log"
    SLEEP_RECORD="${SLEEP_CONTROL_DIR}/fallback_${stage}.log"
    : > "$HELPER_RECORD"
    : > "$SLEEP_RECORD"
    ( cd "$workspace" && X_HELPER_RECORD="$HELPER_RECORD" \
        X_SLEEP_RECORD="$SLEEP_RECORD" LC_ALL=C \
        timeout "$STAGE_TIMEOUT" bash "$@" ) >/dev/null 2>&1 && status=0 || status=$?
}

pool_saved_path="$PATH"
PATH="${fallback_bin}:${SLEEP_CONTROL_DIR}/bin:${PATH}"
for spec in "setup:setup_cases.sh" "mesh:run_mesh_cases.sh" "flow:run_flow_cases.sh" \
            "post:run_post_processing_cases.sh"; do
    stage="${spec%%:*}"
    runner="${spec##*:}"
    run_fallback_stage "$stage" "${fallback_master}/${runner}" \
        -i output_batch_1.csv -O . -j 1
    assert_ne 124 "$status" "the fallback ${stage} run completes without an external kill"
    assert_status 0 "$status" "the fallback ${stage} run keeps exit status 0"
    assert_ne 0 "$(grep -c '^fallback_poll$' "$HELPER_RECORD" || true)" \
        "the fallback ${stage} run uses the Bash 4.0 through 4.2 polling path"
    assert_eq 0 "$(grep -c '^wait_n_selected$' "$HELPER_RECORD" || true)" \
        "the fallback ${stage} run never selects wait -n"
    assert_sleep_argument "$SLEEP_RECORD" 0.5 present "fallback ${stage}"
done
run_fallback_stage transport "${fallback_master}/run_transport_cases.sh" \
    -i output_batch_1.csv -O . -j 1 --save-times 300
assert_ne 124 "$status" "the fallback transport run completes without an external kill"
assert_status 0 "$status" "the fallback transport run keeps exit status 0"
assert_ne 0 "$(grep -c '^fallback_poll$' "$HELPER_RECORD" || true)" \
    "the fallback transport run uses the Bash 4.0 through 4.2 polling path"
assert_eq 0 "$(grep -c '^wait_n_selected$' "$HELPER_RECORD" || true)" \
    "the fallback transport run never selects wait -n"
assert_sleep_argument "$SLEEP_RECORD" 0.5 present "fallback transport"
PATH="$pool_saved_path"

# ---- the setup final drain stays caller-owned ------------------------------
#
# The copied setup Stage Runner changes only the exact Bash-version condition
# in its existing wait_for_all_rows function, so the direct-PID older-Bash
# branch runs. Every other line stays unchanged, and the free-slot wait keeps
# using the shared helper.

new_pool_workspace setup_drain
make_setup_bases "$workspace"
drain_master="${workspace}/master_batch"
make_instrumented_unit "$drain_master"

drain_condition='    if (( BASH_VERSINFO[0] > 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3 ) )); then'
assert_eq 1 "$(grep -c -F -x "$drain_condition" "${drain_master}/setup_cases.sh")" \
    "the copied setup Stage Runner holds exactly one Bash-version condition"
drain_before="$(wc -l < "${drain_master}/setup_cases.sh")"
python3 - "${drain_master}/setup_cases.sh" "$drain_condition" <<'PYTHON'
import sys
path, condition = sys.argv[1], sys.argv[2]
source = open(path).read()
assert source.count(condition + "\n") == 1
open(path, "w").write(source.replace(condition + "\n", "    if false; then\n"))
PYTHON
assert_eq "$drain_before" "$(wc -l < "${drain_master}/setup_cases.sh")" \
    "the copied setup Stage Runner keeps its line count"

new_control setup_drain
drain_bin="${workspace}/_control_bin"
mkdir -p "$drain_bin"
make_setup_side_commands "$drain_bin"
write_case_control "$drain_bin" surfaceTransformPoints "${SLEEP_REAL%/*}/true" \
    'echo "Set centre of rotation to (100 200 0)"
'
HELPER_RECORD="${HELPER_RECORD_DIR}/setup_drain.log"
: > "$HELPER_RECORD"

pool_saved_path="$PATH"
PATH="${drain_bin}:${SLEEP_CONTROL_DIR}/bin:${PATH}"
out="$(cd "$workspace" && LC_ALL=C X_FAIL_TOKEN="$FAIL_TOKEN" \
        X_HELPER_RECORD="$HELPER_RECORD" timeout "$STAGE_TIMEOUT" \
        bash "${drain_master}/setup_cases.sh" \
        -i output_batch_1.csv -O . -j "$JOB_LIMIT" 2>&1)" && status=0 || status=$?
PATH="$pool_saved_path"

assert_ne 124 "$status" "the setup drain run completes without an external kill"
assert_failure "$status" \
    "the older-Bash setup final drain keeps the exact non-zero Stage status"
assert_pool_shape "setup drain"
assert_file_bytes_exact "${workspace}/.setup_cases_failed" \
    "${workspace}/output_batch_1.csv,3"$'\n' \
    "the older-Bash setup final drain keeps the exact Failure Artifact"
assert_eq 6 "$(summary_status_count "${workspace}/setup_cases_summary.csv" created 9)" \
    "the older-Bash setup final drain keeps the created rows"
assert_contains "$out" "Some rows failed." \
    "the older-Bash setup final drain keeps its failure message"
# The free-slot wait still delegates to the shared helper.
assert_ne 0 "$(grep -c '^wait_for_slot$' "$HELPER_RECORD" || true)" \
    "the copied setup Stage Runner still uses the shared free-slot helper"
assert_eq 0 "$(grep -c '^wait_for_all$' "$HELPER_RECORD" || true)" \
    "the setup final drain never uses the shared wait-for-all helper"
