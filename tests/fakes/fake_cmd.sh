#!/usr/bin/env bash
# Fake OpenFOAM command used by the v4 batch-runner contract tests.
#
# One symlink per command name points at this file. The command name comes from
# $0, so every fake records its own exact argument vector and working directory.
#
# The fake writes two records:
#   $FAKE_RECORD_DIR/calls.log       one line per call
#   $FAKE_RECORD_DIR/<n>.<cmd>.rec   one detailed record per call
#
# Side effects stay minimal. Each fake creates only the artifacts that the
# production scripts verify. The fakes must never need an OpenFOAM installation.

set -u

FAKE_US=$'\x1f'
fake_cmd_name="${0##*/}"

: "${FAKE_RECORD_DIR:?FAKE_RECORD_DIR must be set for fake commands}"
mkdir -p "$FAKE_RECORD_DIR"

# ---- recording ---------------------------------------------------------------

fake_record() {
    local lock="${FAKE_RECORD_DIR}/.lockdir"
    local sequence record joined arg

    # Case runners execute in parallel. Serialize the record writes.
    while ! mkdir "$lock" 2>/dev/null; do
        sleep 0.02
    done

    sequence=$(( $(cat "${FAKE_RECORD_DIR}/.sequence" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$sequence" > "${FAKE_RECORD_DIR}/.sequence"

    joined=""
    for arg in "$@"; do
        joined+="${arg}${FAKE_US}"
    done

    printf '%s\t%s\t%s\n' "$fake_cmd_name" "$PWD" "$joined" \
        >> "${FAKE_RECORD_DIR}/calls.log"

    record="${FAKE_RECORD_DIR}/$(printf '%04d' "$sequence").${fake_cmd_name}.rec"
    {
        printf 'cmd=%s\n' "$fake_cmd_name"
        printf 'cwd=%s\n' "$PWD"
        printf 'argc=%s\n' "$#"
        for arg in "$@"; do
            printf 'arg=%s\n' "$arg"
        done
        printf 'env.SCALAR_FIELD=%s\n' "${SCALAR_FIELD:-}"
        printf 'env.RECONSTRUCT_MODE=%s\n' "${RECONSTRUCT_MODE:-}"
        printf 'env.BATCH_NUMBER=%s\n' "${BATCH_NUMBER:-}"
    } > "$record"

    rmdir "$lock"
}

fake_record "$@"

# Forced-failure control for failure-propagation scenarios.
# FAKE_FAIL_COMMANDS holds space-separated command names.
for fake_fail_name in ${FAKE_FAIL_COMMANDS:-}; do
    if [[ "$fake_fail_name" == "$fake_cmd_name" ]]; then
        echo "fake ${fake_cmd_name}: forced failure" >&2
        exit 1
    fi
done

# ---- helpers -----------------------------------------------------------------

fake_has_arg() {
    local wanted="$1" arg
    shift
    for arg in "$@"; do
        [[ "$arg" == "$wanted" ]] && return 0
    done
    return 1
}

# fake_arg_value <flag> <argv...> - print the token after <flag>.
fake_arg_value() {
    local wanted="$1" previous="" arg
    shift
    for arg in "$@"; do
        if [[ "$previous" == "$wanted" ]]; then
            printf '%s\n' "$arg"
            return 0
        fi
        previous="$arg"
    done
    return 1
}

fake_np() {
    local np=""
    if [[ -f system/decomposeParDict ]]; then
        np="$(awk '/^[[:space:]]*numberOfSubdomains[[:space:]]+/ {
                       gsub(/;/, "", $2); print $2; exit
                   }' system/decomposeParDict)"
    fi
    [[ "$np" =~ ^[0-9]+$ ]] || np=2
    printf '%s\n' "$np"
}

fake_make_poly_mesh() {
    local target="$1"
    mkdir -p "$target"
    printf 'FoamFile { class vectorField; object points; }\n' > "${target}/points"
    printf 'FoamFile { class polyBoundaryMesh; object boundary; }\n' > "${target}/boundary"
    printf 'FoamFile { class faceList; object faces; }\n' > "${target}/faces"
    printf 'FoamFile { class labelList; object owner; }\n' > "${target}/owner"
    printf 'FoamFile { class labelList; object neighbour; }\n' > "${target}/neighbour"
}

# fake_solver_times - times that the fake solver writes into processor*/.
fake_solver_times() {
    local times="${FAKE_SOLVER_TIMES:-}"
    if [[ -z "$times" ]]; then
        times="$(awk '/^[[:space:]]*endTime[[:space:]]+/ {
                          gsub(/;/, "", $2); print $2; exit
                      }' system/controlDict 2>/dev/null || true)"
    fi
    [[ -n "$times" ]] || times="1"
    printf '%s\n' "$times"
}

fake_write_time_dir() {
    local target="$1"
    shift
    local field
    mkdir -p "$target"
    for field in "$@"; do
        printf 'FoamFile { object %s; }\n' "$field" > "${target}/${field}"
    done
}

fake_latest_processor_time() {
    [[ -d processor0 ]] || return 1
    find processor0 -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null |
        awk '/^[0-9]+([.][0-9]+)?$|^[.][0-9]+$/' |
        sort -g |
        tail -n 1
}

# ---- per-command behavior ----------------------------------------------------

case "$fake_cmd_name" in

    foamDictionary)
        # Support the exact form used by the production scripts:
        #   foamDictionary -entry <ENTRY> -value <FILE>
        entry="$(fake_arg_value -entry "$@" || true)"
        file="$(fake_arg_value -value "$@" || true)"
        [[ -n "$entry" && -f "${file:-}" ]] || exit 1
        # A dotted entry such as RAS.RASModel resolves by its last component.
        leaf="${entry##*.}"
        value="$(awk -v key="$leaf" '
            $1 == key {
                line = $0
                sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", line)
                sub(/\/\/.*$/, "", line)
                gsub(/;/, "", line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                print line
                exit
            }' "$file")"
        [[ -n "$value" ]] || exit 1
        printf '%s\n' "$value"
        ;;

    foamListTimes)
        # Only the -latestTime form is used by the production scripts.
        if fake_has_arg -latestTime "$@"; then
            find . -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null |
                awk '/^[0-9]+([.][0-9]+)?$|^[.][0-9]+$/ && $0 != "0"' |
                sort -g | tail -n 1
        else
            find . -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null |
                awk '/^[0-9]+([.][0-9]+)?$|^[.][0-9]+$/' | sort -g
        fi
        ;;

    surfaceFeatureExtract)
        mkdir -p constant/extendedFeatureEdgeMesh
        ;;

    blockMesh)
        fake_make_poly_mesh constant/polyMesh
        ;;

    snappyHexMesh)
        # Parallel snappyHexMesh writes the decomposed mesh.
        np="$(fake_np)"
        for (( i = 0; i < np; i++ )); do
            fake_make_poly_mesh "processor${i}/constant/polyMesh"
        done
        fake_make_poly_mesh constant/polyMesh
        ;;

    reconstructParMesh)
        fake_make_poly_mesh constant/polyMesh
        ;;

    checkMesh)
        # The v4 contract generates 0/wallDistance through -writeAllFields.
        if fake_has_arg -writeAllFields "$@"; then
            time_value="$(fake_arg_value -time "$@" || echo 0)"
            fake_write_time_dir "$time_value" wallDistance
        fi
        ;;

    decomposePar)
        np="$(fake_np)"
        for (( i = 0; i < np; i++ )); do
            mkdir -p "processor${i}"
            fake_make_poly_mesh "processor${i}/constant/polyMesh"
            [[ -d 0 ]] && cp -a 0 "processor${i}/0" 2>/dev/null || mkdir -p "processor${i}/0"
        done
        ;;

    renumberMesh)
        ;;

    mpirun)
        # Record the launcher, then run the wrapped command so that the wrapped
        # fake records its own exact argument vector.
        shift_count=0
        args=("$@")
        while (( ${#args[@]} > 0 )); do
            case "${args[0]}" in
                -np|-n|--np) args=("${args[@]:2}") ;;
                -*) args=("${args[@]:1}") ;;
                *) break ;;
            esac
        done
        (( ${#args[@]} > 0 )) || exit 0
        exec "${args[@]}"
        ;;

    simpleFoam|scalarTransportDeffFoam)
        np="$(fake_np)"
        times="$(fake_solver_times)"
        fields=(U p)
        [[ "$fake_cmd_name" == scalarTransportDeffFoam ]] && fields=("${SCALAR_FIELD:-T}" U)
        for (( i = 0; i < np; i++ )); do
            mkdir -p "processor${i}"
            for t in $times; do
                fake_write_time_dir "processor${i}/${t}" "${fields[@]}"
            done
        done
        if [[ -n "${FAKE_SOLVER_FAIL:-}" ]]; then
            echo "fake ${fake_cmd_name}: forced failure" >&2
            exit 1
        fi
        ;;

    reconstructPar)
        if fake_has_arg -time "$@"; then
            wanted="$(fake_arg_value -time "$@")"
            if [[ -d "processor0/${wanted}" ]]; then
                mkdir -p "$wanted"
                cp -a "processor0/${wanted}/." "${wanted}/" 2>/dev/null || true
            fi
        elif fake_has_arg -latestTime "$@"; then
            latest="$(fake_latest_processor_time || true)"
            if [[ -n "$latest" && -d "processor0/${latest}" ]]; then
                mkdir -p "$latest"
                cp -a "processor0/${latest}/." "${latest}/" 2>/dev/null || true
            fi
        else
            if [[ -d processor0 ]]; then
                while IFS= read -r t; do
                    [[ -n "$t" && "$t" != "0" ]] || continue
                    mkdir -p "$t"
                    cp -a "processor0/${t}/." "${t}/" 2>/dev/null || true
                done < <(find processor0 -maxdepth 1 -mindepth 1 -type d -printf '%f\n' |
                             awk '/^[0-9]+([.][0-9]+)?$|^[.][0-9]+$/' | sort -g)
            fi
        fi
        ;;

    foamToVTK)
        # The production script reads VTK/**/internal.vtu from the case directory.
        time_value="$(fake_arg_value -time "$@" || echo 0)"
        vtk_dir="VTK/$(basename -- "$PWD")_${time_value}"
        mkdir -p "$vtk_dir"
        printf '<VTKFile type="UnstructuredGrid"/>\n' > "${vtk_dir}/internal.vtu"
        ;;

    *)
        # An unknown fake stays silent and successful. Recording already happened.
        ;;
esac

exit 0
