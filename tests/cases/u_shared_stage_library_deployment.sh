#!/usr/bin/env bash
# Section 23.U - shared Stage library deployment foundation (Issue #36).
#
# Every assertion uses the public Orchestrator CLI, a direct Stage Runner CLI,
# the process status, the console output, and the Batch Workspace file tree. No
# test calls a private function in lib_batch_stage.sh.
set -euo pipefail
CASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${CASE_DIR}/../lib/harness.sh"
source "${CASE_DIR}/../lib/assert.sh"

STAGE_LIBRARY="${MASTER_SRC_DIR}/lib_batch_stage.sh"

STAGE_RUNNERS=(
    setup_cases.sh
    run_mesh_cases.sh
    run_flow_cases.sh
    run_transport_cases.sh
    run_post_processing_cases.sh
)

# ---- deployment-unit fixtures -----------------------------------------------

# make_deployment_unit <dir> [<library_mode>] - a real deployment unit built
# from the production Stage Runners.
#
# library_mode: complete | absent | no_version | version_2 | unsourceable | unreadable
make_deployment_unit() {
    local dir="$1" mode="${2:-complete}" name

    mkdir -p -- "$dir"
    for name in "${STAGE_RUNNERS[@]}"; do
        cp -f -- "${MASTER_SRC_DIR}/${name}" "${dir}/${name}"
    done

    case "$mode" in
        complete) cp -f -- "$STAGE_LIBRARY" "${dir}/lib_batch_stage.sh" ;;
        absent) rm -f -- "${dir}/lib_batch_stage.sh" ;;
        no_version)
            printf '#!/usr/bin/env bash\n# no API version\n' \
                > "${dir}/lib_batch_stage.sh" ;;
        version_2)
            printf '#!/usr/bin/env bash\nreadonly BATCH_STAGE_LIBRARY_API_VERSION=2\n' \
                > "${dir}/lib_batch_stage.sh" ;;
        unsourceable)
            # A Bash syntax error only. No command and no side effect.
            printf '#!/usr/bin/env bash\nif [\n' > "${dir}/lib_batch_stage.sh" ;;
        unreadable)
            cp -f -- "$STAGE_LIBRARY" "${dir}/lib_batch_stage.sh"
            chmod 000 "${dir}/lib_batch_stage.sh" ;;
    esac
}

# expected_direct_diagnostic <dir> - the exact direct Stage Runner diagnostic.
expected_direct_diagnostic() {
    printf 'Error: Required Stage library is missing or incompatible: %s/lib_batch_stage.sh' "$1"
}

# ---- a direct Stage Runner rejects a missing library ------------------------

workspace="$(new_workspace direct_missing)"
unit="${workspace}/unit"
make_deployment_unit "$unit" absent

out="$(cd "$workspace" && bash "${unit}/setup_cases.sh" --help 2>&1)" \
    && status=0 || status=$?

assert_status 1 "$status" "a missing Stage library gives status 1"
assert_eq "$(expected_direct_diagnostic "$unit")" "$out" \
    "the direct Stage Runner prints the exact library diagnostic"

# ---- a complete deployment unit keeps existing direct behavior --------------

workspace="$(new_workspace direct_complete)"
unit="${workspace}/unit"
make_deployment_unit "$unit" complete

for runner in "${STAGE_RUNNERS[@]}"; do
    out="$(cd "$workspace" && bash "${unit}/${runner}" --help 2>&1)" \
        && status=0 || status=$?
    assert_status 0 "$status" "${runner} --help keeps exit status 0"
    assert_not_contains "$out" "Required Stage library" \
        "${runner} prints no library diagnostic with a complete unit"
done

# ---- every incompatible library shape fails closed --------------------------

for mode in absent no_version version_2 unsourceable; do
    workspace="$(new_workspace "direct_${mode}")"
    unit="${workspace}/unit"
    make_deployment_unit "$unit" "$mode"

    out="$(cd "$workspace" && bash "${unit}/run_mesh_cases.sh" --help 2>&1)" \
        && status=0 || status=$?

    assert_status 1 "$status" "library mode ${mode} gives status 1"
    assert_eq "$(expected_direct_diagnostic "$unit")" "$out" \
        "library mode ${mode} prints the exact diagnostic"
done

# An unreadable library needs an identity that cannot read it.
if (( EUID == 0 )); then
    printf 'SKIP: the unreadable-library assertion needs a non-root identity (EUID=0).\n'
else
    workspace="$(new_workspace direct_unreadable)"
    unit="${workspace}/unit"
    make_deployment_unit "$unit" unreadable

    out="$(cd "$workspace" && bash "${unit}/run_flow_cases.sh" --help 2>&1)" \
        && status=0 || status=$?

    assert_status 1 "$status" "an unreadable library gives status 1"
    assert_eq "$(expected_direct_diagnostic "$unit")" "$out" \
        "an unreadable library prints the exact diagnostic"
    chmod 644 "${unit}/lib_batch_stage.sh"
fi

# An inherited API-version value cannot satisfy the check.

workspace="$(new_workspace inherited_version)"
unit="${workspace}/unit"
make_deployment_unit "$unit" no_version

out="$(cd "$workspace" && BATCH_STAGE_LIBRARY_API_VERSION=1 \
        bash "${unit}/setup_cases.sh" --help 2>&1)" && status=0 || status=$?

assert_status 1 "$status" "an inherited API version cannot satisfy the check"
assert_eq "$(expected_direct_diagnostic "$unit")" "$out" \
    "an inherited API version still prints the exact diagnostic"

# ---- the direct failure happens before any other work -----------------------

workspace="$(new_workspace direct_ordering)"
unit="${workspace}/unit"
make_deployment_unit "$unit" absent
mkdir -p "${workspace}/run" "${workspace}/_poison_bin"
printf 'Case,WS,WD\ncase_0,3.5,270.0\n' > "${workspace}/run/output_batch_1.csv"
for command_name in surfaceCheck surfaceTransformPoints foamDictionary blockMesh \
                    snappyHexMesh decomposePar mpirun simpleFoam foamToVTK; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${0##*/}" >> "%s"\nexit 0\n' \
        "${workspace}/_poison.log" > "${workspace}/_poison_bin/${command_name}"
    chmod +x "${workspace}/_poison_bin/${command_name}"
done

before="$(find "${workspace}/run" | sort)"

# An unknown option would normally fail argument parsing. The library check must
# run first, so the library diagnostic is the only output.
out="$(cd "${workspace}/run" && PATH="${workspace}/_poison_bin:${PATH}" \
        bash "${unit}/setup_cases.sh" --not-a-real-option -i output_batch_1.csv 2>&1)" \
    && status=0 || status=$?

assert_status 1 "$status" "the direct ordering scenario gives status 1"
assert_eq "$(expected_direct_diagnostic "$unit")" "$out" \
    "the library check runs before argument parsing"
assert_not_contains "$out" "Unknown option" \
    "argument parsing never starts"
assert_file_missing "${workspace}/_poison.log" \
    "the direct failure runs no OpenFOAM command"
assert_eq "$before" "$(find "${workspace}/run" | sort)" \
    "the direct failure creates and changes no artifact"
assert_file_missing "${workspace}/run/setup_cases_summary.csv" \
    "the direct failure writes no Stage summary"
assert_file_missing "${workspace}/run/.setup_cases_failed" \
    "the direct failure writes no Failure Artifact"

# ---- Orchestrator deployment-unit resolution --------------------------------

# make_orchestrated <name> - a workspace with a DOE Batch CSV and an output root.
make_orchestrated() {
    workspace="$(new_workspace "$1")"
    master="${workspace}/master_batch"
    output="${workspace}/out"
    mkdir -p "$output"
    make_csv "${workspace}/output_batch_1.csv" case_0
}

# make_reuse_batch <output> <batch> <csv> - a non-empty reusable Batch Workspace.
make_reuse_batch() {
    mkdir -p "${1}/batch_${2}"
    cp -f -- "$3" "${1}/batch_${2}/$(basename -- "$3")"
}

# expected_orchestrator_diagnostic <stage_runner> <library>
expected_orchestrator_diagnostic() {
    printf 'Required Stage library is missing or incompatible for %s: %s' "$1" "$2"
}

# A complete custom master passes preflight in setup initialize mode.

make_orchestrated master_complete
make_deployment_unit "$master" complete

out="$(cd "$workspace" && bash "$RUN_BATCH" --dry-run --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a complete custom master passes preflight"
assert_contains "$out" "Preflight PASS" "the complete deployment unit reaches Preflight PASS"

# A central Stage Runner with no central library fails, even when a batch-local
# library exists.

make_orchestrated central_missing_library
make_deployment_unit "$master" absent
make_reuse_batch "$output" 1 "${workspace}/output_batch_1.csv"
cp -f -- "$STAGE_LIBRARY" "${output}/batch_1/lib_batch_stage.sh"

before="$(find "$output" | sort)"

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 1 "$status" "a central Stage Runner without its library gives status 1"
assert_contains "$out" \
    "$(expected_orchestrator_diagnostic "${master}/run_mesh_cases.sh" "${master}/lib_batch_stage.sh")" \
    "the Orchestrator names the selected Stage Runner and its expected library"
assert_not_contains "$out" "Preflight PASS" "the failure happens before Preflight PASS"
assert_not_contains "$out" "Stage start" "the failure happens before any stage"
assert_not_contains "$out" "Selected-Stage tool advisory" \
    "the failure happens before advisory inspection"
assert_eq "$before" "$(find "$output" | sort)" \
    "the Orchestrator failure changes no Batch Workspace"

# A batch-local Stage Runner with no batch-local library fails, even when a
# central library exists without the selected central Stage Runner.

make_orchestrated batch_local_missing_library
mkdir -p "$master"
cp -f -- "$STAGE_LIBRARY" "${master}/lib_batch_stage.sh"
make_reuse_batch "$output" 1 "${workspace}/output_batch_1.csv"
make_deployment_unit "${output}/batch_1" absent

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 1 "$status" "a batch-local Stage Runner without its library gives status 1"
assert_contains "$out" \
    "$(expected_orchestrator_diagnostic "${output}/batch_1/run_mesh_cases.sh" "${output}/batch_1/lib_batch_stage.sh")" \
    "the Orchestrator uses no central library for a batch-local Stage Runner"

# A complete batch-local deployment unit passes when the central Stage Runner is
# absent.

make_orchestrated batch_local_complete
mkdir -p "$master"
make_reuse_batch "$output" 1 "${workspace}/output_batch_1.csv"
make_deployment_unit "${output}/batch_1" complete

out="$(cd "$workspace" && bash "$RUN_BATCH" --dry-run --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a complete batch-local deployment unit passes preflight"
assert_contains "$out" "Preflight PASS" "the batch-local unit reaches Preflight PASS"

# ---- a symbolic-link Stage Runner uses the library beside its target --------

make_orchestrated symlink_target
target_dir="${workspace}/physical"
make_deployment_unit "$target_dir" complete
mkdir -p "$master"
ln -s "${target_dir}/run_mesh_cases.sh" "${master}/run_mesh_cases.sh"
make_reuse_batch "$output" 1 "${workspace}/output_batch_1.csv"

out="$(cd "$workspace" && bash "$RUN_BATCH" --dry-run --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a symbolic-link Stage Runner uses the library beside its target"
assert_contains "$out" "Preflight PASS" "the symbolic-link deployment unit passes preflight"

# A library beside only the symbolic link is not used.

make_orchestrated symlink_wrong_side
target_dir="${workspace}/physical"
make_deployment_unit "$target_dir" absent
mkdir -p "$master"
ln -s "${target_dir}/run_mesh_cases.sh" "${master}/run_mesh_cases.sh"
cp -f -- "$STAGE_LIBRARY" "${master}/lib_batch_stage.sh"
make_reuse_batch "$output" 1 "${workspace}/output_batch_1.csv"

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 1 "$status" "a library beside only the symbolic link gives status 1"
assert_contains "$out" \
    "$(expected_orchestrator_diagnostic "${master}/run_mesh_cases.sh" "${target_dir}/lib_batch_stage.sh")" \
    "the expected library path is the physical target directory"

# ---- setup initialization copies the library into the Batch Workspace -------

make_orchestrated initialize_copy
make_deployment_unit "$master" complete
mkdir -p "${master}/simpleFoam_files/system" "${master}/scalarTransportDeffFoam_files"
printf 'FoamFile { object controlDict; }\napplication     simpleFoam;\n' \
    > "${master}/simpleFoam_files/system/controlDict"
printf 'Case,WS,WD\n' > "${workspace}/output_batch_1.csv"

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage setup \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "an empty DOE Batch CSV setup run keeps status 0"
assert_file_exists "${output}/batch_1/lib_batch_stage.sh" \
    "setup initialization copies the shared Stage library"
assert_file_exists "${output}/batch_1/setup_cases.sh" \
    "setup initialization copies the Stage Runner of the same unit"

# ---- an old Stage Runner without the declaration keeps its behavior ---------

make_orchestrated old_runner
make_stub_master "$master" master
use_stub_records "$workspace"
make_reuse_batch "$output" 1 "${workspace}/output_batch_1.csv"

out="$(cd "$workspace" && bash "$RUN_BATCH" --stage mesh \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "an old Stage Runner without the declaration still runs"
stub_ran mesh 1 || _fail "the old Stage Runner still executes"
assert_not_contains "$out" "Required Stage library" \
    "an old Stage Runner needs no shared Stage library"

# ---- an optional missing post-processing Stage stays skipped ----------------

# The default pipeline makes post-processing optional. An explicitly selected
# post-processing Stage keeps its existing fatal missing-Stage-Runner behavior.
make_orchestrated optional_post
make_deployment_unit "$master" complete
rm -f -- "${master}/run_post_processing_cases.sh"

out="$(cd "$workspace" && bash "$RUN_BATCH" --dry-run \
        -m "$master" -o "$output" "${workspace}/output_batch_1.csv" 2>&1)" \
    && status=0 || status=$?

assert_status 0 "$status" "a skipped optional post-processing Stage keeps status 0"
assert_contains "$out" "post-processing will be skipped" \
    "the optional post-processing Stage keeps its skip diagnostic"
assert_not_contains "$out" "Required Stage library" \
    "a skipped optional Stage needs no shared Stage library"

# ---- status mode does not resolve or validate a Stage Runner ----------------

make_orchestrated status_mode
make_deployment_unit "$master" unsourceable
make_reuse_batch "$output" 1 "${workspace}/output_batch_1.csv"
make_deployment_unit "${output}/batch_1" unsourceable
cp -f -- "${workspace}/output_batch_1.csv" "${output}/batch_1/output_batch_1.csv"

out="$(cd "$workspace" && bash "$RUN_BATCH" --status -o "$output" \
        "${workspace}/output_batch_1.csv" 2>&1)" && status=0 || status=$?

assert_status 0 "$status" "status mode ignores a poison deployment unit"
assert_contains "$out" "Status report end" "status mode keeps its report"
assert_not_contains "$out" "Required Stage library" \
    "status mode resolves and validates no Stage Runner or library"
