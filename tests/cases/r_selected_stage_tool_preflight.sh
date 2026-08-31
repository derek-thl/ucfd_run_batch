#!/usr/bin/env bash
# Section 23.R - advisory selected-Stage tool preflight (Issue #29).
#
# Every assertion uses the public top-level CLI and its console output. Each
# scenario builds its own command stubs inside its temporary workspace, so the
# scenario needs no change to tests/lib or tests/fakes.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

# Every OpenFOAM-family command and MPI command that the advisory can inspect.
ADVISORY_COMMANDS=(
    surfaceCheck surfaceTransformPoints foamDictionary
    surfaceFeatureExtract blockMesh decomposePar mpirun snappyHexMesh
    reconstructParMesh checkMesh renumberMesh reconstructPar
    simpleFoam scalarTransportDeffFoam foamToVTK
    foamListTimes foamLog gnuplot
)

# Platform utilities that the Orchestrator and the stage stubs need. A scenario
# PATH holds only these utilities and the selected advisory command stubs, so
# the scenario controls exactly which advisory command is absent. A host that
# already has a real OpenFOAM or MPI installation cannot change a result.
PLATFORM_COMMANDS=(
    bash sh env date basename dirname readlink realpath mktemp
    find awk sed grep cat cp mv rm mkdir rmdir chmod ln ls
    sort tail head tr wc cmp cut uniq sleep seq touch stat
)

# make_tool_bin <workspace> <absent_command> [<absent_command> ...]
# Build a complete command directory that holds every advisory command except
# the named ones, and set tool_path for the scenario.
make_tool_bin() {
    local bin_dir="${1}/_tool_bin" command_name absent skip resolved
    shift
    rm -rf -- "$bin_dir"
    mkdir -p -- "$bin_dir"

    for command_name in "${PLATFORM_COMMANDS[@]}"; do
        resolved="$(command -v "$command_name" 2>/dev/null || true)"
        [[ -n "$resolved" ]] || continue
        ln -sf -- "$resolved" "${bin_dir}/${command_name}"
    done

    for command_name in "${ADVISORY_COMMANDS[@]}"; do
        skip=0
        for absent in "$@"; do
            [[ "$command_name" == "$absent" ]] && skip=1
        done
        (( skip == 0 )) || continue

        if [[ "$command_name" == "foamDictionary" ]]; then
            # The advisory reads `application` through this interface.
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
[[ -n "$entry" && -n "$file" && -f "$file" ]] || exit 1
awk -v key="${entry##*.}" '
    $1 == key {
        line = $0
        sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", line)
        gsub(/;/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        print line
        exit
    }' "$file"
STUB
            chmod +x "${bin_dir}/foamDictionary"
            continue
        fi

        printf '#!/usr/bin/env bash\nexit 0\n' > "${bin_dir}/${command_name}"
        chmod +x "${bin_dir}/${command_name}"
    done

    tool_path="$bin_dir"

    # Prove that each named command really is absent from the scenario PATH.
    for absent in "$@"; do
        if ( PATH="$tool_path"; command -v "$absent" >/dev/null 2>&1 ); then
            _fail "the scenario needs a PATH without ${absent}"
        fi
    done
}

# advisory_payload <output> - the advisory lines without the timestamp and the
# level prefix.
advisory_payload() {
    printf '%s\n' "$1" |
        sed -n 's/^\[[0-9][0-9-]* [0-9][0-9:]*\] [A-Z][A-Z]*  *//p' |
        grep '^Selected-Stage tool advisory' || true
}

# ---- one missing static command for one selected stage ----------------------

workspace="$(new_workspace setup_missing_static)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
mkdir -p "$output"
make_csv "${workspace}/output_batch_1.csv" 0
make_tool_bin "$workspace" surfaceCheck

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

payload="$(advisory_payload "$out")"
expected="Selected-Stage tool advisory: stage=setup command=surfaceCheck status=missing
Selected-Stage tool advisory summary: missing=1 undetected=0. Execution continues."

assert_status 0 "$status" "an advisory warning keeps the dry-run status 0"
assert_eq "$expected" "$payload" "the setup advisory payload is exact"
assert_contains "$out" "DRY-RUN complete. No simulations were run." \
    "the dry-run keeps its current output"

# ---- reused Batch Workspace fixtures ----------------------------------------

# make_reused_case <output> <batch> <case_id> <mode> [<application>]
# mode: nomesh | mesh_only | marker | time
make_reused_case() {
    local output="$1" batch="$2" case_id="$3" mode="$4" application="${5:-simpleFoam}"
    local flow_dir="${output}/batch_${batch}/${case_id}/flow" name

    mkdir -p "${flow_dir}/system"
    printf 'FoamFile { object controlDict; }\napplication     %s;\n' "$application" \
        > "${flow_dir}/system/controlDict"

    [[ "$mode" == "nomesh" ]] && return 0

    mkdir -p "${flow_dir}/constant/polyMesh"
    for name in points boundary faces owner neighbour; do
        printf 'FoamFile { object %s; }\n' "$name" > "${flow_dir}/constant/polyMesh/${name}"
    done

    case "$mode" in
        marker) printf 'done\n' > "${flow_dir}/restart.marker" ;;
        time) mkdir -p "${flow_dir}/1000" ;;
    esac
}

# make_reused_batch <workspace> <output> <batch> - a reusable Batch Workspace
# with its CSV copy.
make_reused_batch() {
    local workspace="$1" output="$2" batch="$3"
    shift 3
    make_csv "${workspace}/output_batch_${batch}.csv" "$@"
    mkdir -p "${output}/batch_${batch}"
    cp -f -- "${workspace}/output_batch_${batch}.csv" \
        "${output}/batch_${batch}/output_batch_${batch}.csv"
}

# ---- selected-stage filtering and mesh continue mode ------------------------

workspace="$(new_workspace mesh_continue)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
make_reused_batch "$workspace" "$output" 1 case_0
make_reused_case "$output" 1 case_0 marker
# surfaceCheck belongs to setup, foamToVTK to post-processing, blockMesh to a
# fresh mesh. The selected mesh stage runs in continue mode.
make_tool_bin "$workspace" surfaceCheck foamToVTK blockMesh

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a mesh continue dry-run keeps status 0"
assert_eq "" "$(advisory_payload "$out")" \
    "an unselected stage command and a fresh-only mesh command give no warning"

# A nonzero numeric time directory is also continue evidence.

workspace="$(new_workspace mesh_continue_time)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
make_reused_batch "$workspace" "$output" 1 case_0
make_reused_case "$output" 1 case_0 time
make_tool_bin "$workspace" blockMesh

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a mesh time-directory continue dry-run keeps status 0"
assert_eq "" "$(advisory_payload "$out")" \
    "a nonzero time directory keeps the case in continue mode"

# FORCE_MESH=1 makes the same case fresh.

out="$(cd "$workspace" && PATH="$tool_path" FORCE_MESH=1 bash "$RUN_BATCH" --dry-run \
        --stage mesh -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a forced-fresh mesh dry-run keeps status 0"
assert_eq "Selected-Stage tool advisory: stage=mesh command=blockMesh status=missing
Selected-Stage tool advisory summary: missing=1 undetected=0. Execution continues." \
    "$(advisory_payload "$out")" "FORCE_MESH=1 uses the fresh mesh command set"

# One fresh case and one continue case use the fresh command set once.

workspace="$(new_workspace mesh_mixed)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
make_reused_batch "$workspace" "$output" 1 case_0 case_1
make_reused_case "$output" 1 case_0 marker
make_reused_case "$output" 1 case_1 mesh_only
make_tool_bin "$workspace" blockMesh

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a mixed-mode mesh dry-run keeps status 0"
assert_eq "Selected-Stage tool advisory: stage=mesh command=blockMesh status=missing
Selected-Stage tool advisory summary: missing=1 undetected=0. Execution continues." \
    "$(advisory_payload "$out")" "one fresh case uses the fresh mesh command set once"

# ---- canonical warning order ------------------------------------------------

workspace="$(new_workspace warning_order)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
mkdir -p "$output"
make_csv "${workspace}/output_batch_1.csv" case_0
make_tool_bin "$workspace" surfaceTransformPoints foamDictionary blockMesh mpirun checkMesh

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run --stage setup,mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

payload="$(advisory_payload "$out")"
expected="Selected-Stage tool advisory: stage=setup command=surfaceTransformPoints status=missing
Selected-Stage tool advisory: stage=setup command=foamDictionary status=missing
Selected-Stage tool advisory: stage=mesh command=blockMesh status=missing
Selected-Stage tool advisory: stage=mesh command=mpirun status=missing
Selected-Stage tool advisory: stage=mesh command=checkMesh status=missing
Selected-Stage tool advisory: stage=mesh command=foamDictionary status=missing
Selected-Stage tool advisory summary: missing=6 undetected=0. Execution continues."

assert_status 0 "$status" "a multi-warning dry-run keeps status 0"
assert_eq "$expected" "$payload" \
    "the advisory uses canonical stage order and matrix command order"

# ---- dynamic flow solver discovery ------------------------------------------

workspace="$(new_workspace flow_solver_missing)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
make_reused_batch "$workspace" "$output" 1 case_0
make_reused_case "$output" 1 case_0 mesh_only simpleFoam
make_tool_bin "$workspace" simpleFoam

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run --stage flow \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a missing flow solver keeps the dry-run status 0"
assert_eq "Selected-Stage tool advisory: stage=flow batch=batch_1 case=case_0 command=simpleFoam status=missing
Selected-Stage tool advisory summary: missing=1 undetected=0. Execution continues." \
    "$(advisory_payload "$out")" \
    "a reused flow case reports its own detected solver"

# Two cases with different applications are checked in DOE Batch CSV row order.
# A case without a Case directory gives no dynamic warning.

workspace="$(new_workspace flow_two_cases)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
make_reused_batch "$workspace" "$output" 1 case_0 case_1 case_absent
make_reused_case "$output" 1 case_0 mesh_only simpleFoam
make_reused_case "$output" 1 case_1 mesh_only buoyantSimpleFoam
make_tool_bin "$workspace" simpleFoam buoyantSimpleFoam

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run --stage flow \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "two missing flow solvers keep the dry-run status 0"
assert_eq "Selected-Stage tool advisory: stage=flow batch=batch_1 case=case_0 command=simpleFoam status=missing
Selected-Stage tool advisory: stage=flow batch=batch_1 case=case_1 command=buoyantSimpleFoam status=missing
Selected-Stage tool advisory summary: missing=2 undetected=0. Execution continues." \
    "$(advisory_payload "$out")" \
    "each case is checked independently in row order"
assert_not_contains "$out" "case_absent" \
    "a case without a Case directory gives no dynamic warning"

# An unreadable control dictionary gives an undetected warning.

workspace="$(new_workspace flow_undetected)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
make_reused_batch "$workspace" "$output" 1 case_0
make_reused_case "$output" 1 case_0 mesh_only simpleFoam
rm -f -- "${output}/batch_1/case_0/flow/system/controlDict"
make_tool_bin "$workspace"

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run --stage flow \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "an undetected application keeps the dry-run status 0"
assert_eq "Selected-Stage tool advisory: stage=flow batch=batch_1 case=case_0 application=undetected controlDict=${output}/batch_1/case_0/flow/system/controlDict
Selected-Stage tool advisory summary: missing=0 undetected=1. Execution continues." \
    "$(advisory_payload "$out")" \
    "an unreadable control dictionary names the batch, the case, and the path"

# Setup plus flow reads the application from the master flow template.

workspace="$(new_workspace flow_template)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
mkdir -p "$output" "${master}/simpleFoam_files/system"
printf 'FoamFile { object controlDict; }\napplication     simpleFoam;\n' \
    > "${master}/simpleFoam_files/system/controlDict"
make_csv "${workspace}/output_batch_1.csv" case_0
make_tool_bin "$workspace" simpleFoam

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run --stage setup,flow \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the setup and flow dry-run keeps status 0"
assert_eq "Selected-Stage tool advisory: stage=flow batch=batch_1 case=case_0 command=simpleFoam status=missing
Selected-Stage tool advisory summary: missing=1 undetected=0. Execution continues." \
    "$(advisory_payload "$out")" \
    "a future case reads the application from the master flow template"

# ---- flow reconstruction mode -----------------------------------------------

workspace="$(new_workspace flow_reconstruct)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
make_reused_batch "$workspace" "$output" 1 case_0
make_reused_case "$output" 1 case_0 mesh_only simpleFoam
make_tool_bin "$workspace" reconstructPar

for mode in latest all; do
    out="$(cd "$workspace" && PATH="$tool_path" RECONSTRUCT_MODE="$mode" \
            bash "$RUN_BATCH" --dry-run --stage flow -m "$master" -o "$output" \
            "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

    assert_status 0 "$status" "RECONSTRUCT_MODE=${mode} keeps the dry-run status 0"
    assert_eq "Selected-Stage tool advisory: stage=flow command=reconstructPar status=missing
Selected-Stage tool advisory summary: missing=1 undetected=0. Execution continues." \
        "$(advisory_payload "$out")" \
        "RECONSTRUCT_MODE=${mode} reports a missing reconstructPar"
done

out="$(cd "$workspace" && PATH="$tool_path" RECONSTRUCT_MODE=none \
        bash "$RUN_BATCH" --dry-run --stage flow -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "RECONSTRUCT_MODE=none keeps the dry-run status 0"
assert_eq "" "$(advisory_payload "$out")" \
    "RECONSTRUCT_MODE=none reports no missing reconstructPar"

# ---- transport uses a fixed solver and needs reconstruction ------------------

workspace="$(new_workspace transport_tools)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
make_reused_batch "$workspace" "$output" 1 case_0
# The Case control dictionary names another application. Transport must not use
# it, because the transport solver is fixed.
make_reused_case "$output" 1 case_0 mesh_only buoyantSimpleFoam
make_tool_bin "$workspace" scalarTransportDeffFoam reconstructPar buoyantSimpleFoam

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run --stage transport \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the transport dry-run keeps status 0"
assert_eq "Selected-Stage tool advisory: stage=transport command=scalarTransportDeffFoam status=missing
Selected-Stage tool advisory: stage=transport command=reconstructPar status=missing
Selected-Stage tool advisory summary: missing=2 undetected=0. Execution continues." \
    "$(advisory_payload "$out")" \
    "transport checks the fixed solver and the forwarded reconstruction command"
assert_not_contains "$out" "buoyantSimpleFoam" \
    "transport does not derive its solver from a Case control dictionary"

# ---- optional commands are outside the advisory -----------------------------

workspace="$(new_workspace optional_commands)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
make_reused_batch "$workspace" "$output" 1 case_0
make_reused_case "$output" 1 case_0 marker simpleFoam
make_tool_bin "$workspace" foamListTimes foamLog gnuplot

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run \
        --stage mesh,flow,transport -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "a missing optional command keeps the dry-run status 0"
assert_eq "" "$(advisory_payload "$out")" \
    "foamListTimes, foamLog, and gnuplot give no advisory warning"

# ---- default optional post-processing without a stage runner ----------------

workspace="$(new_workspace optional_post)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
rm -f -- "${master}/run_post_processing_cases.sh"
use_stub_records "$workspace"
mkdir -p "$output" "${master}/simpleFoam_files/system"
printf 'FoamFile { object controlDict; }\napplication     simpleFoam;\n' \
    > "${master}/simpleFoam_files/system/controlDict"
make_csv "${workspace}/output_batch_1.csv" case_0
make_tool_bin "$workspace" foamToVTK

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "the default pipeline dry-run keeps status 0"
assert_contains "$out" "post-processing will be skipped" \
    "the existing optional post-processing warning stays present"
assert_eq "" "$(advisory_payload "$out")" \
    "a skipped optional post-processing stage does not report foamToVTK"

# ---- advisory position and status preservation ------------------------------

workspace="$(new_workspace real_run)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
make_reused_batch "$workspace" "$output" 1 case_0
make_reused_case "$output" 1 case_0 mesh_only simpleFoam
make_tool_bin "$workspace" blockMesh

before="$(find "${output}" -type f -exec cksum {} \; | sort)"

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "an advisory warning does not change a successful run"
assert_contains "$(advisory_payload "$out")" \
    "Selected-Stage tool advisory: stage=mesh command=blockMesh status=missing" \
    "the real run prints the advisory warning"

advisory_line="$(printf '%s\n' "$out" | grep -n 'Selected-Stage tool advisory summary' |
    head -n 1 | cut -d: -f1)"
stage_line="$(printf '%s\n' "$out" | grep -n 'Stage start' | head -n 1 | cut -d: -f1)"

[[ -n "$advisory_line" && -n "$stage_line" ]] ||
    _fail "the run must print an advisory summary and a stage start line"
(( advisory_line < stage_line )) ||
    _fail "every advisory warning must appear before the first stage start line"

# The consolidated report stays present and unchanged in shape.
assert_contains "$out" "Run report begin" "the consolidated report stays present"
assert_contains "$out" "Run report batch: batch_1 result=succeeded" \
    "the consolidated report keeps its batch line"
assert_contains "$out" "Run report end" "the consolidated report stays complete"

# Advisory inspection writes nothing into a Batch Workspace. The stage stub does
# not write into the Batch Workspace either, so the file set stays identical.
assert_eq "$before" "$(find "${output}" -type f -exec cksum {} \; | sort)" \
    "advisory inspection changes no Batch Workspace file"

# A failing stage runner keeps its existing non-zero status.

out="$(cd "$workspace" && PATH="$tool_path" STUB_FAIL_STAGES="mesh" \
        bash "$RUN_BATCH" --stage mesh -m "$master" -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_failure "$status" "an advisory warning does not hide a failed stage"
assert_contains "$out" "Stage failed  : run_mesh_cases.sh" \
    "the existing stage failure diagnostic stays unchanged"

# ---- structural preflight failure prints no advisory ------------------------

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_missing.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "a structural preflight failure stays non-zero"
assert_eq "" "$(advisory_payload "$out")" \
    "a structural preflight failure prints no advisory block"

# ---- the stage runner keeps its own command check ---------------------------

workspace="$(new_workspace runner_check)"
master="${workspace}/master_batch"
output="${workspace}/out"
mkdir -p "$master" "$output" "${master}/simpleFoam_files/system" \
    "${master}/scalarTransportDeffFoam_files"
cp -f -- "$SETUP_SCRIPT" "${master}/setup_cases.sh"
cp -f -- "${MASTER_SRC_DIR}/lib_batch_stage.sh" "${master}/lib_batch_stage.sh"
printf 'FoamFile { object controlDict; }\napplication     simpleFoam;\n' \
    > "${master}/simpleFoam_files/system/controlDict"
make_csv "${workspace}/output_batch_1.csv" case_0
make_tool_bin "$workspace" surfaceCheck

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_failure "$status" "the setup stage runner still fails on a missing command"
assert_contains "$(advisory_payload "$out")" \
    "Selected-Stage tool advisory: stage=setup command=surfaceCheck status=missing" \
    "the advisory names the missing setup command"
assert_contains "$out" "'surfaceCheck' not found in PATH" \
    "the stage runner keeps its own missing-command diagnostic"
assert_contains "$out" "Stage failed  : setup_cases.sh" \
    "the stage runner failure still reaches the Orchestrator"

# ---- the default full pipeline checks every resolvable stage ----------------

workspace="$(new_workspace full_pipeline)"
master="${workspace}/master_batch"
output="${workspace}/out"
make_stub_master "$master" master
use_stub_records "$workspace"
mkdir -p "$output" "${master}/simpleFoam_files/system"
printf 'FoamFile { object controlDict; }\napplication     simpleFoam;\n' \
    > "${master}/simpleFoam_files/system/controlDict"
make_csv "${workspace}/output_batch_1.csv" case_0
make_tool_bin "$workspace" surfaceCheck snappyHexMesh renumberMesh \
    scalarTransportDeffFoam foamToVTK

out="$(cd "$workspace" && PATH="$tool_path" bash "$RUN_BATCH" --dry-run \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

payload="$(advisory_payload "$out")"
expected="Selected-Stage tool advisory: stage=setup command=surfaceCheck status=missing
Selected-Stage tool advisory: stage=mesh command=snappyHexMesh status=missing
Selected-Stage tool advisory: stage=flow command=renumberMesh status=missing
Selected-Stage tool advisory: stage=transport command=renumberMesh status=missing
Selected-Stage tool advisory: stage=transport command=scalarTransportDeffFoam status=missing
Selected-Stage tool advisory: stage=post-processing command=foamToVTK status=missing
Selected-Stage tool advisory summary: missing=6 undetected=0. Execution continues."

assert_status 0 "$status" "the full pipeline dry-run keeps status 0"
assert_eq "$expected" "$payload" "the full pipeline checks every selected stage"

# Mandatory platform utilities are outside this advisory.
for platform_command in awk sed tee find sort; do
    assert_not_contains "$payload" "command=${platform_command} " \
        "the advisory does not report the platform utility ${platform_command}"
done
