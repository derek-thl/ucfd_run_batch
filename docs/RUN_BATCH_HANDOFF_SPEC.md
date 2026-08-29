# UCFD `run_batch.sh` and Stage Runner Handoff Specification

Status: `IMPLEMENTATION_HANDOFF`  
Baseline: `v4`  
Baseline date: `2026-08-26`  
Primary implementation: `run_batch.sh`  
Related stage runners: `setup_cases.sh`, `run_mesh_cases.sh`, `run_flow_cases.sh`, `run_transport_cases.sh`, `run_post_processing_cases.sh`

## 1. Purpose

This document defines the implementation contract for the UCFD batch execution scripts.

The goal is to let different AI agents working through GitHub recreate, review, or modify the scripts without depending on hidden conversation context.

The scripts implement this pipeline:

```text
DOE batch CSV
    |
    v
setup
    |
    v
mesh
    |
    v
flow
    |
    v
transport
    |
    v
post-processing
```

`run_batch.sh` is the orchestration layer. The stage runners are independent execution units.

An agent MAY refactor internal code. It MUST preserve the external contracts in this document unless an approved GitHub Issue, specification, or ADR changes them.

## 2. Normative words

The words `MUST`, `MUST NOT`, `SHOULD`, `SHOULD NOT`, and `MAY` define implementation requirements.

- `MUST`: required for compatibility.
- `SHOULD`: preferred unless there is a documented reason not to do it.
- `MAY`: optional behavior.

## 3. Source-of-truth boundary

### 3.1 `run_batch.sh` owns

`run_batch.sh` MUST own:

- batch CSV selection;
- batch ID extraction;
- `batch_<id>` workspace lifecycle;
- stage selection and fixed stage order;
- batch-level concurrency;
- default and stage-specific case concurrency;
- preflight validation;
- central stage-script selection;
- cross-stage `SCALAR_FIELD` propagation;
- transport `--save-times` propagation;
- dry-run planning;
- batch failure policy;
- top-level logging.

### 3.2 Stage runners own

Each stage runner MUST own:

- case discovery from the selected CSV;
- case-level concurrency;
- case-local OpenFOAM commands;
- case restart/fresh-run semantics;
- case logs;
- stage summary CSV output;
- stage failure files;
- stage-specific environment controls.

### 3.3 No hidden shared library

The v4 baseline uses self-contained shell scripts. No external Bash helper library is required.

An agent SHOULD preserve this deployment property unless a separate change explicitly introduces a shared library and updates all deployment/install rules.

## 4. Required repository/workspace layout

Recommended project layout:

```text
<ProjectRoot>/
├── run_batch.sh
├── output_batch_1.csv
├── output_batch_2.csv
├── ...
├── master_batch/
│   ├── setup_cases.sh
│   ├── run_mesh_cases.sh
│   ├── run_flow_cases.sh
│   ├── run_transport_cases.sh
│   ├── run_post_processing_cases.sh
│   ├── simpleFoam_files/
│   └── scalarTransportDeffFoam_files/
├── batch_1/                   # generated/reused workspace
├── batch_2/
└── ...
```

After setup, one DOE case has this logical structure:

```text
batch_<id>/
└── case_<Case>/
    ├── flow/
    ├── trd/
    └── vtk/                   # created by post-processing
```

`flow/` is the CFD flow case.  
`trd/` is the scalar-transport case.  
`vtk/` contains post-processed VTU outputs.

## 5. Runtime assumptions

The implementation assumes:

- GNU/Linux;
- Bash 4.x or newer;
- Bash 4.3 or newer when `--batch-jobs > 1` is used because `wait -n` is required by the top-level batch scheduler;
- GNU coreutils behavior, including `realpath`, `readlink`, and `cp --reflink=auto`;
- OpenFOAM tools available in `PATH` for actual CFD execution;
- simple CSV input without quoted commas.

The scripts use:

```bash
set -euo pipefail
```

or, for the top-level runner:

```bash
set -Eeuo pipefail
```

They set:

```bash
LC_ALL=C
```

for predictable parsing and sorting.

## 6. Top-level `run_batch.sh` contract

### 6.1 Invocation

```bash
bash run_batch.sh [options] <batch_csv> [<batch_csv> ...]
```

At least one input CSV MUST be supplied.

The shell MAY expand a glob before the script receives arguments:

```bash
bash run_batch.sh output_batch_*.csv
```

### 6.2 Default pipeline

If no `--stage` is given, the default stage set is:

```text
setup -> mesh -> flow -> transport -> post-processing
```

If no post-processing runner exists, the default full pipeline MAY skip post-processing with a warning.

If post-processing is explicitly selected and no post-processing runner exists, the command MUST fail.

### 6.3 Stage selection

Accepted stage names:

- `setup`
- `mesh`
- `flow`
- `transport`
- `post-processing`
- `all`

Accepted post aliases:

- `post`
- `postprocess`
- `post_processing`

The option MAY be repeated:

```bash
--stage mesh --stage flow
```

or comma-separated:

```bash
--stage mesh,flow
```

Input order MUST NOT control execution order. The canonical execution order MUST remain:

```text
setup -> mesh -> flow -> transport -> post-processing
```

Example:

```bash
--stage transport,mesh
```

MUST execute:

```text
mesh -> transport
```

### 6.4 Top-level CLI options

| Option | Contract |
|---|---|
| `-s`, `--stage`, `--stages <STAGE>` | Select one or more stages. Repeatable or comma-separated. |
| `-j`, `--jobs <N>` | Default case-level concurrency for selected stages. |
| `--setup-jobs <N>` | Override `-j` for setup only. |
| `--mesh-jobs <N>` | Override `-j` for mesh only. |
| `--flow-jobs <N>` | Override `-j` for flow only. |
| `--transport-jobs <N>` | Override `-j` for transport only. |
| `--post-jobs <N>` | Override `-j` for post-processing only. |
| `-B`, `--batch-jobs <N>` | Maximum concurrent whole batches. Default `1`. |
| `-m`, `--master-dir <DIR>` | Master batch/template directory. |
| `-o`, `--output-dir <DIR>` | Parent directory for `batch_<id>`. |
| `-f`, `--overwrite` | Replace an existing non-empty batch workspace. Valid only when setup is selected. |
| `--keep-going` | Continue launching other batches after a batch failure. |
| `--skip-post` | Remove post-processing from default/`all` pipeline. |
| `--save-times <LIST>` | Transport reconstruction times. Top-level v4 format is comma-separated non-negative integers. Default `60,120,300`. |
| `--scalar-field <NAME>` | OpenFOAM scalar field token shared by setup, transport, and post-processing. Default `T`. |
| `-n`, `--dry-run` | Run preflight and print the plan. Do not run stages. |
| `-h`, `--help` | Print usage and exit. |
| `--` | End option parsing. Remaining arguments are CSV paths. |

All job-count options MUST be integers `>= 1`.

`--scalar-field` MUST match:

```regex
^[A-Za-z_][A-Za-z0-9_]*$
```

The v4 wrapper accepts `--save-times` only when it matches:

```regex
^[0-9]+(,[0-9]+)*$
```

Example:

```text
60,120,300
```

Note: `run_transport_cases.sh` itself accepts a broader time syntax, including decimal values and comma/semicolon/space separators. The top-level wrapper intentionally has the narrower v4 interface. An agent MUST NOT silently broaden the top-level contract when reproducing v4.

### 6.5 Environment compatibility

The following top-level environment variables MUST remain supported:

| Variable | Meaning |
|---|---|
| `MASTER_BATCH_DIR` | Same purpose as `--master-dir`. |
| `RUN_BATCH_OUTPUT_DIR` | Same purpose as `--output-dir`. |
| `RUN_BATCH_OVERWRITE=1` | Same purpose as `--overwrite`. |
| `SCALAR_FIELD` | Default scalar field unless overridden by `--scalar-field`. |

CLI values take effect after environment defaults are loaded.

### 6.6 Batch ID extraction

For an input filename, batch ID extraction MUST:

1. Prefer a case-insensitive `batch`, optionally followed by `_` or `-`, then digits.
2. Otherwise use a trailing numeric token before the extension.
3. Fail if no batch ID can be found.

Examples:

```text
output_batch_10.csv -> 10
output-batch11.csv  -> 11
scenario_12.csv     -> 12
scenario.csv        -> ERROR
```

The destination MUST be:

```text
<OUTPUT_ROOT>/batch_<id>
```

Two input CSVs that resolve to the same destination batch ID MUST be rejected during preflight.

## 7. Workspace lifecycle

### 7.1 Setup selected: initialize mode

When `setup` is selected:

1. `master_batch` MUST exist.
2. Required selected stage scripts MUST exist in `master_batch`.
3. The destination `batch_<id>` MUST NOT equal `master_batch`.
4. The source CSV MUST NOT be inside its destination `batch_<id>`.
5. A non-empty existing destination MUST fail unless `--overwrite` is set.
6. If overwrite is set, the destination MUST be removed before initialization.
7. The master template MUST be copied to the destination.
8. The source CSV MUST be copied into the destination.

Template copy SHOULD use:

```bash
cp -a --reflink=auto
```

This preserves ordinary copy semantics and uses copy-on-write when the filesystem supports it.

### 7.2 Setup not selected: reuse mode

When setup is not selected:

1. `batch_<id>` MUST already exist.
2. It MUST be non-empty.
3. Selected stage scripts MUST be resolvable from the master or the batch-local copy.
4. The workspace MUST NOT be removed or recreated.
5. `--overwrite` MUST be rejected.

If `batch_<id>/<input-basename>` exists and the caller supplies an external CSV with the same basename, the two files MUST be byte-compared.

If they differ, preflight MUST fail. This prevents a later stage from running against a workspace created from different DOE data.

If no batch-local CSV copy exists, the stage MAY use the external source CSV directly and MUST log a warning.

## 8. Stage-script version precedence

This rule is critical for multi-agent maintenance and old batch compatibility.

For an existing batch, `run_batch.sh` MUST resolve a selected stage script in this order:

```text
1. <MASTER_BATCH_DIR>/<stage script>
2. <batch_dir>/<stage script>
3. fail
```

The central `master_batch` copy is authoritative when available.

Reason: old batch workspaces contain copied scripts. They can become incompatible with a newer `run_batch.sh`. Central-first resolution prevents version drift such as a new wrapper passing `--save-times` to an old transport runner that does not know that option.

Post-processing script names MUST support:

```text
run_post_processing_cases.sh
run_postprocess_cases.sh
```

in that preference order within a directory.

The selected stage script MUST run with the batch workspace as current working directory, even when the executable script file is physically located in `master_batch`.

## 9. Cross-stage environment contract

Before a stage runs, `run_batch.sh` MUST export:

```text
BATCH_CSV
BATCH_CSV_PATH
BATCH_NUMBER
BATCH_DIR
SCALAR_FIELD
```

Meaning:

| Variable | Meaning |
|---|---|
| `BATCH_CSV` | CSV basename. |
| `BATCH_CSV_PATH` | CSV path selected for the current workspace. |
| `BATCH_NUMBER` | Parsed numeric batch ID. |
| `BATCH_DIR` | Absolute/current batch workspace path. |
| `SCALAR_FIELD` | Shared transport scalar field name. |

Stage runners SHOULD accept `-i <csv>` as the explicit primary input and MAY use the exported batch variables as fallback discovery inputs.

## 10. Stage job-count precedence

For each stage:

```text
stage-specific override
    else
-j / --jobs
    else
stage runner's own default
```

Example:

```bash
-j 4 --mesh-jobs 3 --post-jobs 6
```

means:

```text
setup      4
mesh       3
flow       4
transport  4
post       6
```

If neither the global nor stage-specific value is set, `run_batch.sh` MUST omit `-j`, allowing the stage's own default to apply.

## 11. Concurrency model

There are three independent concurrency layers:

```text
batch concurrency
    x
case concurrency per stage
    x
MPI ranks per OpenFOAM case
```

Approximate peak MPI load is:

```text
BATCH_JOBS * active_stage_case_jobs * numberOfSubdomains
```

`run_batch.sh` SHOULD detect a `numberOfSubdomains` hint from:

- the master flow template when setup is selected; or
- the first existing batch flow case when setup is not selected.

It SHOULD report:

```text
MPI ranks/case
Peak MPI ranks
Logical CPU count
```

If estimated peak MPI ranks exceed logical CPUs, the runner SHOULD warn about probable CPU oversubscription.

This is advisory. The runner MUST NOT silently rewrite the user's requested concurrency.

## 12. Batch scheduling and failure policy

### 12.1 Sequential mode

Default:

```text
BATCH_JOBS=1
```

Batches execute one at a time.

Without `--keep-going`, the first failed batch MUST stop later batches.

With `--keep-going`, remaining batches MUST be attempted, and the top-level command MUST return failure if any batch failed.

### 12.2 Parallel batch mode

When `BATCH_JOBS > 1`:

- at most `BATCH_JOBS` batch subshells may run concurrently;
- each batch MUST run in an isolated subshell so its `cd` and exported values do not leak into other batches;
- the scheduler MUST use child exit status to count batch failures;
- without `--keep-going`, a detected failure MUST stop launching new batches, but already-running batches are allowed to finish;
- the top-level command MUST fail if any launched batch failed or if requested batches were not launched because of an earlier failure.

## 13. Dry-run contract

Top-level `--dry-run` MUST:

- run argument validation;
- run preflight;
- resolve batch IDs;
- resolve workspace mode;
- resolve stage-script source paths;
- resolve per-stage job counts;
- print planned copy and stage commands;
- report save times and scalar field when applicable;
- NOT create simulations;
- NOT invoke stage scripts.

This top-level dry-run is different from `setup_cases.sh --dry-run`, which is available when setup is executed directly.

## 14. Setup stage specification

File:

```text
setup_cases.sh
```

### 14.1 Purpose

For every DOE row, setup creates/configures:

```text
case_<Case>/flow
case_<Case>/trd
```

depending on `SETUP_FLOW_CASES` and `SETUP_TRANSPORT_CASES`.

### 14.2 Default configuration

Current v4 defaults:

```text
PARALLEL_JOBS=16
OUT_DIR=./
FLOW_BASE_DIR=simpleFoam_files
TRANSPORT_BASE_DIR=scalarTransportDeffFoam_files
SCALAR_FIELD=T
SETUP_FLOW_CASES=true
SETUP_TRANSPORT_CASES=true
SIM_TYPE=RAS
RAS_MODEL=kEpsilon
NP=8
SNAP_CTRL=off
ADDLAYERS_CTRL=off
SFGS=1.0
YPLUS=false
EXTENTS_H=10,20,5,8
H=40
RDR=300
BASE_STL_NAME=f18p2_all.stl
U_OAI_BASE=5
ZERO_WS_MODE=keep
MIN_WS=0.001
```

### 14.3 Direct CLI

The direct setup runner supports:

```text
-i <csv>
-j <jobs>
-b <flow-base-dir>
-O <output-dir>
-T <RAS|LES>
-t <RAS model>
-n <MPI subdomains>
-s <on|off>
-a <on|off>
-k <far-field grid scale>
-y <true|false>
-e <inlet,outlet,side,top>
--zero-ws-mode <skip|epsilon|keep|error>
--min-ws <value>
--dry-run
-h / --help
```

### 14.4 Required CSV columns

Required semantic columns:

```text
Case
WS
WD
```

Aliases:

```text
Case: Case, case
WS:   WS, ws, wind_speed, U_ref, u_ref, met__WS_mps
WD:   WD, wd, wind_direction, ref_wind_dir,
      relative_wind_direction, met__WD_deg
```

An optional `Stability` family is discovered:

```text
Stability, stability, atmospheric_stability, met__stability
```

but the current v4 implementation does not apply downstream stability behavior from that column. A reproducing agent MUST NOT invent additional stability semantics without an approved change.

### 14.5 Project-specific stack CSV inputs

Flow stack velocity uses headers of the form:

```text
<FAB>_<STACK_ZONE>_<SIDE_ID>__Uexit_mps
```

Example:

```text
P1_SEB_A__Uexit_mps
```

Backward-compatible fallback:

```text
P1_SEB_A_U
```

Transport emission concentration uses:

```text
<FAB>_<STACK_ZONE>_<SIDE_ID>__Cemit_ugpm3
```

Example:

```text
P1_SEB_A__Cemit_ugpm3
```

Backward-compatible fallback:

```text
P1_SEB_A_C
```

Current plant/device/side sets are:

```text
Plants:  f18p1/P1, f18p2/P2, f18p3/P3
Devices: SEB, AEX, SEX, VOC
Sides:   A, B
```

Missing optional stack columns generate warnings and skip the specific patch update rather than failing the entire row.

### 14.6 Flow-case setup behavior

For a new flow case, setup MUST:

1. create `case_<Case>/flow` from `simpleFoam_files`;
2. use `cp -a --reflink=auto` when available through GNU `cp`;
3. write `doe_row.csv` containing the source header and row;
4. write `setup_metadata.env`;
5. synchronize required turbulence field files;
6. configure RAS/LES mode;
7. reject known steady-solver/LES incompatibility;
8. rotate STL geometry from wind direction;
9. compute mesh domain extents;
10. update `blockMeshDict` and `snappyHexMeshDict`;
11. update inlet and project stack velocities;
12. set `numberOfSubdomains=NP`;
13. update compatible `run_flow.sh` `-np`/`NP=` values when present.

An existing flow case is skipped, not overwritten by this stage.

### 14.7 Transport-case setup optimization

For a new transport case, setup MUST:

1. copy the scalar transport template using `cp -a --reflink=auto`;
2. write `doe_row.csv`;
3. write `setup_metadata.env`;
4. remove copied `constant/triSurface` and `constant/polyMesh` payloads if present;
5. configure `0/$SCALAR_FIELD` emission boundary values;
6. update parallel settings.

It MUST NOT rotate STL or build transport mesh dictionaries as part of v4 transport setup.

Reason: transport reuses the converged flow mesh at runtime. Geometry/mesh work in the transport template would be overwritten later.

### 14.8 Setup logs and outputs

Stage artifacts:

```text
setup_cases_summary.csv
_setup_logs/
.setup_cases_failed
```

Final status:

- The setup stage runner MUST wait for all launched setup rows.
- If one or more setup rows fail, `.setup_cases_failed` MUST identify the failed rows, and the setup stage runner MUST return non-zero at stage completion.
- The setup stage runner MUST print the existing failure warning and the summary path before the final non-zero return.
- If no setup row fails, the setup stage runner MUST return `0` after successful completion.
- Fatal validation errors and fatal command errors MUST remain non-zero.

## 15. Mesh stage specification

File:

```text
run_mesh_cases.sh
```

### 15.1 Direct CLI and environment

Direct options:

```text
-i <csv>
-O / --output-dir <dir>
-j <jobs>
-h / --help
```

Environment:

```text
FORCE_MESH=1
PROGRESS_INTERVAL=5
PROGRESS_MAX_ACTIVE=8
```

Default parallel case count is `2`.

### 15.2 Case mapping

For CSV `Case=X`, mesh operates on:

```text
case_X/flow
```

with the same sanitization rule used by setup.

Duplicate case IDs MUST be skipped.

Missing case directories are recorded as skipped.

### 15.3 Fresh/continue mode

Mesh MUST detect `continue` when all are true:

- `FORCE_MESH != 1`;
- a valid `constant/polyMesh` exists;
- either `restart.marker` exists or a nonzero time directory exists.

Continue mode MUST skip the mesh rebuild.

Fresh mode MUST remove stale processor directories and nonzero time directories before rebuilding.

### 15.4 Fresh mesh command sequence

Canonical order:

```text
surfaceFeatureExtract
blockMesh
decomposePar -force
mpirun -np <NP> snappyHexMesh -parallel -overwrite
reconstructParMesh -constant
checkMesh -allGeometry -allTopology -writeAllFields -time 0
```

The final `checkMesh` MUST also request field writing at time `0`. The intended v4 result includes `0/wallDistance` so flow does not need another `checkMesh` pass.

On successful fresh mesh completion:

```text
processor* -> removed
restart.marker -> created
```

### 15.5 Mesh observability

Stage artifacts:

```text
run_mesh_cases_summary.csv
_mesh_logs/
_mesh_state/
.run_mesh_cases_failed
```

State files SHOULD identify current case, stage, message, update time, and log path.

If any case fails, mesh MUST return non-zero at stage completion.

## 16. Flow stage specification

File:

```text
run_flow_cases.sh
```

### 16.1 Direct CLI and environment

Direct options:

```text
-i <csv>
-O / --output-dir <dir>
-j <jobs>
--case-prefix <prefix>
-h / --help
```

Environment:

```text
FORCE_FLOW=1
CLEAN_PROCESSORS=0|1
RECONSTRUCT_MODE=latest|all|none
```

Defaults:

```text
PARALLEL_JOBS=2
CLEAN_PROCESSORS=1
RECONSTRUCT_MODE=latest
FLOW_MARKER=flow.marker
```

### 16.2 Preconditions

Each flow case MUST have:

```text
system/controlDict
system/decomposeParDict
constant/polyMesh/points
constant/polyMesh/boundary
```

The solver MUST be read from `system/controlDict:application`.

MPI rank count MUST be read from `system/decomposeParDict:numberOfSubdomains`.

### 16.3 Fresh/continue behavior

Unless `FORCE_FLOW=1`, the runner treats a case as continuation when either:

```text
flow.marker exists
OR
one or more nonzero numeric time directories exist
```

Fresh mode removes nonzero time directories, `processor*`, and old `flow.marker` before solving.

### 16.4 Flow command sequence

Both fresh and continuation use the same main solve sequence:

```text
decomposePar -force
mpirun -np <NP> renumberMesh -parallel -overwrite
mpirun -np <NP> <solver> -parallel
reconstructPar according to RECONSTRUCT_MODE
ensure wallDistance
cleanup processor* when CLEAN_PROCESSORS=1
write flow.marker
write case.foam
```

Optional post-solver diagnostics MAY run if installed:

```text
foamLog
gnuplot residuals_from_foamLog.gp
```

### 16.5 wallDistance compatibility rule

The mesh stage should already produce:

```text
0/wallDistance
```

Flow MUST first check for that file.

If it exists, flow MUST skip the extra wall-distance `checkMesh` execution.

If it does not exist, flow MUST run the compatibility fallback:

```bash
checkMesh -writeAllFields -time 0
```

and MUST verify that `0/wallDistance` was created.

### 16.6 Flow artifacts

```text
run_flow_cases_summary.csv
_flow_logs/
.run_flow_cases_failed
flow.marker          # inside each completed flow case
case.foam            # inside each completed flow case
```

If any case fails, flow MUST return non-zero at stage completion.

## 17. Transport stage specification

File:

```text
run_transport_cases.sh
```

### 17.1 Direct CLI

```text
-i <csv>
-O / --output-dir <dir>
-j <jobs>
--save-times <list>
--flow-prefix <prefix>
--transport-prefix <prefix>
--base-transport-dir <dir>
-h / --help
```

`--flow-prefix`, `--transport-prefix`, and `--base-transport-dir` remain accepted for compatibility. Missing transport cases MUST NOT be auto-created by the transport runner.

### 17.2 Environment

```text
FORCE_TRANSPORT=1
CLEAN_PROCESSORS=0|1
RECONSTRUCT_MODE=latest|all|custom|none
TRANSPORT_SAVE_TIMES=<list>
PROGRESS_INTERVAL=5
SCALAR_FIELD=T
```

Defaults:

```text
PARALLEL_JOBS=2
SOLVER=scalarTransportDeffFoam
FLOW_CASE_PREFIX=flow
TRANSPORT_CASE_PREFIX=trd
CLEAN_PROCESSORS=1
RECONSTRUCT_MODE=latest
SCALAR_FIELD=T
TRANSPORT_MARKER=transport.marker
```

### 17.3 Save-time normalization

Direct transport execution accepts comma-, semicolon-, or whitespace-separated exact numeric time values.

Supplying save times MUST set:

```text
RECONSTRUCT_MODE=custom
```

Duplicates MUST be removed while preserving a useful requested list.

Before solving, the runner MUST verify:

```text
system/controlDict:endTime >= max(requested save times)
```

If not, the case MUST fail before solver execution.

`RECONSTRUCT_MODE=custom` without a normalized time list MUST fail.

`RECONSTRUCT_MODE=none` with `CLEAN_PROCESSORS=1` MUST fail because processor-only calculated times would otherwise be deleted.

### 17.4 Case mapping

For `Case=X`:

```text
flow case      = case_X/flow
transport case = case_X/trd
```

Both directories MUST already exist for execution.

### 17.5 Fresh/continue decision MUST occur before preparation

This ordering is a v4 invariant.

A transport restart state exists when:

```text
transport.marker exists
OR
one or more nonzero numeric transport time directories exist
```

If `FORCE_TRANSPORT != 1` and restart state exists, mode is `continue`.

Mode MUST be decided before copying a flow mesh or flow fields.

### 17.6 Fresh transport preparation

Only fresh mode MUST synchronize flow data into transport.

Fresh preparation sequence:

1. require existing transport case;
2. enter the transport directory;
3. require `flow/constant/polyMesh`;
4. replace `trd/constant/polyMesh` with a copy of the flow mesh;
5. use `cp -a --reflink=auto`;
6. find the latest numeric flow time;
7. require flow `U` at that time;
8. require transport `0/$SCALAR_FIELD`;
9. copy flow `U` to transport `0/U` and fix the OpenFOAM `location` header to `0`;
10. if present, copy flow `nut` and `phi` to transport `0/` and fix location headers;
11. if `nut` or `phi` is absent in the current flow result, remove stale transport copies and let solver fallback behavior decide.

### 17.7 Continuation transport preparation

Continuation MUST NOT recopy:

```text
constant/polyMesh
0/U
0/nut
0/phi
```

from the flow case.

It MUST reuse the existing transport mesh and restart state that generated the existing nonzero fields.

The runner MUST explicitly `cd` into the transport directory before solver execution when preparation is skipped.

This prevents a continuation run from accidentally executing in the batch root and prevents mesh/field inconsistency.

### 17.8 Solver sequence

After mode-specific preparation:

```text
validate controlDict application == scalarTransportDeffFoam
validate endTime against requested save times
detect numberOfSubdomains
fresh only: remove old nonzero times and processor*
continue only: require existing constant/polyMesh
decomposePar -force
mpirun -np <NP> renumberMesh -parallel -overwrite
mpirun -np <NP> scalarTransportDeffFoam -parallel
reconstruct according to RECONSTRUCT_MODE
cleanup processor* when enabled
touch transport.marker
touch case.foam
```

Custom reconstruction MUST reconstruct each requested output time independently using `reconstructPar -time <resolved-time>`.

If a requested save time was not written by the solver, the case MUST fail with available processor times in the error message.

### 17.9 Transport artifacts

```text
run_transport_cases_summary.csv
_transport_logs/
_transport_state/
.run_transport_cases_failed
transport.marker       # inside each completed transport case
case.foam              # inside each completed transport case
```

If any case fails, transport MUST return non-zero at stage completion.

## 18. Post-processing stage specification

File:

```text
run_post_processing_cases.sh
```

### 18.1 Purpose

Convert selected reconstructed OpenFOAM flow and transport results into per-case VTU files.

Expected layout:

```text
case_<Case>/vtk/
├── flow_0.vtu
├── flow_latest_<time>.vtu
├── flow_latest_time.txt
├── trd_0.vtu
├── trd_<time>.vtu
├── ...
├── post_processing.complete
└── logs/
```

### 18.2 Direct CLI and environment

Direct options:

```text
-i <csv>
-O / --output-dir <dir>
-j <jobs>
-h / --help
```

Environment:

```text
POST_PARALLEL_JOBS
SCALAR_FIELD
FORCE_POST=0|1
BATCH_CSV_PATH
BATCH_CSV
```

Defaults:

```text
PARALLEL_JOBS=${POST_PARALLEL_JOBS:-2}
FLOW_ZERO_FIELDS=(U p wallDistance)
FLOW_RESULT_FIELDS=(U p)
SCALAR_FIELD=T
TRD_FIELDS=($SCALAR_FIELD)
FORCE_POST=0
```

### 18.3 VTU conversion contract

Each `foamToVTK` invocation MUST use:

```text
-time <time>
-no-boundary
-no-point-data
-fields <field list>
```

The runner locates the generated `internal.vtu`, copies it to the stable project filename, and removes the temporary OpenFOAM `VTK/` directory.

Flow outputs:

```text
flow_0.vtu                   fields: U p wallDistance
flow_latest_<time>.vtu       fields: U p
flow_latest_time.txt
```

Transport outputs:

```text
trd_0.vtu                    field: SCALAR_FIELD
trd_<each reconstructed nonzero time>.vtu
```

### 18.4 Incremental/idempotent post-processing

Post-processing MUST NOT blindly rebuild outputs when they are current.

The completion marker is:

```text
vtk/post_processing.complete
```

The marker content is a source-result signature. The signature MUST include at least:

```text
latest flow time
list of transport times
SCALAR_FIELD
flow zero-time field selection
flow result field selection
```

If all of these are true:

1. `FORCE_POST != 1`;
2. completion marker exists;
3. current signature equals stored signature;
4. every expected VTU output exists;

then the case MUST be skipped as current.

If the source signature changes, an expected output is missing, or `FORCE_POST=1`, the post stage MUST rebuild that case.

For a rebuild, the prior `vtk/` directory is removed first to prevent stale outputs.

### 18.5 Post artifacts

```text
run_post_processing_cases_summary.csv
.run_post_processing_cases_failed
case_<Case>/vtk/logs/
case_<Case>/vtk/post_processing.complete
```

If any case fails, post-processing MUST return non-zero at stage completion.

## 19. Logging and summary contract

All scripts SHOULD make failures diagnosable without reading console history.

Each stage MUST write case logs and/or a summary CSV.

The top-level runner MUST log at least:

```text
preflight result
batch count
selected stages
workspace mode
output root
stage-script precedence/source
job counts
batch concurrency
overwrite state
keep-going state
save times when transport is selected
scalar field when relevant
stage start
stage source path
stage command
stage elapsed time
stage failure exit code
batch elapsed time
```

Printed shell commands MAY use shell escaping such as `%q`.

Example display:

```text
60\,120\,300
```

is only an escaped log representation. It MUST NOT imply that backslashes are included in the actual argument passed to the child script.

## 20. Copy-on-write policy

Large directory copies SHOULD use:

```bash
cp -a --reflink=auto
```

Current v4 use cases include:

- `master_batch` -> `batch_<id>`;
- flow template -> flow case;
- transport template -> transport case;
- flow `polyMesh` -> fresh transport case;
- flow `U`, `nut`, `phi` -> fresh transport initial fields.

Hard links MUST NOT be used as a transparent replacement because OpenFOAM case files are modified after copying.

## 21. Resume/idempotency policy

The scripts intentionally use stage-local markers and existing time directories.

| Stage | Resume/skip evidence |
|---|---|
| Setup | Existing case directory causes setup skip. |
| Mesh | Valid mesh plus `restart.marker` or nonzero time. |
| Flow | `flow.marker` or nonzero time. |
| Transport | `transport.marker` or nonzero transport time. |
| Post | `post_processing.complete` signature plus complete expected outputs. |

Force controls:

```text
FORCE_MESH=1
FORCE_FLOW=1
FORCE_TRANSPORT=1
FORCE_POST=1
```

Force behavior MUST be explicit. The top-level runner MUST NOT automatically force stages when rerunning an existing workspace.

## 22. Compatibility examples

### 22.1 Full pipeline

```bash
bash run_batch.sh -j 4 output_batch_1.csv
```

### 22.2 Multiple batches

```bash
bash run_batch.sh -j 4 \
  output_batch_1.csv \
  output_batch_2.csv \
  output_batch_3.csv
```

### 22.3 Glob input

```bash
bash run_batch.sh -j 4 output_batch_*.csv
```

### 22.4 Transport only on existing batches

```bash
bash run_batch.sh \
  -B 2 \
  -j 3 \
  --stage transport \
  --save-times "60,120,300" \
  output_batch_*.csv
```

### 22.5 Stage-specific concurrency

```bash
bash run_batch.sh \
  -B 2 \
  -j 4 \
  --mesh-jobs 3 \
  --flow-jobs 3 \
  --transport-jobs 3 \
  --post-jobs 6 \
  --save-times "60,120,300" \
  output_batch_*.csv
```

### 22.6 Alternative scalar field

```bash
bash run_batch.sh \
  --scalar-field c \
  --save-times "60,120,300" \
  output_batch_1.csv
```

Setup MUST configure `0/c`; transport MUST solve using `c`; post-processing MUST request `c` from `foamToVTK`.

### 22.7 Continue only selected stages

```bash
bash run_batch.sh \
  --stage flow,transport \
  -j 3 \
  output_batch_1.csv
```

The existing `batch_1` MUST be reused and MUST NOT be recreated.

## 23. Acceptance tests for a replicated implementation

An AI agent claiming compatibility MUST run or provide evidence for the following tests.

### A. Syntax

```bash
bash -n run_batch.sh
bash -n master_batch/setup_cases.sh
bash -n master_batch/run_mesh_cases.sh
bash -n master_batch/run_flow_cases.sh
bash -n master_batch/run_transport_cases.sh
bash -n master_batch/run_post_processing_cases.sh
```

Expected: all exit `0`.

### B. CLI help

Run `--help` on every script.

Expected: exit `0` and documented options are present.

### C. Top-level multi-CSV dry-run

```bash
bash run_batch.sh --dry-run \
  output_batch_1.csv output_batch_2.csv
```

Expected:

- two unique batches;
- no CFD stage execution;
- canonical stage order printed.

### D. Stage ordering

```bash
bash run_batch.sh --dry-run \
  --stage transport,mesh \
  output_batch_1.csv
```

Expected printed order:

```text
mesh -> transport
```

### E. Overwrite safety

Expected:

- existing non-empty batch + setup + no overwrite -> fail;
- existing non-empty batch + setup + `--overwrite` -> allowed;
- no setup + `--overwrite` -> fail.

### F. Duplicate batch ID

Supply two different source files that resolve to the same batch ID.

Expected: preflight failure before any stage starts.

### G. CSV mismatch protection

Existing batch contains `output_batch_1.csv`. Supply an external different file with the same name.

Expected: preflight failure.

### H. Central script precedence

Put distinguishable stub scripts in:

```text
master_batch/run_transport_cases.sh
batch_1/run_transport_cases.sh
```

Run transport-only mode.

Expected: the master version executes.

### I. Exact `--save-times` argument forwarding

Use a transport stub that records `argv`.

Run:

```bash
bash run_batch.sh \
  --stage transport \
  --save-times "60,120,300" \
  output_batch_1.csv
```

Expected transport arguments include exactly two tokens:

```text
--save-times
60,120,300
```

No literal backslashes may be present in the child argument.

### J. Stage-specific jobs

Use stage stubs that record arguments.

Example:

```bash
-j 4 --mesh-jobs 3 --post-jobs 6
```

Expected:

```text
setup      -j 4
mesh       -j 3
flow       -j 4
transport  -j 4
post       -j 6
```

### K. Scalar-field propagation

Run with:

```bash
--scalar-field c
```

Expected:

```text
SCALAR_FIELD=c
```

visible to setup, transport, and post scripts.

### L. Mesh wallDistance behavior

Use fake OpenFOAM commands or a small test case.

Expected fresh mesh command contains:

```text
checkMesh -allGeometry -allTopology -writeAllFields -time 0
```

Expected flow:

- skips its fallback if `0/wallDistance` exists;
- runs fallback if it does not.

### M. Transport fresh behavior

Expected fresh transport:

- copies flow mesh into transport;
- copies latest flow `U`;
- synchronizes optional `nut` and `phi`;
- validates requested save times against `endTime`;
- runs solver.

### N. Transport continuation behavior

Create restart evidence and an existing transport mesh.

Expected continuation:

- detects continuation before preparation;
- does not replace `constant/polyMesh`;
- does not overwrite `0/U`, `0/nut`, or `0/phi` from flow;
- executes solver from inside the transport directory.

### O. Post idempotency

Run post twice without changing flow/transport time directories.

Expected second run: skip.

Add or change a source result time.

Expected next run: rebuild.

Set:

```bash
FORCE_POST=1
```

Expected: rebuild even when signature is unchanged.

### P. Failure propagation

For setup, mesh, flow, transport, and post, force one case runner to fail.

Expected:

- stage summary records failure;
- stage exits non-zero;
- `run_batch.sh` marks the batch failed;
- without `--keep-going`, new batches stop launching;
- with `--keep-going`, other batches are attempted and final status remains failure.

The setup case MUST also prove:

- the setup summary records each failed row;
- `.setup_cases_failed` identifies each failed row;
- the setup stage runner exits non-zero;
- successful rows of the same invocation stay in the summary;
- `run_batch.sh` marks the batch failed;
- without `--keep-going`, a failed setup batch stops later batches;
- with `--keep-going`, other batches are attempted and the final status stays non-zero.

## 24. Multi-agent GitHub handoff rules

When an AI agent changes these scripts, its GitHub handoff SHOULD include:

```text
1. Issue / task ID
2. Exact base commit
3. Files changed
4. Behavioral contract changed: yes/no
5. CLI changed: yes/no
6. Workspace layout changed: yes/no
7. Restart semantics changed: yes/no
8. Concurrency semantics changed: yes/no
9. OpenFOAM commands changed: yes/no
10. Tests executed
11. Test results
12. Known limitations / follow-up actions
```

The handoff MUST distinguish:

```text
implementation refactor
```

from:

```text
specification/behavior change
```

An agent MUST NOT change CLI semantics, path conventions, markers, save-time behavior, or restart behavior as an incidental cleanup.

## 25. Recommended AI-agent implementation sequence

For a clean-room recreation, implement in this order:

1. `run_batch.sh` argument parsing and stage normalization.
2. Batch ID extraction and preflight.
3. Workspace initialize/reuse rules.
4. Master-first stage-script resolution.
5. Dry-run command planning.
6. Sequential batch execution.
7. Parallel batch execution.
8. Stage-specific job overrides and MPI advisory.
9. `setup_cases.sh` case creation.
10. `run_mesh_cases.sh` fresh/continue state machine.
11. `run_flow_cases.sh` fresh/continue and wallDistance fallback.
12. `run_transport_cases.sh` save-time normalization and fresh/continue preparation ordering.
13. `run_post_processing_cases.sh` deterministic outputs and signature-based reuse.
14. Add all acceptance tests from Section 23.

At every step, keep the scripts independently executable.

## 26. Non-goals of v4

The baseline does not require:

- a Python orchestrator;
- Slurm/PBS integration;
- Kubernetes scheduling;
- automatic CPU affinity or MPI rank reduction;
- automatic GPU scheduling;
- true RFC-compliant CSV parsing with quoted commas;
- a common shell library;
- multi-time `foamToVTK` batching in one invocation;
- automatic creation of missing transport cases during transport execution.

These may be future improvements but MUST be separate reviewed changes.

## 27. Known technical debt / cautions

1. **Simple CSV parser**: stage scripts use Bash `IFS=','`; quoted commas are unsupported.
2. **MPI estimate is a hint**: the top-level runner detects one `numberOfSubdomains` value and does not prove all cases use the same value.
3. **`--save-times` interface asymmetry**: top-level v4 accepts integer comma lists, while transport runner accepts a broader numeric list format.
4. **Post signature is structural**: it tracks time-directory/field-selection state, not hashes of every OpenFOAM result file. If file contents change without time-set changes, `FORCE_POST=1` may be required.
5. **Central stage source is intentional**: updating `master_batch` affects subsequent runs of old batches because central scripts are preferred.

Do not “fix” these items inside an unrelated implementation task. Open a dedicated Issue if behavior must change.

## 28. Baseline file fingerprints

The v4 implementation used to create this handoff has these SHA-256 fingerprints:

```text
24f623eb8f38764ce7ca9ea940429813ee4f2a3660c86521d520400081230819  run_batch.sh
7595f350871ae90f1d7cdd19131a28ee4150b65ad337b3c060c7faabc57118a3  setup_cases.sh
0e95012e1e63c5bd54aed7967d51c7317e62942207ee9a76e84ede39f4fe2431  run_mesh_cases.sh
8a5ee48b0dcec6e69892475f6e17b62194741d906d2623257ab33ac3178efe3a  run_flow_cases.sh
1b864b3c5ff142b64168691a618a4fb85a26ee22c59d61f1ff0c28617781dc61  run_transport_cases.sh
8ef7e3ef929b2064f226b0179e55f14ef986f51db7f63b5d4ef26f4b51fd688a  run_post_processing_cases.sh
```

Agents can use these only to identify the exact baseline. A legitimate implementation change will naturally change the hashes.

## 29. Definition of done for a replacement implementation

A replacement is compatible when all of the following are true:

- all documented CLI forms work;
- default stage order is preserved;
- independent stage execution works;
- multi-CSV execution works;
- batch workspace safety rules are preserved;
- master-first stage resolution works;
- stage-specific jobs work;
- batch concurrency works;
- MPI advisory works when NP is detectable;
- `SCALAR_FIELD` stays consistent across setup/transport/post;
- `--save-times "60,120,300"` reaches transport as one value argument;
- setup produces compatible flow and transport directories;
- mesh supports fresh/continue and writes restart evidence;
- flow supports fresh/continue and guarantees wallDistance;
- transport makes fresh/continue decision before data synchronization;
- continuation does not replace the mesh/state used by existing transport fields;
- post-processing reuses current outputs and rebuilds stale outputs;
- failures are logged and propagated according to the baseline contract;
- acceptance tests pass;
- GitHub handoff states any intentional spec deviation explicitly.

