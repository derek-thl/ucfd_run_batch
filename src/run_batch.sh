#!/usr/bin/env bash

# run_batch.sh v4 (2026-08-26)
# Purpose: Run a UCFD batch pipeline based on parameters defined in CSV files.

set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Backward-compatible environment overrides.
MASTER_BATCH_DIR="${MASTER_BATCH_DIR:-${SCRIPT_DIR}/master_batch}"
OUTPUT_ROOT="${RUN_BATCH_OUTPUT_DIR:-${SCRIPT_DIR}}"
OVERWRITE="${RUN_BATCH_OVERWRITE:-0}"

PARALLEL_JOBS=""
SETUP_JOBS=""
MESH_JOBS=""
FLOW_JOBS=""
TRANSPORT_JOBS=""
POST_JOBS=""
BATCH_JOBS=1
KEEP_GOING=0
SKIP_POST=0
DRY_RUN=0
SAVE_TIMES="60,120,300"
SCALAR_FIELD="${SCALAR_FIELD:-T}"

# Stage selection. With no --stage option, keep the v2 full-pipeline behavior.
STAGE_SELECTION_EXPLICIT=0
STAGE_TOKENS=()
RUN_SETUP=0
RUN_MESH=0
RUN_FLOW=0
RUN_TRANSPORT=0
RUN_POST=0
POST_REQUIRED=0

INPUT_CSVS=()
INPUT_CSVS_ABS=()
BATCH_NUMBERS=()

log() {
    local level="$1"
    shift
    printf '[%s] %-5s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

info() { log INFO "$@"; }
warn() { log WARN "$@" >&2; }
error() { log ERROR "$@" >&2; }
die() { error "$*"; exit 1; }

usage() {
    cat <<EOF_USAGE
Usage:
  bash run_batch.sh [options] <batch_csv> [<batch_csv> ...]

Default pipeline:
  setup -> mesh -> flow -> transport -> post-processing

Stage selection:
  -s, --stage, --stages <STAGE>
                          Run only selected stage(s). May be repeated or comma-separated.
                           Valid names: setup, mesh, flow, transport, post-processing, all
                           Aliases for post-processing: post, postprocess, post_processing

                           If setup is selected, batch_<id> is initialized from the master
                           template before selected stages run.

                           If setup is NOT selected, batch_<id> must already exist and is
                           reused without being recreated or deleted.

Options:
  -j, --jobs <N>          Default parallel case count for selected stages.
      --setup-jobs <N>    Override -j for setup only.
      --mesh-jobs <N>     Override -j for mesh only.
      --flow-jobs <N>     Override -j for flow only.
      --transport-jobs <N> Override -j for transport only.
      --post-jobs <N>     Override -j for post-processing only.
  -B, --batch-jobs <N>    Number of whole batches allowed to run concurrently.
                           Default: 1 (sequential batches).
  -m, --master-dir <DIR>  Template directory used when setup is selected.
                           Default: ${SCRIPT_DIR}/master_batch
  -o, --output-dir <DIR>  Parent directory for batch_<id> directories.
                           Default: ${SCRIPT_DIR}
  -f, --overwrite         Replace an existing non-empty batch_<id> directory.
                           Valid only when setup is selected.
      --keep-going        Continue with other batches after a batch fails.
      --skip-post         Skip post-processing in the default/all pipeline.
      --save-times <LIST> Transport save times, comma-separated integers.
                           Default: ${SAVE_TIMES}
      --scalar-field <N>  Transport scalar field name shared by setup, transport, and post.
                           Default: ${SCALAR_FIELD}
  -n, --dry-run           Validate everything and print the execution plan only.
  -h, --help              Show this help.
      --                  End option parsing. Remaining arguments are CSV paths.

Environment compatibility:
  MASTER_BATCH_DIR        Same purpose as --master-dir.
  RUN_BATCH_OUTPUT_DIR    Same purpose as --output-dir.
  RUN_BATCH_OVERWRITE=1   Same purpose as --overwrite.

Examples:
  # Full pipeline (same default behavior as v2).
  bash run_batch.sh -j 8 output_batch_3.csv

  # Run setup only and initialize batch_3.
  bash run_batch.sh --stage setup output_batch_3.csv

  # Reuse existing batch_3 and run mesh only.
  bash run_batch.sh --stage mesh -j 8 output_batch_3.csv

  # Run flow then transport on existing batches.
  bash run_batch.sh --stage flow,transport -j 8 \
      output_batch_3.csv output_batch_4.csv

  # Run post-processing only on an existing batch.
  bash run_batch.sh --stage post-processing output_batch_3.csv

  # Initialize a fresh batch and run only setup + mesh.
  bash run_batch.sh --overwrite --stage setup,mesh -j 8 output_batch_3.csv

  # Validate a transport-only continuation without running it.
  bash run_batch.sh --dry-run --stage transport output_batch_3.csv
EOF_USAGE
}

require_positive_integer() {
    local value="$1"
    local option="$2"

    [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 )) ||
        die "$option must be an integer >= 1; got: $value"
}

canonicalize_existing_file() {
    local path="$1"
    local resolved

    resolved="$(readlink -f -- "$path" 2>/dev/null || true)"
    [[ -n "$resolved" && -f "$resolved" ]] || return 1
    printf '%s\n' "$resolved"
}

canonicalize_path() {
    realpath -m -- "$1"
}

extract_batch_number() {
    local filename="$1"
    local stem="${filename%.*}"

    if [[ "$filename" =~ [Bb][Aa][Tt][Cc][Hh][_-]?([0-9]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    if [[ "$stem" =~ ([0-9]+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

find_post_script_in_dir() {
    local dir="$1"
    local candidate
    local candidates=(
        "run_post_processing_cases.sh"
        "run_postprocess_cases.sh"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "${dir}/${candidate}" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

stage_script_path() {
    local script="$1"
    local batch_dir="$2"

    # Prefer one authoritative current version from master_batch. This prevents
    # old scripts copied into existing batch_* directories from drifting behind
    # run_batch.sh. Fall back to batch-local scripts for backward compatibility.
    if [[ -d "$MASTER_BATCH_DIR" && -f "${MASTER_BATCH_DIR}/${script}" ]]; then
        printf '%s\n' "${MASTER_BATCH_DIR}/${script}"
        return 0
    fi
    if [[ -f "${batch_dir}/${script}" ]]; then
        printf '%s\n' "${batch_dir}/${script}"
        return 0
    fi
    return 1
}

post_script_path() {
    local batch_dir="$1"
    local name=""
    if [[ -d "$MASTER_BATCH_DIR" ]] && name="$(find_post_script_in_dir "$MASTER_BATCH_DIR" || true)" && [[ -n "$name" ]]; then
        printf '%s\n' "${MASTER_BATCH_DIR}/${name}"
        return 0
    fi
    if name="$(find_post_script_in_dir "$batch_dir" || true)" && [[ -n "$name" ]]; then
        printf '%s\n' "${batch_dir}/${name}"
        return 0
    fi
    return 1
}

validate_selected_scripts_for_batch() {
    local batch_dir="$1" path=""
    if (( RUN_SETUP == 1 )); then
        path="$(stage_script_path setup_cases.sh "$batch_dir" || true)"
        [[ -n "$path" ]] || die "Selected setup stage script not found in master or batch: $batch_dir"
    fi
    if (( RUN_MESH == 1 )); then
        path="$(stage_script_path run_mesh_cases.sh "$batch_dir" || true)"
        [[ -n "$path" ]] || die "Selected mesh stage script not found in master or batch: $batch_dir"
    fi
    if (( RUN_FLOW == 1 )); then
        path="$(stage_script_path run_flow_cases.sh "$batch_dir" || true)"
        [[ -n "$path" ]] || die "Selected flow stage script not found in master or batch: $batch_dir"
    fi
    if (( RUN_TRANSPORT == 1 )); then
        path="$(stage_script_path run_transport_cases.sh "$batch_dir" || true)"
        [[ -n "$path" ]] || die "Selected transport stage script not found in master or batch: $batch_dir"
    fi
    if (( RUN_POST == 1 )); then
        path="$(post_script_path "$batch_dir" || true)"
        if [[ -z "$path" && "$POST_REQUIRED" == "1" ]]; then
            die "Selected post-processing stage script not found in master or batch: $batch_dir"
        fi
    fi
}

print_command() {
    local arg
    printf '    '
    for arg in "$@"; do
        printf '%q ' "$arg"
    done
    printf '\n'
}

format_seconds() {
    local total="$1"
    printf '%02d:%02d:%02d' \
        "$(( total / 3600 ))" \
        "$(( (total % 3600) / 60 ))" \
        "$(( total % 60 ))"
}

stage_job_count() {
    local stage="$1"
    local override=""
    case "$stage" in
        setup) override="$SETUP_JOBS" ;;
        mesh) override="$MESH_JOBS" ;;
        flow) override="$FLOW_JOBS" ;;
        transport) override="$TRANSPORT_JOBS" ;;
        post) override="$POST_JOBS" ;;
        *) die "Internal error: unknown stage for job count: $stage" ;;
    esac
    printf '%s\n' "${override:-$PARALLEL_JOBS}"
}

build_job_args() {
    local stage="$1"
    local jobs
    jobs="$(stage_job_count "$stage")"
    STAGE_JOB_ARGS=()
    [[ -z "$jobs" ]] || STAGE_JOB_ARGS=(-j "$jobs")
}

detect_np_from_dict() {
    local dict="$1"
    [[ -f "$dict" ]] || return 1
    awk '
        /^[[:space:]]*numberOfSubdomains[[:space:]]+/ {
            gsub(/;/, "", $2); print $2; exit
        }
    ' "$dict"
}

mpi_ranks_hint() {
    local dict="" np=""
    if (( RUN_SETUP == 1 )); then
        dict="${MASTER_BATCH_DIR}/simpleFoam_files/system/decomposeParDict"
    elif (( ${#BATCH_NUMBERS[@]} > 0 )); then
        dict="$(find "${OUTPUT_ROOT}/batch_${BATCH_NUMBERS[0]}" -path '*/flow/system/decomposeParDict' -type f -print -quit 2>/dev/null || true)"
    fi
    [[ -n "$dict" ]] || return 1
    np="$(detect_np_from_dict "$dict" || true)"
    [[ "$np" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$np"
}

run_stage() {
    local script="$1"
    shift
    local started=$SECONDS
    local rc
    local display="${script##*/}"

    [[ -f "$script" ]] || {
        error "Stage script not found: $script"
        return 127
    }

    info "Stage start   : $display"
    info "Stage source  : $script"
    info "Stage command : bash $(printf '%q ' "$script")$(printf '%q ' "$@")"

    if bash "$script" "$@"; then
        info "Stage done    : $display ($(format_seconds "$(( SECONDS - started ))"))"
        return 0
    else
        rc=$?
        error "Stage failed  : $display (exit=$rc, elapsed=$(format_seconds "$(( SECONDS - started ))"))"
        return "$rc"
    fi
}

normalize_stage_selection() {
    local raw
    local token
    local normalized
    local saw_explicit_post=0
    local -A requested=()

    if (( ${#STAGE_TOKENS[@]} == 0 )); then
        requested[setup]=1
        requested[mesh]=1
        requested[flow]=1
        requested[transport]=1
        if (( SKIP_POST == 0 )); then
            requested[post]=1
        fi
    else
        STAGE_SELECTION_EXPLICIT=1

        for raw in "${STAGE_TOKENS[@]}"; do
            IFS=',' read -r -a parts <<< "$raw"
            for token in "${parts[@]}"; do
                token="${token//[[:space:]]/}"
                [[ -n "$token" ]] || die "Empty stage name in --stage '$raw'."

                case "${token,,}" in
                    setup)
                        normalized="setup"
                        ;;
                    mesh)
                        normalized="mesh"
                        ;;
                    flow)
                        normalized="flow"
                        ;;
                    transport)
                        normalized="transport"
                        ;;
                    post|postprocess|post-processing|post_processing)
                        normalized="post"
                        saw_explicit_post=1
                        ;;
                    all)
                        requested[setup]=1
                        requested[mesh]=1
                        requested[flow]=1
                        requested[transport]=1
                        if (( SKIP_POST == 0 )); then
                            requested[post]=1
                        fi
                        continue
                        ;;
                    *)
                        die "Unknown stage '$token'. Valid stages: setup, mesh, flow, transport, post-processing, all."
                        ;;
                esac

                requested["$normalized"]=1
            done
        done
    fi

    if (( SKIP_POST == 1 && saw_explicit_post == 1 )); then
        die "--skip-post conflicts with an explicit --stage post-processing request."
    fi

    RUN_SETUP="${requested[setup]:-0}"
    RUN_MESH="${requested[mesh]:-0}"
    RUN_FLOW="${requested[flow]:-0}"
    RUN_TRANSPORT="${requested[transport]:-0}"
    RUN_POST="${requested[post]:-0}"

    # An explicitly selected post stage must exist; the default full pipeline
    # keeps v2 compatibility and may skip post-processing when no script exists.
    if (( STAGE_SELECTION_EXPLICIT == 1 && RUN_POST == 1 )); then
        POST_REQUIRED=1
    fi

    if (( RUN_SETUP == 0 && OVERWRITE == 1 )); then
        die "--overwrite cannot be used when setup is not selected. Independent later-stage runs reuse the existing batch directory."
    fi
}

selected_stage_summary() {
    local -a names=()
    local name
    local summary=""

    (( RUN_SETUP == 1 )) && names+=(setup)
    (( RUN_MESH == 1 )) && names+=(mesh)
    (( RUN_FLOW == 1 )) && names+=(flow)
    (( RUN_TRANSPORT == 1 )) && names+=(transport)
    (( RUN_POST == 1 )) && names+=(post-processing)

    for name in "${names[@]}"; do
        if [[ -n "$summary" ]]; then
            summary+=" -> "
        fi
        summary+="$name"
    done
    printf '%s' "$summary"
}

validate_selected_scripts_in_dir() {
    local dir="$1"
    local context="$2"
    local post_script=""

    (( RUN_SETUP == 0 )) || [[ -f "${dir}/setup_cases.sh" ]] ||
        die "Selected setup stage script not found in ${context}: ${dir}/setup_cases.sh"

    (( RUN_MESH == 0 )) || [[ -f "${dir}/run_mesh_cases.sh" ]] ||
        die "Selected mesh stage script not found in ${context}: ${dir}/run_mesh_cases.sh"

    (( RUN_FLOW == 0 )) || [[ -f "${dir}/run_flow_cases.sh" ]] ||
        die "Selected flow stage script not found in ${context}: ${dir}/run_flow_cases.sh"

    (( RUN_TRANSPORT == 0 )) || [[ -f "${dir}/run_transport_cases.sh" ]] ||
        die "Selected transport stage script not found in ${context}: ${dir}/run_transport_cases.sh"

    if (( RUN_POST == 1 )); then
        if post_script="$(find_post_script_in_dir "$dir")"; then
            :
        elif (( POST_REQUIRED == 1 )); then
            die "Selected post-processing stage script not found in ${context}: $dir"
        else
            warn "No post-processing script found in ${context}; post-processing will be skipped."
        fi
    fi
}

preflight() {
    local input
    local input_abs
    local filename
    local batch_number
    local batch_dir
    local local_batch_csv
    local -A seen_batch_dirs=()

    OUTPUT_ROOT="$(canonicalize_path "$OUTPUT_ROOT")"
    MASTER_BATCH_DIR="$(canonicalize_path "$MASTER_BATCH_DIR")"

    if (( RUN_SETUP == 1 )); then
        [[ -d "$MASTER_BATCH_DIR" ]] ||
            die "Master batch directory not found: $MASTER_BATCH_DIR. Use --master-dir <DIR> if needed."
        validate_selected_scripts_in_dir "$MASTER_BATCH_DIR" "master batch"
    fi

    INPUT_CSVS_ABS=()
    BATCH_NUMBERS=()

    for input in "${INPUT_CSVS[@]}"; do
        input_abs="$(canonicalize_existing_file "$input" || true)"
        [[ -n "$input_abs" ]] || die "Batch CSV not found: $input"

        filename="$(basename -- "$input_abs")"
        [[ "${filename,,}" == *.csv ]] ||
            die "Input must have a .csv extension: $input_abs"

        batch_number="$(extract_batch_number "$filename" || true)"
        [[ -n "$batch_number" ]] ||
            die "Cannot determine batch ID from filename: $filename. Recommended form: output_batch_<id>.csv"

        batch_dir="${OUTPUT_ROOT}/batch_${batch_number}"
        local_batch_csv="${batch_dir}/${filename}"

        if [[ -n "${seen_batch_dirs[$batch_dir]:-}" ]]; then
            die "Duplicate batch destination detected: $batch_dir. Inputs '${seen_batch_dirs[$batch_dir]}' and '$input_abs' resolve to the same batch ID."
        fi
        seen_batch_dirs["$batch_dir"]="$input_abs"

        if (( RUN_SETUP == 1 )); then
            [[ "$batch_dir" != "$MASTER_BATCH_DIR" ]] ||
                die "Unsafe configuration: output batch directory equals master batch directory: $batch_dir"

            case "$input_abs" in
                "$batch_dir"/*)
                    die "Input CSV is inside its destination batch directory: $input_abs. Move the source CSV outside $batch_dir before running setup."
                    ;;
            esac

            if [[ -d "$batch_dir" && -n "$(find "$batch_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" && "$OVERWRITE" != "1" ]]; then
                die "Batch directory already exists and is not empty: $batch_dir. Use --overwrite to replace it, or omit setup to reuse it."
            fi
        else
            [[ -d "$batch_dir" ]] ||
                die "Existing batch directory required because setup is not selected: $batch_dir"

            [[ -n "$(find "$batch_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] ||
                die "Existing batch directory is empty: $batch_dir"

            validate_selected_scripts_for_batch "$batch_dir"

            # Prefer the copy already stored with the batch. If it exists, ensure
            # the caller did not accidentally supply a different CSV with the same name.
            if [[ -f "$local_batch_csv" && "$input_abs" != "$local_batch_csv" ]]; then
                cmp -s -- "$input_abs" "$local_batch_csv" ||
                    die "CSV mismatch for existing batch_${batch_number}: '$input_abs' differs from '$local_batch_csv'. Use the CSV that created this batch or run setup again with --overwrite."
            fi
        fi

        INPUT_CSVS_ABS+=("$input_abs")
        BATCH_NUMBERS+=("$batch_number")
    done

    if (( DRY_RUN == 0 && RUN_SETUP == 1 )); then
        mkdir -p -- "$OUTPUT_ROOT" || die "Cannot create output directory: $OUTPUT_ROOT"
    fi

    info "Preflight PASS"
    info "Batch count     : ${#INPUT_CSVS_ABS[@]}"
    info "Selected stages : $(selected_stage_summary)"
    if (( RUN_SETUP == 1 )); then
        info "Workspace mode  : initialize from master template"
        info "Master batch    : $MASTER_BATCH_DIR"
    else
        info "Workspace mode  : reuse existing batch directories"
    fi
    info "Output root     : $OUTPUT_ROOT"
    if [[ -d "$MASTER_BATCH_DIR" ]]; then
        info "Stage scripts   : prefer $MASTER_BATCH_DIR; fallback to batch-local"
    else
        info "Stage scripts   : batch-local (master directory unavailable)"
    fi
    info "Case jobs       : ${PARALLEL_JOBS:-stage default}"
    [[ -z "$SETUP_JOBS" ]] || info "Setup jobs      : $SETUP_JOBS"
    [[ -z "$MESH_JOBS" ]] || info "Mesh jobs       : $MESH_JOBS"
    [[ -z "$FLOW_JOBS" ]] || info "Flow jobs       : $FLOW_JOBS"
    [[ -z "$TRANSPORT_JOBS" ]] || info "Transport jobs  : $TRANSPORT_JOBS"
    [[ -z "$POST_JOBS" ]] || info "Post jobs       : $POST_JOBS"
    info "Batch jobs      : $BATCH_JOBS"
    info "Overwrite       : $OVERWRITE"
    info "Keep going      : $KEEP_GOING"
    (( RUN_TRANSPORT == 0 )) || info "Save times      : $SAVE_TIMES"
    if (( RUN_SETUP == 1 || RUN_TRANSPORT == 1 || RUN_POST == 1 )); then
        info "Scalar field    : $SCALAR_FIELD"
    fi

    local cpu_count np_hint stage_jobs max_cases max_mpi
    cpu_count="$(nproc 2>/dev/null || echo '?')"
    np_hint="$(mpi_ranks_hint || true)"
    max_cases=0
    if (( RUN_MESH == 1 )); then
        stage_jobs="$(stage_job_count mesh)"
        [[ "$stage_jobs" =~ ^[0-9]+$ ]] && (( stage_jobs > max_cases )) && max_cases="$stage_jobs"
    fi
    if (( RUN_FLOW == 1 )); then
        stage_jobs="$(stage_job_count flow)"
        [[ "$stage_jobs" =~ ^[0-9]+$ ]] && (( stage_jobs > max_cases )) && max_cases="$stage_jobs"
    fi
    if (( RUN_TRANSPORT == 1 )); then
        stage_jobs="$(stage_job_count transport)"
        [[ "$stage_jobs" =~ ^[0-9]+$ ]] && (( stage_jobs > max_cases )) && max_cases="$stage_jobs"
    fi
    if (( max_cases > 0 )); then
        if [[ "$np_hint" =~ ^[0-9]+$ ]]; then
            max_mpi=$(( BATCH_JOBS * max_cases * np_hint ))
            info "MPI ranks/case  : ~${np_hint} (detected hint)"
            info "Peak MPI ranks  : ~${BATCH_JOBS} x ${max_cases} x ${np_hint} = ${max_mpi}"
            if [[ "$cpu_count" =~ ^[0-9]+$ ]] && (( max_mpi > cpu_count )); then
                warn "Probable CPU oversubscription: peak MPI ranks ~${max_mpi} > logical CPUs ${cpu_count}. Consider reducing --batch-jobs or stage case jobs."
            fi
        elif (( BATCH_JOBS > 1 )); then
            warn "Batch and case parallelism are both enabled. MPI ranks/case could not be detected; actual load is batch_jobs x case_jobs x numberOfSubdomains."
        fi
    fi
}

print_batch_plan() {
    local input_csv_abs="$1"
    local batch_number="$2"
    local batch_dir="${OUTPUT_ROOT}/batch_${batch_number}"
    local csv_basename
    local batch_csv_path
    local local_batch_csv
    local -a job_args=()
    local post_script=""

    csv_basename="$(basename -- "$input_csv_abs")"
    local_batch_csv="${batch_dir}/${csv_basename}"

    info "------------------------------------------------------------"
    info "DRY-RUN batch_${batch_number}"
    info "Input CSV       : $input_csv_abs"
    info "Destination     : $batch_dir"
    info "Selected stages : $(selected_stage_summary)"

    if (( RUN_SETUP == 1 )); then
        batch_csv_path="$local_batch_csv"
        if [[ -d "$batch_dir" && "$OVERWRITE" == "1" ]]; then
            print_command rm -rf -- "$batch_dir"
        fi
        print_command mkdir -p -- "$batch_dir"
        print_command cp -a --reflink=auto "${MASTER_BATCH_DIR}/." "${batch_dir}/"
        print_command cp -f -- "$input_csv_abs" "$batch_csv_path"
    else
        if [[ -f "$local_batch_csv" ]]; then
            batch_csv_path="$local_batch_csv"
        else
            batch_csv_path="$input_csv_abs"
            info "Batch CSV copy  : not present; selected stages will use source CSV directly"
        fi
    fi

    if (( RUN_SETUP == 1 )); then build_job_args setup; post_script="$(stage_script_path setup_cases.sh "$batch_dir")"; print_command bash "$post_script" -i "$batch_csv_path" -O "$batch_dir" "${STAGE_JOB_ARGS[@]}"; fi
    if (( RUN_MESH == 1 )); then build_job_args mesh; post_script="$(stage_script_path run_mesh_cases.sh "$batch_dir")"; print_command bash "$post_script" -i "$batch_csv_path" -O "$batch_dir" "${STAGE_JOB_ARGS[@]}"; fi
    if (( RUN_FLOW == 1 )); then build_job_args flow; post_script="$(stage_script_path run_flow_cases.sh "$batch_dir")"; print_command bash "$post_script" -i "$batch_csv_path" -O "$batch_dir" "${STAGE_JOB_ARGS[@]}"; fi
    if (( RUN_TRANSPORT == 1 )); then build_job_args transport; post_script="$(stage_script_path run_transport_cases.sh "$batch_dir")"; print_command bash "$post_script" -i "$batch_csv_path" -O "$batch_dir" "${STAGE_JOB_ARGS[@]}" --save-times "$SAVE_TIMES"; fi

    if (( RUN_POST == 1 )); then
        post_script="$(post_script_path "$batch_dir" || true)"
        [[ -z "$post_script" ]] || { build_job_args post; print_command bash "$post_script" -i "$batch_csv_path" -O "$batch_dir" "${STAGE_JOB_ARGS[@]}"; }
    fi
}

# run_batch_inner runs inside the run_batch subshell. The subshell keeps the
# per-batch cd and the exported per-batch environment contained.
run_batch_inner() {
    local input_csv_abs="$1"
    local batch_number="$2"
    local ordinal="$3"
    local total="$4"
    local csv_basename
    local batch_dir
    local batch_csv_path
    local local_batch_csv
    local post_script=""
    local -a job_args=()
    local stage_status=0

    csv_basename="$(basename -- "$input_csv_abs")"
    batch_dir="${OUTPUT_ROOT}/batch_${batch_number}"
    local_batch_csv="${batch_dir}/${csv_basename}"

    info "============================================================"
    info "Batch ${ordinal}/${total}: batch_${batch_number}"
    info "Input CSV       : $input_csv_abs"
    info "Batch directory : $batch_dir"
    info "Selected stages : $(selected_stage_summary)"

    if (( RUN_SETUP == 1 )); then
        # v4 Section 7.1: overwrite removes every existing destination, empty
        # or non-empty, before template initialization.
        if [[ -d "$batch_dir" ]]; then
            if [[ "$OVERWRITE" == "1" ]]; then
                info "Overwrite enabled: removing $batch_dir"
                rm -rf -- "$batch_dir" || {
                    error "Failed to remove batch directory: $batch_dir"
                    return 1
                }
            elif [[ -n "$(find "$batch_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
                error "Batch directory became non-empty after preflight: $batch_dir"
                return 1
            fi
        fi

        mkdir -p -- "$batch_dir" || {
            error "Failed to create batch directory: $batch_dir"
            return 1
        }

        info "Copy template   : $MASTER_BATCH_DIR -> $batch_dir"
        cp -a --reflink=auto "${MASTER_BATCH_DIR}/." "${batch_dir}/" || {
            error "Failed to copy master batch template into: $batch_dir"
            return 1
        }

        info "Copy CSV        : $csv_basename"
        cp -f -- "$input_csv_abs" "$local_batch_csv" || {
            error "Failed to copy CSV into batch directory: $local_batch_csv"
            return 1
        }
        batch_csv_path="$local_batch_csv"
    else
        if [[ -f "$local_batch_csv" ]]; then
            batch_csv_path="$local_batch_csv"
            info "Reuse batch CSV : $batch_csv_path"
        else
            batch_csv_path="$input_csv_abs"
            warn "No CSV copy found in batch directory; using source CSV directly: $batch_csv_path"
        fi
    fi

    cd -- "$batch_dir" || {
        error "Cannot enter batch directory: $batch_dir"
        return 1
    }

    export BATCH_CSV="$csv_basename"
    export BATCH_CSV_PATH="$batch_csv_path"
    export BATCH_NUMBER="$batch_number"
    export BATCH_DIR="$batch_dir"
    export SCALAR_FIELD

    if (( RUN_SETUP == 1 )); then
        build_job_args setup
        post_script="$(stage_script_path setup_cases.sh "$PWD")"
        run_stage "$post_script" \
            -i "$BATCH_CSV_PATH" \
            -O "$BATCH_DIR" \
            "${STAGE_JOB_ARGS[@]}" || {
            stage_status=$?
            report_record_stage "$ordinal" setup failed
            return "$stage_status"
        }
        report_record_stage "$ordinal" setup succeeded
    fi

    if (( RUN_MESH == 1 )); then
        build_job_args mesh
        post_script="$(stage_script_path run_mesh_cases.sh "$PWD")"
        run_stage "$post_script" \
            -i "$BATCH_CSV_PATH" \
            -O "$BATCH_DIR" \
            "${STAGE_JOB_ARGS[@]}" || {
            stage_status=$?
            report_record_stage "$ordinal" mesh failed
            return "$stage_status"
        }
        report_record_stage "$ordinal" mesh succeeded
    fi

    if (( RUN_FLOW == 1 )); then
        build_job_args flow
        post_script="$(stage_script_path run_flow_cases.sh "$PWD")"
        run_stage "$post_script" \
            -i "$BATCH_CSV_PATH" \
            -O "$BATCH_DIR" \
            "${STAGE_JOB_ARGS[@]}" || {
            stage_status=$?
            report_record_stage "$ordinal" flow failed
            return "$stage_status"
        }
        report_record_stage "$ordinal" flow succeeded
    fi

    if (( RUN_TRANSPORT == 1 )); then
        build_job_args transport
        post_script="$(stage_script_path run_transport_cases.sh "$PWD")"
        run_stage "$post_script" \
            -i "$BATCH_CSV_PATH" \
            -O "$BATCH_DIR" \
            "${STAGE_JOB_ARGS[@]}" \
            --save-times "$SAVE_TIMES" || {
            stage_status=$?
            report_record_stage "$ordinal" transport failed
            return "$stage_status"
        }
        report_record_stage "$ordinal" transport succeeded
    fi

    if (( RUN_POST == 1 )); then
        if post_script="$(post_script_path "$PWD")"; then
            build_job_args post
            run_stage "$post_script" \
                -i "$BATCH_CSV_PATH" \
                -O "$BATCH_DIR" \
                "${STAGE_JOB_ARGS[@]}" || {
                stage_status=$?
                report_record_stage "$ordinal" post failed
                return "$stage_status"
            }
            report_record_stage "$ordinal" post succeeded
        elif (( POST_REQUIRED == 1 )); then
            error "Requested post-processing stage script not found in master or batch directory: $PWD"
            report_record_stage "$ordinal" post failed
            return 127
        else
            warn "No post-processing script found in batch directory. Skip."
        fi
    fi

}

run_batch() (
    local batch_number="$2"
    local ordinal="$3"
    local started=$SECONDS
    local rc=0

    run_batch_inner "$@" || rc=$?

    # v4 Section 19: successful and failed batches report elapsed time. The
    # original child failure status is preserved.
    if (( rc != 0 )); then
        report_record_batch "$ordinal" "$batch_number" failed
        error "Batch failed    : batch_${batch_number} (exit=${rc}, elapsed=$(format_seconds "$(( SECONDS - started ))"))"
        return "$rc"
    fi
    report_record_batch "$ordinal" "$batch_number" succeeded
    info "Batch finished  : batch_${batch_number} ($(format_seconds "$(( SECONDS - started ))"))"
)

run_all_batches_sequential() {
    local i
    local rc
    local failures=0
    local total="${#INPUT_CSVS_ABS[@]}"

    for (( i = 0; i < total; i++ )); do
        if run_batch "${INPUT_CSVS_ABS[$i]}" "${BATCH_NUMBERS[$i]}" "$(( i + 1 ))" "$total"; then
            :
        else
            rc=$?
            (( failures += 1 ))
            error "Batch failed: batch_${BATCH_NUMBERS[$i]} (exit=$rc)"
            if (( KEEP_GOING == 0 )); then
                error "Stop after first failed batch. Use --keep-going to continue other batches."
                return "$rc"
            fi
        fi
    done

    (( failures == 0 )) || {
        error "$failures batch(es) failed."
        return 1
    }
}

run_all_batches_parallel() {
    local i
    local running=0
    local failures=0
    local launched=0
    local total="${#INPUT_CSVS_ABS[@]}"

    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        die "--batch-jobs > 1 requires Bash >= 4.3. Current: ${BASH_VERSION}"
    fi

    info "Batch-level parallel execution enabled: max $BATCH_JOBS concurrent batches"

    for (( i = 0; i < total; i++ )); do
        run_batch "${INPUT_CSVS_ABS[$i]}" "${BATCH_NUMBERS[$i]}" "$(( i + 1 ))" "$total" &
        (( running += 1 ))
        (( launched += 1 ))

        if (( running >= BATCH_JOBS )); then
            if wait -n; then
                :
            else
                (( failures += 1 ))
            fi
            running=$(( running - 1 ))

            if (( failures > 0 && KEEP_GOING == 0 )); then
                warn "A batch failed. Stop launching new batches; already-running batches will finish."
                break
            fi
        fi
    done

    while (( running > 0 )); do
        if wait -n; then
            :
        else
            (( failures += 1 ))
        fi
        running=$(( running - 1 ))
    done

    if (( launched < total )); then
        warn "$(( total - launched )) batch(es) were not started because a previous batch failed."
    fi

    (( failures == 0 && launched == total )) || {
        error "Parallel batch execution did not complete successfully: failures=$failures, launched=$launched/$total"
        return 1
    }
}

# =============================================================================
# Consolidated end-of-run report (v4 Section 19)
# =============================================================================
#
# The report states the actual execution result of each batch and of each
# selected stage. A batch runs in a subshell, and parallel batches run as
# background jobs, so a result cannot return through a shell variable. One
# temporary directory holds the execution record. The directory belongs to one
# Orchestrator process, stays outside every Batch Workspace, and is removed when
# the Orchestrator exits. The presence of a stage summary is never execution
# evidence, because a reused Batch Workspace can hold a stale summary.

REPORT_DIR=""

report_init() {
    REPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run_batch_report.XXXXXXXX")" ||
        die "Cannot create the temporary run-report directory."
}

# report_cleanup keeps the original process status. A failed removal gives a
# warning only.
report_cleanup() {
    local status=$?

    [[ -n "$REPORT_DIR" && -d "$REPORT_DIR" ]] || return "$status"

    rm -rf -- "$REPORT_DIR" ||
        warn "Could not remove the temporary run-report directory: $REPORT_DIR"

    return "$status"
}

# report_record_batch <ordinal> <batch_number> <succeeded|failed>
report_record_batch() {
    [[ -n "$REPORT_DIR" ]] || return 0

    printf '%s\n' "$3" > "${REPORT_DIR}/batch.${1}.result" 2>/dev/null ||
        warn "Could not record the run-report result of batch_${2}."
}

# report_record_stage <ordinal> <stage_key> <succeeded|failed>
report_record_stage() {
    [[ -n "$REPORT_DIR" ]] || return 0

    printf '%s\n' "$3" > "${REPORT_DIR}/stage.${1}.${2}.result" 2>/dev/null ||
        warn "Could not record the run-report result of stage ${2}."
}

# report_selected_stage_keys prints the selected stage keys in canonical order.
report_selected_stage_keys() {
    (( RUN_SETUP == 0 )) || printf 'setup\n'
    (( RUN_MESH == 0 )) || printf 'mesh\n'
    (( RUN_FLOW == 0 )) || printf 'flow\n'
    (( RUN_TRANSPORT == 0 )) || printf 'transport\n'
    (( RUN_POST == 0 )) || printf 'post\n'
}

report_stage_name() {
    case "$1" in
        post) printf 'post-processing\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

report_stage_summary_file() {
    case "$1" in
        setup) printf 'setup_cases_summary.csv\n' ;;
        mesh) printf 'run_mesh_cases_summary.csv\n' ;;
        flow) printf 'run_flow_cases_summary.csv\n' ;;
        transport) printf 'run_transport_cases_summary.csv\n' ;;
        post) printf 'run_post_processing_cases_summary.csv\n' ;;
    esac
}

# report_stage_columns <stage_key> prints "case row status message".
# A row value of 0 means that the summary has no row-number column.
report_stage_columns() {
    case "$1" in
        setup) printf '3 2 9 10\n' ;;
        post) printf '1 0 3 4\n' ;;
        *) printf '3 2 6 7\n' ;;
    esac
}

# report_stage_success_status <stage_key> prints the success status values.
report_stage_success_status() {
    case "$1" in
        setup) printf 'created dry_run\n' ;;
        mesh) printf 'meshed continued\n' ;;
        post) printf 'completed\n' ;;
        *) printf 'solved continued\n' ;;
    esac
}

# report_summary_counts <summary> <status_column> <success_values>
# prints "total succeeded skipped failed other".
report_summary_counts() {
    awk -F, -v column="$2" -v success_values="$3" '
        function clean(value) {
            gsub(/"/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        BEGIN {
            count = split(success_values, values, " ")
            for (i = 1; i <= count; i++) success[values[i]] = 1
        }
        NR == 1 { next }
        /^[[:space:]]*$/ { next }
        {
            status = clean($column)
            total++
            if (status in success) succeeded++
            else if (status == "skipped") skipped++
            else if (status == "failed") failed++
            else other++
        }
        END {
            printf "%d %d %d %d %d\n", total + 0, succeeded + 0, skipped + 0,
                failed + 0, other + 0
        }' "$1"
}

# report_failed_rows <summary> <case_col> <row_col> <status_col> <message_col>
# prints "row_number<TAB>case_id<TAB>message" for each failed row. The order is
# numeric row number, then Case ID.
report_failed_rows() {
    awk -F, -v case_column="$2" -v row_column="$3" -v status_column="$4" \
            -v message_column="$5" '
        function clean(value) {
            gsub(/"/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        NR == 1 { next }
        /^[[:space:]]*$/ { next }
        clean($status_column) == "failed" {
            message = ""
            for (i = message_column; i <= NF; i++) {
                message = (message == "" ? $i : message "," $i)
            }
            row = (row_column > 0 ? clean($row_column) : "0")
            if (row !~ /^[0-9]+$/) row = "0"
            printf "%s\t%s\t%s\n", row, clean($case_column), clean(message)
        }' "$1" |
        LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2
}

# report_log_path <message> prints the first absolute path of the summary
# message. The report never builds a path.
report_log_path() {
    local path

    path="$(printf '%s\n' "$1" |
        awk '{ for (i = 1; i <= NF; i++) if (substr($i, 1, 1) == "/") { print $i; exit } }')"

    printf '%s\n' "${path:-unavailable}"
}

print_run_report() {
    local requested_count="${#INPUT_CSVS_ABS[@]}"
    local attempted=0 succeeded=0 failed=0 not_started=0
    local i ordinal batch_id batch_result
    local stage_key stage_name stage_result summary_path summary_state
    local total_count succeeded_count skipped_count failed_count other_count
    local case_column row_column status_column message_column
    local row_number case_id message log_path

    info "Run report begin"

    for (( i = 0; i < requested_count; i++ )); do
        ordinal=$(( i + 1 ))
        batch_id="${BATCH_NUMBERS[$i]}"

        # A batch without an execution record never started.
        if [[ ! -f "${REPORT_DIR}/batch.${ordinal}.result" ]]; then
            not_started=$(( not_started + 1 ))
            continue
        fi

        batch_result="$(cat "${REPORT_DIR}/batch.${ordinal}.result")"
        attempted=$(( attempted + 1 ))
        if [[ "$batch_result" == "succeeded" ]]; then
            succeeded=$(( succeeded + 1 ))
        else
            failed=$(( failed + 1 ))
        fi

        info "Run report batch: batch_${batch_id} result=${batch_result}"

        while IFS= read -r stage_key; do
            stage_name="$(report_stage_name "$stage_key")"

            stage_result="not_attempted"
            if [[ -f "${REPORT_DIR}/stage.${ordinal}.${stage_key}.result" ]]; then
                stage_result="$(cat "${REPORT_DIR}/stage.${ordinal}.${stage_key}.result")"
            fi

            summary_state="unavailable"
            total_count="unknown"
            succeeded_count="unknown"
            skipped_count="unknown"
            failed_count="unknown"
            other_count="unknown"

            summary_path="${OUTPUT_ROOT}/batch_${batch_id}/$(report_stage_summary_file "$stage_key")"
            read -r case_column row_column status_column message_column \
                <<< "$(report_stage_columns "$stage_key")"

            # A stage that did not run never contributes summary counts, even
            # when a stale summary exists in a reused Batch Workspace.
            if [[ "$stage_result" != "not_attempted" && -r "$summary_path" ]]; then
                summary_state="available"
                read -r total_count succeeded_count skipped_count failed_count other_count \
                    <<< "$(report_summary_counts "$summary_path" "$status_column" \
                        "$(report_stage_success_status "$stage_key")")"
            fi

            info "Run report stage: batch=batch_${batch_id} stage=${stage_name} result=${stage_result} summary=${summary_state} total=${total_count} succeeded=${succeeded_count} skipped=${skipped_count} failed=${failed_count} other=${other_count}"

            [[ "$summary_state" == "available" ]] || continue

            while IFS=$'\t' read -r row_number case_id message; do
                [[ -n "${row_number}${case_id}${message}" ]] || continue
                log_path="$(report_log_path "$message")"
                info "Run report failure: batch=batch_${batch_id} stage=${stage_name} case=${case_id:-unavailable} log=${log_path}"
            done < <(report_failed_rows "$summary_path" "$case_column" "$row_column" \
                "$status_column" "$message_column")
        done < <(report_selected_stage_keys)
    done

    info "Run report total: requested=${requested_count} attempted=${attempted} succeeded=${succeeded} failed=${failed} not_started=${not_started}"
    info "Run report end"
}

# =============================================================================
# Advisory selected-Stage tool preflight (v4 Section 5.1)
# =============================================================================
#
# The advisory names missing commands for the selected stages before stage 1.
# The advisory is read-only: it never runs a stage command, never writes into a
# Batch Workspace, and never changes a status. Every stage runner keeps its own
# final command validation.

TOOL_ADVISORY_MISSING=0
TOOL_ADVISORY_UNDETECTED=0

tool_available() {
    command -v "$1" >/dev/null 2>&1
}

# advise_missing_command <stage> <command>
advise_missing_command() {
    if tool_available "$2"; then
        return 0
    fi

    warn "Selected-Stage tool advisory: stage=${1} command=${2} status=missing"
    TOOL_ADVISORY_MISSING=$(( TOOL_ADVISORY_MISSING + 1 ))
}

# tool_advisory_case_id <raw> applies the stage runner Case ID rule.
tool_advisory_case_id() {
    local value

    value="$(printf '%s' "${1//$'\r'/}" |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
            -e 's/[[:space:]]\+/_/g' -e 's/[^0-9A-Za-z._-]/_/g' \
            -e 's/_\+/_/g' -e 's/^_//; s/_$//')"

    [[ -n "$value" ]] || value="NA"

    if [[ "$value" == "NA" || "$value" == case_* ]]; then
        printf '%s\n' "$value"
        return 0
    fi

    printf 'case_%s\n' "$value"
}

# orchestrator_case_column <csv> prints the 1-based index of the
# case-insensitive Case column, or nothing when the column does not exist. The
# selected-Stage advisory and the read-only status mode share this lookup.
orchestrator_case_column() {
    awk -F, 'NR == 1 {
            for (i = 1; i <= NF; i++) {
                value = $i
                gsub(/\r/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                if (tolower(value) == "case") { print i; exit }
            }
        }' "$1"
}

# tool_advisory_case_ids <csv> prints each unique normalized Case ID in DOE
# Batch CSV row order. The advisory uses the existing simple CSV assumptions.
tool_advisory_case_ids() {
    local csv="$1" column line raw case_id
    local -A seen=()

    column="$(orchestrator_case_column "$csv")"

    [[ -n "$column" ]] || return 0

    while IFS= read -r line; do
        line="${line//$'\r'/}"
        [[ -n "${line//[[:space:]]/}" ]] || continue

        raw="$(printf '%s\n' "$line" | awk -F, -v c="$column" '{ print $c }')"
        [[ -n "${raw//[[:space:]]/}" ]] || continue

        case_id="$(tool_advisory_case_id "$raw")"
        [[ "$case_id" != "NA" ]] || continue
        [[ -z "${seen[$case_id]:-}" ]] || continue

        seen["$case_id"]=1
        printf '%s\n' "$case_id"
    done < <(tail -n +2 "$csv")
}

tool_advisory_has_nonzero_time_dir() {
    local name

    while IFS= read -r name; do
        [[ "$name" != "0" ]] || continue
        [[ "$name" =~ ^[0-9]+([.][0-9]+)?$ || "$name" =~ ^[.][0-9]+$ ]] && return 0
    done < <(find "$1" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null)

    return 1
}

# tool_advisory_case_is_continue <flow_case_dir> applies the Section 15.3 rule.
tool_advisory_case_is_continue() {
    local dir="$1"

    [[ -d "${dir}/constant/polyMesh" &&
        -f "${dir}/constant/polyMesh/points" &&
        -f "${dir}/constant/polyMesh/boundary" ]] || return 1

    [[ -f "${dir}/restart.marker" ]] && return 0

    tool_advisory_has_nonzero_time_dir "$dir"
}

# tool_advisory_mesh_is_fresh is true when at least one eligible mesh Case needs
# a fresh mesh.
tool_advisory_mesh_is_fresh() {
    local i batch_dir case_id

    # Setup initializes each Batch Workspace, so every Case meshes fresh.
    (( RUN_SETUP == 0 )) || return 0
    [[ "${FORCE_MESH:-0}" != "1" ]] || return 0

    for (( i = 0; i < ${#INPUT_CSVS_ABS[@]}; i++ )); do
        batch_dir="${OUTPUT_ROOT}/batch_${BATCH_NUMBERS[$i]}"
        while IFS= read -r case_id; do
            [[ -d "${batch_dir}/${case_id}/flow" ]] || continue
            tool_advisory_case_is_continue "${batch_dir}/${case_id}/flow" || return 0
        done < <(tool_advisory_case_ids "${INPUT_CSVS_ABS[$i]}")
    done

    return 1
}

# tool_advisory_application <control_dict> prints the detected solver, or
# nothing when the Orchestrator cannot read it. The advisory never falls back to
# a default solver name.
tool_advisory_application() {
    local file="$1" value

    [[ -r "$file" ]] || return 0
    tool_available foamDictionary || return 0

    value="$(foamDictionary -entry application -value "$file" 2>/dev/null || true)"
    printf '%s' "$value" | tr -d '\r' | tr -d '";' | awk '{ $1 = $1; print }'
}

# tool_advisory_flow_solvers inspects the solver of each eligible flow Case, in
# DOE Batch CSV argument order and then DOE Batch CSV row order.
tool_advisory_flow_solvers() {
    local i batch_id batch_dir case_id control_dict solver

    for (( i = 0; i < ${#INPUT_CSVS_ABS[@]}; i++ )); do
        batch_id="${BATCH_NUMBERS[$i]}"
        batch_dir="${OUTPUT_ROOT}/batch_${batch_id}"

        while IFS= read -r case_id; do
            if (( RUN_SETUP == 1 )); then
                # Setup creates each future Case from the master flow template.
                control_dict="${MASTER_BATCH_DIR}/simpleFoam_files/system/controlDict"
            else
                # A Case without a flow directory is skipped by the stage runner.
                [[ -d "${batch_dir}/${case_id}/flow" ]] || continue
                control_dict="${batch_dir}/${case_id}/flow/system/controlDict"
            fi

            solver="$(tool_advisory_application "$control_dict")"

            if [[ -z "$solver" ]]; then
                warn "Selected-Stage tool advisory: stage=flow batch=batch_${batch_id} case=${case_id} application=undetected controlDict=${control_dict}"
                TOOL_ADVISORY_UNDETECTED=$(( TOOL_ADVISORY_UNDETECTED + 1 ))
                continue
            fi

            tool_available "$solver" && continue

            warn "Selected-Stage tool advisory: stage=flow batch=batch_${batch_id} case=${case_id} command=${solver} status=missing"
            TOOL_ADVISORY_MISSING=$(( TOOL_ADVISORY_MISSING + 1 ))
        done < <(tool_advisory_case_ids "${INPUT_CSVS_ABS[$i]}")
    done
}

# tool_advisory_post_available is true when a post-processing stage runner is
# resolvable. Existing behavior skips an optional post-processing stage that has
# no stage runner, so that stage needs no command.
tool_advisory_post_available() {
    local i batch_dir

    if [[ -d "$MASTER_BATCH_DIR" ]] &&
        find_post_script_in_dir "$MASTER_BATCH_DIR" >/dev/null 2>&1; then
        return 0
    fi

    for (( i = 0; i < ${#BATCH_NUMBERS[@]}; i++ )); do
        batch_dir="${OUTPUT_ROOT}/batch_${BATCH_NUMBERS[$i]}"
        if find_post_script_in_dir "$batch_dir" >/dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}

run_tool_advisory() {
    TOOL_ADVISORY_MISSING=0
    TOOL_ADVISORY_UNDETECTED=0

    if (( RUN_SETUP == 1 )); then
        advise_missing_command setup surfaceCheck
        advise_missing_command setup surfaceTransformPoints
        advise_missing_command setup foamDictionary
    fi

    if (( RUN_MESH == 1 )); then
        if tool_advisory_mesh_is_fresh; then
            advise_missing_command mesh surfaceFeatureExtract
            advise_missing_command mesh blockMesh
            advise_missing_command mesh decomposePar
            advise_missing_command mesh mpirun
            advise_missing_command mesh snappyHexMesh
            advise_missing_command mesh reconstructParMesh
            advise_missing_command mesh checkMesh
        fi
        advise_missing_command mesh foamDictionary
    fi

    if (( RUN_FLOW == 1 )); then
        advise_missing_command flow decomposePar
        advise_missing_command flow mpirun
        advise_missing_command flow renumberMesh
        advise_missing_command flow checkMesh
        advise_missing_command flow foamDictionary
        tool_advisory_flow_solvers

        # RECONSTRUCT_MODE=none never calls reconstructPar.
        if [[ "${RECONSTRUCT_MODE:-latest}" != "none" ]]; then
            advise_missing_command flow reconstructPar
        fi
    fi

    if (( RUN_TRANSPORT == 1 )); then
        advise_missing_command transport decomposePar
        advise_missing_command transport mpirun
        advise_missing_command transport renumberMesh
        # The transport solver is fixed. The Orchestrator always forwards a
        # non-empty --save-times value, so transport reconstructs custom times.
        advise_missing_command transport scalarTransportDeffFoam
        advise_missing_command transport reconstructPar
        advise_missing_command transport foamDictionary
    fi

    # A skipped optional post-processing stage has no required command.
    if (( RUN_POST == 1 )) && tool_advisory_post_available; then
        advise_missing_command post-processing foamToVTK
    fi

    (( TOOL_ADVISORY_MISSING > 0 || TOOL_ADVISORY_UNDETECTED > 0 )) || return 0

    warn "Selected-Stage tool advisory summary: missing=${TOOL_ADVISORY_MISSING} undetected=${TOOL_ADVISORY_UNDETECTED}. Execution continues."
}

# =============================================================================
# Read-only status mode (v4 Section 6.7)
# =============================================================================
#
# Status mode observes the existing Stage marker state of each valid unique
# Case. Status mode writes nothing, resolves no stage runner, runs no OpenFOAM
# command, and prints no execution diagnostic. Status mode reports marker
# presence only. Marker presence is not proof of stage success.

STATUS_MODE=0
STATUS_CONFLICT_OPTION=""

# The `--status` help text lives in its own function, so that the existing
# usage() text and every existing help entry stay unchanged.
usage_status() {
    cat <<'EOF_STATUS'

Read-only status mode:
  --status                Report the existing stage marker state of each Case
                           and exit. Status mode writes nothing, runs no stage
                           script, and runs no OpenFOAM command.

                           Usage:
                             bash run_batch.sh --status [-o <DIR>] <batch_csv> [<batch_csv> ...]

                           Compatible options: -o, --output-dir, -h, --help, --
                           Compatible environment: RUN_BATCH_OUTPUT_DIR

                           --status cannot be combined with an execution option:
                             -s, --stage, --stages, -j, --jobs, --setup-jobs,
                             --mesh-jobs, --flow-jobs, --transport-jobs,
                             --post-jobs, -B, --batch-jobs, -m, --master-dir,
                             -f, --overwrite, --keep-going, --skip-post,
                             --save-times, --scalar-field, -n, --dry-run

                           Each batch_<id> directory must already exist.
                           Reported state is marker presence only. It does not
                           prove that stage output is valid or current.
EOF_STATUS
}

usage_full() {
    usage
    usage_status
}

status_dir_state() {
    if [[ -d "$1" ]]; then
        printf 'present\n'
        return 0
    fi
    printf 'absent\n'
}

status_file_state() {
    if [[ -f "$1" ]]; then
        printf 'present\n'
        return 0
    fi
    printf 'absent\n'
}

# status_validate collects every accepted DOE Batch CSV and Batch ID. Validation
# finishes for every requested batch before the report starts.
status_validate() {
    local input input_abs filename batch_number batch_dir local_batch_csv
    local -A seen_batch_dirs=()

    OUTPUT_ROOT="$(canonicalize_path "$OUTPUT_ROOT")"

    STATUS_CSVS=()
    STATUS_BATCHES=()

    for input in "${INPUT_CSVS[@]}"; do
        input_abs="$(canonicalize_existing_file "$input" || true)"
        [[ -n "$input_abs" ]] || die "Batch CSV not found: $input"

        filename="$(basename -- "$input_abs")"
        [[ "${filename,,}" == *.csv ]] ||
            die "Input must have a .csv extension: $input_abs"

        batch_number="$(extract_batch_number "$filename" || true)"
        [[ -n "$batch_number" ]] ||
            die "Cannot determine batch ID from filename: $filename. Recommended form: output_batch_<id>.csv"

        batch_dir="${OUTPUT_ROOT}/batch_${batch_number}"
        local_batch_csv="${batch_dir}/${filename}"

        if [[ -n "${seen_batch_dirs[$batch_dir]:-}" ]]; then
            die "Duplicate batch destination detected: $batch_dir. Inputs '${seen_batch_dirs[$batch_dir]}' and '$input_abs' resolve to the same batch ID."
        fi
        seen_batch_dirs["$batch_dir"]="$input_abs"

        [[ -d "$batch_dir" ]] ||
            die "Existing batch directory required for --status: $batch_dir"

        [[ -n "$(find "$batch_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] ||
            die "Existing batch directory is empty: $batch_dir"

        if [[ -f "$local_batch_csv" && "$input_abs" != "$local_batch_csv" ]]; then
            cmp -s -- "$input_abs" "$local_batch_csv" ||
                die "CSV mismatch for existing batch_${batch_number}: '$input_abs' differs from '$local_batch_csv'. Use the CSV that created this batch or run setup again with --overwrite."
        fi

        # Status mode cannot build its per-Case report without a Case column.
        [[ -n "$(orchestrator_case_column "$input_abs")" ]] ||
            die "Required column not found in $input_abs: Case"

        STATUS_CSVS+=("$input_abs")
        STATUS_BATCHES+=("$batch_number")
    done
}

run_status_mode() {
    local i batch_number batch_dir case_id case_root case_count=0

    status_validate

    info "Status report begin"

    for (( i = 0; i < ${#STATUS_CSVS[@]}; i++ )); do
        batch_number="${STATUS_BATCHES[$i]}"
        batch_dir="${OUTPUT_ROOT}/batch_${batch_number}"

        while IFS= read -r case_id; do
            case_root="${batch_dir}/${case_id}"
            info "Status report case: batch=batch_${batch_number} case=${case_id} case_dir=$(status_dir_state "$case_root") mesh_restart_marker=$(status_file_state "${case_root}/flow/restart.marker") flow_marker=$(status_file_state "${case_root}/flow/flow.marker") transport_marker=$(status_file_state "${case_root}/trd/transport.marker") post_signature=$(status_file_state "${case_root}/vtk/post_processing.complete")"
            case_count=$(( case_count + 1 ))
        done < <(tool_advisory_case_ids "${STATUS_CSVS[$i]}")
    done

    info "Status report total: batches=${#STATUS_CSVS[@]} cases=${case_count}"
    info "Status report end"
}

main() {
    local end_of_options=0

    (( $# >= 1 )) || {
        usage_full
        exit 1
    }

    while (( $# > 0 )); do
        if (( end_of_options == 1 )); then
            INPUT_CSVS+=("$1")
            shift
            continue
        fi

        case "$1" in
            # Record the first execution option that the user supplies, so that
            # a --status conflict never comes from an environment value.
            -s|--stage|--stages|-j|--jobs|--setup-jobs|--mesh-jobs|--flow-jobs| \
            --transport-jobs|--post-jobs|-B|--batch-jobs|-m|--master-dir| \
            -f|--overwrite|--keep-going|--skip-post|--save-times| \
            --scalar-field|-n|--dry-run)
                [[ -n "$STATUS_CONFLICT_OPTION" ]] || STATUS_CONFLICT_OPTION="$1"
                ;;&
            --status)
                STATUS_MODE=1
                shift
                ;;
            -s|--stage|--stages)
                (( $# >= 2 )) || die "$1 requires a stage name or comma-separated stage list."
                STAGE_TOKENS+=("$2")
                shift 2
                ;;
            -j|--jobs)
                (( $# >= 2 )) || die "$1 requires a value."
                PARALLEL_JOBS="$2"
                shift 2
                ;;
            --setup-jobs)
                (( $# >= 2 )) || die "$1 requires a value."
                SETUP_JOBS="$2"; shift 2 ;;
            --mesh-jobs)
                (( $# >= 2 )) || die "$1 requires a value."
                MESH_JOBS="$2"; shift 2 ;;
            --flow-jobs)
                (( $# >= 2 )) || die "$1 requires a value."
                FLOW_JOBS="$2"; shift 2 ;;
            --transport-jobs)
                (( $# >= 2 )) || die "$1 requires a value."
                TRANSPORT_JOBS="$2"; shift 2 ;;
            --post-jobs)
                (( $# >= 2 )) || die "$1 requires a value."
                POST_JOBS="$2"; shift 2 ;;
            -B|--batch-jobs)
                (( $# >= 2 )) || die "$1 requires a value."
                BATCH_JOBS="$2"
                shift 2
                ;;
            -m|--master-dir)
                (( $# >= 2 )) || die "$1 requires a directory."
                MASTER_BATCH_DIR="$2"
                shift 2
                ;;
            -o|--output-dir)
                (( $# >= 2 )) || die "$1 requires a directory."
                OUTPUT_ROOT="$2"
                shift 2
                ;;
            -f|--overwrite)
                OVERWRITE=1
                shift
                ;;
            --keep-going)
                KEEP_GOING=1
                shift
                ;;
            --skip-post)
                SKIP_POST=1
                shift
                ;;
            --save-times)
                (( $# >= 2 )) || die "$1 requires a comma-separated list."
                SAVE_TIMES="$2"
                shift 2
                ;;
            --scalar-field)
                (( $# >= 2 )) || die "$1 requires a field name."
                SCALAR_FIELD="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage_full
                exit 0
                ;;
            --)
                end_of_options=1
                shift
                ;;
            -*)
                die "Unknown option: $1. Use -h for help."
                ;;
            *)
                INPUT_CSVS+=("$1")
                shift
                ;;
        esac
    done

    if (( STATUS_MODE == 1 )); then
        [[ -z "$STATUS_CONFLICT_OPTION" ]] ||
            die "--status cannot be combined with ${STATUS_CONFLICT_OPTION}."

        (( ${#INPUT_CSVS[@]} >= 1 )) || {
            usage_full
            exit 1
        }

        run_status_mode
        exit 0
    fi

    (( ${#INPUT_CSVS[@]} >= 1 )) || {
        usage_full
        exit 1
    }

    if [[ -n "$PARALLEL_JOBS" ]]; then
        require_positive_integer "$PARALLEL_JOBS" "--jobs"
    fi
    [[ -z "$SETUP_JOBS" ]] || require_positive_integer "$SETUP_JOBS" "--setup-jobs"
    [[ -z "$MESH_JOBS" ]] || require_positive_integer "$MESH_JOBS" "--mesh-jobs"
    [[ -z "$FLOW_JOBS" ]] || require_positive_integer "$FLOW_JOBS" "--flow-jobs"
    [[ -z "$TRANSPORT_JOBS" ]] || require_positive_integer "$TRANSPORT_JOBS" "--transport-jobs"
    [[ -z "$POST_JOBS" ]] || require_positive_integer "$POST_JOBS" "--post-jobs"
    require_positive_integer "$BATCH_JOBS" "--batch-jobs"

    [[ "$OVERWRITE" == "0" || "$OVERWRITE" == "1" ]] ||
        die "RUN_BATCH_OVERWRITE must be 0 or 1; got: $OVERWRITE"

    [[ "$SAVE_TIMES" =~ ^[0-9]+(,[0-9]+)*$ ]] ||
        die "--save-times must be comma-separated non-negative integers, e.g. 60,120,300; got: $SAVE_TIMES"
    [[ "$SCALAR_FIELD" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
        die "--scalar-field must be a valid OpenFOAM field token; got: $SCALAR_FIELD"

    normalize_stage_selection
    preflight
    run_tool_advisory

    if (( DRY_RUN == 1 )); then
        local i
        local total="${#INPUT_CSVS_ABS[@]}"
        for (( i = 0; i < total; i++ )); do
            print_batch_plan "${INPUT_CSVS_ABS[$i]}" "${BATCH_NUMBERS[$i]}"
        done
        info "DRY-RUN complete. No simulations were run."
        exit 0
    fi

    local scheduler_status=0

    report_init
    trap report_cleanup EXIT

    # The scheduler status is captured so that a failed run still reports.
    if (( BATCH_JOBS == 1 )); then
        run_all_batches_sequential || scheduler_status=$?
    else
        run_all_batches_parallel || scheduler_status=$?
    fi

    print_run_report

    (( scheduler_status == 0 )) || exit "$scheduler_status"

    info "All requested batches and stages finished successfully."
}

main "$@"
