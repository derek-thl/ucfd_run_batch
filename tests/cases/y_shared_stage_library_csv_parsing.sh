#!/usr/bin/env bash
# Section 23.Y - shared CSV-parsing extraction (Issue #51).
#
# This scenario proves that the I-G4 extraction keeps every public CSV parsing
# behavior of the five Stage Runners. Every assertion uses a direct Stage Runner
# CLI, the process status, the console output, the fake command records, and the
# bytes of the Batch Workspace artifacts. No assertion sources
# lib_batch_stage.sh, and no assertion calls a shared helper or a private Stage
# Runner function.
#
# Design notes.
#
# 1. The base characterization group runs the production deployment unit with no
#    instrumentation, so each observation validates production behavior. The
#    group passes against the exact base production code and against the
#    extracted production code.
# 2. The post-extraction group runs a copied deployment unit whose copied
#    library adds compatible instrumentation. The instrumented helpers keep the
#    approved logic, output, and status, and record one line per call. The first
#    delegation assertion is the intentional TDD red observation.
# 3. Every parser instrumentation record lives in a sibling directory of the
#    Batch Workspaces, so no record enters a Batch Workspace.
# 4. Most observations need no Case directory, because a Stage Runner selects
#    and trims the Case cell before it inspects the Case directory. The skipped
#    and failed rows therefore report the exact selected cell.
# 5. Setup STABILITY_COL has no public consumer, so this scenario proves that
#    the Stability vector stays optional and changes no public result. The exact
#    optional alias vector is proven by the delegation group.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# Every Stage Runner invocation has a finite timeout. Status 124 is never an
# accepted result.
STAGE_TIMEOUT=120

# Test control records live in a sibling directory of the Batch Workspaces,
# under CONTRACT_TEST_RUN_DIR, so no record enters a Batch Workspace.
CONTROL_ROOT="${CONTRACT_TEST_RUN_DIR}/y_controls"
mkdir -p "$CONTROL_ROOT"

SETUP_SUMMARY_HEADER="csv_file,row_number,case_id,case_name,wd,ws,ws_for_setup,case_dir,status,message"
STAGE_SUMMARY_HEADER="csv_file,row_number,case_id,case_name,case_dir,status,message"
TRANSPORT_SUMMARY_HEADER="csv_file,row_number,case_id,flow_case_transport_case,transport_case_dir,status,message"
POST_SUMMARY_HEADER="case_id,case_dir,status,message"

# ---- helpers -----------------------------------------------------------------

# assert_file_bytes_exact <path> <expected> <label>
# The comparison appends one literal X to each side, so a trailing newline byte
# stays significant inside command substitution.
assert_file_bytes_exact() {
    assert_file_exists "$1" "${3}: the file exists"
    assert_eq "${2}X" "$(cat -- "$1"; printf X)" "${3}: the exact bytes"
}

# csv_row <field>... - one summary row with the current rendering for a plain
# value. Every field in a Y expectation is a plain value, so the row adds one
# leading and one trailing double quote per field and joins the fields with one
# comma. Scenario W owns the escaping proof for a value that holds a double
# quote. The two Y expectations that hold a double quote use exact literals.
csv_row() {
    local field out=""
    for field in "$@"; do
        [[ -z "$out" ]] || out+=","
        out+="\"${field}\""
    done
    printf '%s\n' "$out"
}

# new_ws <name> - one Batch Workspace with active fakes and the setup base
# folders. The function sets workspace and csv_abs.
new_ws() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    assert_fakes_active
    mkdir -p "${workspace}/simpleFoam_files" "${workspace}/scalarTransportDeffFoam_files"
    csv_abs="${workspace}/output_batch_1.csv"
}

# write_csv <path> <line>... - one CSV with one final newline after each line.
write_csv() {
    local path="$1" line
    shift
    : > "$path"
    for line in "$@"; do
        printf '%s\n' "$line" >> "$path"
    done
}

# run_stage <dir> <script> <arg>... - one Stage Runner run with a finite
# timeout. The function sets out and status.
run_stage() {
    local dir="$1" script="$2"
    shift 2
    out="$(cd "$dir" && LC_ALL=C timeout "$STAGE_TIMEOUT" bash "$script" "$@" 2>&1)" &&
        status=0 || status=$?
    assert_ne 124 "$status" "the ${script##*/} run completes without an external kill"
}

run_setup_dry() {
    run_stage "$workspace" "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1 --dry-run
}

run_mesh() {
    run_stage "$workspace" "$MESH_SCRIPT" -i output_batch_1.csv -O . -j 1
}

run_flow() {
    run_stage "$workspace" "$FLOW_SCRIPT" -i output_batch_1.csv -O . -j 1
}

run_transport() {
    run_stage "$workspace" "$TRANSPORT_SCRIPT" \
        -i output_batch_1.csv -O . -j 1 --save-times 300
}

run_post() {
    run_stage "$workspace" "$POST_SCRIPT" -i output_batch_1.csv -O . -j 1
}

setup_summary() { printf '%s\n' "${workspace}/setup_cases_summary.csv"; }
mesh_summary() { printf '%s\n' "${workspace}/run_mesh_cases_summary.csv"; }
flow_summary() { printf '%s\n' "${workspace}/run_flow_cases_summary.csv"; }
transport_summary() { printf '%s\n' "${workspace}/run_transport_cases_summary.csv"; }
post_summary() { printf '%s\n' "${workspace}/run_post_processing_cases_summary.csv"; }

# assert_no_data_row <path> <header> <label> - the summary holds the header only.
assert_no_data_row() {
    assert_file_bytes_exact "$1" "${2}"$'\n' "$3"
}

# assert_no_artifact_data <path> <label> - the Failure Artifact holds no data.
assert_no_artifact_data() {
    if [[ -e "$1" ]]; then
        assert_eq "" "$(cat -- "$1")" "${2}: the Failure Artifact holds no data"
    fi
}

# assert_no_openfoam_call <label> - no fake OpenFOAM-family command ran.
assert_no_openfoam_call() {
    local command_name
    for command_name in "${FAKE_COMMANDS[@]}"; do
        assert_eq 0 "$(fake_call_count "$command_name")" \
            "${1}: ${command_name} does not run"
    done
}

# assert_no_marker <dir> <label> - the state folder holds no marker file.
assert_no_marker() {
    local found=""
    [[ ! -d "$1" ]] || found="$(find "$1" -type f | sort | tr '\n' ' ')"
    assert_eq "" "$found" "${1##*/} holds no marker: ${2}"
}

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

# make_setup_side_commands <bin_dir> - the extra commands that a real setup run
# requires. Each stub gives the exact log text that the Stage Runner parses, so
# the section needs no OpenFOAM installation and no host command.
make_setup_side_commands() {
    cat > "${1}/surfaceCheck" <<'STUB'
#!/usr/bin/env bash
echo "Overall bounds (0 0 0) (10 10 10)"
exit 0
STUB

    cat > "${1}/surfaceTransformPoints" <<'STUB'
#!/usr/bin/env bash
echo "Set centre of rotation to (100 200 0)"
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

    chmod +x "${1}/surfaceCheck" "${1}/surfaceTransformPoints" "${1}/foamDictionary"
}

# =============================================================================
# BASE CHARACTERIZATION GROUP
#
# Every observation below runs the production deployment unit with no
# instrumentation. The group passes against the exact base production code.
# =============================================================================

# ---- 1. a reordered, mixed-case, whitespace header --------------------------
#
# The Case column is not column zero. The header names use mixed case and hold
# leading and trailing whitespace. Setup selects WS and WD from the reordered
# columns and reports the selected values in the summary.

new_ws header_shape
write_csv "$csv_abs" \
    '  MET__wd_DEG ,met__ws_MPS,  cAsE  ' \
    '270.0,3.5,zeta'

run_setup_dry
assert_status 0 "$status" "the reordered header keeps the setup status"
expected="${SETUP_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/flow 270.000 3.5 3.5 \
    "${workspace}/case_zeta/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/trd 270.000 3.5 3.5 \
    "${workspace}/case_zeta/trd" dry_run "would create transport case")"$'\n'
assert_file_bytes_exact "$(setup_summary)" "$expected" "setup reordered header"

run_mesh
assert_status 0 "$status" "the reordered header keeps the mesh status"
expected="${STAGE_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/flow \
    "${workspace}/case_zeta/flow" skipped "case directory not found")"$'\n'
assert_file_bytes_exact "$(mesh_summary)" "$expected" "mesh reordered header"

run_flow
assert_status 0 "$status" "the reordered header keeps the flow status"
assert_file_bytes_exact "$(flow_summary)" "$expected" "flow reordered header"

run_transport
assert_status 1 "$status" "the reordered header keeps the transport status"
expected="${TRANSPORT_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta 'case_zeta/flow|case_zeta/trd' \
    "${workspace}/case_zeta/trd" failed \
    "flow case directory not found: ${workspace}/case_zeta/flow")"$'\n'
assert_file_bytes_exact "$(transport_summary)" "$expected" \
    "transport reordered header"
assert_file_bytes_exact "${workspace}/.run_transport_cases_failed" \
    "case_zeta/trd"$'\n' "the transport Failure Artifact"

run_post
assert_status 1 "$status" "the reordered header keeps the post-processing status"
expected="${POST_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row case_zeta "${workspace}/case_zeta" failed \
    "case directory not found")"$'\n'
assert_file_bytes_exact "$(post_summary)" "$expected" \
    "post-processing reordered header"

# ---- 2. a CRLF header and a CRLF data row -----------------------------------

new_ws crlf
printf 'met__WD_deg,met__WS_mps,Case\r\n270.0,3.5,zeta\r\n' > "$csv_abs"

run_setup_dry
assert_status 0 "$status" "the CRLF input keeps the setup status"
expected="${SETUP_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/flow 270.000 3.5 3.5 \
    "${workspace}/case_zeta/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/trd 270.000 3.5 3.5 \
    "${workspace}/case_zeta/trd" dry_run "would create transport case")"$'\n'
assert_file_bytes_exact "$(setup_summary)" "$expected" "setup CRLF"

run_mesh
assert_status 0 "$status" "the CRLF input keeps the mesh status"
expected="${STAGE_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/flow \
    "${workspace}/case_zeta/flow" skipped "case directory not found")"$'\n'
assert_file_bytes_exact "$(mesh_summary)" "$expected" "mesh CRLF"

run_flow
assert_status 0 "$status" "the CRLF input keeps the flow status"
assert_file_bytes_exact "$(flow_summary)" "$expected" "flow CRLF"

run_transport
assert_status 1 "$status" "the CRLF input keeps the transport status"
expected="${TRANSPORT_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta 'case_zeta/flow|case_zeta/trd' \
    "${workspace}/case_zeta/trd" failed \
    "flow case directory not found: ${workspace}/case_zeta/flow")"$'\n'
assert_file_bytes_exact "$(transport_summary)" "$expected" "transport CRLF"

run_post
assert_status 1 "$status" "the CRLF input keeps the post-processing status"
expected="${POST_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row case_zeta "${workspace}/case_zeta" failed \
    "case directory not found")"$'\n'
assert_file_bytes_exact "$(post_summary)" "$expected" "post-processing CRLF"

# ---- 3. every documented setup alias ----------------------------------------
#
# One alias changes per observation. The other required columns keep a known
# alias, so each observation isolates one alias.

new_ws alias_vectors

setup_alias_expectation() {
    expected="${SETUP_SUMMARY_HEADER}"$'\n'
    expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/flow 270.000 3.5 3.5 \
        "${workspace}/case_zeta/flow" dry_run "would create flow case")"$'\n'
    expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/trd 270.000 3.5 3.5 \
        "${workspace}/case_zeta/trd" dry_run "would create transport case")"$'\n'
}

for alias_name in Case case; do
    write_csv "$csv_abs" "${alias_name},met__WS_mps,met__WD_deg" 'zeta,3.5,270.0'
    run_setup_dry
    assert_status 0 "$status" "the setup Case alias ${alias_name} resolves"
    setup_alias_expectation
    assert_file_bytes_exact "$(setup_summary)" "$expected" \
        "setup Case alias ${alias_name}"
done

for alias_name in WS ws wind_speed U_ref u_ref met__WS_mps; do
    write_csv "$csv_abs" "Case,${alias_name},met__WD_deg" 'zeta,3.5,270.0'
    run_setup_dry
    assert_status 0 "$status" "the setup WS alias ${alias_name} resolves"
    setup_alias_expectation
    assert_file_bytes_exact "$(setup_summary)" "$expected" \
        "setup WS alias ${alias_name}"
done

for alias_name in WD wd wind_direction ref_wind_dir relative_wind_direction \
        met__WD_deg; do
    write_csv "$csv_abs" "Case,met__WS_mps,${alias_name}" 'zeta,3.5,270.0'
    run_setup_dry
    assert_status 0 "$status" "the setup WD alias ${alias_name} resolves"
    setup_alias_expectation
    assert_file_bytes_exact "$(setup_summary)" "$expected" \
        "setup WD alias ${alias_name}"
done

# The Stability column stays optional. No Stability alias changes a public
# result, because STABILITY_COL has no public consumer.
write_csv "$csv_abs" 'Case,met__WS_mps,met__WD_deg' 'zeta,3.5,270.0'
run_setup_dry
assert_status 0 "$status" "an absent Stability column keeps the setup status"
setup_alias_expectation
assert_file_bytes_exact "$(setup_summary)" "$expected" "setup without Stability"

for alias_name in Stability stability atmospheric_stability met__stability; do
    write_csv "$csv_abs" "Case,met__WS_mps,met__WD_deg,${alias_name}" \
        'zeta,3.5,270.0,neutral'
    run_setup_dry
    assert_status 0 "$status" \
        "the setup Stability alias ${alias_name} keeps the status"
    setup_alias_expectation
    assert_file_bytes_exact "$(setup_summary)" "$expected" \
        "setup Stability alias ${alias_name}"
done

# ---- 4. caller alias priority ------------------------------------------------
#
# The header holds two different aliases for the WS column and two different
# aliases for the WD column. The first alias in the caller list stays
# authoritative.

new_ws alias_priority
write_csv "$csv_abs" \
    'Case,WS,met__WS_mps,WD,met__WD_deg' \
    'zeta,7.5,3.5,90.0,270.0'

run_setup_dry
assert_status 0 "$status" "the two-alias header keeps the setup status"
expected="${SETUP_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/flow 90.000 7.5 7.5 \
    "${workspace}/case_zeta/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/trd 90.000 7.5 7.5 \
    "${workspace}/case_zeta/trd" dry_run "would create transport case")"$'\n'
assert_file_bytes_exact "$(setup_summary)" "$expected" "setup alias priority"
assert_not_contains "$(cat -- "$(setup_summary)")" '"3.5"' \
    "the later WS alias does not win"
assert_not_contains "$(cat -- "$(setup_summary)")" '"270.000"' \
    "the later WD alias does not win"

# ---- 5. two header fields that normalize to one key -------------------------
#
# The later field index stays authoritative.

new_ws duplicate_header
write_csv "$csv_abs" \
    'Case,cAsE,met__WS_mps,met__WD_deg' \
    'alpha,beta,3.5,270.0'

run_setup_dry
assert_status 0 "$status" "the duplicate normalized header keeps the setup status"
expected="${SETUP_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_beta case_beta/flow 270.000 3.5 3.5 \
    "${workspace}/case_beta/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_beta case_beta/trd 270.000 3.5 3.5 \
    "${workspace}/case_beta/trd" dry_run "would create transport case")"$'\n'
assert_file_bytes_exact "$(setup_summary)" "$expected" "setup duplicate header"

run_mesh
assert_status 0 "$status" "the duplicate normalized header keeps the mesh status"
expected="${STAGE_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_beta case_beta/flow \
    "${workspace}/case_beta/flow" skipped "case directory not found")"$'\n'
assert_file_bytes_exact "$(mesh_summary)" "$expected" "mesh duplicate header"

run_flow
assert_status 0 "$status" "the duplicate normalized header keeps the flow status"
assert_file_bytes_exact "$(flow_summary)" "$expected" "flow duplicate header"

run_transport
assert_status 1 "$status" \
    "the duplicate normalized header keeps the transport status"
expected="${TRANSPORT_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_beta 'case_beta/flow|case_beta/trd' \
    "${workspace}/case_beta/trd" failed \
    "flow case directory not found: ${workspace}/case_beta/flow")"$'\n'
assert_file_bytes_exact "$(transport_summary)" "$expected" \
    "transport duplicate header"

run_post
assert_status 1 "$status" \
    "the duplicate normalized header keeps the post-processing status"
expected="${POST_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row case_beta "${workspace}/case_beta" failed \
    "case directory not found")"$'\n'
assert_file_bytes_exact "$(post_summary)" "$expected" \
    "post-processing duplicate header"

# ---- 6. an empty field, a missing field, and a trailing delimiter -----------
#
# Row 2 keeps the empty field between two commas, so the Case cell after that
# empty field stays selected. Row 3 drops the one empty element after the
# trailing delimiter. Row 4 has fewer fields than the header. Rows 3 and 4 give
# the current empty-cell result and add no field-count diagnostic.

new_ws sparse_rows
write_csv "$csv_abs" \
    'met__WD_deg,met__WS_mps,Case' \
    '270.0,,zeta' \
    '270.0,3.5,' \
    '270.0,3.5'

run_setup_dry
assert_status 1 "$status" "the sparse rows keep the setup status"
expected="${SETUP_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta "" 270.0 "" "" "" failed \
    "invalid WS")"$'\n'
expected+="$(csv_row "$csv_abs" 3 NA NA/flow 270.000 3.5 3.5 \
    "${workspace}/NA/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_abs" 3 NA NA/trd 270.000 3.5 3.5 \
    "${workspace}/NA/trd" dry_run "would create transport case")"$'\n'
expected+="$(csv_row "$csv_abs" 4 NA NA/flow 270.000 3.5 3.5 \
    "${workspace}/NA/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_abs" 4 NA NA/trd 270.000 3.5 3.5 \
    "${workspace}/NA/trd" dry_run "would create transport case")"$'\n'
assert_file_bytes_exact "$(setup_summary)" "$expected" "setup sparse rows"

run_mesh
assert_status 0 "$status" "the sparse rows keep the mesh status"
expected="${STAGE_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/flow \
    "${workspace}/case_zeta/flow" skipped "case directory not found")"$'\n'
expected+="$(csv_row "$csv_abs" 3 "" "" "" skipped "missing Case")"$'\n'
expected+="$(csv_row "$csv_abs" 4 "" "" "" skipped "missing Case")"$'\n'
assert_file_bytes_exact "$(mesh_summary)" "$expected" "mesh sparse rows"
assert_not_contains "$out" "field count" "mesh adds no field-count diagnostic"
assert_not_contains "$out" "malformed" "mesh adds no malformed-row diagnostic"

run_flow
assert_status 0 "$status" "the sparse rows keep the flow status"
assert_file_bytes_exact "$(flow_summary)" "$expected" "flow sparse rows"
assert_not_contains "$out" "field count" "flow adds no field-count diagnostic"

run_transport
assert_status 1 "$status" "the sparse rows keep the transport status"
expected="${TRANSPORT_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta 'case_zeta/flow|case_zeta/trd' \
    "${workspace}/case_zeta/trd" failed \
    "flow case directory not found: ${workspace}/case_zeta/flow")"$'\n'
expected+="$(csv_row "$csv_abs" 3 "" "" "" skipped "missing Case")"$'\n'
expected+="$(csv_row "$csv_abs" 4 "" "" "" skipped "missing Case")"$'\n'
assert_file_bytes_exact "$(transport_summary)" "$expected" \
    "transport sparse rows"
assert_not_contains "$out" "field count" \
    "transport adds no field-count diagnostic"

run_post
assert_status 1 "$status" "the sparse rows keep the post-processing status"
expected="${POST_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row case_zeta "${workspace}/case_zeta" failed \
    "case directory not found")"$'\n'
assert_file_bytes_exact "$(post_summary)" "$expected" \
    "post-processing sparse rows"
assert_contains "$out" ">>> [warn] CSV row 3 has an empty Case value." \
    "post-processing keeps the empty-Case diagnostic for the trailing delimiter"
assert_contains "$out" ">>> [warn] CSV row 4 has an empty Case value." \
    "post-processing keeps the empty-Case diagnostic for the short row"
assert_not_contains "$out" "field count" \
    "post-processing adds no field-count diagnostic"

# ---- 7. a data value with a quoted comma ------------------------------------
#
# The simple parser splits the value at the comma inside the double quotes. The
# scenario rejects an RFC-compliant interpretation, which would keep
# "alpha,beta" as one field and would move every later field by one index.

new_ws quoted_comma
write_csv "$csv_abs" \
    'Case,met__WS_mps,met__WD_deg' \
    '"alpha,beta",3.5,270.0'

run_setup_dry
assert_status 1 "$status" "the quoted comma keeps the setup status"
# The WS cell is the second field after the split, so it holds the trailing
# quote byte and fails the float test. The WD column then holds 3.5. The ws
# field is the one Y expectation that holds a double quote, so the expected
# bytes are an exact literal.
expected="${SETUP_SUMMARY_HEADER}"$'\n'
expected+="\"${csv_abs}\",\"2\",\"case_alpha\",\"\",\"3.5\",\"beta\"\"\",\"\",\"\",\"failed\",\"invalid WS\""$'\n'
assert_file_bytes_exact "$(setup_summary)" "$expected" "setup quoted comma"

run_mesh
assert_status 0 "$status" "the quoted comma keeps the mesh status"
expected="${STAGE_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_alpha case_alpha/flow \
    "${workspace}/case_alpha/flow" skipped "case directory not found")"$'\n'
assert_file_bytes_exact "$(mesh_summary)" "$expected" "mesh quoted comma"
assert_not_contains "$(cat -- "$(mesh_summary)")" "case_alpha_beta" \
    "mesh does not join the quoted comma into one field"

run_flow
assert_status 0 "$status" "the quoted comma keeps the flow status"
assert_file_bytes_exact "$(flow_summary)" "$expected" "flow quoted comma"

run_transport
assert_status 1 "$status" "the quoted comma keeps the transport status"
expected="${TRANSPORT_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_alpha 'case_alpha/flow|case_alpha/trd' \
    "${workspace}/case_alpha/trd" failed \
    "flow case directory not found: ${workspace}/case_alpha/flow")"$'\n'
assert_file_bytes_exact "$(transport_summary)" "$expected" \
    "transport quoted comma"

run_post
assert_status 1 "$status" "the quoted comma keeps the post-processing status"
expected="${POST_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row case_alpha "${workspace}/case_alpha" failed \
    "case directory not found")"$'\n'
assert_file_bytes_exact "$(post_summary)" "$expected" \
    "post-processing quoted comma"
assert_not_contains "$(cat -- "$(post_summary)")" "case_alpha_beta" \
    "post-processing does not join the quoted comma into one field"

# ---- 8. a doubled double quote and a quoted numeric value -------------------
#
# Row 2 keeps the doubled double quote as data. The parser does not unescape it,
# so the summary renders four double quotes for the two input bytes. Row 3 keeps
# both quote bytes of a quoted numeric value, so the setup float test fails. The
# expected bytes are exact literals.

new_ws doubled_quote
write_csv "$csv_abs" \
    'Case,met__WS_mps,met__WD_deg' \
    'zeta,a""b,270.0' \
    'eta,"3.5",270.0'

run_setup_dry
assert_status 1 "$status" "the quote-byte rows keep the setup status"
expected="${SETUP_SUMMARY_HEADER}"$'\n'
expected+="\"${csv_abs}\",\"2\",\"case_zeta\",\"\",\"270.0\",\"a\"\"\"\"b\",\"\",\"\",\"failed\",\"invalid WS\""$'\n'
expected+="\"${csv_abs}\",\"3\",\"case_eta\",\"\",\"270.0\",\"\"\"3.5\"\"\",\"\",\"\",\"failed\",\"invalid WS\""$'\n'
assert_file_bytes_exact "$(setup_summary)" "$expected" "setup quote bytes"

# ---- 9. Stage-specific trim behavior for a quote byte -----------------------
#
# The Case cell holds one double quote. Setup, mesh, flow, and transport keep
# that byte, so the Case ID normalizes to NA. Post-processing removes one
# leading and one trailing double quote, so the Case cell becomes empty and
# post-processing reports the empty-Case diagnostic instead.

new_ws quote_trim
write_csv "$csv_abs" \
    'Case,met__WS_mps,met__WD_deg' \
    '",3.5,270.0'

run_mesh
assert_status 0 "$status" "the quote-byte Case keeps the mesh status"
expected="${STAGE_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 NA NA/flow "${workspace}/NA/flow" skipped \
    "case directory not found")"$'\n'
assert_file_bytes_exact "$(mesh_summary)" "$expected" "mesh quote-byte Case"
assert_not_contains "$(cat -- "$(mesh_summary)")" "missing Case" \
    "mesh keeps the quote byte, so the Case cell is not empty"

run_flow
assert_status 0 "$status" "the quote-byte Case keeps the flow status"
assert_file_bytes_exact "$(flow_summary)" "$expected" "flow quote-byte Case"

run_transport
assert_status 1 "$status" "the quote-byte Case keeps the transport status"
expected="${TRANSPORT_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 NA 'NA/flow|NA/trd' "${workspace}/NA/trd" \
    failed "flow case directory not found: ${workspace}/NA/flow")"$'\n'
assert_file_bytes_exact "$(transport_summary)" "$expected" \
    "transport quote-byte Case"

run_post
assert_status 0 "$status" "the quote-byte Case keeps the post-processing status"
assert_no_data_row "$(post_summary)" "$POST_SUMMARY_HEADER" \
    "post-processing quote-byte Case"
assert_contains "$out" ">>> [warn] CSV row 2 has an empty Case value." \
    "post-processing removes the quote byte and reports an empty Case"
assert_not_contains "$out" "invalid Case value" \
    "post-processing does not report an invalid Case value"

# ---- 10. a quoted Case header ------------------------------------------------
#
# Post-processing removes the quote bytes during header normalization, so the
# quoted header stays accepted. Setup, mesh, flow, and transport keep the quote
# bytes, so the required column stays absent.

new_ws quoted_header
write_csv "$csv_abs" \
    '"Case",met__WS_mps,met__WD_deg' \
    'zeta,3.5,270.0'

run_setup_dry
assert_status 1 "$status" "the quoted Case header fails the setup lookup"
assert_contains "$out" "Required column not found in ${csv_abs}: Case" \
    "setup keeps the required-Case diagnostic"
assert_no_data_row "$(setup_summary)" "$SETUP_SUMMARY_HEADER" \
    "setup quoted Case header"

run_mesh
assert_status 1 "$status" "the quoted Case header fails the mesh lookup"
assert_contains "$out" "Required column not found in ${csv_abs}: Case" \
    "mesh keeps the required-Case diagnostic"
assert_no_data_row "$(mesh_summary)" "$STAGE_SUMMARY_HEADER" \
    "mesh quoted Case header"

run_flow
assert_status 1 "$status" "the quoted Case header fails the flow lookup"
assert_contains "$out" "Required column not found in ${csv_abs}: Case" \
    "flow keeps the required-Case diagnostic"

run_transport
assert_status 1 "$status" "the quoted Case header fails the transport lookup"
assert_contains "$out" "Required column not found in ${csv_abs}: Case" \
    "transport keeps the required-Case diagnostic"

run_post
assert_status 1 "$status" "the quoted Case header keeps the post-processing status"
expected="${POST_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row case_zeta "${workspace}/case_zeta" failed \
    "case directory not found")"$'\n'
assert_file_bytes_exact "$(post_summary)" "$expected" \
    "post-processing accepts the quoted Case header"

# ---- 11. missing required columns -------------------------------------------

new_ws missing_columns
write_csv "$csv_abs" 'met__WS_mps,met__WD_deg' '3.5,270.0'

run_setup_dry
assert_status 1 "$status" "an absent Case column fails the setup lookup"
assert_contains "$out" "Required column not found in ${csv_abs}: Case" \
    "setup names the absent Case column"

run_mesh
assert_status 1 "$status" "an absent Case column fails the mesh lookup"
assert_contains "$out" "Required column not found in ${csv_abs}: Case" \
    "mesh names the absent Case column"

run_flow
assert_status 1 "$status" "an absent Case column fails the flow lookup"
assert_contains "$out" "Required column not found in ${csv_abs}: Case" \
    "flow names the absent Case column"

run_transport
assert_status 1 "$status" "an absent Case column fails the transport lookup"
assert_contains "$out" "Required column not found in ${csv_abs}: Case" \
    "transport names the absent Case column"

run_post
assert_status 1 "$status" \
    "an absent Case column fails the post-processing lookup"
assert_contains "$out" "Required CSV column not found: Case" \
    "post-processing keeps its own absent-Case diagnostic"
assert_no_data_row "$(post_summary)" "$POST_SUMMARY_HEADER" \
    "post-processing absent Case column"

write_csv "$csv_abs" 'Case,met__WD_deg' 'zeta,270.0'
run_setup_dry
assert_status 1 "$status" "an absent WS column fails the setup lookup"
assert_contains "$out" \
    "Required column not found in ${csv_abs}: WS / wind_speed / U_ref / met__WS_mps" \
    "setup keeps the exact required-WS diagnostic"

write_csv "$csv_abs" 'Case,met__WS_mps' 'zeta,3.5'
run_setup_dry
assert_status 1 "$status" "an absent WD column fails the setup lookup"
assert_contains "$out" \
    "Required column not found in ${csv_abs}: WD / wind_direction / met__WD_deg" \
    "setup keeps the exact required-WD diagnostic"

# ---- 12. a header without a final newline -----------------------------------
#
# Transport reads the header with one unguarded direct read, so a header without
# a final newline stops transport before the required-column lookup and writes
# no diagnostic. The other four Stage Runners keep their current head -n 1
# result.

new_ws no_final_newline
printf 'Case,met__WS_mps,met__WD_deg' > "$csv_abs"

run_setup_dry
assert_status 0 "$status" \
    "a header without a final newline keeps the setup status"
assert_no_data_row "$(setup_summary)" "$SETUP_SUMMARY_HEADER" \
    "setup header without a final newline"

run_mesh
assert_status 0 "$status" "a header without a final newline keeps the mesh status"
assert_no_data_row "$(mesh_summary)" "$STAGE_SUMMARY_HEADER" \
    "mesh header without a final newline"

run_flow
assert_status 0 "$status" "a header without a final newline keeps the flow status"
assert_no_data_row "$(flow_summary)" "$STAGE_SUMMARY_HEADER" \
    "flow header without a final newline"

run_transport
assert_status 1 "$status" \
    "a header without a final newline keeps the transport failure"
assert_eq "" "$out" "the transport direct header read writes no diagnostic"
assert_no_data_row "$(transport_summary)" "$TRANSPORT_SUMMARY_HEADER" \
    "transport header without a final newline"

run_post
assert_status 0 "$status" \
    "a header without a final newline keeps the post-processing status"
assert_no_data_row "$(post_summary)" "$POST_SUMMARY_HEADER" \
    "post-processing header without a final newline"

# ---- 13. empty, NA, normalized, and duplicate Case rules --------------------
#
# The blank row keeps its current selection and adds no summary row. The row
# numbers count the blank row. Setup continues to process a duplicate Case row.
# Mesh, flow, transport, and post-processing keep their current duplicate
# suppression.

new_ws case_rules
write_csv "$csv_abs" \
    'met__WD_deg,met__WS_mps,Case' \
    '270.0,3.5,zeta' \
    '' \
    '270.0,3.5,' \
    '270.0,3.5,NA' \
    '270.0,3.5,case_zeta' \
    '270.0,3.5,a b'

run_setup_dry
assert_status 0 "$status" "the Case-rule rows keep the setup status"
expected="${SETUP_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/flow 270.000 3.5 3.5 \
    "${workspace}/case_zeta/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/trd 270.000 3.5 3.5 \
    "${workspace}/case_zeta/trd" dry_run "would create transport case")"$'\n'
expected+="$(csv_row "$csv_abs" 4 NA NA/flow 270.000 3.5 3.5 \
    "${workspace}/NA/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_abs" 4 NA NA/trd 270.000 3.5 3.5 \
    "${workspace}/NA/trd" dry_run "would create transport case")"$'\n'
expected+="$(csv_row "$csv_abs" 5 NA NA/flow 270.000 3.5 3.5 \
    "${workspace}/NA/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_abs" 5 NA NA/trd 270.000 3.5 3.5 \
    "${workspace}/NA/trd" dry_run "would create transport case")"$'\n'
expected+="$(csv_row "$csv_abs" 6 case_zeta case_zeta/flow 270.000 3.5 3.5 \
    "${workspace}/case_zeta/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_abs" 6 case_zeta case_zeta/trd 270.000 3.5 3.5 \
    "${workspace}/case_zeta/trd" dry_run "would create transport case")"$'\n'
expected+="$(csv_row "$csv_abs" 7 case_a_b case_a_b/flow 270.000 3.5 3.5 \
    "${workspace}/case_a_b/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_abs" 7 case_a_b case_a_b/trd 270.000 3.5 3.5 \
    "${workspace}/case_a_b/trd" dry_run "would create transport case")"$'\n'
assert_file_bytes_exact "$(setup_summary)" "$expected" "setup Case rules"

run_mesh
assert_status 0 "$status" "the Case-rule rows keep the mesh status"
expected="${STAGE_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta case_zeta/flow \
    "${workspace}/case_zeta/flow" skipped "case directory not found")"$'\n'
expected+="$(csv_row "$csv_abs" 4 "" "" "" skipped "missing Case")"$'\n'
expected+="$(csv_row "$csv_abs" 5 NA NA/flow "${workspace}/NA/flow" skipped \
    "case directory not found")"$'\n'
expected+="$(csv_row "$csv_abs" 6 case_zeta case_zeta/flow \
    "${workspace}/case_zeta/flow" skipped "duplicate case id")"$'\n'
expected+="$(csv_row "$csv_abs" 7 case_a_b case_a_b/flow \
    "${workspace}/case_a_b/flow" skipped "case directory not found")"$'\n'
assert_file_bytes_exact "$(mesh_summary)" "$expected" "mesh Case rules"
assert_no_marker "${workspace}/_mesh_state" "the mesh Case-rule rows"

run_flow
assert_status 0 "$status" "the Case-rule rows keep the flow status"
assert_file_bytes_exact "$(flow_summary)" "$expected" "flow Case rules"

run_transport
assert_status 1 "$status" "the Case-rule rows keep the transport status"
expected="${TRANSPORT_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_abs" 2 case_zeta 'case_zeta/flow|case_zeta/trd' \
    "${workspace}/case_zeta/trd" failed \
    "flow case directory not found: ${workspace}/case_zeta/flow")"$'\n'
expected+="$(csv_row "$csv_abs" 4 "" "" "" skipped "missing Case")"$'\n'
expected+="$(csv_row "$csv_abs" 5 NA 'NA/flow|NA/trd' "${workspace}/NA/trd" \
    failed "flow case directory not found: ${workspace}/NA/flow")"$'\n'
expected+="$(csv_row "$csv_abs" 6 case_zeta 'case_zeta/flow|case_zeta/trd' \
    "${workspace}/case_zeta/trd" skipped "duplicate case id")"$'\n'
expected+="$(csv_row "$csv_abs" 7 case_a_b 'case_a_b/flow|case_a_b/trd' \
    "${workspace}/case_a_b/trd" failed \
    "flow case directory not found: ${workspace}/case_a_b/flow")"$'\n'
assert_file_bytes_exact "$(transport_summary)" "$expected" \
    "transport Case rules"
assert_file_bytes_exact "${workspace}/.run_transport_cases_failed" \
    "case_zeta/trd"$'\n'"NA/trd"$'\n'"case_a_b/trd"$'\n' \
    "the transport Case-rule Failure Artifact"
assert_no_marker "${workspace}/_transport_state" "the transport Case-rule rows"

run_post
assert_status 1 "$status" "the Case-rule rows keep the post-processing status"
expected="${POST_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row case_zeta "${workspace}/case_zeta" failed \
    "case directory not found")"$'\n'
expected+="$(csv_row case_a_b "${workspace}/case_a_b" failed \
    "case directory not found")"$'\n'
assert_file_bytes_exact "$(post_summary)" "$expected" \
    "post-processing Case rules"
assert_contains "$out" ">>> [warn] CSV row 4 has an empty Case value." \
    "post-processing keeps the empty-Case diagnostic"
assert_contains "$out" ">>> [warn] CSV row 5 has an invalid Case value." \
    "post-processing keeps the invalid-Case diagnostic"
assert_contains "$out" ">>> [warn] Skipping duplicate case: case_zeta" \
    "post-processing keeps the duplicate-Case diagnostic"

# ---- 14. setup dynamic stack-header cell lookup -----------------------------
#
# The velocity headers are dynamic names that setup builds at run time. An
# absent header keeps the current empty result and the current warning. A
# present header keeps the current selected value and adds no warning. The
# backward-compatible fallback header keeps its current behavior.
#
# Setup runs each row in one background job and redirects that job to one Case
# log, so the observation reads the Case log.

STACK_WARNING=">>> [warn] CSV velocity column missing or empty: P1_SEB_A__Uexit_mps; skip f18p1_seb_a"

# run_real_setup - one real setup run. The function sets out, status, and log.
run_real_setup() {
    local stack_bin="${workspace}/_setup_bin"
    mkdir -p "$stack_bin"
    make_setup_side_commands "$stack_bin"
    local saved_path="$PATH"
    PATH="${stack_bin}:${PATH}"
    run_stage "$workspace" "$SETUP_SCRIPT" -i output_batch_1.csv -O . -j 1
    PATH="$saved_path"
    log="$(case_log "$workspace" _setup_logs case_zeta)"
}

new_ws stack_absent
make_setup_bases "$workspace"
write_csv "$csv_abs" 'Case,met__WS_mps,met__WD_deg' 'zeta,3.5,270.0'
run_real_setup
assert_status 0 "$status" "the real setup run without a stack header succeeds"
assert_contains "$log" "$STACK_WARNING" \
    "an absent dynamic stack header keeps the current empty result"

new_ws stack_present
make_setup_bases "$workspace"
write_csv "$csv_abs" 'Case,met__WS_mps,met__WD_deg,P1_SEB_A__Uexit_mps' \
    'zeta,3.5,270.0,5.0'
run_real_setup
assert_status 0 "$status" "the real setup run with a stack header succeeds"
assert_contains "$log" "CSV velocity column missing or empty: P1_SEB_B__Uexit_mps" \
    "the present-header run still warns for the absent sibling headers"
assert_not_contains "$log" "$STACK_WARNING" \
    "a present dynamic stack header keeps the current selected value"

new_ws stack_fallback
make_setup_bases "$workspace"
write_csv "$csv_abs" 'Case,met__WS_mps,met__WD_deg,P1_SEB_A_U' \
    'zeta,3.5,270.0,5.0'
run_real_setup
assert_status 0 "$status" "the real setup run with the fallback header succeeds"
assert_not_contains "$log" "$STACK_WARNING" \
    "the backward-compatible fallback header keeps its current behavior"

# ---- 15. two DOE Batch CSV files in one invocation --------------------------
#
# The second CSV uses a different column order and fewer columns than the first
# CSV. A stale caller header element from the first CSV would move the Case
# column past the last field of a second-CSV row, so the selection is
# observable. No column from the first CSV may resolve for the second CSV.

new_multi_ws() {
    workspace="$(new_workspace "$1")"
    install_fakes "$workspace"
    assert_fakes_active
    mkdir -p "${workspace}/simpleFoam_files" "${workspace}/scalarTransportDeffFoam_files"
    csv_one="${workspace}/output_batch_1.csv"
    csv_two="${workspace}/output_batch_2.csv"
}

new_multi_ws multi_stale
write_csv "$csv_one" 'met__WD_deg,met__WS_mps,zzz_extra,Case' '270.0,3.5,x,zeta'
write_csv "$csv_two" 'Case,met__WS_mps,met__WD_deg' 'eta,3.5,270.0'

run_stage "$workspace" "$SETUP_SCRIPT" -O . -j 1 --dry-run
assert_status 0 "$status" "two CSV files keep the setup status"
expected="${SETUP_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_one" 2 case_zeta case_zeta/flow 270.000 3.5 3.5 \
    "${workspace}/case_zeta/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_one" 2 case_zeta case_zeta/trd 270.000 3.5 3.5 \
    "${workspace}/case_zeta/trd" dry_run "would create transport case")"$'\n'
expected+="$(csv_row "$csv_two" 2 case_eta case_eta/flow 270.000 3.5 3.5 \
    "${workspace}/case_eta/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_two" 2 case_eta case_eta/trd 270.000 3.5 3.5 \
    "${workspace}/case_eta/trd" dry_run "would create transport case")"$'\n'
assert_file_bytes_exact "$(setup_summary)" "$expected" "setup two CSV files"

run_stage "$workspace" "$MESH_SCRIPT" -O . -j 1
assert_status 0 "$status" "two CSV files keep the mesh status"
expected="${STAGE_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_one" 2 case_zeta case_zeta/flow \
    "${workspace}/case_zeta/flow" skipped "case directory not found")"$'\n'
expected+="$(csv_row "$csv_two" 2 case_eta case_eta/flow \
    "${workspace}/case_eta/flow" skipped "case directory not found")"$'\n'
assert_file_bytes_exact "$(mesh_summary)" "$expected" "mesh two CSV files"

run_stage "$workspace" "$FLOW_SCRIPT" -O . -j 1
assert_status 0 "$status" "two CSV files keep the flow status"
assert_file_bytes_exact "$(flow_summary)" "$expected" "flow two CSV files"

run_stage "$workspace" "$TRANSPORT_SCRIPT" -O . -j 1 --save-times 300
assert_status 1 "$status" "two CSV files keep the transport status"
expected="${TRANSPORT_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_one" 2 case_zeta 'case_zeta/flow|case_zeta/trd' \
    "${workspace}/case_zeta/trd" failed \
    "flow case directory not found: ${workspace}/case_zeta/flow")"$'\n'
expected+="$(csv_row "$csv_two" 2 case_eta 'case_eta/flow|case_eta/trd' \
    "${workspace}/case_eta/trd" failed \
    "flow case directory not found: ${workspace}/case_eta/flow")"$'\n'
assert_file_bytes_exact "$(transport_summary)" "$expected" \
    "transport two CSV files"

# Post-processing keeps its current single-CSV selection.
run_stage "$workspace" "$POST_SCRIPT" -O . -j 1
assert_status 1 "$status" "two CSV files keep the post-processing status"
expected="${POST_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row case_zeta "${workspace}/case_zeta" failed \
    "case directory not found")"$'\n'
assert_file_bytes_exact "$(post_summary)" "$expected" \
    "post-processing selects only the first CSV"

# The second CSV omits one required column that the first CSV supplies. No
# column index from the first CSV may resolve for the second CSV.

new_multi_ws multi_required
write_csv "$csv_one" 'Case,met__WS_mps,met__WD_deg' 'zeta,3.5,270.0'
write_csv "$csv_two" 'Case,met__WD_deg' 'eta,270.0'

run_stage "$workspace" "$SETUP_SCRIPT" -O . -j 1 --dry-run
assert_status 1 "$status" "the second CSV without WS fails the setup lookup"
assert_contains "$out" \
    "Required column not found in ${csv_two}: WS / wind_speed / U_ref / met__WS_mps" \
    "setup names the second CSV in the required-WS diagnostic"
expected="${SETUP_SUMMARY_HEADER}"$'\n'
expected+="$(csv_row "$csv_one" 2 case_zeta case_zeta/flow 270.000 3.5 3.5 \
    "${workspace}/case_zeta/flow" dry_run "would create flow case")"$'\n'
expected+="$(csv_row "$csv_one" 2 case_zeta case_zeta/trd 270.000 3.5 3.5 \
    "${workspace}/case_zeta/trd" dry_run "would create transport case")"$'\n'
assert_file_bytes_exact "$(setup_summary)" "$expected" \
    "setup processes the first CSV and rejects the second CSV"

new_multi_ws multi_absent_case
write_csv "$csv_one" 'met__WD_deg,met__WS_mps,Case' '270.0,3.5,zeta'
write_csv "$csv_two" 'zzz_one,zzz_two' '1,2'

run_stage "$workspace" "$MESH_SCRIPT" -O . -j 1
assert_status 1 "$status" "the second CSV without Case fails the mesh lookup"
assert_contains "$out" "Required column not found in ${csv_two}: Case" \
    "mesh names the second CSV in the required-Case diagnostic"
assert_no_data_row "$(mesh_summary)" "$STAGE_SUMMARY_HEADER" \
    "mesh rejects the second CSV before any Case work"

run_stage "$workspace" "$FLOW_SCRIPT" -O . -j 1
assert_status 1 "$status" "the second CSV without Case fails the flow lookup"
assert_contains "$out" "Required column not found in ${csv_two}: Case" \
    "flow names the second CSV in the required-Case diagnostic"

run_stage "$workspace" "$TRANSPORT_SCRIPT" -O . -j 1 --save-times 300
assert_status 1 "$status" \
    "the second CSV without Case fails the transport lookup"
assert_contains "$out" "Required column not found in ${csv_two}: Case" \
    "transport names the second CSV in the required-Case diagnostic"

# ---- 16. a header field that normalizes to an empty string ------------------
#
# The caller-owned associative-index assignment keeps the current Bash runtime
# rejection. Each Stage Runner keeps status 1, stops before Case work and before
# an OpenFOAM command, writes no summary data row, and writes no Failure
# Artifact data. The assertion never compares a Bash-generated source line
# number.

new_ws empty_header
write_csv "$csv_abs" 'Case,,met__WS_mps,met__WD_deg' 'zeta,x,3.5,270.0'

reset_fake_records
run_setup_dry
assert_status 1 "$status" "an empty normalized header keeps the setup status"
assert_contains "$out" "bad array subscript" \
    "setup keeps the Bash runtime rejection"
assert_contains "$out" 'COL[' "the setup message names the Stage Runner index"
assert_no_data_row "$(setup_summary)" "$SETUP_SUMMARY_HEADER" \
    "setup empty normalized header"
assert_no_artifact_data "${workspace}/.setup_cases_failed" "setup empty header"
assert_no_openfoam_call "setup empty normalized header"

reset_fake_records
run_mesh
assert_status 1 "$status" "an empty normalized header keeps the mesh status"
assert_contains "$out" "bad array subscript" \
    "mesh keeps the Bash runtime rejection"
assert_contains "$out" 'COL[' "the mesh message names the Stage Runner index"
assert_no_data_row "$(mesh_summary)" "$STAGE_SUMMARY_HEADER" \
    "mesh empty normalized header"
assert_no_artifact_data "${workspace}/.run_mesh_cases_failed" "mesh empty header"
assert_no_openfoam_call "mesh empty normalized header"

reset_fake_records
run_flow
assert_status 1 "$status" "an empty normalized header keeps the flow status"
assert_contains "$out" "bad array subscript" \
    "flow keeps the Bash runtime rejection"
assert_contains "$out" 'COL[' "the flow message names the Stage Runner index"
assert_no_data_row "$(flow_summary)" "$STAGE_SUMMARY_HEADER" \
    "flow empty normalized header"
assert_no_artifact_data "${workspace}/.run_flow_cases_failed" "flow empty header"
assert_no_openfoam_call "flow empty normalized header"

reset_fake_records
run_transport
assert_status 1 "$status" "an empty normalized header keeps the transport status"
assert_contains "$out" "bad array subscript" \
    "transport keeps the Bash runtime rejection"
assert_contains "$out" 'COL[' \
    "the transport message names the Stage Runner index"
assert_no_data_row "$(transport_summary)" "$TRANSPORT_SUMMARY_HEADER" \
    "transport empty normalized header"
assert_no_artifact_data "${workspace}/.run_transport_cases_failed" \
    "transport empty header"
assert_no_openfoam_call "transport empty normalized header"

reset_fake_records
run_post
assert_status 1 "$status" \
    "an empty normalized header keeps the post-processing status"
assert_contains "$out" "bad array subscript" \
    "post-processing keeps the Bash runtime rejection"
assert_contains "$out" 'COLUMN_INDEX[' \
    "the post-processing message names the Stage Runner index"
assert_no_data_row "$(post_summary)" "$POST_SUMMARY_HEADER" \
    "post-processing empty normalized header"
assert_no_artifact_data "${workspace}/.run_post_processing_cases_failed" \
    "post-processing empty header"
assert_no_openfoam_call "post-processing empty normalized header"

# =============================================================================
# POST-EXTRACTION GROUP
#
# The copied deployment unit adds compatible instrumentation to the copied
# library. Each instrumented helper keeps the approved logic, output, and
# status, and appends one record outside every Batch Workspace. The first
# assertion below is the intentional TDD red observation: the base production
# Stage Runners parse the CSV locally, so they record no delegation.
# =============================================================================

HELPER_RECORD_DIR="${CONTROL_ROOT}/parser"
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

# Test instrumentation. Each definition keeps the approved parsing behavior and
# records one call outside the Batch Workspace. The normalization record holds
# the captured caller-callback output, which the approved helper already assigns
# to one variable, so the record adds no operation to the production path.
__y_record() { printf '%s\n' "$*" >> "${Y_HELPER_RECORD:-/dev/null}"; }

batch_stage_csv_tokenize() {
    __y_record "tokenize|$1"
    IFS=, read -r -a "$1" <<< "${2-}"
}

batch_stage_csv_normalize_header() {
    local __batch_stage_csv_normalize_header_value
    __batch_stage_csv_normalize_header_value="$("$1" "${2-}")"
    __y_record "normalize_header|$1|${2-}|${__batch_stage_csv_normalize_header_value}"
    echo "$__batch_stage_csv_normalize_header_value" | tr '[:upper:]' '[:lower:]'
}

batch_stage_csv_find_column() {
    local __batch_stage_csv_find_column_index="$1"
    shift
    local __batch_stage_csv_find_column_alias
    local __batch_stage_csv_find_column_key
    local __batch_stage_csv_find_column_reference

    __y_record "find_column|${__batch_stage_csv_find_column_index}|$*"
    for __batch_stage_csv_find_column_alias in "$@"; do
        __batch_stage_csv_find_column_key="$(
            echo "$__batch_stage_csv_find_column_alias" | tr '[:upper:]' '[:lower:]')"
        __batch_stage_csv_find_column_reference="${__batch_stage_csv_find_column_index}[${__batch_stage_csv_find_column_key}]"
        if [[ -n "${!__batch_stage_csv_find_column_reference+x}" ]]; then
            echo "${!__batch_stage_csv_find_column_reference}"
            return 0
        fi
    done
    return 1
}

batch_stage_csv_get_cell() {
    local -a __batch_stage_csv_get_cell_cells
    __y_record "get_cell|$1|${3-}"
    batch_stage_csv_tokenize __batch_stage_csv_get_cell_cells "${2-}"
    "$1" "${__batch_stage_csv_get_cell_cells[${3-}]:-}"
}
INSTRUMENT
}

# run_copied_stage <record-name> <script> <arg>...
run_copied_stage() {
    local record_name="$1"
    shift
    HELPER_RECORD="${HELPER_RECORD_DIR}/${record_name}.log"
    : > "$HELPER_RECORD"
    ( cd "$workspace" && Y_HELPER_RECORD="$HELPER_RECORD" \
        LC_ALL=C timeout "$STAGE_TIMEOUT" bash "$@" ) >/dev/null 2>&1 || true
}

# assert_record <record> <pattern> <message>
assert_record() {
    assert_ne 0 "$(grep -c -- "$2" "$1" || true)" "$3"
}

# assert_parser_delegation <stage> <record> <index> <header-array>
assert_parser_delegation() {
    local stage="$1" record="$2" index="$3" header_array="$4"

    assert_record "$record" '^normalize_header|' \
        "the copied ${stage} Stage Runner uses the shared header-normalization helper"
    assert_record "$record" '^find_column|' \
        "the copied ${stage} Stage Runner uses the shared column-lookup helper"
    assert_record "$record" '^get_cell|' \
        "the copied ${stage} Stage Runner uses the shared cell-lookup helper"
    assert_record "$record" "^tokenize|${header_array}\$" \
        "the copied ${stage} Stage Runner tokenizes the header with the shared helper"
    assert_record "$record" '^tokenize|__batch_stage_csv_get_cell_cells$' \
        "the copied ${stage} Stage Runner tokenizes a row with the shared helper"
    assert_record "$record" "^find_column|${index}|" \
        "the copied ${stage} Stage Runner passes its own associative index"
    assert_record "$record" '^normalize_header|trim|' \
        "the copied ${stage} Stage Runner passes its own trim callback to normalization"
    assert_record "$record" '^get_cell|trim|' \
        "the copied ${stage} Stage Runner passes its own trim callback to cell lookup"
}

new_ws delegation
parser_master="${workspace}/master_batch"
make_instrumented_unit "$parser_master"
make_setup_bases "$workspace"
# The "note" header holds two quote bytes, so the recorded normalization output
# proves which Stage Runner trim function ran inside the shared helper.
write_csv "$csv_abs" \
    'Case,met__WS_mps,met__WD_deg,Stability,"note"' \
    '"zeta",3.5,270.0,neutral,text'

run_copied_stage setup "${parser_master}/setup_cases.sh" \
    -i output_batch_1.csv -O . -j 1 --dry-run
assert_parser_delegation setup "$HELPER_RECORD" COL headers
assert_record "$HELPER_RECORD" '^find_column|COL|Case case$' \
    "the copied setup Stage Runner passes the exact Case alias vector"
assert_record "$HELPER_RECORD" \
    '^find_column|COL|WS ws wind_speed U_ref u_ref met__WS_mps$' \
    "the copied setup Stage Runner passes the exact WS alias vector"
assert_record "$HELPER_RECORD" \
    '^find_column|COL|WD wd wind_direction ref_wind_dir relative_wind_direction met__WD_deg$' \
    "the copied setup Stage Runner passes the exact WD alias vector"
assert_record "$HELPER_RECORD" \
    '^find_column|COL|Stability stability atmospheric_stability met__stability$' \
    "the copied setup Stage Runner passes the exact optional Stability vector"
assert_record "$HELPER_RECORD" '^normalize_header|trim|"note"|"note"$' \
    "the copied setup Stage Runner keeps its own header trim behavior"

run_copied_stage mesh "${parser_master}/run_mesh_cases.sh" \
    -i output_batch_1.csv -O . -j 1
assert_parser_delegation mesh "$HELPER_RECORD" COL headers
assert_record "$HELPER_RECORD" '^find_column|COL|Case case$' \
    "the copied mesh Stage Runner passes the exact Case alias vector"
assert_record "$HELPER_RECORD" '^normalize_header|trim|"note"|"note"$' \
    "the copied mesh Stage Runner keeps its own header trim behavior"

run_copied_stage flow "${parser_master}/run_flow_cases.sh" \
    -i output_batch_1.csv -O . -j 1
assert_parser_delegation flow "$HELPER_RECORD" COL headers
assert_record "$HELPER_RECORD" '^find_column|COL|Case case$' \
    "the copied flow Stage Runner passes the exact Case alias vector"
assert_record "$HELPER_RECORD" '^normalize_header|trim|"note"|"note"$' \
    "the copied flow Stage Runner keeps its own header trim behavior"

run_copied_stage transport "${parser_master}/run_transport_cases.sh" \
    -i output_batch_1.csv -O . -j 1 --save-times 300
assert_parser_delegation transport "$HELPER_RECORD" COL header
assert_record "$HELPER_RECORD" '^find_column|COL|Case case$' \
    "the copied transport Stage Runner passes the exact Case alias vector"
assert_record "$HELPER_RECORD" '^normalize_header|trim|"note"|"note"$' \
    "the copied transport Stage Runner keeps its own header trim behavior"

run_copied_stage post "${parser_master}/run_post_processing_cases.sh" \
    -i output_batch_1.csv -O . -j 1
assert_parser_delegation post-processing "$HELPER_RECORD" COLUMN_INDEX columns
assert_record "$HELPER_RECORD" '^find_column|COLUMN_INDEX|Case$' \
    "the copied post-processing Stage Runner passes the exact Case alias vector"
assert_record "$HELPER_RECORD" '^normalize_header|trim|"note"|note$' \
    "the copied post-processing Stage Runner keeps its own quote-removing trim"

# No Stage Runner uses another Stage Runner's trim behavior.
for stage in setup mesh flow transport; do
    assert_eq 0 \
        "$(grep -c '^normalize_header|trim|"note"|note$' \
            "${HELPER_RECORD_DIR}/${stage}.log" || true)" \
        "the copied ${stage} Stage Runner does not remove the header quote bytes"
done
assert_eq 0 \
    "$(grep -c '^normalize_header|trim|"note"|"note"$' \
        "${HELPER_RECORD_DIR}/post.log" || true)" \
    "the copied post-processing Stage Runner does not keep the header quote bytes"

# Every parser instrumentation record lives outside every Batch Workspace.
assert_eq "" \
    "$(find "$CONTRACT_TEST_RUN_DIR" -path "$CONTROL_ROOT" -prune -o \
        -name '*.log' -path '*parser*' -print | sort | tr '\n' ' ')" \
    "no parser instrumentation record enters a Batch Workspace"
