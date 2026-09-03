#!/usr/bin/env bash
# setup_cases.sh v4
#
# Integrated UCFD case setup script. (Derek Lai, 2026-06-19)
#
# Purpose
# -------
# 1) Read all output_batch_*.csv DOE files by default.
# 2) For each DOE row, create one OpenFOAM case folder from BASE_DIR.
# 3) Apply the key setup_case operations inside this single script:
#    - copy base case
#    - rotate STL by WD
#    - update blockMeshDict / snappyHexMeshDict
#    - set RAS/LES turbulence mode
#    - update 0/U inlet and plant boundary velocities
#    - update decomposeParDict / run_flow.sh
#    - write doe_row.csv and setup metadata
# 4) Run case setup in parallel using PARALLEL_JOBS configured below.
#
# CSV requirements
# ----------------
# Required columns:
#   Case, WS, WD
#
# Accepted aliases:
#   Case: Case, case
#   WS  : WS, ws, wind_speed, U_ref, u_ref, met__WS_mps
#   WD  : WD, wd, wind_direction, ref_wind_dir, relative_wind_direction, met__WD_deg
#
# Notes
# -----
# - This script intentionally assumes simple CSV without quoted commas.
# - Edit the USER CONFIG section first for normal use.
# - Use --dry-run to verify case names and paths without OpenFOAM commands.

set -euo pipefail
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
# Main batch setup
PARALLEL_JOBS=16
OUT_DIR="./"
FLOW_BASE_DIR="simpleFoam_files"
TRANSPORT_BASE_DIR="scalarTransportDeffFoam_files"
SCALAR_FIELD="${SCALAR_FIELD:-T}"

SETUP_FLOW_CASES="true"
SETUP_TRANSPORT_CASES="true"

# Flow setup defaults
SIM_TYPE="RAS"              # RAS | LES
RAS_MODEL="kEpsilon"       # kOmega | kOmegaSST | kEpsilon | realizableKE
NP="8"
SNAP_CTRL="off"             # on | off
ADDLAYERS_CTRL="off"         # on | off
SFGS="1.0"                  # far-field grid scale: dx_far = SFGS * H
YPLUS="false"               # true | false
EXTENTS_H="10,20,5,8"       # inlet,outlet,side,top in units of H

# Project geometry constants
H="40"
RDR="300"
BASE_STL_NAME="f18p2_all.stl"

# Velocity anchors used by the legacy setup_flow_case logic
U_OAI_BASE="5"

# WS <= 0 behavior because setup_flow_case-style U_ref must be positive
ZERO_WS_MODE="keep"         # skip | epsilon | keep | error
MIN_WS="0.001"

# Optional single CSV. Leave empty to process all output_batch_*.csv.
CSV_FILE=""

# Dry run
DRY_RUN="false"

# =============================================================================
# 1. SMALL UTILITIES
# =============================================================================

usage() {
    cat <<'USAGE'
Usage:
  bash setup_cases.sh [options]

Typical:
  bash setup_cases.sh -i output_batch_1.csv -j 8

Options:
  -i <csv>       Process one DOE CSV. If omitted, process all output_batch_*.csv.
  -j <jobs>      Number of cases processed in parallel. Default: 16.
  -b <dir>       Base case folder. Default is set in USER CONFIG.
  -O <dir>       Output root folder. Default is set in USER CONFIG.
  -T <RAS|LES>   Simulation type.
  -t <model>     RAS model when -T RAS.
  -n <np>        Number of MPI subdomains per OpenFOAM case.
  -s <on|off>    snappyHexMesh snap switch.
  -a <on|off>    snappyHexMesh addLayers switch.
  -k <scale>     Far-field grid scale coefficient.
  -y <bool>      yPlus monitor true|false.
  -e <list>      Domain extents in H: "inlet,outlet,side,top".
  --zero-ws-mode <skip|epsilon|keep|error>
  --min-ws <value>
  --dry-run
  -h, --help

Notes:
  -j controls how many cases are set up concurrently.
  -n controls the MPI subdomain count inside each OpenFOAM case.
USAGE
}

die()  { echo "Error: $*" >&2; exit 1; }
warn() { echo ">>> [warn] $*" >&2; }
info() { echo ">>> $*"; }

is_float() { awk -v x="$1" 'BEGIN{exit !(x+0==x)}' </dev/null 2>/dev/null; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH."
}

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

numeric_tag() {
    local value="$1"
    local scale="$2"
    local width="$3"
    awk -v x="$value" -v scale="$scale" -v width="$width" '
        BEGIN{
            v = int(x * scale + (x >= 0 ? 0.5 : -0.5));
            if (v < 0) v = -v;
            printf "%0*d", width, v;
        }' </dev/null
}

normalize_wd() {
    awk -v wd="$1" '
        function floor2(x){ return (x>=0)?int(x):int(x)-(x==int(x)?0:1) }
        BEGIN{
            a = wd - 360*floor2(wd/360);
            if (a < 0)    a += 360;
            if (a >= 360) a -= 360;
            printf "%.3f", a;
        }' </dev/null
}

rot_angle_from_wd() {
    awk -v wd="$1" '
        BEGIN{
            a = wd + 25;
            q = int(a/360);
            a -= 360*q;
            if (a < 0) a += 360;
            printf "%.3f", a;
        }' </dev/null
}

append_summary() {
    local csv_file="$1" row_no="$2" case_id="$3" case_name="$4" wd="$5" ws="$6" ws_for_setup="$7" case_dir="$8" status="$9" msg="${10}"
    local lock="${SUMMARY_CSV}.lockdir"

    local f_csv_file f_row_no f_case_id f_case_name f_wd
    local f_ws f_ws_for_setup f_case_dir f_status f_msg

    batch_stage_lock_acquire "$lock" 0.05

    batch_stage_csv_quote f_csv_file "$csv_file"
    batch_stage_csv_quote f_row_no "$row_no"
    batch_stage_csv_quote f_case_id "$case_id"
    batch_stage_csv_quote f_case_name "$case_name"
    batch_stage_csv_quote f_wd "$wd"
    batch_stage_csv_quote f_ws "$ws"
    batch_stage_csv_quote f_ws_for_setup "$ws_for_setup"
    batch_stage_csv_quote f_case_dir "$case_dir"
    batch_stage_csv_quote f_status "$status"
    batch_stage_csv_quote f_msg "$msg"

    batch_stage_csv_append_row "$SUMMARY_CSV" \
        "$f_csv_file" "$f_row_no" "$f_case_id" "$f_case_name" "$f_wd" \
        "$f_ws" "$f_ws_for_setup" "$f_case_dir" "$f_status" "$f_msg"

    batch_stage_lock_release "$lock"
}


TOTAL_ROWS=0
STARTED_CASES=0
_LAST_PROGRESS_TIME=0

count_total_rows() {
    local csv csv_abs line
    TOTAL_ROWS=0

    while IFS= read -r csv; do
        csv_abs="$(cd "$(dirname "$csv")" && pwd -P)/$(basename "$csv")"

        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line//$'\r'/}"
            [[ -z "${line//[[:space:]]/}" ]] && continue
            TOTAL_ROWS=$((TOTAL_ROWS + 1))
        done < <(tail -n +2 "$csv_abs")
    done < <(find_csv_files)
}

show_progress() {
    local running processed created skipped failed dry_run now

    now=$(date +%s)
    # throttle: print at most once per second
    (( now - _LAST_PROGRESS_TIME < 1 )) && return 0
    _LAST_PROGRESS_TIME=$now

    running="$(jobs -rp | wc -l | tr -d ' ')"
    processed=0
    created=0
    skipped=0
    failed=0
    dry_run=0

    if [[ -f "$SUMMARY_CSV" ]]; then
        read -r processed created skipped failed dry_run < <(
            awk -F, 'NR>1 {
                gsub(/"/,"",$9); processed++;
                if ($9=="created") created++;
                else if ($9=="skipped") skipped++;
                else if ($9=="failed") failed++;
                else if ($9=="dry_run") dry++;
            } END { print processed+0, created+0, skipped+0, failed+0, dry+0 }' "$SUMMARY_CSV"
        )
    fi

    info "Progress: launched=${STARTED_CASES}/${TOTAL_ROWS}, processed=${processed}/${TOTAL_ROWS}, running=${running}/${PARALLEL_JOBS}, created=${created}, skipped=${skipped}, failed=${failed}, dry_run=${dry_run}"
}

# The caller owns the wait-status meaning. Setup counts each non-zero wait once.
setup_slot_wait_status() {
    (( $1 == 0 )) || FAILED_ROW_JOBS=$(( FAILED_ROW_JOBS + 1 ))
    return 0
}

wait_for_free_slot() {
    batch_stage_job_pool_wait_for_slot "$1" show_progress setup_slot_wait_status 0
}

# =============================================================================
# 2. ARGUMENTS AND GLOBAL VALIDATION
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i)
            [[ $# -ge 2 ]] || die "-i requires a CSV filename."
            CSV_FILE="$2"
            shift 2
            ;;
        -j)
            [[ $# -ge 2 ]] || die "-j requires a job count."
            PARALLEL_JOBS="$2"
            shift 2
            ;;
        -b)
            [[ $# -ge 2 ]] || die "-b requires a directory."
            FLOW_BASE_DIR="$2"
            shift 2
            ;;
        -O|--output-dir)
            [[ $# -ge 2 ]] || die "$1 requires a directory."
            OUT_DIR="$2"
            shift 2
            ;;
        -T)
            [[ $# -ge 2 ]] || die "-T requires RAS or LES."
            SIM_TYPE="$2"
            shift 2
            ;;
        -t)
            [[ $# -ge 2 ]] || die "-t requires a model."
            RAS_MODEL="$2"
            shift 2
            ;;
        -n)
            [[ $# -ge 2 ]] || die "-n requires an MPI subdomain count."
            NP="$2"
            shift 2
            ;;
        -s)
            [[ $# -ge 2 ]] || die "-s requires on or off."
            SNAP_CTRL="$2"
            shift 2
            ;;
        -a)
            [[ $# -ge 2 ]] || die "-a requires on or off."
            ADDLAYERS_CTRL="$2"
            shift 2
            ;;
        -k)
            [[ $# -ge 2 ]] || die "-k requires a scale."
            SFGS="$2"
            shift 2
            ;;
        -y)
            [[ $# -ge 2 ]] || die "-y requires true or false."
            YPLUS="$2"
            shift 2
            ;;
        -e)
            [[ $# -ge 2 ]] || die "-e requires an extent list."
            EXTENTS_H="$2"
            shift 2
            ;;
        --zero-ws-mode)
            [[ $# -ge 2 ]] || die "--zero-ws-mode requires a value."
            ZERO_WS_MODE="$2"
            shift 2
            ;;
        --min-ws)
            [[ $# -ge 2 ]] || die "--min-ws requires a value."
            MIN_WS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
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

validate_global_config() {
    [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] && (( PARALLEL_JOBS >= 1 )) || die "PARALLEL_JOBS must be integer >= 1."

    [[ "$SETUP_FLOW_CASES" == "true" || "$SETUP_TRANSPORT_CASES" == "true" ]] \
        || die "At least one of SETUP_FLOW_CASES or SETUP_TRANSPORT_CASES must be true."

    if [[ "$SETUP_FLOW_CASES" == "true" ]]; then
        [[ -d "$FLOW_BASE_DIR" ]] || die "Flow base folder not found: $FLOW_BASE_DIR"
    fi

    if [[ "$SETUP_TRANSPORT_CASES" == "true" ]]; then
        [[ -d "$TRANSPORT_BASE_DIR" ]] || die "Transport base folder not found: $TRANSPORT_BASE_DIR"
    fi

    [[ "$SIM_TYPE" == "RAS" || "$SIM_TYPE" == "LES" ]] || die "-T must be RAS or LES."
    if [[ "$SIM_TYPE" == "RAS" ]]; then
        case "$RAS_MODEL" in
            kOmega|kOmegaSST|kEpsilon|realizableKE) ;;
            *) die "RAS_MODEL must be kOmega | kOmegaSST | kEpsilon | realizableKE." ;;
        esac
    fi

    [[ "$NP" =~ ^[0-9]+$ ]] && (( NP >= 1 )) || die "-n must be integer >= 1."
    [[ "$SNAP_CTRL" == "on" || "$SNAP_CTRL" == "off" ]] || die "-s must be on|off."
    [[ "$ADDLAYERS_CTRL" == "on" || "$ADDLAYERS_CTRL" == "off" ]] || die "-a must be on|off."
    [[ "$YPLUS" == "true" || "$YPLUS" == "false" ]] || die "-y must be true|false."
    is_float "$SFGS" || die "-k must be numeric."
    awk -v x="$SFGS" 'BEGIN{exit !(x>0)}' </dev/null || die "-k must be > 0."

    case "$ZERO_WS_MODE" in skip|epsilon|keep|error) ;; *) die "--zero-ws-mode must be skip|epsilon|keep|error." ;; esac
    is_float "$MIN_WS" || die "--min-ws must be numeric."

    local ext_norm extra
    ext_norm="$(echo "$EXTENTS_H" | tr ';' ',' | tr ' ' ',' | tr -s ',')"
    IFS=',' read -r INLET_H OUTLET_H SIDE_H TOP_H extra <<< "$ext_norm"
    [[ -z "${extra:-}" && -n "${TOP_H:-}" ]] || die "-e must provide 4 values: inlet,outlet,side,top."
    for v in "$INLET_H" "$OUTLET_H" "$SIDE_H" "$TOP_H"; do
        is_float "$v" || die "Domain extents must be numeric."
        awk -v x="$v" 'BEGIN{exit !(x>0)}' </dev/null || die "Domain extents must be > 0."
    done

    if [[ "$DRY_RUN" != "true" ]]; then
        need_cmd awk
        need_cmd sed
        need_cmd surfaceCheck
        need_cmd surfaceTransformPoints
        need_cmd foamDictionary
    fi

    mkdir -p "$OUT_DIR"

    FLOW_BASE_ABS=""
    TRANSPORT_BASE_ABS=""

    if [[ "$SETUP_FLOW_CASES" == "true" ]]; then
        FLOW_BASE_ABS="$(cd "$FLOW_BASE_DIR" && pwd -P)"
        BASE_ABS="$FLOW_BASE_ABS"
    fi

    if [[ "$SETUP_TRANSPORT_CASES" == "true" ]]; then
        TRANSPORT_BASE_ABS="$(cd "$TRANSPORT_BASE_DIR" && pwd -P)"
    fi

    OUT_ABS="$(cd "$OUT_DIR" && pwd -P)"
    SUMMARY_CSV="$OUT_ABS/setup_cases_summary.csv"
    LOG_DIR="$OUT_ABS/_setup_logs"
    FAIL_FILE="$OUT_ABS/.setup_cases_failed"
    mkdir -p "$LOG_DIR"
    : > "$FAIL_FILE"

    printf 'csv_file,row_number,case_id,case_name,wd,ws,ws_for_setup,case_dir,status,message\n' > "$SUMMARY_CSV"
}

# =============================================================================
# 3. CSV HELPERS
# =============================================================================

declare -A COL=()
declare -A SEEN_CASES=()
headers=()
header_line=""
CASE_COL=""
WS_COL=""
WD_COL=""
STABILITY_COL=""

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
    WS_COL="$(find_col WS ws wind_speed U_ref u_ref met__WS_mps)" || die "Required column not found in $csv_abs: WS / wind_speed / U_ref / met__WS_mps"
    WD_COL="$(find_col WD wd wind_direction ref_wind_dir relative_wind_direction met__WD_deg)" || die "Required column not found in $csv_abs: WD / wind_direction / met__WD_deg"

    STABILITY_COL=""
    if tmp_col="$(find_col Stability stability atmospheric_stability met__stability 2>/dev/null)"; then
        STABILITY_COL="$tmp_col"
    fi
}

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

get_cell_from_row() {
    local row_line="$1"
    local idx="$2"
    local -a cells
    IFS=',' read -r -a cells <<< "$row_line"
    trim "${cells[$idx]:-}"
}

find_csv_files() {
    if [[ -n "$CSV_FILE" ]]; then
        if [[ -f "$CSV_FILE" ]]; then
            echo "$CSV_FILE"
            return 0
        fi

        if [[ -n "${BATCH_DIR:-}" && -f "${BATCH_DIR}/${CSV_FILE}" ]]; then
            echo "${BATCH_DIR}/${CSV_FILE}"
            return 0
        fi

        die "CSV file not found: $CSV_FILE"
    fi

    if [[ -n "${BATCH_CSV_PATH:-}" && -f "$BATCH_CSV_PATH" ]]; then
        echo "$BATCH_CSV_PATH"
        return 0
    fi

    if [[ -n "${BATCH_DIR:-}" && -n "${BATCH_CSV:-}" && -f "${BATCH_DIR}/${BATCH_CSV}" ]]; then
        echo "${BATCH_DIR}/${BATCH_CSV}"
        return 0
    fi

    shopt -s nullglob
    local files=(output_batch_*.csv)
    shopt -u nullglob

    (( ${#files[@]} > 0 )) || die "No output_batch_*.csv found."
    printf '%s\n' "${files[@]}" | sort -V
}

# =============================================================================
# 4. INTEGRATED FLOW CASE SETUP
# =============================================================================

foam_set() {
    local case_dir="$1" file="$2" entry="$3" value="$4"
    [[ -f "$file" ]] || { warn "missing file: $file"; return 0; }
    foamDictionary -case "$case_dir" -entry "$entry" -set "$value" "$file" >/dev/null 2>&1 \
        || warn "$(basename "$file"): entry '$entry' not found or not set."
}

foam_get() {
    local case_dir="$1" file="$2" entry="$3"
    [[ -f "$file" ]] || { echo "N/A"; return 0; }
    local v
    v="$(foamDictionary -case "$case_dir" -entry "$entry" -value "$file" 2>/dev/null || true)"
    v="$(echo "$v" | tr -d '\r' | tr -d '";' | awk '{$1=$1; print}')"
    [[ -n "$v" ]] && echo "$v" || echo "N/A"
}

sync_turbulence_files() {
    local case_dir="$1"
    local sim_type="$2"
    local ras_model="$3"

    local -a required=(U p)
    local -a known=(U p k nut omega epsilon)

    if [[ "$sim_type" == "RAS" ]]; then
        required+=(k nut)
        case "$ras_model" in
            kOmega|kOmegaSST) required+=(omega) ;;
            kEpsilon|realizableKE) required+=(epsilon) ;;
        esac
    else
        required+=(nut)
    fi

    local f keep
    for f in "${required[@]}"; do
        [[ -f "$case_dir/0/$f" ]] || die "base case missing required field: 0/$f"
    done

    for f in "${known[@]}"; do
        keep="false"
        local r
        for r in "${required[@]}"; do
            [[ "$f" == "$r" ]] && keep="true"
        done
        if [[ "$keep" == "false" && -f "$case_dir/0/$f" ]]; then
            rm -f "$case_dir/0/$f"
        fi
    done
}

configure_turbulence() {
    local case_dir="$1"
    local tp="$case_dir/constant/turbulenceProperties"

    [[ -f "$tp" ]] || die "missing constant/turbulenceProperties"

    if [[ "$SIM_TYPE" == "RAS" ]]; then
        foam_set "$case_dir" "$tp" "simulationType" "RAS"
        foam_set "$case_dir" "$tp" "RAS.RASModel" "$RAS_MODEL"
        foam_set "$case_dir" "$tp" "RAS.turbulence" "on"
        foam_set "$case_dir" "$tp" "RAS.printCoeffs" "on"
    else
        foam_set "$case_dir" "$tp" "simulationType" "LES"
        foam_set "$case_dir" "$tp" "LES.turbulence" "on"
        foam_set "$case_dir" "$tp" "LES.printCoeffs" "on"
    fi
}

validate_solver_mode() {
    local case_dir="$1"
    local cd="$case_dir/system/controlDict"
    [[ -f "$cd" ]] || die "missing system/controlDict"

    local solver
    solver="$(foam_get "$case_dir" "$cd" application)"
    [[ "$solver" != "N/A" ]] || die "Cannot read application from system/controlDict."

    case "${SIM_TYPE}:${solver}" in
        LES:simpleFoam|LES:buoyantSimpleFoam|LES:porousSimpleFoam|LES:buoyantBoussinesqSimpleFoam)
            die "Incompatible steady solver '${solver}' for LES."
            ;;
    esac
}

rotate_stl_and_domain() {
    local case_dir="$1"
    local wd_norm="$2"

    local tri_dir="$case_dir/constant/triSurface"
    local stl="$tri_dir/$BASE_STL_NAME"
    local st_log="$case_dir/log.surfaceTransformPoints"
    local sc_log="$case_dir/log.surfaceCheck"

    [[ -f "$stl" ]] || die "missing base STL: $stl"

    local rot_angle
    rot_angle="$(rot_angle_from_wd "$wd_norm")"

    surfaceTransformPoints -auto-centre -rotate-z "$rot_angle" "$stl" "$stl" > "$st_log" 2>&1

    local rot_center
    rot_center="$(awk 'BEGIN{IGNORECASE=1}
        /Set centre of rotation to/ {
            for (i=1; i<=NF; ++i) gsub("[()]","",$i);
            print $(NF-2),$(NF-1),$NF;
            exit
        }' "$st_log")"
    [[ -n "$rot_center" ]] || die "cannot parse rotation centre from log.surfaceTransformPoints."

    read -r CX CY CZ <<< "$rot_center"

    shopt -s nullglob nocaseglob
    local f
    for f in "$tri_dir"/*.stl; do
        [[ "$f" == "$stl" ]] && continue
        surfaceTransformPoints -centre "(${CX} ${CY} ${CZ})" -rotate-z "$rot_angle" "$f" "$f" >> "$st_log" 2>&1
    done
    shopt -u nullglob nocaseglob

    surfaceCheck "$stl" > "$sc_log" 2>&1

    local bbox
    bbox="$(awk 'BEGIN{IGNORECASE=1}
        /bounding box|overall bounds/ {
            for (i=1; i<=NF; ++i) gsub("[()]","",$i);
            print $(NF-5),$(NF-4),$(NF-3),$(NF-2),$(NF-1),$NF;
            exit
        }' "$sc_log")"
    [[ -n "$bbox" ]] || die "cannot parse bounds from surfaceCheck output."

    read -r LOWER_X LOWER_Y LOWER_Z UPPER_X UPPER_Y UPPER_Z <<< "$bbox"

    ROT_ANGLE="$rot_angle"
}

compute_domain() {
    X_MIN=$(awk -v cx="$CX" -v rdr="$RDR" -v h="$H" -v a="$INLET_H"  'BEGIN{printf "%.3f", cx-rdr-a*h}' </dev/null)
    X_MAX=$(awk -v cx="$CX" -v rdr="$RDR" -v h="$H" -v a="$OUTLET_H" 'BEGIN{printf "%.3f", cx+rdr+a*h}' </dev/null)
    Y_MIN=$(awk -v cy="$CY" -v rdr="$RDR" -v h="$H" -v a="$SIDE_H"   'BEGIN{printf "%.3f", cy-rdr-a*h}' </dev/null)
    Y_MAX=$(awk -v cy="$CY" -v rdr="$RDR" -v h="$H" -v a="$SIDE_H"   'BEGIN{printf "%.3f", cy+rdr+a*h}' </dev/null)
    Z_MIN="$LOWER_Z"
    Z_MAX=$(awk -v uz="$UPPER_Z" -v h="$H" -v a="$TOP_H" 'BEGIN{printf "%.3f", uz+a*h}' </dev/null)

    DX_FAR=$(awk -v k="$SFGS" -v h="$H" 'BEGIN{printf "%.3f", k*h}' </dev/null)
    NX=$(awk -v a="$X_MIN" -v b="$X_MAX" -v d="$DX_FAR" 'BEGIN{s=b-a; n=int(s/d+0.999999); if(n<1)n=1; print n}' </dev/null)
    NY=$(awk -v a="$Y_MIN" -v b="$Y_MAX" -v d="$DX_FAR" 'BEGIN{s=b-a; n=int(s/d+0.999999); if(n<1)n=1; print n}' </dev/null)
    NZ=$(awk -v a="$Z_MIN" -v b="$Z_MAX" -v d="$DX_FAR" 'BEGIN{s=b-a; n=int(s/d+0.999999); if(n<1)n=1; print n}' </dev/null)

    RDH=$(awk -v uz="$UPPER_Z" -v h="$H" 'BEGIN{printf "%.3f", uz+h}' </dev/null)
    RDR_EXT=$(awk -v rdr="$RDR" 'BEGIN{printf "%.3f", rdr*1000}' </dev/null)
}

update_mesh_dicts() {
    local case_dir="$1"

    local bmd="$case_dir/system/blockMeshDict"
    local shmd="$case_dir/system/snappyHexMeshDict"

    [[ -f "$bmd" ]] || die "missing system/blockMeshDict"
    sed -i \
        -e "s#<xMin>#${X_MIN}#g" \
        -e "s#<xMax>#${X_MAX}#g" \
        -e "s#<yMin>#${Y_MIN}#g" \
        -e "s#<yMax>#${Y_MAX}#g" \
        -e "s#<zMin>#${Z_MIN}#g" \
        -e "s#<zMax>#${Z_MAX}#g" \
        -e "s#<nx>#${NX}#g" \
        -e "s#<ny>#${NY}#g" \
        -e "s#<nz>#${NZ}#g" \
        "$bmd"

    [[ -f "$shmd" ]] || die "missing system/snappyHexMeshDict"
    sed -i -e "s#<snap_ctrl>#${SNAP_CTRL}#g" "$shmd"

    foam_set "$case_dir" "$shmd" "addLayers" "$ADDLAYERS_CTRL"
    foam_set "$case_dir" "$shmd" "geometry.refinementDomain.point1" "(${CX} ${CY} ${Z_MIN})"
    foam_set "$case_dir" "$shmd" "geometry.refinementDomain.point2" "(${CX} ${CY} ${RDH})"
    foam_set "$case_dir" "$shmd" "geometry.refinementDomain.radius" "$RDR"
    foam_set "$case_dir" "$shmd" "geometry.refineGroundPlane.origin" "(${CX} ${CY} ${Z_MIN})"
    foam_set "$case_dir" "$shmd" "geometry.refineGroundPlane.radius" "$RDR_EXT"
    foam_set "$case_dir" "$shmd" "castellatedMeshControls.locationInMesh" "(${CX} ${CY} ${RDH})"
}

update_velocity_fields() {
    local case_dir="$1"
    local u_ref="$2"
    local row_line="$3"

    local zero_u="$case_dir/0/U"
    [[ -f "$zero_u" ]] || die "missing 0/U"

    local zero_k="$case_dir/0/k"
    local turb_scalar=""

    if [[ "$SIM_TYPE" == "RAS" ]]; then
        case "$RAS_MODEL" in
            kOmega|kOmegaSST) turb_scalar="$case_dir/0/omega" ;;
            kEpsilon|realizableKE) turb_scalar="$case_dir/0/epsilon" ;;
        esac

        [[ -f "$zero_k" ]] && foam_set "$case_dir" "$zero_k" "boundaryField.inlet.Uref" "$u_ref"
        [[ -f "$turb_scalar" ]] && foam_set "$case_dir" "$turb_scalar" "boundaryField.inlet.Uref" "$u_ref"
    fi

    foam_set "$case_dir" "$zero_u" "boundaryField.inlet.Uref" "$u_ref"

    read -r sinTheta cosTheta <<< "$(awk -v deg="${ROT_ANGLE:-0}" '
        BEGIN { pi = atan2(0, -1); t = deg*pi/180.0; printf "%.9f %.9f", sin(t), cos(t) }' </dev/null)"

    rot2d() {
        awk -v ux="$1" -v uy="$2" -v s="$sinTheta" -v c="$cosTheta" '
            BEGIN { printf "%.9f %.9f", c*ux-s*uy, s*ux+c*uy }' </dev/null
    }

    local U_oai="$U_OAI_BASE"
    local Ux1a Uy1a Ux1b Uy1b
    local Ux2a Uy2a Ux2b Uy2b
    local Ux3a Uy3a Ux3b Uy3b

    read -r Ux1a Uy1a <<< "$(rot2d 0 "-$U_oai")"
    read -r Ux1b Uy1b <<< "$(rot2d 0 "$U_oai")"
    read -r Ux2a Uy2a <<< "$(rot2d "$U_oai" 0)"
    read -r Ux2b Uy2b <<< "$(rot2d "-$U_oai" 0)"
    read -r Ux3a Uy3a <<< "$(rot2d "$U_oai" 0)"
    read -r Ux3b Uy3b <<< "$(rot2d "-$U_oai" 0)"

    declare -A oai_A=()
    declare -A oai_B=()
    oai_A[f18p1]="uniform (${Ux1a} ${Uy1a} 0)"
    oai_B[f18p1]="uniform (${Ux1b} ${Uy1b} 0)"
    oai_A[f18p2]="uniform (${Ux2a} ${Uy2a} 0)"
    oai_B[f18p2]="uniform (${Ux2b} ${Uy2b} 0)"
    oai_A[f18p3]="uniform (${Ux3a} ${Uy3a} 0)"
    oai_B[f18p3]="uniform (${Ux3b} ${Uy3b} 0)"

    # 0/U uses exhaust velocity from: <FAB>_<STACK_ZONE>_<SIDE_ID>__Uexit_mps
    local plants=("f18p1:P1" "f18p2:P2" "f18p3:P3")
    local devices=(SEB AEX SEX VOC)
    local sides=(A B)

    local plant_pair plant csv_prefix dev side patch header raw_value foam_value

    for plant_pair in "${plants[@]}"; do
        plant="${plant_pair%%:*}"
        csv_prefix="${plant_pair##*:}"

        for dev in "${devices[@]}"; do
            for side in "${sides[@]}"; do
                patch="${plant}_$(echo "$dev" | tr '[:upper:]' '[:lower:]')_$(echo "$side" | tr '[:upper:]' '[:lower:]')"

                # 0/U velocity header, e.g. P1_SEB_A__Uexit_mps
                header="${csv_prefix}_${dev}_${side}__Uexit_mps"
                raw_value="$(get_cell_by_header "$row_line" "$header")"

                # Backward-compatible fallback for older CSV files
                if [[ -z "$raw_value" ]]; then
                    header="${csv_prefix}_${dev}_${side}_U"
                    raw_value="$(get_cell_by_header "$row_line" "$header")"
                fi

                if [[ -z "$raw_value" ]]; then
                    warn "CSV velocity column missing or empty: ${csv_prefix}_${dev}_${side}__Uexit_mps; skip $patch"
                    continue
                fi

                foam_value="$(make_velocity_foam_value "$raw_value")" || {
                    warn "Invalid velocity value '$raw_value' for $header; skip $patch"
                    continue
                }

                foam_set "$case_dir" "$zero_u" "boundaryField.${patch}.value" "$foam_value"
            done
        done

        foam_set "$case_dir" "$zero_u" "boundaryField.${plant}_oai_a1.value" "${oai_A[$plant]}"
        foam_set "$case_dir" "$zero_u" "boundaryField.${plant}_oai_a2.value" "${oai_A[$plant]}"
        foam_set "$case_dir" "$zero_u" "boundaryField.${plant}_oai_b1.value" "${oai_B[$plant]}"
        foam_set "$case_dir" "$zero_u" "boundaryField.${plant}_oai_b2.value" "${oai_B[$plant]}"
    done
}

update_transport_scalar_field() {
    local case_dir="$1"
    local row_line="$2"

    local zero_t="$case_dir/0/$SCALAR_FIELD"
    [[ -f "$zero_t" ]] || die "missing transport scalar field: 0/$SCALAR_FIELD"

    # 0/$SCALAR_FIELD uses emission concentration from: <FAB>_<STACK_ZONE>_<SIDE_ID>__Cemit_ugpm3
    local plants=("f18p1:P1" "f18p2:P2" "f18p3:P3")
    local devices=(SEB AEX SEX VOC)
    local sides=(A B)

    local plant_pair plant csv_prefix dev side patch
    local header raw_value foam_value current_type

    for plant_pair in "${plants[@]}"; do
        plant="${plant_pair%%:*}"
        csv_prefix="${plant_pair##*:}"

        for dev in "${devices[@]}"; do
            for side in "${sides[@]}"; do
                patch="${plant}_$(echo "$dev" | tr '[:upper:]' '[:lower:]')_$(echo "$side" | tr '[:upper:]' '[:lower:]')"

                # CSV header example: P1_SEB_A__Cemit_ugpm3
                header="${csv_prefix}_${dev}_${side}__Cemit_ugpm3"
                raw_value="$(get_cell_by_header "$row_line" "$header")"

                # Backward-compatible fallback
                if [[ -z "$raw_value" ]]; then
                    header="${csv_prefix}_${dev}_${side}_C"
                    raw_value="$(get_cell_by_header "$row_line" "$header")"
                fi

                if [[ -z "$raw_value" ]]; then
                    warn "CSV scalar column missing or empty: ${csv_prefix}_${dev}_${side}__Cemit_ugpm3; skip $patch"
                    continue
                fi

                foam_value="$(make_scalar_foam_value "$raw_value")" || {
                    warn "Invalid scalar value '$raw_value' for $header; skip $patch"
                    continue
                }

                current_type="$(foam_get "$case_dir" "$zero_t" "boundaryField.${patch}.type")"
                if [[ "$current_type" != "fixedValue" ]]; then
                    foam_set "$case_dir" "$zero_t" "boundaryField.${patch}.type" "fixedValue"
                fi

                foam_set "$case_dir" "$zero_t" "boundaryField.${patch}.value" "$foam_value"
            done
        done
    done
}

setup_transport_case_from_row() {
    local csv_abs="$1"
    local row_no="$2"
    local row_line="$3"
    local case_id="$4"
    local flow_case_name="$5"
    local wd_norm="$6"
    local ws="$7"
    local ws_for_setup="$8"

    [[ "$SETUP_TRANSPORT_CASES" == "true" ]] || return 0

    local case_root="$OUT_ABS/$case_id"
    local transport_case_name="${case_id}/trd"
    local transport_case_dir="$case_root/trd"

    if [[ "$DRY_RUN" == "true" ]]; then
        append_summary "$csv_abs" "$row_no" "$case_id" "$transport_case_name" "$wd_norm" "$ws" "$ws_for_setup" "$transport_case_dir" "dry_run" "would create transport case"
        return 0
    fi

    [[ -d "$TRANSPORT_BASE_ABS" ]] || die "Transport base folder not found: $TRANSPORT_BASE_ABS"

    if [[ -e "$transport_case_dir" ]]; then
        append_summary "$csv_abs" "$row_no" "$case_id" "$transport_case_name" "$wd_norm" "$ws" "$ws_for_setup" "$transport_case_dir" "skipped" "transport case already exists"
        return 0
    fi

    mkdir -p "$case_root"
    cp -a --reflink=auto "$TRANSPORT_BASE_ABS" "$transport_case_dir"

    {
        echo "$header_line"
        echo "$row_line"
    } > "$transport_case_dir/doe_row.csv"

    {
        echo "case_type=transport"
        echo "csv_file=$csv_abs"
        echo "row_number=$row_no"
        echo "case_id=$case_id"
        echo "case_name=$transport_case_name"
        echo "wd=$wd_norm"
        echo "ws=$ws"
        echo "ws_for_setup=$ws_for_setup"
    } > "$transport_case_dir/setup_metadata.env"

    # Transport reuses the converged flow mesh at runtime. Do not rotate STL or
    # prepare transport mesh dictionaries here; that work would be overwritten by
    # run_transport_cases.sh. Remove copied geometry/mesh payload if present.
    rm -rf "$transport_case_dir/constant/triSurface"            "$transport_case_dir/constant/polyMesh"

    update_transport_scalar_field "$transport_case_dir" "$row_line"

    if declare -F update_parallel_settings >/dev/null 2>&1; then
        update_parallel_settings "$transport_case_dir"
    fi

    append_summary "$csv_abs" "$row_no" "$case_id" "$transport_case_name" "$wd_norm" "$ws" "$ws_for_setup" "$transport_case_dir" "created" "transport case created"
}

get_cell_by_header() {
    local row_line="$1"
    local header_name="$2"
    local key idx

    key="$(lower "$header_name")"
    [[ -n "${COL[$key]+x}" ]] || { echo ""; return 0; }

    idx="${COL[$key]}"
    get_cell_from_row "$row_line" "$idx"
}

make_scalar_foam_value() {
    local raw
    raw="$(trim "$1")"
    [[ -n "$raw" ]] || return 1

    if [[ "$raw" == uniform* ]]; then
        echo "$raw"
        return 0
    fi

    is_float "$raw" || return 1
    echo "uniform $raw"
}

# Build "uniform (ux uy uz)" from a CSV magnitude.
# Direction: along +x rotated by ROT_ANGLE about Z (consistent with wind rotation).
make_velocity_foam_value() {
    local raw
    raw="$(trim "$1")"
    [[ -n "$raw" ]] || return 1

    if [[ "$raw" == *"("*")"* ]]; then
        if [[ "$raw" == uniform* ]]; then
            echo "$raw"
        else
            echo "uniform $raw"
        fi
        return 0
    fi

    is_float "$raw" || return 1

    awk -v mag="$raw" '
        BEGIN {
            printf "uniform (0 0 %.9g)", mag;
        }' </dev/null
}

update_parallel_settings() {
    local case_dir="$1"
    local dpd="$case_dir/system/decomposeParDict"
    local run_sh="$case_dir/run_flow.sh"

    if [[ -f "$dpd" ]]; then
        foam_set "$case_dir" "$dpd" "numberOfSubdomains" "$NP"
    fi

    if [[ -f "$run_sh" ]]; then
        sed -i -E "s/(-np[[:space:]]+)[0-9]+/\1${NP}/g; s/(NP=)[0-9]+/\1${NP}/g" "$run_sh"
    fi
}

# =============================================================================
# 5. PER-ROW DRIVERS AND MAIN
# =============================================================================

resolve_ws_for_setup() {
    local ws="$1"

    is_float "$ws" || return 1

    if awk -v x="$ws" 'BEGIN{exit !(x>0)}' </dev/null; then
        echo "$ws"
        return 0
    fi

    case "$ZERO_WS_MODE" in
        skip)    return 2 ;;
        epsilon) echo "$MIN_WS"; return 0 ;;
        keep)    echo "$ws"; return 0 ;;
        error)   return 1 ;;
    esac
}

setup_flow_case_from_row() {
    local csv_abs="$1"
    local row_no="$2"
    local row_line="$3"
    local case_id="$4"
    local wd_norm="$5"
    local ws="$6"
    local ws_for_setup="$7"

    [[ "$SETUP_FLOW_CASES" == "true" ]] || return 0

    local case_root="$OUT_ABS/$case_id"
    local case_name="${case_id}/flow"
    local case_dir="$case_root/flow"

    if [[ "$DRY_RUN" == "true" ]]; then
        append_summary "$csv_abs" "$row_no" "$case_id" "$case_name" "$wd_norm" "$ws" "$ws_for_setup" "$case_dir" "dry_run" "would create flow case"
        echo "$case_name"
        return 0
    fi

    [[ -d "$FLOW_BASE_ABS" ]] || die "Flow base folder not found: $FLOW_BASE_ABS"

    if [[ -e "$case_dir" ]]; then
        append_summary "$csv_abs" "$row_no" "$case_id" "$case_name" "$wd_norm" "$ws" "$ws_for_setup" "$case_dir" "skipped" "flow case already exists"
        echo "$case_name"
        return 0
    fi

    mkdir -p "$case_root"
    cp -a --reflink=auto "$FLOW_BASE_ABS" "$case_dir"

    {
        echo "$header_line"
        echo "$row_line"
    } > "$case_dir/doe_row.csv"

    {
        echo "case_type=flow"
        echo "csv_file=$csv_abs"
        echo "row_number=$row_no"
        echo "case_id=$case_id"
        echo "case_name=$case_name"
        echo "wd=$wd_norm"
        echo "ws=$ws"
        echo "ws_for_setup=$ws_for_setup"
        echo "sim_type=$SIM_TYPE"
        echo "ras_model=$RAS_MODEL"
    } > "$case_dir/setup_metadata.env"

    sync_turbulence_files "$case_dir" "$SIM_TYPE" "$RAS_MODEL"
    configure_turbulence "$case_dir"
    validate_solver_mode "$case_dir"
    rotate_stl_and_domain "$case_dir" "$wd_norm"
    compute_domain
    update_mesh_dicts "$case_dir"
    update_velocity_fields "$case_dir" "$ws_for_setup" "$row_line"
    update_parallel_settings "$case_dir"

    append_summary "$csv_abs" "$row_no" "$case_id" "$case_name" "$wd_norm" "$ws" "$ws_for_setup" "$case_dir" "created" "flow case created"
    echo "$case_name"
}

setup_one_row() {
    local csv_abs="$1"
    local row_no="$2"
    local row_line="$3"

    local raw_case raw_ws raw_wd case_id ws wd wd_norm ws_for_setup flow_case_name rc

    raw_case="$(get_cell_from_row "$row_line" "$CASE_COL")"
    raw_ws="$(get_cell_from_row "$row_line" "$WS_COL")"
    raw_wd="$(get_cell_from_row "$row_line" "$WD_COL")"

    case_id="$(make_case_id "$raw_case")"
    ws="$(trim "$raw_ws")"
    wd="$(trim "$raw_wd")"

    is_float "$ws" || {
        append_summary "$csv_abs" "$row_no" "$case_id" "" "$wd" "$ws" "" "" "failed" "invalid WS"
        return 1
    }

    is_float "$wd" || {
        append_summary "$csv_abs" "$row_no" "$case_id" "" "$wd" "$ws" "" "" "failed" "invalid WD"
        return 1
    }

    wd_norm="$(normalize_wd "$wd")"

    if ws_for_setup="$(resolve_ws_for_setup "$ws")"; then
        :
    else
        rc=$?
        if (( rc == 2 )); then
            append_summary "$csv_abs" "$row_no" "$case_id" "" "$wd_norm" "$ws" "" "" "skipped" "WS<=0 and ZERO_WS_MODE=skip"
            return 0
        fi
        append_summary "$csv_abs" "$row_no" "$case_id" "" "$wd_norm" "$ws" "" "" "failed" "invalid WS for setup"
        return 1
    fi

    flow_case_name="$(setup_flow_case_from_row "$csv_abs" "$row_no" "$row_line" "$case_id" "$wd_norm" "$ws" "$ws_for_setup")" || return 1

    if [[ "$SETUP_TRANSPORT_CASES" == "true" ]]; then
        setup_transport_case_from_row "$csv_abs" "$row_no" "$row_line" "$case_id" "$flow_case_name" "$wd_norm" "$ws" "$ws_for_setup" || return 1
    fi
}

run_row_in_background() {
    local csv_abs="$1"
    local row_no="$2"
    local row_line="$3"

    local raw_case case_id log_file
    raw_case="$(get_cell_from_row "$row_line" "$CASE_COL")"
    case_id="$(make_case_id "$raw_case")"

    [[ -n "$case_id" && "$case_id" != "NA" ]] || case_id="row_${row_no}"

    log_file="$LOG_DIR/${case_id}.log"

    # The job status reports the row result to the parent. A failed record
    # append cannot hide a failed row, because the artifact can stay empty.
    (
        if setup_one_row "$csv_abs" "$row_no" "$row_line" >"$log_file" 2>&1; then
            exit 0
        fi
        echo "$csv_abs,$row_no" >> "$FAIL_FILE" || exit 2
        exit 1
    ) &
}

# wait_for_all_rows - wait for every launched row job and count the failures.
wait_for_all_rows() {
    local rc pid

    if (( BASH_VERSINFO[0] > 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3 ) )); then
        while [[ -n "$(jobs -p)" ]]; do
            rc=0
            wait -n || rc=$?
            (( rc == 0 )) || FAILED_ROW_JOBS=$(( FAILED_ROW_JOBS + 1 ))
        done
        return 0
    fi

    for pid in $(jobs -p); do
        rc=0
        wait "$pid" || rc=$?
        (( rc == 0 )) || FAILED_ROW_JOBS=$(( FAILED_ROW_JOBS + 1 ))
    done
}

main() {
    FAILED_ROW_JOBS=0

    validate_global_config

    local csv csv_abs row_no line

    info "Counting CSV rows..."
    count_total_rows
    info "Total rows: $TOTAL_ROWS"

    while IFS= read -r csv; do
        csv_abs="$(cd "$(dirname "$csv")" && pwd -P)/$(basename "$csv")"
        info "Processing CSV: $csv_abs"

        load_csv_header "$csv_abs"

        row_no=2
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line//$'\r'/}"
            [[ -z "${line//[[:space:]]/}" ]] && { row_no=$((row_no + 1)); continue; }

            wait_for_free_slot "$PARALLEL_JOBS"
            run_row_in_background "$csv_abs" "$row_no" "$line"
            STARTED_CASES=$((STARTED_CASES + 1))
            show_progress

            row_no=$((row_no + 1))
        done < <(tail -n +2 "$csv_abs")
    done < <(find_csv_files)

    wait_for_all_rows
    show_progress

    local rows_failed=0

    if (( FAILED_ROW_JOBS > 0 )) || [[ -s "$FAIL_FILE" ]]; then
        rows_failed=1
        warn "Some rows failed. Check: $FAIL_FILE"
    else
        info "Done."
    fi

    info "Summary: $SUMMARY_CSV"

    (( rows_failed == 0 )) || return 1
}

main "$@"
