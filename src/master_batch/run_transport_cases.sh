#!/usr/bin/env bash
# run_transport_cases.sh v4 - batch scalar-transport runner for OpenFOAM.

set -euo pipefail
trap 'echo ">>> [ERROR] run_transport_cases.sh failed at line $LINENO: $BASH_COMMAND" >&2' ERR
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

# ---- User config -------------------------------------------------------------
PARALLEL_JOBS=2
OUT_DIR="./"
CSV_FILE=""

FLOW_CASE_PREFIX="flow"
TRANSPORT_CASE_PREFIX="trd"
BASE_TRANSPORT_DIR="scalarTransportDeffFoam_files"

FORCE_TRANSPORT="${FORCE_TRANSPORT:-0}"
CLEAN_PROCESSORS="${CLEAN_PROCESSORS:-1}"
RECONSTRUCT_MODE="${RECONSTRUCT_MODE:-latest}"  # latest | all | custom | none

# Comma- or space-separated exact time values.
# When specified, RECONSTRUCT_MODE is automatically changed to custom.
# IMPORTANT: Each transport case's system/controlDict endTime must be greater
# than or equal to the maximum value specified in TRANSPORT_SAVE_TIMES.
TRANSPORT_SAVE_TIMES="${TRANSPORT_SAVE_TIMES:-}"

PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-5}"

SOLVER="scalarTransportDeffFoam"
SCALAR_FIELD="${SCALAR_FIELD:-T}"
TRANSPORT_MARKER="transport.marker"

usage() {
    cat <<'USAGE'
Usage:
  bash run_transport_cases.sh [options]

Typical:
  bash run_transport_cases.sh
  bash run_transport_cases.sh -i output_batch_1.csv -O ./ -j 2

Options:
  -i <csv>                    Process one DOE CSV. Omit to process all output_batch_*.csv.
  -O, --output-dir            Root folder containing case directories.
  -j <jobs>                   Number of parallel transport jobs.
  --save-times <list>         Reconstruct selected times, e.g. "0,100,200,500".
  --flow-prefix <p>           Kept for compatibility.
  --transport-prefix <p>      Kept for compatibility.
  --base-transport-dir <d>    Kept for compatibility. Missing transport cases will NOT be created.
  -h, --help

Environment:
  FORCE_TRANSPORT=1
  CLEAN_PROCESSORS=0
  RECONSTRUCT_MODE=latest     latest | all | custom | none
  TRANSPORT_SAVE_TIMES=""     Selected times, e.g. "0,100,200,500".
                              controlDict endTime must be >= the maximum value.
  PROGRESS_INTERVAL=5
  SCALAR_FIELD=T             Scalar field name used by the transport case.
USAGE
}

# ---- Small utilities ---------------------------------------------------------
info() { echo ">>> $*"; }
die()  { echo ">>> [ERROR] $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH."; }
has_cmd()  { command -v "$1" >/dev/null 2>&1; }
lower()    { echo "$1" | tr '[:upper:]' '[:lower:]'; }
trim()     { local s="${1//$'\r'/}"; echo "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

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

declare -a TRANSPORT_TIME_LIST=()

normalize_transport_save_times() {
    local raw="$1"
    local value
    local -A seen=()

    TRANSPORT_TIME_LIST=()

    # Support comma-, semicolon-, or whitespace-separated values.
    raw="${raw//,/ }"
    raw="${raw//;/ }"

    for value in $raw; do
        value="$(trim "$value")"
        [[ -n "$value" ]] || continue

        if ! is_time_dir "$value"; then
            die "Invalid transport save time: '$value'. Expected values such as 0, 100, 0.5."
        fi

        if [[ -z "${seen[$value]+x}" ]]; then
            seen["$value"]=1
            TRANSPORT_TIME_LIST+=("$value")
        fi
    done

    ((${#TRANSPORT_TIME_LIST[@]} > 0)) ||
        die "TRANSPORT_SAVE_TIMES did not contain any valid time values."
}

transport_save_times_display() {
    local IFS=","
    echo "${TRANSPORT_TIME_LIST[*]}"
}

transport_max_save_time() {
    printf '%s\n' "${TRANSPORT_TIME_LIST[@]}" |
        awk '
            NR == 1 { maximum = $1 + 0 }
            ($1 + 0) > maximum { maximum = $1 + 0 }
            END { print maximum }
        '
}

# Safety check for the final simulation time:
# When TRANSPORT_SAVE_TIMES is specified, controlDict.endTime must cover the
# largest requested save time; otherwise the solver cannot produce that time.
validate_transport_end_time() {
    local control_dict="system/controlDict"
    local end_time max_save_time
    local number_pattern='^[+]?[0-9]+([.][0-9]*)?([eE][-+]?[0-9]+)?$|^[+]?[.][0-9]+([eE][-+]?[0-9]+)?$'

    [[ -n "$(trim "$TRANSPORT_SAVE_TIMES")" ]] || return 0
    ((${#TRANSPORT_TIME_LIST[@]} > 0)) ||
        die "TRANSPORT_SAVE_TIMES is set, but no normalized save times are available."

    end_time="$(dict_get endTime "$control_dict" || true)"
    [[ -n "$end_time" ]] ||
        die "Missing endTime in $control_dict."

    [[ "$end_time" =~ $number_pattern ]] ||
        die "Invalid endTime='$end_time' in $control_dict. Expected a numeric value."

    max_save_time="$(transport_max_save_time)"

    if ! awk \
        -v end_time="$end_time" \
        -v max_save_time="$max_save_time" \
        'BEGIN { exit !((end_time + 0) >= (max_save_time + 0)) }'
    then
        die "$control_dict endTime=$end_time is smaller than the maximum requested TRANSPORT_SAVE_TIMES value $max_save_time."
    fi

    echo ">>> endTime check   : $end_time >= $max_save_time"
}

append_summary() {
    local csv_file="$1" row_no="$2" case_id="$3" case_name="$4" case_dir="$5" status="$6" msg="$7"
    local lock="${SUMMARY_CSV}.lockdir"
    local f_csv_file f_row_no f_case_id f_case_name f_case_dir f_status f_msg

    batch_stage_lock_acquire "$lock" 0.05
    batch_stage_csv_quote f_csv_file "$csv_file"
    batch_stage_csv_quote f_row_no "$row_no"
    batch_stage_csv_quote f_case_id "$case_id"
    batch_stage_csv_quote f_case_name "$case_name"
    batch_stage_csv_quote f_case_dir "$case_dir"
    batch_stage_csv_quote f_status "$status"
    batch_stage_csv_quote f_msg "$msg"

    local append_status=0 release_status=0

    batch_stage_csv_append_row "$SUMMARY_CSV" \
        "$f_csv_file" "$f_row_no" "$f_case_id" "$f_case_name" "$f_case_dir" \
        "$f_status" "$f_msg" || append_status=$?

    batch_stage_lock_release "$lock" || release_status=$?

    # The Issue #47 status matrix. The append status has precedence, and
    # exactly one release attempt runs. A successful append must not hide a
    # non-zero release status.
    (( append_status == 0 )) || return "$append_status"
    return "$release_status"
}

# mark_failed returns the failure-artifact append status. The lock release
# must not replace a failed append with success, because a failure-artifact
# write error must not produce stage success.
mark_failed() {
    local case_name="$1" lock="${SUMMARY_CSV}.lockdir" rc=0
    batch_stage_lock_acquire "$lock" 0.05
    echo "$case_name" >> "$FAIL_FILE" || rc=$?
    batch_stage_lock_release "$lock"
    return "$rc"
}

# ---- Arguments / config ------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i)
            [[ $# -ge 2 ]] || die "-i requires a CSV file."
            CSV_FILE="$2"
            shift 2
            ;;
        -O|--output-dir)
            [[ $# -ge 2 ]] || die "$1 requires a directory."
            OUT_DIR="$2"
            shift 2
            ;;
        -j)
            [[ $# -ge 2 ]] || die "-j requires a job count."
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        --save-times)
            [[ $# -ge 2 ]] || die "--save-times requires a time list."
            TRANSPORT_SAVE_TIMES="$2"
            shift 2
            ;;
        --flow-prefix)
            FLOW_CASE_PREFIX="${2:-}"
            shift 2
            ;;
        --transport-prefix)
            TRANSPORT_CASE_PREFIX="${2:-}"
            shift 2
            ;;
        --base-transport-dir)
            BASE_TRANSPORT_DIR="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1. Use -h for help."
            ;;
    esac
done

validate_config() {
    [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] &&
        ((PARALLEL_JOBS >= 1)) ||
        die "PARALLEL_JOBS must be integer >= 1."

    [[ "$PROGRESS_INTERVAL" =~ ^[0-9]+$ ]] ||
        die "PROGRESS_INTERVAL must be an integer."

    if [[ -n "$(trim "$TRANSPORT_SAVE_TIMES")" ]]; then
        RECONSTRUCT_MODE="custom"
        normalize_transport_save_times "$TRANSPORT_SAVE_TIMES"
    fi

    [[ "$RECONSTRUCT_MODE" =~ ^(latest|all|custom|none)$ ]] ||
        die "RECONSTRUCT_MODE must be latest|all|custom|none."

    if [[ "$RECONSTRUCT_MODE" == "custom" ]] &&
       ((${#TRANSPORT_TIME_LIST[@]} == 0)); then
        die "RECONSTRUCT_MODE=custom requires TRANSPORT_SAVE_TIMES."
    fi

    if [[ "$RECONSTRUCT_MODE" == "none" &&
          "$CLEAN_PROCESSORS" == "1" ]]; then
        die "RECONSTRUCT_MODE=none cannot be used with CLEAN_PROCESSORS=1 because calculated times would be deleted."
    fi

    [[ -d "$OUT_DIR" ]] ||
        die "Output folder not found: $OUT_DIR"

    for cmd in awk sed tee foamDictionary; do
        need_cmd "$cmd"
    done

    OUT_ABS="$(cd "$OUT_DIR" && pwd -P)"

    if [[ -n "$BASE_TRANSPORT_DIR" &&
          -d "$BASE_TRANSPORT_DIR" ]]; then
        BASE_TRANSPORT_ABS="$(
            cd "$BASE_TRANSPORT_DIR" &&
                pwd -P
        )"
    else
        BASE_TRANSPORT_ABS=""
    fi

    SUMMARY_CSV="$OUT_ABS/run_transport_cases_summary.csv"
    LOG_DIR="$OUT_ABS/_transport_logs"
    STATE_DIR="$OUT_ABS/_transport_state"
    FAIL_FILE="$OUT_ABS/.run_transport_cases_failed"

    mkdir -p "$LOG_DIR" "$STATE_DIR"
    rm -f "$STATE_DIR"/*.state 2>/dev/null || true
    : >"$FAIL_FILE"

    printf '%s\n' \
        'csv_file,row_number,case_id,flow_case_transport_case,transport_case_dir,status,message' \
        >"$SUMMARY_CSV"
}

# ---- CSV helpers -------------------------------------------------------------
declare -A COL=()
declare -A SEEN_CASES=()
CASE_COL=""

find_col() {
    local alias
    for alias in "$@"; do
        alias="$(lower "$alias")"
        [[ -n "${COL[$alias]+x}" ]] && { echo "${COL[$alias]}"; return 0; }
    done
    return 1
}

load_csv_header() {
    local csv_abs="$1" i h
    local -a header
    IFS=',' read -r -a header < "$csv_abs"
    COL=()
    for i in "${!header[@]}"; do
        h="$(lower "$(trim "${header[$i]}")")"
        COL["$h"]="$i"
    done
    CASE_COL="$(find_col Case case)" || die "Required column not found in $csv_abs: Case"
}

get_cell() {
    local line="$1" idx="$2"
    local -a cells
    IFS=',' read -r -a cells <<< "$line"
    trim "${cells[$idx]:-}"
}

find_csv_files() {
    if [[ -n "$CSV_FILE" ]]; then
        [[ -f "$CSV_FILE" ]] || die "CSV file not found: $CSV_FILE"
        echo "$CSV_FILE"
        return 0
    fi

    shopt -s nullglob
    local files=(output_batch_*.csv)
    shopt -u nullglob
    (( ${#files[@]} > 0 )) || die "No output_batch_*.csv found."
    printf '%s\n' "${files[@]}" | sort -V
}

# ---- OpenFOAM helpers --------------------------------------------------------
run_tee() {
    local logfile="$1"; shift
    echo ">>> [$PWD] $* (tee -> $logfile)"
    "$@" 2>&1 | tee "$logfile"
}

run_cmd() {
    echo ">>> [$PWD] $*"
    "$@"
}

dict_get() {
    local entry="$1" file="$2" v=""
    [[ -f "$file" ]] || return 1
    v="$(foamDictionary -entry "$entry" -value "$file" 2>/dev/null || true)"
    v="$(echo "$v" | tr -d '\r' | tr -d '";' | awk '{$1=$1; print}')"
    [[ -n "$v" ]] && echo "$v"
}

is_time_dir() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ || "$1" =~ ^[.][0-9]+$ ]]; }

has_nonzero_time_dir() {
    local d
    shopt -s nullglob
    for d in [0-9]* .[0-9]*; do
        [[ -d "$d" && "$d" != "0" ]] && is_time_dir "$d" && return 0
    done
    return 1
}

remove_nonzero_time_dirs() {
    local d
    shopt -s nullglob
    for d in [0-9]* .[0-9]*; do
        [[ -d "$d" && "$d" != "0" ]] && is_time_dir "$d" || continue
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

find_latest_time() {
    local case_dir="$1" latest=""
    if has_cmd foamListTimes; then
        latest="$(cd "$case_dir" && foamListTimes -latestTime 2>/dev/null | awk 'NF{last=$NF} END{print last}' || true)"
        [[ -n "$latest" && -d "$case_dir/$latest" ]] && { echo "$latest"; return 0; }
    fi
    latest="$(find "$case_dir" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' \
        | awk '/^[0-9]+([.][0-9]+)?$|^[.][0-9]+$/{print}' | sort -g | tail -n 1)"
    [[ -n "$latest" ]] || die "No numeric time directories found in $case_dir"
    echo "$latest"
}

fix_location_header() {
    local file="$1" loc="$2"
    [[ -f "$file" ]] || return 0
    sed -i -E \
        "s#(location[[:space:]]+\")[^\"]*(\"[[:space:]]*;)#\1${loc}\2#g" \
        "$file" || true
}

# ---- Progress / job control --------------------------------------------------
_LAST_PROGRESS_TIME=0
CURRENT_STATE_FILE=""
CURRENT_CASE_NAME=""
CURRENT_LOG_FILE=""

stage() {
    local name="$1" msg="${2:-}"
    [[ -n "$CURRENT_STATE_FILE" ]] || return 0
    printf '%s|%s|%s|%s|%s\n' "$CURRENT_CASE_NAME" "$name" "$msg" "$(date '+%Y-%m-%d %H:%M:%S')" "$CURRENT_LOG_FILE" > "$CURRENT_STATE_FILE"
}

count_status() {
    local pattern="$1"
    awk -F, -v pat="$pattern" 'NR > 1 {gsub(/"/, "", $6); if ($6 ~ pat) c++} END{print c + 0}' "$SUMMARY_CSV"
}

show_progress() {
    local now running solved continued skipped failed pending state f case_name st msg updated log_file
    now="$(date +%s)"
    (( now - _LAST_PROGRESS_TIME < PROGRESS_INTERVAL )) && return 0
    _LAST_PROGRESS_TIME="$now"

    running="$(jobs -rp | wc -l | tr -d ' ')"
    read -r solved continued skipped < <(
        awk -F, 'NR>1 {
            gsub(/"/, "", $6);
            if ($6=="solved") solved++;
            else if ($6=="continued") continued++;
            else if ($6=="skipped") skipped++;
        } END { print solved+0, continued+0, skipped+0 }' "$SUMMARY_CSV"
    )
    # The progress line counts Failure Artifact lines only when the Failure
    # Artifact is a regular file. A character device supplies an endless stream,
    # so an unconditional read prevents Stage completion. The sibling Stage
    # Runners already use this rule.
    failed=0
    if [[ -f "$FAIL_FILE" ]]; then
        failed="$(wc -l < "$FAIL_FILE" | tr -d ' ')"
    fi
    pending=$(( TOTAL_CASES - STARTED_CASES ))
    (( pending >= 0 )) || pending=0

    info "Transport progress: total=$TOTAL_CASES, launched=$STARTED_CASES, running=${running}/${PARALLEL_JOBS}, pending=$pending, solved=$solved, continued=$continued, skipped=$skipped, failed=$failed"

    shopt -s nullglob
    for f in "$STATE_DIR"/*.state; do
        IFS='|' read -r case_name st msg updated log_file < "$f" || true
        [[ -n "${case_name:-}" ]] || continue
        info "  RUNNING: $case_name | stage=$st | $msg | updated=$updated | log=$log_file"
    done
    shopt -u nullglob
}

# Failure-recording error counters. A non-zero child exit must not be hidden
# when the failure artifact could not be written.
FAIL_RECORD_ERRORS=0
JOB_FAILURES=0

# ---- private Case completion accounting (Issue #47) -------------------------
# JOB_FAILURES keeps its current purpose. The private records supplement it, so
# a Case process that finishes before a slot wait or the final drain cannot
# escape the accounting. The accounting directory lives outside the Batch
# Workspace and never becomes a public artifact.
JOB_STATUS_DIR=""

job_status_cleanup() {
    [[ -n "${JOB_STATUS_DIR:-}" ]] || return 0
    [[ -d "$JOB_STATUS_DIR" ]] || return 0
    rm -rf -- "$JOB_STATUS_DIR"
    return 0
}

job_status_init() {
    JOB_STATUS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run_transport_cases_status.XXXXXX")"
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

wait_for_free_slot() {
    while (( $(jobs -rp | wc -l | tr -d ' ') >= PARALLEL_JOBS )); do
        show_progress
        if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
            wait -n || JOB_FAILURES=$(( JOB_FAILURES + 1 ))
        else
            sleep 0.5
        fi
    done
}

wait_for_all_jobs() {
    while (( $(jobs -rp | wc -l | tr -d ' ') > 0 )); do
        _LAST_PROGRESS_TIME=0
        show_progress
        if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
            wait -n || JOB_FAILURES=$(( JOB_FAILURES + 1 ))
        else
            sleep 0.5
        fi
    done
}

# ---- Case logic --------------------------------------------------------------
transport_has_restart_state() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    [[ -f "$dir/$TRANSPORT_MARKER" ]] && return 0
    (cd "$dir" && has_nonzero_time_dir)
}

prepare_transport_case() {
    local flow_dir="$1" transport_dir="$2"
    local latest_time flow_time_dir

    [[ -d "$transport_dir" ]] || die "Transport case directory not found: $transport_dir. Missing transport cases will not be created automatically."
    echo ">>> Using existing transport case: $transport_dir"

    cd "$transport_dir"

    stage "copy-mesh" "copying flow mesh"
    [[ -d "$flow_dir/constant/polyMesh" ]] || die "Flow mesh not found: $flow_dir/constant/polyMesh"
    mkdir -p constant
    rm -rf constant/polyMesh
    cp -a --reflink=auto "$flow_dir/constant/polyMesh" constant/polyMesh
    has_constant_mesh || die "Mesh copy verification failed."

    latest_time="$(find_latest_time "$flow_dir")"
    flow_time_dir="$flow_dir/$latest_time"

    stage "copy-fields" "copying U and synchronizing optional nut/phi from flow time $latest_time"
    [[ -f "$flow_time_dir/U" ]] || die "Missing U: $flow_time_dir/U"
    [[ -f "0/$SCALAR_FIELD" ]] ||
        die "Missing scalar field in existing transport case: $transport_dir/0/$SCALAR_FIELD"

    mkdir -p 0
    cp -a --reflink=auto "$flow_time_dir/U" 0/U
    fix_location_header 0/U "0"

    # nut and phi are solver-dependent. Copy them when the converged flow case
    # wrote them. If not, remove any stale transport copy and let the solver's
    # READ_IF_PRESENT / reconstruction / fallback logic decide what to do.
    local field
    for field in nut phi; do
        if [[ -f "$flow_time_dir/$field" ]]; then
            cp -a --reflink=auto "$flow_time_dir/$field" "0/$field"
            fix_location_header "0/$field" "0"
            echo ">>> Copied optional flow field: $field (time $latest_time -> 0/$field)"
        else
            if [[ -f "0/$field" ]]; then
                echo ">>> Removing stale 0/$field because flow time $latest_time does not contain $field."
                rm -f "0/$field"
            fi
            echo ">>> Optional flow field not available: $flow_time_dir/$field; solver-side fallback will be used."
        fi
    done

    echo ">>> Prepared transport case using flow latest time: $latest_time"
}

find_equivalent_time_dir() {
    local parent="$1" requested="$2"

    [[ -d "$parent" ]] || return 1

    find "$parent" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' |
        awk -v requested="$requested" '
            /^[0-9]+([.][0-9]+)?$|^[.][0-9]+$/ {
                difference = ($0 + 0) - (requested + 0)
                if (difference < 0) {
                    difference = -difference
                }

                tolerance = 1e-10 * (1 + (requested < 0 ? -requested : requested))
                if (difference <= tolerance) {
                    print
                    exit
                }
            }
        '
}

list_processor_times() {
    if [[ ! -d processor0 ]]; then
        echo "none (processor0 does not exist)"
        return
    fi

    find processor0 -maxdepth 1 -mindepth 1 -type d -printf '%f\n' |
        awk '/^[0-9]+([.][0-9]+)?$|^[.][0-9]+$/' |
        sort -g |
        paste -sd, -
}

reconstruct_selected_transport_times() {
    local requested_time processor_time reconstructed_time time_token

    for requested_time in "${TRANSPORT_TIME_LIST[@]}"; do
        if [[ "$requested_time" == "0" ]]; then
            echo ">>> Initial time 0 already exists; no reconstruction needed."
            continue
        fi

        reconstructed_time="$(
            find_equivalent_time_dir "." "$requested_time" || true
        )"

        if [[ -n "$reconstructed_time" ]]; then
            echo ">>> Requested time $requested_time is already reconstructed as $reconstructed_time."
            continue
        fi

        processor_time="$(
            find_equivalent_time_dir processor0 "$requested_time" || true
        )"

        if [[ -z "$processor_time" ]]; then
            die "Requested time $requested_time was not written by the solver. Available processor0 times: $(list_processor_times). --save-times selects outputs for reconstruction; controlDict writeControl/writeInterval must also produce every requested time."
        fi

        time_token="$(safe_path_token "$processor_time")"

        stage \
            "reconstructPar" \
            "reconstructing requested time $requested_time from $processor_time"

        run_tee \
            "log.reconstructPar.${time_token}" \
            reconstructPar -time "$processor_time"

        reconstructed_time="$(
            find_equivalent_time_dir "." "$requested_time" || true
        )"

        [[ -n "$reconstructed_time" ]] ||
            die "reconstructPar completed, but requested time $requested_time was not reconstructed."
    done
}

solve_transport_case() {
    local mode="${1:-fresh}"
    local app np
    [[ "$mode" == "fresh" || "$mode" == "continue" ]] || die "Invalid transport run mode: $mode"
    [[ -f system/controlDict ]] || die "Missing system/controlDict"
    app="$(dict_get application system/controlDict || true)"
    [[ "$app" == "$SOLVER" ]] || die "system/controlDict application='$app', expected '$SOLVER'."

    validate_transport_end_time

    for cmd in decomposePar mpirun renumberMesh "$SOLVER"; do need_cmd "$cmd"; done
    [[ "$RECONSTRUCT_MODE" == "none" ]] || need_cmd reconstructPar

    np="$(detect_np)" || die "Failed to detect numberOfSubdomains"
    [[ -n "$np" ]] || die "numberOfSubdomains is empty"

    echo ">>> Solver         : $SOLVER"
    echo ">>> MPI subdomains : $np"
    echo ">>> Run mode       : $mode"

    if [[ "$mode" == "fresh" ]]; then
        stage "cleanup" "removing old time and processor directories"
        remove_nonzero_time_dirs
        rm -rf processor*
        rm -f "$TRANSPORT_MARKER"
    else
        # A continuation must keep the exact mesh/state that produced its existing
        # nonzero fields. Replacing polyMesh here can invalidate those fields.
        has_constant_mesh || die "Continue mode requires an existing transport mesh in constant/polyMesh."
        echo ">>> Continue mode: reuse existing transport mesh and initial fields."
    fi

    stage "decomposePar" "decomposing transport case"
    run_tee log.decomposePar decomposePar -force

    stage "renumberMesh" "renumbering mesh in parallel, np=$np"
    run_tee log.renumberMesh mpirun -np "$np" renumberMesh -parallel -overwrite

    stage "$SOLVER" "transport solver is running, np=$np"
    run_tee "log.${SOLVER}" mpirun -np "$np" "$SOLVER" -parallel

    case "$RECONSTRUCT_MODE" in
        latest)
            stage "reconstructPar" "reconstructing latest time"
            run_tee log.reconstructPar reconstructPar -latestTime
            ;;

        all)
            stage "reconstructPar" "reconstructing all times"
            run_tee log.reconstructPar reconstructPar
            ;;

        custom)
            stage \
                "reconstructPar" \
                "selected times: $(transport_save_times_display)"

            reconstruct_selected_transport_times
            ;;

        none)
            echo ">>> Skipping reconstructPar (RECONSTRUCT_MODE=none)."
            ;;
    esac

    stage "finalize" "cleaning processors and writing marker"

    if [[ "$CLEAN_PROCESSORS" == "1" ]]; then
        rm -rf processor*
    else
        echo ">>> Keeping processor* folders."
    fi

    touch "$TRANSPORT_MARKER" case.foam

    CASE_STATUS="solved"
    CASE_MESSAGE="OK"
    [[ "$mode" == "continue" ]] && { CASE_STATUS="continued"; CASE_MESSAGE="OK (resumed)"; }
}

run_one_case() {
    local csv_abs="$1" row_no="$2" case_id="$3" flow_name="$4" flow_dir="$5" transport_name="$6" transport_dir="$7"
    local log_file="$LOG_DIR/$(safe_path_token "$transport_name").log"
    local state_file="$STATE_DIR/$(safe_path_token "$transport_name").state"

    if (
        CURRENT_CASE_NAME="$transport_name"
        CURRENT_STATE_FILE="$state_file"
        CURRENT_LOG_FILE="$log_file"
        trap 'rm -f "$CURRENT_STATE_FILE"' EXIT

        {
            echo ">>> Start transport case : $transport_name"
            echo ">>> Flow case dir        : $flow_dir"
            echo ">>> Transport case dir   : $transport_dir"
            echo ">>> CSV row              : $csv_abs:$row_no"
            echo ">>> Log file             : $log_file"
            [[ -d "$flow_dir" ]] || die "Flow case directory not found: $flow_dir"
            [[ -d "$transport_dir" ]] || die "Transport case directory not found: $transport_dir. Missing transport cases will not be created automatically."

            local transport_mode="fresh"
            if [[ "$FORCE_TRANSPORT" != "1" ]] && transport_has_restart_state "$transport_dir"; then
                transport_mode="continue"
            fi

            if [[ "$transport_mode" == "fresh" ]]; then
                stage "prepare" "preparing fresh transport case from flow=$flow_name"
                prepare_transport_case "$flow_dir" "$transport_dir"
            else
                stage "prepare" "reusing existing transport mesh/state for continuation"
                echo ">>> Continue mode detected before preparation; skip flow mesh/field recopy."
                cd "$transport_dir"
            fi

            solve_transport_case "$transport_mode"
            stage "done" "transport completed"

            append_summary "$csv_abs" "$row_no" "$case_id" "${flow_name}|${transport_name}" "$transport_dir" "$CASE_STATUS" "$CASE_MESSAGE"
        } > "$log_file" 2>&1
    ); then
        return 0
    else
        local summary_status=0 fail_record_status=0
        append_summary "$csv_abs" "$row_no" "$case_id" "${flow_name}|${transport_name}" "$transport_dir" "failed" "see log: $log_file" ||
            summary_status=$?
        mark_failed "$transport_name" || fail_record_status=$?
        info "TRANSPORT FAILED: $transport_name | log=$log_file"
        # Neither attempt can stop this handler. The Case process result stays
        # non-zero, and the parent accounting keeps the Stage non-zero.
        : "$summary_status" "$fail_record_status"
        return 1
    fi
}

# ---- Batch loop --------------------------------------------------------------
TOTAL_CASES=0
STARTED_CASES=0

dispatch_row() {
    local csv_abs="$1" row_no="$2" line="$3"
    local case_id case_root flow_name flow_dir transport_name transport_dir

    case_id="$(get_cell "$line" "$CASE_COL")"
    if [[ -z "$case_id" ]]; then
        append_summary "$csv_abs" "$row_no" "" "" "" "skipped" "missing Case"
        return 0
    fi

    case_root="$(make_case_id "$case_id")"
    flow_name="${case_root}/flow"
    transport_name="${case_root}/trd"
    flow_dir="$OUT_ABS/$flow_name"
    transport_dir="$OUT_ABS/$transport_name"

    if [[ -n "${SEEN_CASES[$transport_name]+x}" ]]; then
        append_summary "$csv_abs" "$row_no" "$case_root" "${flow_name}|${transport_name}" "$transport_dir" "skipped" "duplicate case id"
        return 0
    fi
    SEEN_CASES["$transport_name"]=1

    if [[ ! -d "$flow_dir" ]]; then
        # v4 Sections 17.4 and 23.P: a requested transport case without its
        # required flow case is a failed case, not a skipped case. The failure
        # artifact makes the stage exit non-zero. A failed artifact append is
        # counted so that a write error cannot produce stage success.
        append_summary "$csv_abs" "$row_no" "$case_root" "${flow_name}|${transport_name}" "$transport_dir" "failed" "flow case directory not found: $flow_dir"
        mark_failed "$transport_name" ||
            FAIL_RECORD_ERRORS=$(( FAIL_RECORD_ERRORS + 1 ))
        info "TRANSPORT FAILED: $transport_name | missing required flow case: $flow_dir"
        return 0
    fi

    if [[ ! -d "$transport_dir" ]]; then
        append_summary "$csv_abs" "$row_no" "$case_root" "${flow_name}|${transport_name}" "$transport_dir" "failed" "transport case directory not found: $transport_dir"
        mark_failed "$transport_name"
        info "TRANSPORT FAILED: $transport_name | missing existing transport case: $transport_dir"
        return 0
    fi

    wait_for_free_slot
    STARTED_CASES=$((STARTED_CASES + 1))
    info "TRANSPORT RUNNING [$STARTED_CASES/$TOTAL_CASES]: $transport_name | flow=$flow_name | log=$LOG_DIR/$(safe_path_token "$transport_name").log"
    local job_ordinal="$STARTED_CASES"
    (
        job_status=0
        run_one_case "$csv_abs" "$row_no" "$case_root" "$flow_name" "$flow_dir" "$transport_name" "$transport_dir" < /dev/null ||
            job_status=$?
        printf '%s\n' "$job_status" > "${JOB_STATUS_DIR}/${job_ordinal}" || exit 91
        exit "$job_status"
    ) &
    show_progress
}

process_csv() {
    local csv_file="$1" csv_abs line row_no=1
    csv_abs="$(cd "$(dirname "$csv_file")" && pwd -P)/$(basename "$csv_file")"
    load_csv_header "$csv_abs"
    info "Processing CSV: $csv_abs"

    while IFS= read -r line || [[ -n "$line" ]]; do
        row_no=$((row_no + 1))
        line="${line//$'\r'/}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        dispatch_row "$csv_abs" "$row_no" "$line"
    done < <(tail -n +2 "$csv_abs")
}

count_total_cases() {
    local csv csv_abs line case_id case_root transport_name
    declare -A seen=()
    TOTAL_CASES=0

    while IFS= read -r csv; do
        csv_abs="$(cd "$(dirname "$csv")" && pwd -P)/$(basename "$csv")"
        load_csv_header "$csv_abs"
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line//$'\r'/}"
            [[ -z "${line//[[:space:]]/}" ]] && continue
            case_id="$(get_cell "$line" "$CASE_COL")"
            [[ -n "$case_id" ]] || continue
            case_root="$(make_case_id "$case_id")"
            transport_name="${case_root}/trd"
            [[ -n "${seen[$transport_name]+x}" ]] && continue
            seen["$transport_name"]=1
            TOTAL_CASES=$((TOTAL_CASES + 1))
        done < <(tail -n +2 "$csv_abs")
    done < <(find_csv_files)
}

main() {
    validate_config
    count_total_cases
    job_status_init

    info "Output folder         : $OUT_ABS"
    [[ -n "$BASE_TRANSPORT_ABS" ]] && info "Base transport dir    : $BASE_TRANSPORT_ABS"
    info "Transport case policy : existing cases only"
    info "Scalar field          : $SCALAR_FIELD"
    info "Summary CSV           : $SUMMARY_CSV"
    info "Logs                  : $LOG_DIR"
    info "Flow case prefix      : $FLOW_CASE_PREFIX"
    info "Transport case prefix : $TRANSPORT_CASE_PREFIX"
    info "FORCE_TRANSPORT       : $FORCE_TRANSPORT"
    info "CLEAN_PROCESSORS      : $CLEAN_PROCESSORS"
    info "RECONSTRUCT_MODE      : $RECONSTRUCT_MODE"

    if [[ "$RECONSTRUCT_MODE" == "custom" ]]; then
        info "TRANSPORT_SAVE_TIMES : $(transport_save_times_display)"
    fi

    info "PROGRESS_INTERVAL     : $PROGRESS_INTERVAL"
    info "Total cases           : $TOTAL_CASES"

    local csv
    while IFS= read -r csv; do process_csv "$csv"; done < <(find_csv_files)

    wait_for_all_jobs
    _LAST_PROGRESS_TIME=0
    show_progress

    # The final gate must not trust the failure artifact alone. A failed
    # summary row, a discarded non-zero child exit, or a failure-artifact
    # write error must also make the stage non-zero.
    local failed_rows job_failures
    failed_rows="$(count_status '^failed$')"
    job_failures="$(job_status_failures)"
    if [[ -s "$FAIL_FILE" ]] || (( failed_rows > 0 )) ||
       (( JOB_FAILURES > 0 )) || (( FAIL_RECORD_ERRORS > 0 )) ||
       (( job_failures > 0 )); then
        die "One or more transport jobs failed. See $SUMMARY_CSV and $LOG_DIR"
    fi
    rm -f "$FAIL_FILE"
    info "All transport jobs finished."
    info "Summary: $SUMMARY_CSV"
    info "Logs   : $LOG_DIR"
}

main "$@"
