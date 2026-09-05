#!/usr/bin/env bash
# run_mesh_cases.sh v4
# Batch mesh runner for OpenFOAM cases created by setup_cases.sh.

set -euo pipefail
trap 'echo ">>> [ERROR] ${0##*/} failed at line $LINENO: $BASH_COMMAND" >&2' ERR
export LC_ALL=C

# =============================================================================
# SHARED STAGE LIBRARY DEPLOYMENT UNIT
# =============================================================================
# This Stage Runner and its co-located lib_batch_stage.sh are one deployment
# unit. The library comes only from the physical directory of this script
# target. The check runs before argument parsing, artifact initialization, Case
# work, and any OpenFOAM command.
unset BATCH_STAGE_LIBRARY_REQUIRED_API_VERSION BATCH_STAGE_LIBRARY_API_VERSION
readonly BATCH_STAGE_LIBRARY_REQUIRED_API_VERSION=1
BATCH_STAGE_LIBRARY="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib_batch_stage.sh"

batch_stage_library_reject() {
    echo "Error: Required Stage library is missing or incompatible: ${BATCH_STAGE_LIBRARY}" >&2
    exit 1
}

[[ -f "$BATCH_STAGE_LIBRARY" && -r "$BATCH_STAGE_LIBRARY" ]] || batch_stage_library_reject

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib_batch_stage.sh
source "$BATCH_STAGE_LIBRARY" 2>/dev/null || batch_stage_library_reject

[[ "${BATCH_STAGE_LIBRARY_API_VERSION:-}" == "$BATCH_STAGE_LIBRARY_REQUIRED_API_VERSION" ]] ||
    batch_stage_library_reject

# =============================================================================
# 0. USER CONFIG
# =============================================================================
PARALLEL_JOBS=2
OUT_DIR="./"
CSV_FILE=""
CASE_PREFIX="flow"

FORCE_MESH="${FORCE_MESH:-0}"
RESTART_MARKER="restart.marker"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-5}"
PROGRESS_MAX_ACTIVE="${PROGRESS_MAX_ACTIVE:-8}"

# =============================================================================
# 1. COMMON HELPERS
# =============================================================================
usage() {
    cat <<'USAGE'
Usage:
  bash run_mesh_cases.sh [options]

Typical:
  bash run_mesh_cases.sh
  bash run_mesh_cases.sh -i output_batch_1.csv -O ./ -j 4

Options:
  -i <csv>            Process one DOE CSV. If omitted, process all output_batch_*.csv.
  -O, --output-dir    Output root folder containing case directories.
  -j <jobs>           Number of parallel mesh jobs.
  -h, --help

Environment:
  FORCE_MESH=1          Force a fresh mesh rebuild in every case.
  PROGRESS_INTERVAL=5   Console progress interval in seconds.
  PROGRESS_MAX_ACTIVE=8 Maximum active mesh cases listed in each progress update.
USAGE
}

info() { echo ">>> $*"; }
die()  { echo ">>> [ERROR] $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH."; }

trim() {
    local s="${1//$'\r'/}"
    echo "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

sanitize_token() {
    local s
    s="$(trim "$1")"
    s="$(echo "$s" | sed -e 's/[[:space:]]\+/_/g' -e 's/[^0-9A-Za-z._-]/_/g' -e 's/_\+/_/g' -e 's/^_//; s/_$//')"
    [[ -n "$s" ]] || s="NA"
    echo "$s"
}

make_case_id() {
    local s
    s="$(sanitize_token "$1")"

    if [[ "$s" == "NA" ]]; then
        echo "$s"
    elif [[ "$s" == case_* ]]; then
        echo "$s"
    else
        echo "case_${s}"
    fi
}

safe_path_token() {
    local s="$1"
    s="${s//\//_}"
    sanitize_token "$s"
}

# with_lock applies the Issue #47 append and lock-release status matrix. The
# callback status has precedence, and exactly one release attempt runs. A
# successful callback must not hide a non-zero release status, and a release
# status must not replace a callback failure.
with_lock() {
    local lock="$1"
    shift
    local callback_status=0 release_status=0

    batch_stage_lock_acquire "$lock" 0.05
    "$@" || callback_status=$?
    batch_stage_lock_release "$lock" || release_status=$?

    (( callback_status == 0 )) || return "$callback_status"
    return "$release_status"
}

append_summary_unlocked() {
    local csv_file="$1" row_no="$2" case_id="$3" case_name="$4" case_dir="$5" status="$6" msg="$7"
    local f_csv_file f_row_no f_case_id f_case_name f_case_dir f_status f_msg

    batch_stage_csv_quote f_csv_file "$csv_file"
    batch_stage_csv_quote f_row_no "$row_no"
    batch_stage_csv_quote f_case_id "$case_id"
    batch_stage_csv_quote f_case_name "$case_name"
    batch_stage_csv_quote f_case_dir "$case_dir"
    batch_stage_csv_quote f_status "$status"
    batch_stage_csv_quote f_msg "$msg"

    batch_stage_csv_append_row "$SUMMARY_CSV" \
        "$f_csv_file" "$f_row_no" "$f_case_id" "$f_case_name" "$f_case_dir" \
        "$f_status" "$f_msg"
}

append_summary() {
    with_lock "${SUMMARY_CSV}.lockdir" append_summary_unlocked "$@"
}

append_fail_unlocked() { echo "$1" >> "$FAIL_FILE"; }
mark_failed() { with_lock "${SUMMARY_CSV}.lockdir" append_fail_unlocked "$1"; }

now_stamp() { date '+%Y-%m-%d %H:%M:%S'; }

# ---- private Case completion accounting (Issue #47) -------------------------
# The parent records one status for every launched Case process, so a failed
# result append cannot hide a failed Case. The accounting directory lives
# outside the Batch Workspace and never becomes a public artifact.
JOB_STATUS_DIR=""

job_status_cleanup() {
    [[ -n "${JOB_STATUS_DIR:-}" ]] || return 0
    [[ -d "$JOB_STATUS_DIR" ]] || return 0
    rm -rf -- "$JOB_STATUS_DIR"
    return 0
}

job_status_init() {
    local parent parent_abs

    parent="${TMPDIR:-/tmp}"
    parent_abs="$(cd -- "$parent" 2>/dev/null && pwd -P)" ||
        die "TMPDIR is not a usable directory for private Case accounting: $parent"

    # The private accounting directory must stay outside the Batch Workspace, so
    # that it never becomes a Batch Workspace artifact. An unusable location is
    # an explicit failure, not a silent Batch Workspace write.
    if [[ "$parent_abs" == "$OUT_ABS" || "$parent_abs" == "$OUT_ABS"/* ]]; then
        die "TMPDIR must not be inside the Batch Workspace: $parent_abs"
    fi

    JOB_STATUS_DIR="$(mktemp -d "${parent_abs}/run_mesh_cases_status.XXXXXX")"
    trap job_status_cleanup EXIT
}

# job_status_failures - launched Case processes without a valid zero record.
job_status_failures() {
    local ordinal record value failures=0

    for (( ordinal = 1; ordinal <= STARTED_CASES; ordinal++ )); do
        record="${JOB_STATUS_DIR}/${ordinal}"
        if [[ ! -f "$record" ]]; then
            failures=$(( failures + 1 ))
            continue
        fi
        value="$(cat -- "$record" 2>/dev/null || true)"
        if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value != 0 )); then
            failures=$(( failures + 1 ))
        fi
    done

    printf '%s' "$failures"
}

# =============================================================================
# 2. PROGRESS / STATE HELPERS
# =============================================================================
state_file() {
    echo "${STATE_DIR}/$(safe_path_token "$CURRENT_CASE_NAME").state"
}

set_case_stage() {
    [[ -n "${STATE_DIR:-}" && -d "${STATE_DIR:-}" && -n "${CURRENT_CASE_NAME:-}" ]] || return 0

    local stage="$1" msg="${2:-}" f tmp
    f="$(state_file)"
    tmp="${f}.$$"
    {
        printf 'case=%s\n' "$CURRENT_CASE_NAME"
        printf 'pid=%s\n' "$$"
        printf 'stage=%s\n' "$stage"
        printf 'message=%s\n' "$msg"
        printf 'updated=%s\n' "$(now_stamp)"
        printf 'log=%s\n' "${CURRENT_CASE_LOG:-}"
    } > "$tmp" && mv -f "$tmp" "$f" || true
}

clear_case_stage() {
    [[ -n "${STATE_DIR:-}" && -n "${CURRENT_CASE_NAME:-}" ]] || return 0
    rm -f "$(state_file)" "$(state_file).$$" || true
}

count_status() {
    local status="$1"
    [[ -f "${SUMMARY_CSV:-}" ]] || { echo 0; return 0; }
    awk -F, -v status="$status" 'NR > 1 { gsub(/"/, "", $6); if ($6 == status) c++ } END { print c + 0 }' "$SUMMARY_CSV"
}

show_running_cases() {
    [[ -d "${STATE_DIR:-}" ]] || return 0

    shopt -s nullglob
    local files=("$STATE_DIR"/*.state)
    shopt -u nullglob
    (( ${#files[@]} > 0 )) || return 0

    info "Mesh cases currently running:"

    local shown=0 f case_name stage msg updated log_file remain read_status
    for f in "${files[@]}"; do
        (( shown >= PROGRESS_MAX_ACTIVE )) && break
        read_status=0
        IFS=$'\t' read -r case_name stage msg updated log_file < <(
            awk -F= '
                $1 == "case"    { c = substr($0, index($0,"=") + 1) }
                $1 == "stage"   { s = substr($0, index($0,"=") + 1) }
                $1 == "message" { m = substr($0, index($0,"=") + 1) }
                $1 == "updated" { u = substr($0, index($0,"=") + 1) }
                $1 == "log"     { l = substr($0, index($0,"=") + 1) }
                END { printf "%s\t%s\t%s\t%s\t%s\n", c, s, m, u, l }
            ' "$f" 2>/dev/null || true
        ) || read_status=$?

        # A concurrent case can remove a selected state file before this read
        # completes. The read then reports no field and returns non-zero. That
        # selection is stale, so this function ignores it instead of printing a
        # record built from default values. A selected path that still exists
        # keeps the existing default-fill behavior.
        if (( read_status != 0 )) && [[ ! -e "$f" ]]; then
            continue
        fi

        case_name="${case_name:-$(basename "$f" .state)}"
        stage="${stage:-running}"
        msg="${msg:-mesh job active}"
        updated="${updated:-N/A}"
        log_file="${log_file:-${LOG_DIR:-}/${case_name}.log}"

        printf '>>>   - %s | stage=%s | %s | updated=%s | log=%s\n' \
            "$case_name" "$stage" "$msg" "$updated" "$log_file"
        shown=$((shown + 1))
    done

    remain=$((${#files[@]} - shown))
    (( remain <= 0 )) || info "  ... ${remain} more running mesh case(s) not shown."
}

_LAST_PROGRESS_TIME=0
show_progress() {
    local force="${1:-0}" running meshed continued skipped failed done pending
    # The shared helper owns only the timing gate. This Stage Runner keeps
    # PROGRESS_INTERVAL, the force argument, the last-time variable, and every
    # progress field.
    local progress_due

    batch_stage_progress_tick progress_due _LAST_PROGRESS_TIME "$PROGRESS_INTERVAL" "$force"
    (( progress_due == 1 )) || return 0

    running="$(batch_stage_job_pool_running_count)"
    read -r meshed continued skipped < <(
        awk -F, 'NR>1 {
            gsub(/"/, "", $6);
            if ($6=="meshed") meshed++;
            else if ($6=="continued") continued++;
            else if ($6=="skipped") skipped++;
        } END { print meshed+0, continued+0, skipped+0 }' "$SUMMARY_CSV"
    )
    failed=0
    [[ -f "$FAIL_FILE" ]] && failed="$(wc -l < "$FAIL_FILE" | tr -d ' ')"

    done=$((meshed + continued + skipped + failed))
    pending=$((TOTAL_CASES - done - running))
    (( pending < 0 )) && pending=0

    info "Mesh progress: total=${TOTAL_CASES}, launched=${STARTED_CASES}, running=${running}/${PARALLEL_JOBS}, pending=${pending}, meshed=${meshed}, continued=${continued}, skipped=${skipped}, failed=${failed}"
    (( running == 0 )) || show_running_cases
}

wait_for_slot() {
    batch_stage_job_pool_wait_for_slot "$PARALLEL_JOBS" show_progress : 0.1
}

# The final drain keeps its forced progress call.
mesh_drain_progress() {
    show_progress 1
    return 0
}

wait_all_cases() {
    batch_stage_job_pool_wait_for_all mesh_drain_progress : 0
}

# =============================================================================
# 3. ARGUMENTS / GLOBAL VALIDATION
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i) CSV_FILE="${2:-}"; shift 2 ;;
        -O|--output-dir) OUT_DIR="${2:-}"; shift 2 ;;
        -j) PARALLEL_JOBS="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1. Use -h for help." ;;
    esac
done

validate_config() {
    [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] && (( PARALLEL_JOBS >= 1 )) || die "PARALLEL_JOBS must be integer >= 1."
    [[ "$PROGRESS_INTERVAL" =~ ^[0-9]+$ ]] && (( PROGRESS_INTERVAL >= 1 )) || die "PROGRESS_INTERVAL must be integer >= 1."
    [[ "$PROGRESS_MAX_ACTIVE" =~ ^[0-9]+$ ]] && (( PROGRESS_MAX_ACTIVE >= 1 )) || die "PROGRESS_MAX_ACTIVE must be integer >= 1."
    [[ -d "$OUT_DIR" ]] || die "Output folder not found: $OUT_DIR"

    need_cmd awk
    need_cmd sed
    need_cmd tee
    need_cmd foamDictionary

    OUT_ABS="$(cd "$OUT_DIR" && pwd -P)"
    SUMMARY_CSV="$OUT_ABS/run_mesh_cases_summary.csv"
    LOG_DIR="$OUT_ABS/_mesh_logs"
    STATE_DIR="$OUT_ABS/_mesh_state"
    FAIL_FILE="$OUT_ABS/.run_mesh_cases_failed"

    mkdir -p "$LOG_DIR"
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR"
    : > "$FAIL_FILE"
    printf 'csv_file,row_number,case_id,case_name,case_dir,status,message\n' > "$SUMMARY_CSV"
}

# =============================================================================
# 4. CSV HELPERS
# =============================================================================
declare -A COL=()

# Each shared parser helper reads this column index through the caller-supplied
# index name, so no direct read of the index stays visible in this Stage Runner.
# The side-effect-free reference below prevents ShellCheck SC2034 for an index
# that only a shared helper reads. A suppression directive is not used. The
# reference writes no output, creates no process, and changes no value.
: "${#COL[@]}"

declare -A SEEN_CASES=()
headers=()
CASE_COL=""

load_csv_header() {
    local csv_abs="$1" header_line h_lc i
    header_line="$(head -n 1 "$csv_abs")"
    header_line="${header_line//$'\r'/}"
    batch_stage_csv_tokenize headers "$header_line"

    COL=()
    for i in "${!headers[@]}"; do
        h_lc="$(batch_stage_csv_normalize_header trim "${headers[$i]}")"
        COL["$h_lc"]="$i"
    done

    CASE_COL="$(batch_stage_csv_find_column COL Case case)" || die "Required column not found in $csv_abs: Case"
}

get_cell() {
    local row="$1" idx="$2"
    batch_stage_csv_get_cell trim "$row" "$idx"
}

find_csv_files() {
    if [[ -n "$CSV_FILE" ]]; then
        [[ -f "$CSV_FILE" ]] && { echo "$CSV_FILE"; return 0; }
        [[ -n "${BATCH_DIR:-}" && -f "${BATCH_DIR}/${CSV_FILE}" ]] && { echo "${BATCH_DIR}/${CSV_FILE}"; return 0; }
        die "CSV file not found: $CSV_FILE"
    fi

    [[ -n "${BATCH_CSV_PATH:-}" && -f "$BATCH_CSV_PATH" ]] && { echo "$BATCH_CSV_PATH"; return 0; }
    [[ -n "${BATCH_DIR:-}" && -n "${BATCH_CSV:-}" && -f "${BATCH_DIR}/${BATCH_CSV}" ]] && { echo "${BATCH_DIR}/${BATCH_CSV}"; return 0; }

    shopt -s nullglob
    local files=(output_batch_*.csv)
    shopt -u nullglob
    (( ${#files[@]} > 0 )) || die "No output_batch_*.csv found."
    printf '%s\n' "${files[@]}" | sort -V
}

# =============================================================================
# 5. CASE-LOCAL MESH LOGIC
# =============================================================================
run_cmd() {
    echo ">>> [$PWD] $*"
    "$@"
}

run_tee() {
    local logfile="$1"
    shift
    echo ">>> [$PWD] $* (tee -> ${logfile})"
    "$@" 2>&1 | tee "$logfile"
}

run_step() {
    local stage="$1" msg="$2" log="${3:-}"
    shift 3
    set_case_stage "$stage" "$msg"
    # run_step wraps required mesh commands only. The case body executes in an
    # errexit-ignored context (Bash disables set -e on the left of ||), so a
    # failed required command must stop the case explicitly (v4 Sections 15.5
    # and 23.P). die exits the case subshell; the failure handler in
    # mesh_one_case then records the failed case.
    if [[ -n "$log" ]]; then
        run_tee "$log" "$@" ||
            die "Required mesh command failed: $1 (see log: $log)"
    else
        run_cmd "$@" ||
            die "Required mesh command failed: $1"
    fi
}

dict_get() {
    local entry="$1" file="$2" value=""
    [[ -f "$file" ]] || return 1
    value="$(foamDictionary -entry "$entry" -value "$file" 2>/dev/null || true)"
    value="$(echo "$value" | tr -d '\r' | tr -d '";' | awk '{$1=$1; print}')"
    [[ -n "$value" ]] && echo "$value"
}

has_nonzero_time_dir() {
    shopt -s nullglob
    local d
    for d in [0-9]* .[0-9]*; do
        [[ -d "$d" && "$d" != "0" ]] || continue
        [[ "$d" =~ ^[0-9]+([.][0-9]+)?$ || "$d" =~ ^[.][0-9]+$ ]] && return 0
    done
    return 1
}

remove_nonzero_time_dirs() {
    shopt -s nullglob
    local d
    for d in [0-9]* .[0-9]*; do
        [[ -d "$d" && "$d" != "0" ]] || continue
        [[ "$d" =~ ^[0-9]+([.][0-9]+)?$ || "$d" =~ ^[.][0-9]+$ ]] || continue
        echo ">>> Removing time directory: $d"
        rm -rf "$d"
    done
}

has_constant_mesh() {
    [[ -d constant/polyMesh && -f constant/polyMesh/points && -f constant/polyMesh/boundary ]]
}

detect_np() {
    local np
    [[ -f system/decomposeParDict ]] || die "Missing system/decomposeParDict"
    np="$(dict_get numberOfSubdomains system/decomposeParDict || true)"
    [[ "$np" =~ ^[0-9]+$ ]] && (( np >= 1 )) || die "Invalid numberOfSubdomains in system/decomposeParDict"
    echo "$np"
}

load_case_settings() {
    [[ -f system/controlDict ]] || die "Missing system/controlDict"
    [[ -f constant/turbulenceProperties ]] || die "Missing constant/turbulenceProperties"

    SOLVER="$(dict_get application system/controlDict || true)"
    SIM_TYPE="$(dict_get simulationType constant/turbulenceProperties || true)"
    [[ -n "$SOLVER" ]] || die "Could not detect 'application' in system/controlDict"
    [[ "$SIM_TYPE" == "RAS" || "$SIM_TYPE" == "LES" ]] || die "Invalid or missing simulationType in constant/turbulenceProperties"

    RAS_MODEL=""
    if [[ "$SIM_TYPE" == "RAS" ]]; then
        RAS_MODEL="$(dict_get RAS.RASModel constant/turbulenceProperties || true)"
        [[ -n "$RAS_MODEL" ]] || die "simulationType=RAS but RAS.RASModel is missing in constant/turbulenceProperties"
    fi

    echo ">>> Detected solver         : $SOLVER"
    echo ">>> Detected simulationType : $SIM_TYPE"
    [[ "$SIM_TYPE" != "RAS" ]] || echo ">>> Detected RAS model      : $RAS_MODEL"
}

validate_case_settings() {
    case "$SIM_TYPE:$SOLVER" in
        LES:simpleFoam|LES:buoyantSimpleFoam|LES:porousSimpleFoam|LES:buoyantBoussinesqSimpleFoam)
            die "Detected LES in turbulenceProperties, but solver '$SOLVER' appears to be steady-state. Use a transient solver for LES."
            ;;
    esac

    local required=(0/U 0/p)
    case "$SIM_TYPE" in
        RAS)
            required+=(0/k 0/nut)
            case "$RAS_MODEL" in
                kOmega|kOmegaSST) required+=(0/omega) ;;
                kEpsilon|realizableKE) required+=(0/epsilon) ;;
                *) die "Unsupported RAS model '$RAS_MODEL' in constant/turbulenceProperties." ;;
            esac
            ;;
        LES) required+=(0/nut) ;;
    esac

    local f
    echo ">>> Solver/turbulence check passed: simulationType=$SIM_TYPE, solver=$SOLVER"
    [[ "$SIM_TYPE" != "RAS" ]] || echo ">>> RAS model: $RAS_MODEL"
    echo ">>> Checking required field files..."
    for f in "${required[@]}"; do
        [[ -f "$f" ]] || die "Missing required field '$f' for simulationType=$SIM_TYPE${RAS_MODEL:+, RASModel=$RAS_MODEL}"
    done
}

detect_run_mode() {
    if [[ "$FORCE_MESH" != "1" ]] && has_constant_mesh && { [[ -f "$RESTART_MARKER" ]] || has_nonzero_time_dir; }; then
        echo "continue"
    else
        echo "fresh"
    fi
}

prepare_fresh_mesh() {
    set_case_stage "housekeeping" "cleaning old processor and time directories before meshing"
    echo ">>> Fresh-mode housekeeping..."
    if has_nonzero_time_dir; then
        echo ">>> Removing old nonzero time directories for a clean fresh run..."
        remove_nonzero_time_dirs
    fi
    rm -rf processor*
    rm -f "$RESTART_MARKER"
}

mesh_current_case() {
    local mode case_np

    set_case_stage "validate" "checking controlDict, turbulenceProperties, and initial fields"
    load_case_settings
    validate_case_settings

    mode="$(detect_run_mode)"
    echo ">>> Run mode detected: $mode"

    if [[ "$mode" == "continue" ]]; then
        echo ">>> Continue mode: skip meshing. Set FORCE_MESH=1 to force a full mesh rebuild."
        CASE_STATUS="continued"
        CASE_MESSAGE="existing mesh detected; skipped"
        set_case_stage "$CASE_STATUS" "$CASE_MESSAGE"
        return 0
    fi

    echo ">>> Fresh mode: rebuild mesh."
    prepare_fresh_mesh

    need_cmd surfaceFeatureExtract
    need_cmd blockMesh
    need_cmd decomposePar
    need_cmd mpirun
    need_cmd snappyHexMesh
    need_cmd reconstructParMesh
    need_cmd checkMesh

    case_np="$(detect_np)"
    echo ">>> Using MPI subdomains    : $case_np"

    run_step "surfaceFeatureExtract" "extracting surface features" "" surfaceFeatureExtract
    run_step "blockMesh" "building background mesh" "" blockMesh
    run_step "decomposePar" "decomposing mesh for parallel snappyHexMesh" "log.decomposePar.mesh" decomposePar -force
    run_step "snappyHexMesh" "parallel meshing is running, np=${case_np}" "log.snappyHexMesh" mpirun -np "$case_np" snappyHexMesh -parallel -overwrite
    run_step "reconstructParMesh" "reconstructing parallel mesh" "log.reconstructParMesh" reconstructParMesh -constant
    run_step "checkMesh" "checking mesh and generating wallDistance" "log.checkMesh" checkMesh -allGeometry -allTopology -writeAllFields -time 0

    set_case_stage "cleanup" "removing processor directories and writing restart marker"
    rm -rf processor*
    touch "$RESTART_MARKER"

    CASE_STATUS="meshed"
    CASE_MESSAGE="OK"
    set_case_stage "$CASE_STATUS" "$CASE_MESSAGE"
    echo ">>> Mesh stage completed successfully."
}

mesh_one_case() {
    local csv_abs="$1" row_no="$2" case_id="$3" case_name="$4" case_dir="$5"
    local log_file="$LOG_DIR/$(safe_path_token "$case_name").log"

    CURRENT_CASE_NAME="$case_name"
    CURRENT_CASE_LOG="$log_file"
    CASE_STATUS=""
    CASE_MESSAGE=""

    # The case body runs in an explicit subshell. A die (exit) inside the body
    # then terminates only the body and returns non-zero to this guard, so the
    # failure handler below always records the failed case (v4 Section 23.P).
    # A brace group here would let die exit the whole background job and skip
    # the handler.
    (
        set_case_stage "starting" "mesh job started"
        echo ">>> Start case: $case_name"
        echo ">>> Case dir  : $case_dir"
        echo ">>> CSV row   : $csv_abs:$row_no"
        echo ">>> Log file  : $log_file"

        [[ -d "$case_dir" ]] || die "Case directory not found: $case_dir"
        cd "$case_dir"
        mesh_current_case
        append_summary "$csv_abs" "$row_no" "$case_id" "$case_name" "$case_dir" "$CASE_STATUS" "$CASE_MESSAGE"
    ) > "$log_file" 2>&1 || {
        local summary_status=0 fail_record_status=0
        set_case_stage "failed" "mesh job failed; see log: $log_file"
        append_summary "$csv_abs" "$row_no" "$case_id" "$case_name" "$case_dir" "failed" "see log: $log_file" ||
            summary_status=$?
        mark_failed "$case_name" || fail_record_status=$?
        info "MESH FAILED: $case_name | log: $log_file"
        clear_case_stage
        # Neither attempt can stop this handler. The Case process result stays
        # non-zero, and the parent accounting keeps the Stage non-zero.
        : "$summary_status" "$fail_record_status"
        return 1
    }

    # The body subshell cannot export CASE_STATUS. The body's final
    # set_case_stage wrote the status into the case state file; read it back
    # for the console line before the state file is cleared.
    CASE_STATUS="$(
        awk -F= '$1 == "stage" { print substr($0, index($0, "=") + 1) }' \
            "$(state_file)" 2>/dev/null | tail -n 1
    )"
    info "MESH FINISHED: $case_name | status=${CASE_STATUS:-unknown} | log: $log_file"
    clear_case_stage
}

# =============================================================================
# 6. BATCH LOOP
# =============================================================================
case_name_from_id() {
    echo "$(make_case_id "$1")/flow"
}

dispatch_case_row() {
    local csv_abs="$1" row_no="$2" line="$3" raw_case case_id case_name case_dir
    raw_case="$(get_cell "$line" "$CASE_COL")"

    if [[ -z "$raw_case" ]]; then
        append_summary "$csv_abs" "$row_no" "" "" "" "skipped" "missing Case"
        return 0
    fi

    case_id="$(make_case_id "$raw_case")"
    case_name="${case_id}/flow"
    case_dir="$OUT_ABS/$case_name"

    if [[ -n "${SEEN_CASES[$case_name]+x}" ]]; then
        append_summary "$csv_abs" "$row_no" "$case_id" "$case_name" "$case_dir" "skipped" "duplicate case id"
        return 0
    fi
    SEEN_CASES["$case_name"]=1

    if [[ ! -d "$case_dir" ]]; then
        append_summary "$csv_abs" "$row_no" "$case_id" "$case_name" "$case_dir" "skipped" "case directory not found"
        return 0
    fi

    wait_for_slot
    STARTED_CASES=$((STARTED_CASES + 1))
    info "MESH RUNNING [$STARTED_CASES/$TOTAL_CASES]: $case_name | log: $LOG_DIR/$(safe_path_token "$case_name").log"

    # Important:
    # Redirect stdin from /dev/null so background OpenFOAM commands cannot
    # consume the CSV stream used by the parent while-read loop.
    local job_ordinal="$STARTED_CASES"
    (
        job_status=0
        mesh_one_case "$csv_abs" "$row_no" "$case_id" "$case_name" "$case_dir" < /dev/null ||
            job_status=$?
        printf '%s\n' "$job_status" > "${JOB_STATUS_DIR}/${job_ordinal}" || exit 91
        exit "$job_status"
    ) &

    show_progress
}

process_csv() {
    local csv_file="$1" csv_abs row_no=1 line
    csv_abs="$(cd "$(dirname "$csv_file")" && pwd -P)/$(basename "$csv_file")"
    load_csv_header "$csv_abs"

    info "Processing CSV: $csv_abs"
    info "Case column   : $CASE_COL"
    info "Parallel jobs : $PARALLEL_JOBS"

    while IFS= read -r line || [[ -n "$line" ]]; do
        row_no=$((row_no + 1))
        line="${line//$'\r'/}"
        [[ -z "${line//[[:space:]]/}" ]] || dispatch_case_row "$csv_abs" "$row_no" "$line"
    done < <(tail -n +2 "$csv_abs")
}

TOTAL_CASES=0
STARTED_CASES=0

count_total_cases() {
    local csv csv_abs line case_id case_name
    declare -A seen=()
    TOTAL_CASES=0

    while IFS= read -r csv; do
        csv_abs="$(cd "$(dirname "$csv")" && pwd -P)/$(basename "$csv")"
        load_csv_header "$csv_abs"

        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line//$'\r'/}"
            [[ -z "${line//[[:space:]]/}" ]] && continue

            case_id="$(get_cell "$line" "$CASE_COL")"
            [[ -z "$case_id" ]] && continue

            case_name="$(case_name_from_id "$case_id")"
            [[ -n "${seen[$case_name]+x}" ]] && continue
            seen["$case_name"]=1
            TOTAL_CASES=$((TOTAL_CASES + 1))
        done < <(tail -n +2 "$csv_abs")
    done < <(find_csv_files)
}

main() {
    validate_config
    count_total_cases
    job_status_init

    info "Output folder   : $OUT_ABS"
    info "Summary CSV     : $SUMMARY_CSV"
    info "Logs            : $LOG_DIR"
    info "State files     : $STATE_DIR"
    info "FORCE_MESH      : $FORCE_MESH"
    info "Progress every  : ${PROGRESS_INTERVAL}s"
    info "CASE_PREFIX     : $CASE_PREFIX"
    info "BATCH_DIR       : ${BATCH_DIR:-N/A}"
    info "BATCH_CSV       : ${BATCH_CSV:-N/A}"
    info "BATCH_CSV_PATH  : ${BATCH_CSV_PATH:-N/A}"
    info "Total cases     : $TOTAL_CASES"

    local csv
    while IFS= read -r csv; do
        process_csv "$csv"
    done < <(find_csv_files)

    wait_all_cases
    show_progress 1

    local job_failures
    job_failures="$(job_status_failures)"
    if [[ -s "$FAIL_FILE" ]] || (( job_failures > 0 )); then
        die "One or more mesh jobs failed. See $SUMMARY_CSV and $LOG_DIR"
    fi

    rm -f "$FAIL_FILE"
    info "All mesh jobs finished."
    info "Summary: $SUMMARY_CSV"
    info "Logs   : $LOG_DIR"
}

main "$@"
