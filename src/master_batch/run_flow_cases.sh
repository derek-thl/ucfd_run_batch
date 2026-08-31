#!/usr/bin/env bash
# run_flow_cases.sh v4
#
# Batch flow runner for OpenFOAM cases meshed by run_mesh_cases.sh.
#
# Behavior
# --------
# - Read all output_batch_*.csv DOE files by default
# - Resolve the Case column using the same CSV/header logic as setup_cases.sh
# - Map each Case ID to case folder: ${CASE_PREFIX}_${sanitize(Case)}
# - Run flow solver in parallel using PARALLEL_JOBS
# - For each case:
#     * detect solver from system/controlDict
#     * validate mesh exists
#     * detect fresh / continue mode
#     * in fresh mode:
#         decomposePar -force -> renumberMesh(parallel) ->
#         SOLVER(parallel) -> reconstructPar ->
#         checkMesh -writeAllFields -latestTime
#     * in continue mode: resume from latest time
#
# Notes
# -----
# - FORCE_FLOW=1 forces a fresh flow run (removes nonzero time dirs).
# - CLEAN_PROCESSORS=1 removes processor* at the end (default: 1).
# - RECONSTRUCT_MODE=latest|all|none controls reconstructPar (default: latest).
# - MPI process count is read from system/decomposeParDict:numberOfSubdomains.

set -euo pipefail
trap 'echo ">>> [ERROR] run_flow_cases.sh failed at line $LINENO: $BASH_COMMAND" >&2' ERR
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
CASE_PREFIX="flow"
CSV_FILE=""

FORCE_FLOW="${FORCE_FLOW:-0}"
CLEAN_PROCESSORS="${CLEAN_PROCESSORS:-1}"
RECONSTRUCT_MODE="${RECONSTRUCT_MODE:-latest}"
FLOW_MARKER="flow.marker"

# =============================================================================
# 1. SMALL UTILITIES
# =============================================================================

usage() {
    cat <<'USAGE'
Usage:
  bash run_flow_cases.sh [options]

Typical:
  bash run_flow_cases.sh
  bash run_flow_cases.sh -i output_batch_1.csv -O ./ -j 2

Options:
  -i <csv>            Process one DOE CSV. If omitted, process all output_batch_*.csv.
  -O, --output-dir    Output root folder containing case directories.
  -j <jobs>           Number of parallel flow jobs.
  --case-prefix <t>   Case directory prefix. Default: case
  -h, --help

Environment:
  FORCE_FLOW=1            Force a fresh flow run in every case.
  CLEAN_PROCESSORS=0      Keep processor* folders after reconstructPar.
  RECONSTRUCT_MODE=latest|all|none
USAGE
}

die()  { echo ">>> [ERROR] $*" >&2; exit 1; }
warn() { echo ">>> [warn] $*" >&2; }
info() { echo ">>> $*"; }

trim() {
    local s="$1"
    s="${s//$'\r'/}"
    echo "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

sanitize_token() {
    local s="$1"
    s="$(trim "$s")"
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

csv_quote() {
    local s="${1:-}"
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH."
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

_LAST_PROGRESS_TIME=0

show_progress() {
    local running completed skipped failed now

    now=$(date +%s)
    (( now - _LAST_PROGRESS_TIME < 1 )) && return 0
    _LAST_PROGRESS_TIME=$now

    running="$(jobs -rp | wc -l | tr -d ' ')"
    completed=0
    skipped=0
    failed=0

    if [[ -f "$SUMMARY_CSV" ]]; then
        read -r completed skipped < <(
            awk -F, 'NR>1 {
                gsub(/"/, "", $6);
                if ($6=="solved" || $6=="continued" || $6=="failed") completed++;
                else if ($6=="skipped") skipped++;
            } END { print completed+0, skipped+0 }' "$SUMMARY_CSV"
        )
    fi

    if [[ -f "$FAIL_FILE" ]]; then
        failed="$(wc -l < "$FAIL_FILE" | tr -d ' ')"
    fi

    info "Progress: launched=${STARTED_CASES}/${TOTAL_CASES}, completed=${completed}, running=${running}/${PARALLEL_JOBS}, skipped=${skipped}, failed=${failed}"
}

wait_for_free_slot() {
    local max_jobs="$1"
    local running
    while true; do
        running=$(jobs -rp | wc -l | tr -d ' ')
        (( running < max_jobs )) && break
        show_progress
        if (( BASH_VERSINFO[0] > 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3 ) )); then
            wait -n || true
        else
            sleep 0.5
        fi
        sleep 0.1
    done
}

append_summary() {
    local csv_file="$1" row_no="$2" case_id="$3" case_name="$4" case_dir="$5" status="$6" msg="${7}"
    local lock="${SUMMARY_CSV}.lockdir"

    batch_stage_lock_acquire "$lock" 0.05

    {
        csv_quote "$csv_file"; printf ','
        csv_quote "$row_no"; printf ','
        csv_quote "$case_id"; printf ','
        csv_quote "$case_name"; printf ','
        csv_quote "$case_dir"; printf ','
        csv_quote "$status"; printf ','
        csv_quote "$msg"; printf '\n'
    } >> "$SUMMARY_CSV"

    batch_stage_lock_release "$lock"
}

# =============================================================================
# 2. ARGUMENTS AND GLOBAL VALIDATION
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i) CSV_FILE="${2:-}"; shift 2 ;;
        -O|--output-dir) OUT_DIR="${2:-}"; shift 2 ;;
        -j) PARALLEL_JOBS="${2:-}"; shift 2 ;;
        --case-prefix) CASE_PREFIX="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1. Use -h for help." ;;
    esac
done

validate_global_config() {
    [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] && (( PARALLEL_JOBS >= 1 )) || die "PARALLEL_JOBS must be integer >= 1."
    [[ -d "$OUT_DIR" ]] || die "Output folder not found: $OUT_DIR"

    [[ "$RECONSTRUCT_MODE" == "latest" || "$RECONSTRUCT_MODE" == "all" || "$RECONSTRUCT_MODE" == "none" ]] \
        || die "RECONSTRUCT_MODE must be latest|all|none."

    need_cmd awk
    need_cmd sed
    need_cmd tee
    need_cmd foamDictionary

    OUT_ABS="$(cd "$OUT_DIR" && pwd -P)"
    SUMMARY_CSV="$OUT_ABS/run_flow_cases_summary.csv"
    LOG_DIR="$OUT_ABS/_flow_logs"
    FAIL_FILE="$OUT_ABS/.run_flow_cases_failed"

    mkdir -p "$LOG_DIR"
    : > "$FAIL_FILE"
    printf 'csv_file,row_number,case_id,case_name,case_dir,status,message\n' > "$SUMMARY_CSV"
}

# =============================================================================
# 3. CSV HELPERS
# =============================================================================

declare -A COL=()
declare -A SEEN_CASES=()
headers=()
header_line=""
CASE_COL=""

find_col() {
    local alias
    for alias in "$@"; do
        alias="$(lower "$alias")"
        if [[ -n "${COL[$alias]+x}" ]]; then
            echo "${COL[$alias]}"
            return 0
        fi
    done
    return 1
}

load_csv_header() {
    local csv_abs="$1"
    header_line="$(head -n 1 "$csv_abs")"
    header_line="${header_line//$'\r'/}"
    IFS=',' read -r -a headers <<< "$header_line"

    COL=()
    local i h h_lc
    for i in "${!headers[@]}"; do
        h="$(trim "${headers[$i]}")"
        h_lc="$(lower "$h")"
        COL["$h_lc"]="$i"
    done

    CASE_COL="$(find_col Case case)" || die "Required column not found in $csv_abs: Case"
}

get_cell_from_row() {
    local row_line="$1"
    local idx="$2"
    local -a cells
    IFS=',' read -r -a cells <<< "$row_line"
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

# =============================================================================
# 4. CASE-LOCAL FLOW LOGIC
# =============================================================================

run_cmd() {
    echo ">>> [$PWD] $*"
    "$@"
}

run_tee() {
    local logfile="$1"; shift
    echo ">>> [$PWD] $* (tee -> ${logfile})"
    # run_tee wraps required flow commands only; optional diagnostics use
    # run_cmd with an explicit || true. The case body executes in an
    # errexit-ignored context (Bash disables set -e on the left of ||), so a
    # failed required command must stop the case explicitly (v4 Sections 16.6
    # and 23.P). die exits the case subshell; the failure handler in
    # solve_one_case then records the failed case. pipefail keeps the
    # command's own status through the tee pipeline.
    "$@" 2>&1 | tee "$logfile" ||
        die "Required flow command failed: $1 (see log: $logfile)"
}

dict_get() {
    local entry="$1"
    local file="$2"
    local v=""
    [[ -f "$file" ]] || return 1
    v="$(foamDictionary -entry "$entry" -value "$file" 2>/dev/null || true)"
    v="$(echo "$v" | tr -d '\r' | tr -d '";' | awk '{$1=$1; print}')"
    [[ -n "$v" ]] && echo "$v"
}

has_nonzero_time_dir() {
    shopt -s nullglob
    local d
    for d in [0-9]* .[0-9]*; do
        [[ -d "$d" ]] || continue
        [[ "$d" == "0" ]] && continue
        [[ "$d" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ "$d" =~ ^[.][0-9]+$ ]] || continue
        return 0
    done
    return 1
}

remove_nonzero_time_dirs() {
    shopt -s nullglob
    local d
    for d in [0-9]* .[0-9]*; do
        [[ -d "$d" ]] || continue
        [[ "$d" == "0" ]] && continue
        [[ "$d" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ "$d" =~ ^[.][0-9]+$ ]] || continue
        echo ">>> Removing time directory: $d"
        rm -rf "$d"
    done
}

has_constant_mesh() {
    [[ -d constant/polyMesh ]] &&
    [[ -f constant/polyMesh/points ]] &&
    [[ -f constant/polyMesh/boundary ]]
}

detect_np() {
    local np
    [[ -f system/decomposeParDict ]] || die "Missing system/decomposeParDict"
    np="$(dict_get numberOfSubdomains system/decomposeParDict || true)"
    [[ "$np" =~ ^[0-9]+$ ]] && (( np >= 1 )) || die "Invalid numberOfSubdomains in system/decomposeParDict"
    echo "$np"
}

do_reconstruct() {
    case "$RECONSTRUCT_MODE" in
        latest) run_tee log.reconstructPar reconstructPar -latestTime ;;
        all)    run_tee log.reconstructPar reconstructPar ;;
        none)   echo ">>> Skipping reconstructPar (RECONSTRUCT_MODE=none)." ;;
    esac
}

generate_wall_distance() {
    # v4 mesh stage already requests -writeAllFields -time 0. Keep this fallback
    # for compatibility with older/external meshes that do not contain wallDistance.
    if [[ -f 0/wallDistance ]]; then
        echo ">>> wallDistance already exists from mesh stage; skip extra checkMesh."
        return 0
    fi
    echo ">>> wallDistance missing; generating it with checkMesh fallback..."
    run_tee log.checkMesh.wallDistance checkMesh -writeAllFields -time 0
    [[ -f 0/wallDistance ]] || die "checkMesh completed but 0/wallDistance was not created."
    echo ">>> wallDistance field generation completed."
}

solve_current_case() {
    local case_np

    [[ -f system/controlDict ]] || die "Missing system/controlDict"

    has_constant_mesh || die "No mesh found in constant/polyMesh. Run run_mesh_cases.sh first."

    local SOLVER
    SOLVER="$(dict_get application system/controlDict || true)"
    [[ -n "$SOLVER" ]] || die "Could not detect 'application' in system/controlDict"
    echo ">>> Detected solver: $SOLVER"

    case_np="$(detect_np)"
    echo ">>> Using MPI subdomains: $case_np"

    need_cmd "$SOLVER"
    need_cmd decomposePar
    need_cmd mpirun
    need_cmd renumberMesh
    # reconstructPar is required only when the selected reconstruction mode
    # can execute it. RECONSTRUCT_MODE=none never calls reconstructPar, so the
    # documented none mode must not depend on the disabled command. This
    # matches the transport runner's conditional check.
    [[ "$RECONSTRUCT_MODE" == "none" ]] || need_cmd reconstructPar
    need_cmd checkMesh

    # Detect fresh vs continue
    local MODE="fresh"
    if [[ "$FORCE_FLOW" == "1" ]]; then
        MODE="fresh"
    else
        if [[ -f "$FLOW_MARKER" ]] || has_nonzero_time_dir; then
            MODE="continue"
        fi
    fi

    echo ">>> Run mode detected: ${MODE}"

    if [[ "$MODE" == "continue" ]]; then
        echo ">>> Continue mode: resuming from latest time."
        echo ">>> Tip: set FORCE_FLOW=1 to force a fresh flow run."
        CASE_STATUS="continued"
        CASE_MESSAGE="resumed from existing time directory"

        run_tee log.decomposePar decomposePar -force
        run_tee log.renumberMesh mpirun -np "$case_np" renumberMesh -parallel -overwrite
        echo ">>> Running $SOLVER (continue)..."
        run_tee "log.${SOLVER}" mpirun -np "$case_np" "$SOLVER" -parallel

        do_reconstruct
        generate_wall_distance

        if [[ "$CLEAN_PROCESSORS" == "1" ]]; then
            rm -rf processor*
        else
            echo ">>> Keeping processor* folders (CLEAN_PROCESSORS=0)."
        fi

        touch "$FLOW_MARKER"
        touch case.foam

        has_cmd foamLog  && run_cmd foamLog  "log.${SOLVER}" || true
        has_cmd gnuplot  && [[ -f residuals_from_foamLog.gp ]] \
            && run_cmd gnuplot residuals_from_foamLog.gp || true

        CASE_STATUS="continued"
        CASE_MESSAGE="OK (resumed)"
        return 0
    fi

    # Fresh mode
    echo ">>> Fresh mode: clean and run."
    if has_nonzero_time_dir; then
        echo ">>> Removing old nonzero time directories..."
        remove_nonzero_time_dirs
    fi
    rm -rf processor*
    rm -f "$FLOW_MARKER"

    run_tee log.decomposePar decomposePar -force
    run_tee log.renumberMesh mpirun -np "$case_np" renumberMesh -parallel -overwrite

    echo ">>> Running $SOLVER..."
    run_tee "log.${SOLVER}" mpirun -np "$case_np" "$SOLVER" -parallel

    do_reconstruct
    generate_wall_distance

    if [[ "$CLEAN_PROCESSORS" == "1" ]]; then
        rm -rf processor*
    else
        echo ">>> Keeping processor* folders (CLEAN_PROCESSORS=0)."
    fi

    touch "$FLOW_MARKER"
    touch case.foam

    has_cmd foamLog && run_cmd foamLog "log.${SOLVER}" || true
    has_cmd gnuplot && [[ -f residuals_from_foamLog.gp ]] \
        && run_cmd gnuplot residuals_from_foamLog.gp || true

    echo ">>> Flow stage completed successfully."
    CASE_STATUS="solved"
    CASE_MESSAGE="OK"
}

solve_one_case() {
    local csv_abs="$1" row_no="$2" case_id="$3" case_name="$4" case_dir="$5"
    local log_file="$LOG_DIR/$(safe_path_token "$case_name").log"

    # The case body runs in an explicit subshell. A die (exit) inside the body
    # then terminates only the body and returns non-zero to this guard, so the
    # failure handler below always records the failed case (v4 Section 23.P).
    # A brace group here would let die exit the whole background job and skip
    # the handler.
    (
        echo ">>> Start case: $case_name"
        echo ">>> Case dir  : $case_dir"
        echo ">>> CSV row   : $csv_abs:$row_no"
        echo ">>> Log file  : $log_file"

        [[ -d "$case_dir" ]] || die "Case directory not found: $case_dir"

        CASE_STATUS=""
        CASE_MESSAGE=""

        cd "$case_dir"
        solve_current_case

        append_summary "$csv_abs" "$row_no" "$case_id" "$case_name" "$case_dir" "$CASE_STATUS" "$CASE_MESSAGE"
    ) > "$log_file" 2>&1 || {
        append_summary "$csv_abs" "$row_no" "$case_id" "$case_name" "$case_dir" "failed" "see log: $log_file"

        local lock="${SUMMARY_CSV}.lockdir"
        batch_stage_lock_acquire "$lock" 0.05
        echo "$case_name" >> "$FAIL_FILE"
        batch_stage_lock_release "$lock"

        info "Case failed: $case_name"
        return 1
    }
}

# =============================================================================
# 5. BATCH LOOP
# =============================================================================

dispatch_case_row() {
    local csv_abs="$1" row_no="$2" line="$3"

    local raw_case case_id case_name case_dir
    raw_case="$(get_cell_from_row "$line" "$CASE_COL")"

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

    wait_for_free_slot "$PARALLEL_JOBS"

    STARTED_CASES=$((STARTED_CASES + 1))
    info "Launching [$STARTED_CASES/$TOTAL_CASES]: $case_name"

    # Important:
    # Prevent OpenFOAM/MPI commands in the background from consuming
    # the parent while-read CSV stream.
    solve_one_case "$csv_abs" "$row_no" "$case_id" "$case_name" "$case_dir" < /dev/null &

    show_progress
}

process_csv() {
    local csv_file="$1"
    local csv_abs
    csv_abs="$(cd "$(dirname "$csv_file")" && pwd -P)/$(basename "$csv_file")"

    load_csv_header "$csv_abs"

    info "Processing CSV: $csv_abs"
    info "Case column   : $CASE_COL"
    info "Parallel jobs : $PARALLEL_JOBS"

    local row_no=1
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        row_no=$((row_no + 1))
        line="${line//$'\r'/}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        dispatch_case_row "$csv_abs" "$row_no" "$line"
    done < <(tail -n +2 "$csv_abs")
}

TOTAL_CASES=0
STARTED_CASES=0

count_total_cases() {
    local csv csv_abs line case_id case_token case_name
    declare -A seen=()
    TOTAL_CASES=0

    while IFS= read -r csv; do
        csv_abs="$(cd "$(dirname "$csv")" && pwd -P)/$(basename "$csv")"
        load_csv_header "$csv_abs"

        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line//$'\r'/}"
            [[ -z "${line//[[:space:]]/}" ]] && continue

            case_id="$(get_cell_from_row "$line" "$CASE_COL")"
            [[ -z "$case_id" ]] && continue

            case_token="$(make_case_id "$case_id")"
            case_name="${case_token}/flow"

            [[ -n "${seen[$case_name]+x}" ]] && continue
            seen["$case_name"]=1
            TOTAL_CASES=$((TOTAL_CASES + 1))
        done < <(tail -n +2 "$csv_abs")
    done < <(find_csv_files)
}

# =============================================================================
# 6. MAIN
# =============================================================================

main() {
    validate_global_config
    count_total_cases

    info "Output folder      : $OUT_ABS"
    info "Summary CSV        : $SUMMARY_CSV"
    info "Logs               : $LOG_DIR"
    info "FORCE_FLOW         : $FORCE_FLOW"
    info "CLEAN_PROCESSORS   : $CLEAN_PROCESSORS"
    info "RECONSTRUCT_MODE   : $RECONSTRUCT_MODE"
    info "Total cases        : $TOTAL_CASES"

    local csv
    while IFS= read -r csv; do
        process_csv "$csv"
    done < <(find_csv_files)

    # drain: wait for all background jobs to finish
    local running
    while true; do
        running=$(jobs -rp | wc -l | tr -d ' ')
        (( running == 0 )) && break
        _LAST_PROGRESS_TIME=0
        show_progress
        if (( BASH_VERSINFO[0] > 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3 ) )); then
            wait -n || true
        else
            sleep 0.5
        fi
    done

    _LAST_PROGRESS_TIME=0
    show_progress

    if [[ -s "$FAIL_FILE" ]]; then
        die "One or more flow jobs failed. See $SUMMARY_CSV and $LOG_DIR"
    fi

    rm -f "$FAIL_FILE"

    info "All flow jobs finished."
    info "Summary: $SUMMARY_CSV"
    info "Logs   : $LOG_DIR"
}

main "$@"