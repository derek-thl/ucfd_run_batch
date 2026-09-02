#!/usr/bin/env bash
# Section 23.W - shared result-recording extraction (Issue #45).
#
# This scenario proves that the I-G2 extraction keeps every public
# result-recording behavior of the five Stage Runners. Every assertion uses a
# direct Stage Runner CLI, the process status, the console output, the fake
# command records, and the bytes of the Batch Workspace artifacts. No assertion
# sources lib_batch_stage.sh, and no assertion calls a shared helper or a
# private Stage Runner function.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# Every Stage Runner invocation has a finite timeout.
STAGE_TIMEOUT=120

# One Batch Workspace path component that holds a space, a comma, a double
# quote, and an embedded newline. ODD_RAW is the real path component. ODD_ESC is
# the expected CSV rendering, written as an independent literal. The expected
# bytes never come from Stage Runner output.
ODD_RAW=$'out dir a,b"c\nd'
ODD_ESC='out dir a,b""c'$'\n''d'

# ---- helpers -----------------------------------------------------------------

# assert_file_bytes <path> <expected> <label>
# The comparison appends one literal X to each side, so a trailing newline byte
# stays significant inside command substitution.
assert_file_bytes() {
    local path="$1" expected="$2" label="$3"

    assert_file_exists "$path" "${label}: the summary exists"
    assert_eq "${expected}X" "$(cat -- "$path"; printf X)" \
        "${label}: the summary holds the exact expected bytes"
}

# new_odd_root <name> - one workspace with an odd-path Batch Workspace root.
# The function sets workspace, out_root, root_esc, and csv_esc.
new_odd_root() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    assert_fakes_active
    out_root="${workspace}/${ODD_RAW}"
    mkdir -p "$out_root"
    root_esc="${workspace}/${ODD_ESC}"
    csv_esc="${root_esc}/output_batch_1.csv"
}

# ---- setup: the exact 10-column summary bytes -------------------------------
#
# The invalid-WS row proves that an empty field stays "" and that the failed
# status and message are unchanged.

new_odd_root setup_bytes
mkdir -p "${out_root}/simpleFoam_files" "${out_root}/scalarTransportDeffFoam_files"
make_csv "${out_root}/output_batch_1.csv" 0 1
printf 'case_2,notanumber,270.0\n' >> "${out_root}/output_batch_1.csv"

out="$(cd "$out_root" && timeout "$STAGE_TIMEOUT" bash "$SETUP_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 --dry-run 2>&1)" && status=0 || status=$?

assert_ne 124 "$status" "the setup run completes without an external kill"
assert_status 1 "$status" "one invalid row keeps the current non-zero setup status"

expected="csv_file,row_number,case_id,case_name,wd,ws,ws_for_setup,case_dir,status,message"$'\n'
expected+="\"${csv_esc}\",\"2\",\"case_0\",\"case_0/flow\",\"270.000\",\"3.5\",\"3.5\",\"${root_esc}/case_0/flow\",\"dry_run\",\"would create flow case\""$'\n'
expected+="\"${csv_esc}\",\"2\",\"case_0\",\"case_0/trd\",\"270.000\",\"3.5\",\"3.5\",\"${root_esc}/case_0/trd\",\"dry_run\",\"would create transport case\""$'\n'
expected+="\"${csv_esc}\",\"3\",\"case_1\",\"case_1/flow\",\"270.000\",\"3.5\",\"3.5\",\"${root_esc}/case_1/flow\",\"dry_run\",\"would create flow case\""$'\n'
expected+="\"${csv_esc}\",\"3\",\"case_1\",\"case_1/trd\",\"270.000\",\"3.5\",\"3.5\",\"${root_esc}/case_1/trd\",\"dry_run\",\"would create transport case\""$'\n'
expected+="\"${csv_esc}\",\"4\",\"case_2\",\"\",\"270.0\",\"notanumber\",\"\",\"\",\"failed\",\"invalid WS\""$'\n'

assert_file_bytes "${out_root}/setup_cases_summary.csv" "$expected" "setup"

# ---- mesh: the exact 7-column summary bytes ---------------------------------
#
# The empty Case row proves that empty fields stay "".

new_odd_root mesh_bytes
make_csv "${out_root}/output_batch_1.csv" 0 1
printf ',3.5,270.0\n' >> "${out_root}/output_batch_1.csv"
make_flow_case "${out_root}/case_0/flow" 2

out="$(cd "$out_root" && timeout "$STAGE_TIMEOUT" bash "$MESH_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_ne 124 "$status" "the mesh run completes without an external kill"
assert_status 0 "$status" "the mesh run keeps exit status 0"

expected="csv_file,row_number,case_id,case_name,case_dir,status,message"$'\n'
expected+="\"${csv_esc}\",\"3\",\"case_1\",\"case_1/flow\",\"${root_esc}/case_1/flow\",\"skipped\",\"case directory not found\""$'\n'
expected+="\"${csv_esc}\",\"4\",\"\",\"\",\"\",\"skipped\",\"missing Case\""$'\n'
expected+="\"${csv_esc}\",\"2\",\"case_0\",\"case_0/flow\",\"${root_esc}/case_0/flow\",\"meshed\",\"OK\""$'\n'

assert_file_bytes "${out_root}/run_mesh_cases_summary.csv" "$expected" "mesh"
assert_file_missing "${out_root}/.run_mesh_cases_failed" \
    "the successful mesh run writes no Failure Artifact"

# ---- flow: the exact 7-column summary bytes ---------------------------------

new_odd_root flow_bytes
make_csv "${out_root}/output_batch_1.csv" 0 1
printf ',3.5,270.0\n' >> "${out_root}/output_batch_1.csv"
make_flow_case "${out_root}/case_0/flow" 2
make_flow_mesh "${out_root}/case_0/flow"
printf 'FoamFile { object wallDistance; }\n' > "${out_root}/case_0/flow/0/wallDistance"

out="$(cd "$out_root" && timeout "$STAGE_TIMEOUT" bash "$FLOW_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_ne 124 "$status" "the flow run completes without an external kill"
assert_status 0 "$status" "the flow run keeps exit status 0"

expected="csv_file,row_number,case_id,case_name,case_dir,status,message"$'\n'
expected+="\"${csv_esc}\",\"3\",\"case_1\",\"case_1/flow\",\"${root_esc}/case_1/flow\",\"skipped\",\"case directory not found\""$'\n'
expected+="\"${csv_esc}\",\"4\",\"\",\"\",\"\",\"skipped\",\"missing Case\""$'\n'
expected+="\"${csv_esc}\",\"2\",\"case_0\",\"case_0/flow\",\"${root_esc}/case_0/flow\",\"solved\",\"OK\""$'\n'

assert_file_bytes "${out_root}/run_flow_cases_summary.csv" "$expected" "flow"

# ---- transport: the exact 7-column summary bytes ----------------------------

new_odd_root transport_bytes
make_csv "${out_root}/output_batch_1.csv" 0
printf ',3.5,270.0\n' >> "${out_root}/output_batch_1.csv"
make_flow_case "${out_root}/case_0/flow" 2
make_flow_mesh "${out_root}/case_0/flow"
make_flow_result "${out_root}/case_0/flow" 3000
make_transport_case "${out_root}/case_0/trd" 2 T 300

out="$(cd "$out_root" && timeout "$STAGE_TIMEOUT" bash "$TRANSPORT_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 --save-times "300" 2>&1)" && status=0 || status=$?

assert_ne 124 "$status" "the transport run completes without an external kill"
assert_status 0 "$status" "the transport run keeps exit status 0"

expected="csv_file,row_number,case_id,flow_case_transport_case,transport_case_dir,status,message"$'\n'
expected+="\"${csv_esc}\",\"3\",\"\",\"\",\"\",\"skipped\",\"missing Case\""$'\n'
expected+="\"${csv_esc}\",\"2\",\"case_0\",\"case_0/flow|case_0/trd\",\"${root_esc}/case_0/trd\",\"solved\",\"OK\""$'\n'

assert_file_bytes "${out_root}/run_transport_cases_summary.csv" "$expected" "transport"

# ---- post-processing: the exact 4-column summary bytes ----------------------
#
# Post-processing keeps its own distinct rendering. The Case ID, the Case
# directory, and the status keep their literal double-quote delimiters and add
# no inner-quote escaping, so the Case directory field holds one raw double
# quote. Only the message field doubles an inner double quote. I-G2 must not
# normalize post-processing to the other four Stage Runners.

new_odd_root post_bytes
make_csv "${out_root}/output_batch_1.csv" 0
make_flow_case "${out_root}/case_0/flow" 2
make_flow_result "${out_root}/case_0/flow" 3000
make_transport_case "${out_root}/case_0/trd" 2 T 300

out="$(cd "$out_root" && timeout "$STAGE_TIMEOUT" bash "$POST_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_ne 124 "$status" "the odd-path post run completes without an external kill"

# The Case directory field keeps the raw component, so it is not escaped.
expected="case_id,case_dir,status,message"$'\n'
expected+="\"case_0\",\"${out_root}/case_0\",\"failed\",\"VTU conversion failed; see ${root_esc}/case_0/vtk/logs\""$'\n'

assert_file_bytes "${out_root}/run_post_processing_cases_summary.csv" "$expected" \
    "post-processing"
assert_status 1 "$status" "the failed post-processing run keeps its non-zero status"

# ---- post-processing: the completed status on a plain path ------------------

workspace="$(new_workspace post_completed)"
install_fakes "$workspace"
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$POST_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "the plain-path post run keeps exit status 0"

expected="case_id,case_dir,status,message"$'\n'
expected+="\"case_0\",\"${workspace}/case_0\",\"completed\",\"flow and transport VTU files created\""$'\n'

assert_file_bytes "${workspace}/run_post_processing_cases_summary.csv" "$expected" \
    "post-processing completed"

# The second run keeps the skipped status.
out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$POST_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "the repeated post run keeps exit status 0"

expected="case_id,case_dir,status,message"$'\n'
expected+="\"case_0\",\"${workspace}/case_0\",\"skipped\",\"source results unchanged; existing VTU outputs reused\""$'\n'

assert_file_bytes "${workspace}/run_post_processing_cases_summary.csv" "$expected" \
    "post-processing skipped"

# ---- concurrent summary rows stay complete and parseable -------------------
#
# A merged row or a partial row changes the field count of a line, so the field
# count of every line proves that concurrent appends stayed complete. This
# section uses a plain path, because an embedded newline is a legal byte inside
# a quoted field and would defeat a line-based field count.

CASE_COUNT=4

workspace="$(new_workspace flow_concurrent)"
install_fakes "$workspace"
make_csv "${workspace}/output_batch_1.csv" 0 1 2 3
for index in 0 1 2 3; do
    make_flow_case "${workspace}/case_${index}/flow" 2
    make_flow_mesh "${workspace}/case_${index}/flow"
    printf 'FoamFile { object wallDistance; }\n' \
        > "${workspace}/case_${index}/flow/0/wallDistance"
done

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$FLOW_SCRIPT" \
        -i output_batch_1.csv -O . -j 4 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "the concurrent flow run keeps exit status 0"
summary="${workspace}/run_flow_cases_summary.csv"
assert_eq 'csv_file,row_number,case_id,case_name,case_dir,status,message' \
    "$(sed -n '1p' "$summary")" "the concurrent flow run keeps its exact header"
assert_eq "$CASE_COUNT" \
    "$(awk -F, 'NR > 1 && NF > 0 { count++ } END { print count + 0 }' "$summary")" \
    "the concurrent flow run keeps one row for each Case"
assert_eq "" \
    "$(awk -F, 'NF != 7 { printf "line %d has %d fields; ", NR, NF }' "$summary")" \
    "every concurrent flow summary line holds seven fields"
assert_eq "solved " "$(awk -F, 'NR > 1 && NF > 0 {
        value = $6; gsub(/"/, "", value); print value
    }' "$summary" | sort -u | tr '\n' ' ')" \
    "the concurrent flow run keeps its status values"

# ---- the Failure Artifact keeps its name, contents, and status effect -------

workspace="$(new_workspace flow_failure)"
install_fakes "$workspace"
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_mesh "${workspace}/case_0/flow"
printf 'FoamFile { object wallDistance; }\n' > "${workspace}/case_0/flow/0/wallDistance"

out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="simpleFoam" \
        timeout "$STAGE_TIMEOUT" bash "$FLOW_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_ne 0 "$status" "a failed flow Case keeps a non-zero Stage status"
assert_file_bytes "${workspace}/.run_flow_cases_failed" "case_0/flow"$'\n' \
    "the flow Failure Artifact"
expected="csv_file,row_number,case_id,case_name,case_dir,status,message"$'\n'
expected+="\"${workspace}/output_batch_1.csv\",\"2\",\"case_0\",\"case_0/flow\",\"${workspace}/case_0/flow\",\"failed\",\"see log: ${workspace}/_flow_logs/case_0_flow.log\""$'\n'
assert_file_bytes "${workspace}/run_flow_cases_summary.csv" "$expected" \
    "the failed flow summary"
assert_eq "" "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the failed flow run leaves no lock directory"

# ---- a summary row append failure keeps a non-zero Stage status -------------
#
# The control runs after the Stage Runner writes its header and before it
# appends a Case row. An external fake-command wrapper moves the initialized
# summary to an evidence path and creates a directory at the summary path. The
# next append redirection must then fail promptly, because the target is a
# directory. The wrapper stays inside the isolated test workspace and it runs
# exactly once.
#
# This section uses the post-processing Stage Runner. Section 23.P already
# covers Stage failure propagation for the other Stage Runners through a failed
# Case command.

workspace="$(new_workspace append_failure)"
install_fakes "$workspace"
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300

append_dir="${workspace}/_append_control"
append_bin="${workspace}/_append_bin"
append_marker="${append_dir}/marker"
append_evidence="${append_dir}/summary_before_append.csv"
append_summary_path="${workspace}/run_post_processing_cases_summary.csv"
mkdir -p "$append_dir" "$append_bin"

append_real_command="$(command -v foamToVTK)"
assert_eq "${FAKE_BIN_DIR}/foamToVTK" "$append_real_command" \
    "the append control delegates to the fake foamToVTK"

{
    printf '#!/usr/bin/env bash\n'
    printf 'control_marker=%q\n' "$append_marker"
    printf 'control_evidence=%q\n' "$append_evidence"
    printf 'control_summary=%q\n' "$append_summary_path"
    printf 'real_command=%q\n' "$append_real_command"
    cat <<'WRAPPER'
# Replace the initialized summary with a directory exactly once. The Stage
# Runner has already written its header, and it appends its Case row after this
# command returns.
if mkdir "${control_marker}.once" 2>/dev/null; then
    if [[ -f "$control_summary" ]]; then
        mv -- "$control_summary" "$control_evidence"
        mkdir -- "$control_summary"
        printf 'replaced=1\n' > "$control_marker"
    fi
fi
exec "$real_command" "$@"
WRAPPER
} > "${append_bin}/foamToVTK"
chmod +x "${append_bin}/foamToVTK"

append_saved_path="$PATH"
PATH="${append_bin}:${PATH}"

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$POST_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

# No append-control wrapper stays resolvable after this section.
PATH="$append_saved_path"

assert_file_bytes "$append_marker" "replaced=1"$'\n' "the append control record"
assert_dir_exists "$append_summary_path" \
    "the summary path holds a directory, so the row append target fails"
assert_file_bytes "$append_evidence" \
    "case_id,case_dir,status,message"$'\n' \
    "the summary before the row append"
assert_ne 124 "$status" "the append-failure run completes without an external kill"
assert_ne 0 "$status" "a failed summary row append keeps a non-zero Stage status"
assert_contains "$out" "One or more post-processing jobs failed." \
    "the append failure keeps the current Stage failure diagnostic"
assert_not_contains "$out" "All post-processing jobs completed." \
    "a failed summary row append is not converted to Stage success"
# The summary lock is held across the row append, and a failed append ends the
# Case job before the release. The lock directory therefore survives this path.
# That is the current lock-release behavior, and I-G2 must not change it.
assert_eq "${append_summary_path}.lockdir " \
    "$(find "$workspace" -name '*.lockdir' | sort | tr '\n' ' ')" \
    "the append failure keeps the current lock-release behavior"

# ---- setup: the created status and the failed Failure Artifact -------------
#
# A real setup run needs flow and transport base folders that the Stage Runner
# can copy without an OpenFOAM installation. One invalid row in the same run
# proves the failed status, the Failure Artifact bytes, and the final status.

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

# make_setup_command_stubs <workspace> - the extra commands that a real setup
# run requires. The stubs give the exact log text that the Stage Runner parses,
# so the section needs no OpenFOAM installation and no host command.
make_setup_command_stubs() {
    local bin_dir="${1}/_setup_bin"
    mkdir -p "$bin_dir"

    cat > "${bin_dir}/surfaceTransformPoints" <<'STUB'
#!/usr/bin/env bash
echo "Set centre of rotation to (100 200 0)"
exit 0
STUB

    cat > "${bin_dir}/surfaceCheck" <<'STUB'
#!/usr/bin/env bash
echo "Overall bounds (0 0 0) (10 10 10)"
exit 0
STUB

    cat > "${bin_dir}/foamDictionary" <<'STUB'
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

    chmod +x "${bin_dir}/surfaceTransformPoints" "${bin_dir}/surfaceCheck" \
        "${bin_dir}/foamDictionary"
    setup_stub_bin="$bin_dir"
}

workspace="$(new_workspace setup_created)"
install_fakes "$workspace"
make_setup_bases "$workspace"
make_setup_command_stubs "$workspace"
make_csv "${workspace}/output_batch_1.csv" 0
printf 'case_1,notanumber,270.0\n' >> "${workspace}/output_batch_1.csv"

setup_saved_path="$PATH"
PATH="${setup_stub_bin}:${PATH}"

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$SETUP_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

# No setup stub stays resolvable after this section.
PATH="$setup_saved_path"

assert_ne 124 "$status" "the real setup run completes without an external kill"
assert_status 1 "$status" "one invalid setup row keeps the current non-zero status"

expected="csv_file,row_number,case_id,case_name,wd,ws,ws_for_setup,case_dir,status,message"$'\n'
expected+="\"${workspace}/output_batch_1.csv\",\"2\",\"case_0\",\"case_0/flow\",\"270.000\",\"3.5\",\"3.5\",\"${workspace}/case_0/flow\",\"created\",\"flow case created\""$'\n'
expected+="\"${workspace}/output_batch_1.csv\",\"2\",\"case_0\",\"case_0/trd\",\"270.000\",\"3.5\",\"3.5\",\"${workspace}/case_0/trd\",\"created\",\"transport case created\""$'\n'
expected+="\"${workspace}/output_batch_1.csv\",\"3\",\"case_1\",\"\",\"270.0\",\"notanumber\",\"\",\"\",\"failed\",\"invalid WS\""$'\n'

assert_file_bytes "${workspace}/setup_cases_summary.csv" "$expected" "setup created"
assert_file_bytes "${workspace}/.setup_cases_failed" \
    "${workspace}/output_batch_1.csv,3"$'\n' "the setup Failure Artifact"

# ---- transport: the continued status ---------------------------------------
#
# An existing transport marker with an existing transport mesh and initial state
# selects continuation.

workspace="$(new_workspace transport_continued)"
install_fakes "$workspace"
make_csv "${workspace}/output_batch_1.csv" 0
flow_dir="${workspace}/case_0/flow"
trd_dir="${workspace}/case_0/trd"
make_flow_case "$flow_dir" 2
make_flow_mesh "$flow_dir"
make_flow_result "$flow_dir" 3000
printf 'flow-U-at-3000\n' > "${flow_dir}/3000/U"
printf 'flow-nut-at-3000\n' > "${flow_dir}/3000/nut"
printf 'flow-phi-at-3000\n' > "${flow_dir}/3000/phi"
make_transport_case "$trd_dir" 2 T 300
mkdir -p "${trd_dir}/constant/polyMesh"
for name in points boundary faces owner neighbour; do
    printf 'transport-mesh-%s\n' "$name" > "${trd_dir}/constant/polyMesh/${name}"
done
printf 'transport-U\n' > "${trd_dir}/0/U"
printf 'transport-nut\n' > "${trd_dir}/0/nut"
printf 'transport-phi\n' > "${trd_dir}/0/phi"
printf 'done\n' > "${trd_dir}/transport.marker"

out="$(cd "$workspace" && FAKE_SOLVER_TIMES="300" \
        timeout "$STAGE_TIMEOUT" bash "$TRANSPORT_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 --save-times 300 2>&1)" && status=0 || status=$?

assert_ne 124 "$status" "the transport continuation completes without an external kill"
assert_status 0 "$status" "the transport continuation keeps exit status 0"

expected="csv_file,row_number,case_id,flow_case_transport_case,transport_case_dir,status,message"$'\n'
expected+="\"${workspace}/output_batch_1.csv\",\"2\",\"case_0\",\"case_0/flow|case_0/trd\",\"${workspace}/case_0/trd\",\"continued\",\"OK (resumed)\""$'\n'

assert_file_bytes "${workspace}/run_transport_cases_summary.csv" "$expected" \
    "transport continued"

# ---- mesh: the failed Failure Artifact -------------------------------------

workspace="$(new_workspace mesh_failure)"
install_fakes "$workspace"
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2

out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="blockMesh" \
        timeout "$STAGE_TIMEOUT" bash "$MESH_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_ne 0 "$status" "a failed mesh Case keeps a non-zero Stage status"
expected="csv_file,row_number,case_id,case_name,case_dir,status,message"$'\n'
expected+="\"${workspace}/output_batch_1.csv\",\"2\",\"case_0\",\"case_0/flow\",\"${workspace}/case_0/flow\",\"failed\",\"see log: ${workspace}/_mesh_logs/case_0_flow.log\""$'\n'
assert_file_bytes "${workspace}/run_mesh_cases_summary.csv" "$expected" \
    "the failed mesh summary"
assert_file_bytes "${workspace}/.run_mesh_cases_failed" "case_0/flow"$'\n' \
    "the mesh Failure Artifact"

# ---- transport: the failed Failure Artifact ---------------------------------

workspace="$(new_workspace transport_failure)"
install_fakes "$workspace"
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_mesh "${workspace}/case_0/flow"
make_flow_result "${workspace}/case_0/flow" 3000
# endTime 100 cannot cover the requested save time 300.
make_transport_case "${workspace}/case_0/trd" 2 T 100

out="$(cd "$workspace" && timeout "$STAGE_TIMEOUT" bash "$TRANSPORT_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 --save-times 300 2>&1)" && status=0 || status=$?

assert_ne 0 "$status" "a failed transport Case keeps a non-zero Stage status"
expected="csv_file,row_number,case_id,flow_case_transport_case,transport_case_dir,status,message"$'\n'
expected+="\"${workspace}/output_batch_1.csv\",\"2\",\"case_0\",\"case_0/flow|case_0/trd\",\"${workspace}/case_0/trd\",\"failed\",\"see log: ${workspace}/_transport_logs/case_0_trd.log\""$'\n'
assert_file_bytes "${workspace}/run_transport_cases_summary.csv" "$expected" \
    "the failed transport summary"
assert_file_bytes "${workspace}/.run_transport_cases_failed" "case_0/trd"$'\n' \
    "the transport Failure Artifact"

# ---- post-processing: the failed Failure Artifact ---------------------------

workspace="$(new_workspace post_failure)"
install_fakes "$workspace"
make_csv "${workspace}/output_batch_1.csv" 0
make_flow_case "${workspace}/case_0/flow" 2
make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300

out="$(cd "$workspace" && FAKE_FAIL_COMMANDS="foamToVTK" \
        timeout "$STAGE_TIMEOUT" bash "$POST_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 2>&1)" && status=0 || status=$?

assert_ne 0 "$status" "a failed conversion keeps a non-zero post-processing status"
expected="case_id,case_dir,status,message"$'\n'
expected+="\"case_0\",\"${workspace}/case_0\",\"failed\",\"VTU conversion failed; see ${workspace}/case_0/vtk/logs\""$'\n'
assert_file_bytes "${workspace}/run_post_processing_cases_summary.csv" "$expected" \
    "the failed post-processing summary"
assert_file_bytes "${workspace}/.run_post_processing_cases_failed" "case_0"$'\n' \
    "the post-processing Failure Artifact"

# ---- the Stage Runners use the shared result-recording helpers --------------
#
# This section builds one copied deployment unit inside the isolated test
# workspace. The copied library keeps its production content and then receives
# compatible instrumented implementations of the two approved helpers. Each
# instrumented helper preserves the production rendering and the production
# append behavior, and it records one call outside the summary.
#
# The test never sources the library and never calls a helper. It observes only
# the record files that the copied Stage Runners produce through their public
# CLIs. A Stage Runner that keeps local result-recording mechanics produces no
# record, so this section fails at the exact base.

workspace="$(new_workspace helper_use)"
install_fakes "$workspace"
master="${workspace}/master_batch"
records="${workspace}/_helper_records"
mkdir -p "$master" "$records"

for name in lib_batch_stage.sh setup_cases.sh run_mesh_cases.sh \
        run_flow_cases.sh run_transport_cases.sh run_post_processing_cases.sh; do
    cp -f -- "${MASTER_SRC_DIR}/${name}" "${master}/${name}"
done

cat >> "${master}/lib_batch_stage.sh" <<'INSTRUMENT'

# Test instrumentation. Each definition replaces the production definition with
# the same rendering and the same append behavior, and records one call.
batch_stage_csv_quote() {
    local __w_value="${2-}"
    __w_value="${__w_value//\"/\"\"}"
    printf -v "$1" '"%s"' "$__w_value"
    __w_status=$?
    printf 'quote\n' >> "${W_HELPER_RECORD:-/dev/null}"
    return "$__w_status"
}

batch_stage_csv_append_row() {
    local __w_target="$1"
    shift
    printf 'append\n' >> "${W_HELPER_RECORD:-/dev/null}"
    local IFS=,
    printf '%s\n' "$*" >> "$__w_target"
}
INSTRUMENT

# assert_helper_records <stage> - both helper records exist for one Stage.
assert_helper_records() {
    local stage="$1" record="${records}/${1}.log"

    assert_file_exists "$record" \
        "${stage} records a shared result-recording helper call"
    assert_ne 0 "$(grep -c '^quote$' "$record" || true)" \
        "${stage} uses the shared CSV quote helper"
    assert_ne 0 "$(grep -c '^append$' "$record" || true)" \
        "${stage} uses the shared CSV append helper"
}

run_copied_stage() {
    local stage="$1"
    shift
    ( cd "$workspace" && W_HELPER_RECORD="${records}/${stage}.log" \
        timeout "$STAGE_TIMEOUT" bash "$@" ) >/dev/null 2>&1 || true
}

make_csv "${workspace}/output_batch_1.csv" 0
mkdir -p "${workspace}/simpleFoam_files" "${workspace}/scalarTransportDeffFoam_files"
make_flow_case "${workspace}/case_0/flow" 2
make_flow_mesh "${workspace}/case_0/flow"
printf 'FoamFile { object wallDistance; }\n' > "${workspace}/case_0/flow/0/wallDistance"

run_copied_stage setup "${master}/setup_cases.sh" -i output_batch_1.csv -O . -j 1 --dry-run
run_copied_stage mesh "${master}/run_mesh_cases.sh" -i output_batch_1.csv -O . -j 1
run_copied_stage flow "${master}/run_flow_cases.sh" -i output_batch_1.csv -O . -j 1

make_flow_result "${workspace}/case_0/flow" 3000
make_transport_case "${workspace}/case_0/trd" 2 T 300

run_copied_stage transport "${master}/run_transport_cases.sh" \
    -i output_batch_1.csv -O . -j 1 --save-times 300
run_copied_stage post "${master}/run_post_processing_cases.sh" \
    -i output_batch_1.csv -O . -j 1

for stage in setup mesh flow transport post; do
    assert_helper_records "$stage"
done
