#!/usr/bin/env bash
# Shared harness for the v4 batch-runner contract tests.
#
# Every scenario gets a new temporary workspace. No test writes into the
# repository working tree. Fake OpenFOAM commands and stage stubs record the
# exact argument vector, the working directory, and the exported environment.

US=$'\x1f'

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/.." && pwd -P)"
SRC_DIR="${REPO_ROOT}/src"
MASTER_SRC_DIR="${SRC_DIR}/master_batch"

RUN_BATCH="${SRC_DIR}/run_batch.sh"
SETUP_SCRIPT="${MASTER_SRC_DIR}/setup_cases.sh"
MESH_SCRIPT="${MASTER_SRC_DIR}/run_mesh_cases.sh"
FLOW_SCRIPT="${MASTER_SRC_DIR}/run_flow_cases.sh"
TRANSPORT_SCRIPT="${MASTER_SRC_DIR}/run_transport_cases.sh"
POST_SCRIPT="${MASTER_SRC_DIR}/run_post_processing_cases.sh"

FAKE_CMD_SOURCE="${TESTS_DIR}/fakes/fake_cmd.sh"
STUB_LIB="${TESTS_DIR}/fakes/stage_stub.sh"
export STUB_LIB

# All OpenFOAM-family commands that the production scripts resolve through PATH.
FAKE_COMMANDS=(
    foamDictionary
    foamListTimes
    foamToVTK
    surfaceFeatureExtract
    blockMesh
    snappyHexMesh
    reconstructParMesh
    reconstructPar
    checkMesh
    decomposePar
    renumberMesh
    mpirun
    simpleFoam
    scalarTransportDeffFoam
)

# ---- workspaces --------------------------------------------------------------

# new_workspace <name> - create and print an isolated workspace directory.
new_workspace() {
    local name="$1" dir
    : "${CONTRACT_TEST_RUN_DIR:?CONTRACT_TEST_RUN_DIR must be set by the runner}"
    dir="${CONTRACT_TEST_RUN_DIR}/${CONTRACT_TEST_NAME:-case}.${name}"
    rm -rf -- "$dir"
    mkdir -p -- "$dir"
    printf '%s\n' "$dir"
}

# ---- fake commands -----------------------------------------------------------

# install_fakes <workspace> - create the fake bin directory and export PATH.
install_fakes() {
    local workspace="$1" bin_dir="${1}/_fake_bin" command_name
    mkdir -p "$bin_dir"
    for command_name in "${FAKE_COMMANDS[@]}"; do
        ln -sf "$FAKE_CMD_SOURCE" "${bin_dir}/${command_name}"
    done
    FAKE_BIN_DIR="$bin_dir"
    FAKE_RECORD_DIR="${workspace}/_fake_records"
    mkdir -p "$FAKE_RECORD_DIR"
    export FAKE_RECORD_DIR
    PATH="${bin_dir}:${PATH}"
    export PATH
}

# remove_fake <name> - make one command unavailable in PATH.
remove_fake() {
    rm -f "${FAKE_BIN_DIR}/$1"
}

# ---- stage stubs -------------------------------------------------------------

# make_stub_script <path> <origin>
make_stub_script() {
    local path="$1" origin="$2"
    mkdir -p -- "$(dirname -- "$path")"
    cat > "$path" <<STUB
#!/usr/bin/env bash
STUB_ORIGIN="${origin}"
source "\${STUB_LIB}"
STUB
    chmod +x "$path"
}

# make_stub_master <dir> <origin> - a master template of stage stubs only.
make_stub_master() {
    local dir="$1" origin="${2:-master}" name
    mkdir -p -- "$dir"
    for name in setup_cases.sh run_mesh_cases.sh run_flow_cases.sh \
                run_transport_cases.sh run_post_processing_cases.sh; do
        make_stub_script "${dir}/${name}" "$origin"
    done
}

# use_stub_records <workspace> - export the stub record directory.
use_stub_records() {
    STUB_RECORD_DIR="${1}/_stub_records"
    mkdir -p "$STUB_RECORD_DIR"
    export STUB_RECORD_DIR
}

# ---- fixtures ----------------------------------------------------------------

# make_csv <path> <case_id> [<case_id> ...]
make_csv() {
    local path="$1" case_id
    shift
    mkdir -p -- "$(dirname -- "$path")"
    printf 'Case,met__WS_mps,met__WD_deg\n' > "$path"
    for case_id in "$@"; do
        printf '%s,3.5,270.0\n' "$case_id" >> "$path"
    done
}

# make_flow_case <dir> [np] - a synthetic simpleFoam case for mesh and flow.
make_flow_case() {
    local dir="$1" np="${2:-2}" field
    mkdir -p "${dir}/system" "${dir}/constant" "${dir}/0"

    cat > "${dir}/system/controlDict" <<'DICT'
FoamFile { version 2.0; format ascii; class dictionary; object controlDict; }
application     simpleFoam;
startFrom       startTime;
startTime       0;
stopAt          endTime;
endTime         3000;
writeControl    timeStep;
writeInterval   1000;
DICT

    cat > "${dir}/system/decomposeParDict" <<DICT
FoamFile { version 2.0; format ascii; class dictionary; object decomposeParDict; }
numberOfSubdomains ${np};
method          scotch;
DICT

    cat > "${dir}/constant/turbulenceProperties" <<'DICT'
FoamFile { version 2.0; format ascii; class dictionary; object turbulenceProperties; }
simulationType      RAS;
RAS
{
    RASModel        kOmega;
    turbulence      on;
}
DICT

    for field in U p k nut omega; do
        printf 'FoamFile { object %s; }\n' "$field" > "${dir}/0/${field}"
    done
}

# make_flow_mesh <dir> - give a flow case a constant/polyMesh.
make_flow_mesh() {
    local dir="$1" name
    mkdir -p "${dir}/constant/polyMesh"
    for name in points boundary faces owner neighbour; do
        printf 'FoamFile { object %s; }\n' "$name" > "${dir}/constant/polyMesh/${name}"
    done
}

# make_flow_result <dir> <time> - a converged flow time directory.
make_flow_result() {
    local dir="$1" time_value="$2" field
    mkdir -p "${dir}/${time_value}"
    for field in U p nut phi; do
        printf 'FoamFile { object %s; }\n' "$field" > "${dir}/${time_value}/${field}"
    done
}

# make_transport_case <dir> [np] [scalar_field] [end_time]
make_transport_case() {
    local dir="$1" np="${2:-2}" scalar="${3:-T}" end_time="${4:-300}"
    mkdir -p "${dir}/system" "${dir}/constant" "${dir}/0"

    cat > "${dir}/system/controlDict" <<DICT
FoamFile { version 2.0; format ascii; class dictionary; object controlDict; }
application     scalarTransportDeffFoam;
startFrom       startTime;
startTime       0;
stopAt          endTime;
endTime         ${end_time};
writeControl    runTime;
writeInterval   60;
DICT

    cat > "${dir}/system/decomposeParDict" <<DICT
FoamFile { version 2.0; format ascii; class dictionary; object decomposeParDict; }
numberOfSubdomains ${np};
method          scotch;
DICT

    printf 'FoamFile { object %s; }\n' "$scalar" > "${dir}/0/${scalar}"
}

# ---- record queries ----------------------------------------------------------

# argv_line <token> [<token> ...] - build the recorded argument-vector form.
argv_line() {
    local token joined=""
    for token in "$@"; do
        joined+="${token}${US}"
    done
    printf '%s' "$joined"
}

# fake_calls <command> - print "cwd<TAB>argv" for each recorded call.
fake_calls() {
    local command_name="$1"
    [[ -f "${FAKE_RECORD_DIR}/calls.log" ]] || return 0
    awk -F'\t' -v want="$command_name" '$1 == want { print $2 "\t" $3 }' \
        "${FAKE_RECORD_DIR}/calls.log"
}

# fake_call_count <command>
fake_call_count() {
    fake_calls "$1" | grep -c . || true
}

# fake_argvs <command> - print only the recorded argument vectors.
fake_argvs() {
    fake_calls "$1" | cut -f2-
}

# fake_cwds <command> - print only the recorded working directories.
fake_cwds() {
    fake_calls "$1" | cut -f1
}

# stub_argv <stage> <batch> - print the recorded argument vector, one per line.
stub_argv() {
    local path="${STUB_RECORD_DIR}/${1}.${2}.argv"
    [[ -f "$path" ]] || return 1
    cat "$path"
}

# stub_argv_joined <stage> <batch>
stub_argv_joined() {
    local token joined=""
    while IFS= read -r token; do
        joined+="${token}${US}"
    done < <(stub_argv "$1" "$2")
    printf '%s' "$joined"
}

# stub_env <stage> <batch> <key>
stub_env() {
    local path="${STUB_RECORD_DIR}/${1}.${2}.env"
    [[ -f "$path" ]] || return 1
    awk -F= -v key="$3" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$path"
}

# stub_ran <stage> <batch>
stub_ran() {
    [[ -f "${STUB_RECORD_DIR}/${1}.${2}.argv" ]]
}

# stub_origin <stage> <batch>
stub_origin() {
    stub_env "$1" "$2" origin
}

# summary_status_count <summary_csv> <status> [field]
# The stage summaries put status in column 6. The post-processing summary uses
# column 3.
summary_status_count() {
    local path="$1" status="$2" field="${3:-6}"
    [[ -f "$path" ]] || { printf '0\n'; return 0; }
    awk -F, -v want="$status" -v field="$field" '
        NR > 1 { for (i = 1; i <= NF; i++) gsub(/"/, "", $i); if ($field == want) count++ }
        END { print count + 0 }' "$path"
}

# reset_fake_records - clear the recorded calls before a new observation window.
reset_fake_records() {
    : "${FAKE_RECORD_DIR:?install_fakes must run before reset_fake_records}"
    rm -rf -- "$FAKE_RECORD_DIR"
    mkdir -p -- "$FAKE_RECORD_DIR"
}

# stub_arg_after <stage> <batch> <flag> - print the token that follows <flag>.
stub_arg_after() {
    local stage="$1" batch="$2" flag="$3" previous="" token
    while IFS= read -r token; do
        if [[ "$previous" == "$flag" ]]; then
            printf '%s\n' "$token"
            return 0
        fi
        previous="$token"
    done < <(stub_argv "$stage" "$batch")
    return 1
}

# fake_arg_after <command> <flag> - print the token after <flag> in the first
# recorded call of <command>.
fake_arg_after() {
    local command_name="$1" flag="$2"
    fake_argvs "$command_name" | head -n 1 | tr "$US" '\n' |
        awk -v flag="$flag" 'previous == flag { print; exit } { previous = $0 }'
}

# assert_fakes_active - prove that PATH resolves every OpenFOAM-family command
# to the fake bin directory. A host with a real OpenFOAM installation must not
# change the result of a contract scenario.
assert_fakes_active() {
    local command_name resolved
    : "${FAKE_BIN_DIR:?install_fakes must run before assert_fakes_active}"
    for command_name in "${FAKE_COMMANDS[@]}"; do
        resolved="$(command -v "$command_name" || true)"
        if [[ "$resolved" != "${FAKE_BIN_DIR}/${command_name}" ]]; then
            printf 'ASSERT FAIL: %s must resolve to the fake bin directory\n' \
                "$command_name" >&2
            printf '  expected: %s\n  actual:   %s\n' \
                "${FAKE_BIN_DIR}/${command_name}" "${resolved:-<not found>}" >&2
            return 1
        fi
    done
}

# case_log <workspace> <stage_log_dir> <case_token> - print one case log.
# Example: case_log "$workspace" _transport_logs case_0_trd
case_log() {
    local path="${1}/${2}/${3}.log"
    [[ -f "$path" ]] || return 1
    cat "$path"
}
