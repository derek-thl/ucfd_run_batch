# A4-1a: real OpenFOAM v2506 four-Stage evidence

Contract: [Issue #69](https://github.com/derek-thl/ucfd_run_batch/issues/69) revision 7.
Bootstrap Item: [Issue #68](https://github.com/derek-thl/ucfd_run_batch/issues/68), merged as [Pull Request #71](https://github.com/derek-thl/ucfd_run_batch/pull/71).
Base `main` SHA: `70d8786adac2cb58b630e78c8b49b019a99579aa`.

This report records one real OpenFOAM run. It makes no scientific-validation claim and no transport Stage claim.

## 1. Headline result

| Field | Value |
|---|---|
| Overall result | `FAILED_EXIT_1` |
| Cause | The mesh Stage stopped. `mpirun` refused eight MPI ranks on a four-core runner. |
| Class of result | A real product result. It is not an infrastructure failure and not a budget stop. |
| Runs used | 1 of the 2 permitted |
| Run 2 | Not permitted. A product failure is final evidence for this Item. |

**The highest-value comparison passed.** Real OpenFOAM v2506 `surfaceTransformPoints` writes the exact text `Set centre of rotation to`, the setup parser read it, and the setup Stage completed. Section 9 holds the evidence.

## 2. Run identity

| Field | Value |
|---|---|
| Workflow | `openfoam-evidence`, id `357577437` |
| Workflow file | `.github/workflows/openfoam-evidence.yml`, blob `aa66e28ff347a115a2cfaad2fe9058f5bf6e247f`, unchanged |
| Trigger | `workflow_dispatch` from the default branch |
| Run URL | https://github.com/derek-thl/ucfd_run_batch/actions/runs/34858566571 |
| Run conclusion | `success` |
| Run head SHA | `70d8786adac2cb58b630e78c8b49b019a99579aa` |
| Artifact | `openfoam-v2506-evidence`, id `10354306964`, 17664 bytes |
| Artifact URL | https://github.com/derek-thl/ucfd_run_batch/actions/runs/34858566571/artifacts/10354306964 |

The run conclusion is `success` because a Stage failure does not fail the job. The workflow records the product result separately, and that product result is `FAILED_EXIT_1`.

## 3. Environment

| Field | Value |
|---|---|
| Runner image | `ubuntu-24.04`, version `20260907.300.1` |
| Image release | https://github.com/actions/runner-images/releases/tag/ubuntu24%2F20260907.300 |
| Runner host | `runnervmlun5p` |
| OpenFOAM distribution | OpenCFD Ltd OpenFOAM from openfoam.com |
| OpenFOAM version | `v2506` |
| OpenFOAM build | `_d6aa836d-20260127 OPENFOAM=2506 patch=260127 version=2506` |
| Architecture | `LSB;label=32;scalar=64` |
| Installation method | `dl.openfoam.com/add-debian-repo.sh`, then the pinned package `openfoam2506-default` |

The runner printed the version before the Orchestrator started:

```text
WM_PROJECT_VERSION=v2506
simpleFoam: /usr/lib/openfoam/openfoam2506/platforms/linux64GccDPInt32Opt/bin/simpleFoam
snappyHexMesh: /usr/lib/openfoam/openfoam2506/platforms/linux64GccDPInt32Opt/bin/snappyHexMesh
surfaceTransformPoints: /usr/lib/openfoam/openfoam2506/platforms/linux64GccDPInt32Opt/bin/surfaceTransformPoints
foamToVTK: /usr/lib/openfoam/openfoam2506/platforms/linux64GccDPInt32Opt/bin/foamToVTK
```

## 4. The fourteen deadline and status evidence fields

| # | Field | Value |
|---|---|---|
| 1 | Evidence-clock start time | `1789397619`, that is `2026-09-14 14:53:39Z` |
| 2 | Absolute capture deadline | `1789403919`, that is `2026-09-14 16:38:39Z` |
| 3 | `CAPTURE_START_GUARD_SECONDS` | `60` |
| 4 | Checkout phase result | `SUCCEEDED` |
| 5 | Installation phase result | `SUCCEEDED` |
| 6 | Preparation phase result | `SUCCEEDED` |
| 7 | Orchestrator start time | `1789397923`, that is `2026-09-14 14:58:43Z` |
| 8 | Raw remaining seconds | `5996` |
| 9 | Termination-grace seconds | `60` |
| 10 | Bounded command seconds | `5876` |
| 11 | `ORCHESTRATOR_STATUS` | `1` |
| 12 | `TIMEOUT_WRAPPER_STATUS` | `1` |
| 13 | GNU `timeout` locale | `LC_ALL=C` |
| 14 | Capture start time | `1789397928`, that is `2026-09-14 14:58:48Z` |

Field 2 equals field 1 plus 6300 seconds: `1789397619 + 6300 = 1789403919`.

Field 7 equals the first timestamp of `orchestrator.log`, `[2026-09-14 14:58:43]`.

### The four separate budget values and the exact calculation

```text
available = raw_remaining - termination_grace - capture_start_guard
```

| Bounded command | `raw_remaining` | `termination_grace` | `capture_start_guard` | `available` | Check |
|---|---:|---:|---:|---:|---|
| Installation | `6300` | `30` | `60` | `6210` | `6300 - 30 - 60 = 6210` |
| Preparation | `5997` | `15` | `60` | `5922` | `5997 - 15 - 60 = 5922` |
| Orchestrator | `5996` | `60` | `60` | `5876` | `5996 - 60 - 60 = 5876` |

Only `available` reached `timeout`. The capture-start guard of `60` was subtracted in every calculation.

### The capture start is inside the deadline

```text
CAPTURE_START    = 1789397928   2026-09-14 14:58:48Z
CAPTURE_DEADLINE = 1789403919   2026-09-14 16:38:39Z
CAPTURE_START_WITHIN_DEADLINE = true
margin           = 5991 seconds, that is 1 hour 39 minutes 51 seconds
```

This report makes no claim that every artifact-upload step started before that deadline.

## 5. The authoritative result

`ORCHESTRATOR_STATUS` and `TIMEOUT_WRAPPER_STATUS` are two separate fields.

| Field | Value |
|---|---|
| `orchestrator_status.txt` exact bytes | `1` |
| `ORCHESTRATOR_STATUS` | `1` |
| `TIMEOUT_WRAPPER_STATUS` | `1` |
| Anchored timeout diagnostic | **None. No line of `orchestrator-timeout.log` matches `^timeout: sending signal (TERM\|KILL)`.** |
| Derived result | `FAILED_EXIT_1` |

`orchestrator-timeout.log` holds 35 bytes, one line:

```text
[1]+  Exit 1                  "$@"
```

That line is a shell job-control notice. The bounded runner enables `set -m`, so such a notice can reach this log. **This report does not treat it as a timeout diagnostic.** The classifier matches only the anchored form, so the notice does not change the result.

No anchored line exists. The absence is recorded as an absence, not as an error.

The result comes from the recorded inner status, not from `TIMEOUT_WRAPPER_STATUS`. Both happen to be `1` in this run, and a valid status file was present, so the inner status is authoritative.

### Logs

| File | Content |
|---|---|
| `orchestrator.log` | 68 lines. The complete Orchestrator output. |
| `orchestrator-timeout.log` | 35 bytes. One job-control notice. No anchored diagnostic. |

Both files are inside the artifact `openfoam-v2506-evidence`:
https://github.com/derek-thl/ucfd_run_batch/actions/runs/34858566571/artifacts/10354306964

## 6. Stage results

| Stage | Result | Wall-clock time | Diagnostic that names it |
|---|---|---|---|
| setup | `SUCCEEDED` | `00:00:03` | `Stage done    : setup_cases.sh (00:00:03)` |
| mesh | `FAILED_EXIT_1` | `00:00:02` | `Stage failed  : run_mesh_cases.sh (exit=1, elapsed=00:00:02)` |
| flow | `NOT_ATTEMPTED` | none | No `Stage start   :` line for `run_flow_cases.sh` exists. |
| post-processing | `NOT_ATTEMPTED` | none | No `Stage start   :` line for `run_post_processing_cases.sh` exists. |

The transport Stage was not selected and did not run.

Every Stage result comes from an Orchestrator diagnostic. No Stage result is inferred, and no exit status is invented for a Stage that never started.

The Orchestrator run report agrees:

```text
Run report stage: batch=batch_9 stage=setup result=succeeded summary=available total=2 succeeded=2 skipped=0 failed=0 other=0
Run report stage: batch=batch_9 stage=mesh result=failed summary=available total=1 succeeded=0 skipped=0 failed=1 other=0
Run report failure: batch=batch_9 stage=mesh case=case_7 log=<batch>/_mesh_logs/case_7_flow.log
Run report stage: batch=batch_9 stage=flow result=not_attempted summary=unavailable total=unknown succeeded=unknown skipped=unknown failed=unknown other=unknown
Run report stage: batch=batch_9 stage=post-processing result=not_attempted summary=unavailable total=unknown succeeded=unknown skipped=unknown failed=unknown other=unknown
Run report total: requested=1 attempted=1 succeeded=0 failed=1 not_started=0
```

## 7. Exact Stage summary bytes

### setup, 10 columns

```text
csv_file,row_number,case_id,case_name,wd,ws,ws_for_setup,case_dir,status,message
"<batch>/output_batch_9.csv","2","case_7","case_7/flow","180.000","5.0","5.0","<batch>/case_7/flow","created","flow case created"
"<batch>/output_batch_9.csv","2","case_7","case_7/trd","180.000","5.0","5.0","<batch>/case_7/trd","created","transport case created"
```

Setup created a transport Case directory because the committed default `SETUP_TRANSPORT_CASES="true"` selects it. The transport **Stage Runner** never ran. This report makes no transport Stage claim.

### mesh, 7 columns

```text
csv_file,row_number,case_id,case_name,case_dir,status,message
"<batch>/output_batch_9.csv","2","case_7","case_7/flow","<batch>/case_7/flow","failed","see log: <batch>/_mesh_logs/case_7_flow.log"
```

### flow

`UNAVAILABLE`. The reason is that the Orchestrator stopped after the mesh Stage failed, so `run_flow_cases_summary.csv` was never created.

### post-processing

`UNAVAILABLE`. The reason is the same: the Stage never started, so `run_post_processing_cases_summary.csv` was never created.

`<batch>` replaces `/home/runner/work/ucfd_run_batch/ucfd_run_batch/src/batch_9` in this report. The artifact holds the unshortened bytes.

## 8. The exact command vector of each OpenFOAM-family command that ran

| Command | Exact vector | Count | Result |
|---|---|---:|---|
| `surfaceTransformPoints` | `surfaceTransformPoints -auto-centre -rotate-z 205.000 <batch>/case_7/flow/constant/triSurface/f18p2_all.stl <batch>/case_7/flow/constant/triSurface/f18p2_all.stl` | 1 | Completed |
| `surfaceTransformPoints` | `surfaceTransformPoints -centre (297.57 -836.476 22.985) -rotate-z 205.000 <batch>/case_7/flow/constant/triSurface/<file>.stl <batch>/case_7/flow/constant/triSurface/<file>.stl` | 51 | Completed |
| `surfaceCheck` | `surfaceCheck <batch>/case_7/flow/constant/triSurface/f18p2_all.stl` | 1 | Completed |
| `decomposePar` | `decomposePar -force` | 1 | Completed. It wrote `processor0` to `processor7`. |
| `mpirun` | `mpirun -np 8 snappyHexMesh -parallel -overwrite` | 1 | **Refused. It launched no rank.** |

`surfaceFeatureExtract` and `blockMesh` also ran inside the mesh Stage. `run_mesh_cases.sh` gives those two steps no separate log file, so their output went to `_mesh_logs/case_7_flow.log`. That file is in the Batch Workspace tree but is **not** inside the artifact. Section 12 records that gap. The Batch Workspace holds `constant/extendedFeatureEdgeMesh` and `constant/polyMesh` for the Case, and `decomposePar` needs a mesh, so both commands completed. This report states that from the directory evidence and does not quote a log that it does not hold.

`simpleFoam` and `foamToVTK` never ran.

The rotation angle `205.000` follows from the DOE row `WD=180.0` through the committed mapping. No tuning option was passed. The MPI rank count `8` follows from the committed default `NP="8"`, which setup wrote into `system/decomposeParDict`.

## 9. The parser comparison

**Result: the real output holds the exact text. The parser succeeded.**

`src/master_batch/setup_cases.sh` parses `log.surfaceTransformPoints` with `awk` for the exact text `Set centre of rotation to` and calls `die` when that text is absent. Before this run, only a project-written stub in `tests/cases/p_failure_propagation.sh` validated that text.

The real OpenFOAM v2506 log holds the line 52 times. The first occurrence:

```text
Reading surf from "<batch>/case_7/flow/constant/triSurface/f18p2_all.stl" ...
Writing surf to "<batch>/case_7/flow/constant/triSurface/f18p2_all.stl" ...
Set centre of rotation to (297.57 -836.476 22.985)
Rotating points about z-axis: 205
Rotating points by (-0.906308 0.422618 0 -0.422618 -0.906308 0 0 0 1)
Unset centre of rotation from (297.57 -836.476 22.985)
End
```

The parser took the three numbers after the text and used them as the rotation centre:

```text
CX = 297.57      CY = -836.476      CZ = 22.985
```

The evidence that the parser succeeded is the later behavior. The 51 following `surfaceTransformPoints` calls carry `-centre (297.57 -836.476 22.985)`, which is the parsed value, and the setup Stage completed with status `created`. A parse failure would have called `die` and would have stopped the setup Stage.

**This closes the largest assumption in the project.** The real command surface matches the parser for this command.

The `surfaceCheck` bounds parser also succeeded, because `compute_domain` needs those bounds and the Stage completed.

## 10. The point-data comparison

**Result: `NOT_ATTEMPTED`.**

The reason is that the post-processing Stage never started. The Orchestrator stopped after the mesh Stage failed, so `foamToVTK` never ran and no VTU file exists. This report therefore makes no claim about real `foamToVTK` point data.

Item A7 removed the `-no-point-data` argument. That change stays unverified against a real solver.

## 11. The mesh Stage failure

The mesh Stage stopped at the parallel `snappyHexMesh` step. `log.snappyHexMesh` holds the exact Open MPI text and no OpenFOAM banner, so `snappyHexMesh` never started:

```text
--------------------------------------------------------------------------
There are not enough slots available in the system to satisfy the 8
slots that were requested by the application:

  snappyHexMesh

Either request fewer slots for your application, or make more slots
available for use.
...
Alternatively, you can use the --oversubscribe option to ignore the
number of available slots when deciding the number of processes to
launch.
--------------------------------------------------------------------------
```

| Field | Value |
|---|---|
| Command vector | `mpirun -np 8 snappyHexMesh -parallel -overwrite` |
| Requested ranks | `8`, from the committed default `NP="8"` |
| Available cores | `4` on a GitHub-hosted `ubuntu-24.04` runner |
| Stage status | `FAILED_EXIT_1` |
| Case status | `failed` |

Issue #69 predicted this exact risk and named it a valid and valuable product result. This report records it without a workaround. No actor changed `NP`, changed a dictionary, changed a committed default, or passed a tuning option.

The steps before this one succeeded: `surfaceFeatureExtract`, `blockMesh`, and `decomposePar -force`. `decomposePar` wrote eight processor directories, so the decomposition itself accepted eight subdomains. The refusal came from the MPI launcher, not from OpenFOAM.

## 12. Failure Artifacts

The Batch Workspace holds two Failure Artifact files:

```text
<batch>/.setup_cases_failed
<batch>/.run_mesh_cases_failed
```

**The existence of `.setup_cases_failed` is not a setup failure.** `setup_cases.sh` line 464 runs `: > "$FAIL_FILE"` during initialization, so the file always exists. Line 1226 tests `[[ -s "$FAIL_FILE" ]]`, so only a **non-empty** file marks a failure. The setup Stage reported `created` for both rows and completed, so this file is empty.

**Known gap.** The capture step of the merged workflow collects files that match `log.*` and `FAILED_*`. The real Failure Artifact names begin with a dot, so their **contents** are not inside the artifact. `_mesh_logs/case_7_flow.log` is also outside the artifact for the same reason. Both files appear in the recorded Batch Workspace tree, so their existence is evidence, but their bytes are not. This report does not quote bytes that it does not hold. The workflow is read-only in this Item, so a correction needs a new bounded Item.

## 13. The Batch Workspace tree

The complete tree is inside the artifact as `batch-workspace-tree.txt`. The Case structure:

```text
<batch>/case_7/flow/            the flow Case, meshed to the decomposition step
<batch>/case_7/flow/0/          U, epsilon, k, nut, p
<batch>/case_7/flow/constant/   extendedFeatureEdgeMesh, polyMesh, triSurface, transportProperties, turbulenceProperties
<batch>/case_7/flow/processor0 .. processor7
<batch>/case_7/flow/log.surfaceTransformPoints
<batch>/case_7/flow/log.surfaceCheck
<batch>/case_7/flow/log.decomposePar.mesh
<batch>/case_7/flow/log.snappyHexMesh
<batch>/case_7/trd/             the transport Case directory, created by setup, never run
```

The `0/` directory holds exactly the five fields that RAS with `kEpsilon` needs. `0/omega` was pruned, which matches the committed defaults `SIM_TYPE="RAS"` and `RAS_MODEL="kEpsilon"`.

## 14. The phase and cutoff mapping rules

This run took the product-failure path. The table records which rule applied and which rules this run did not exercise.

| Rule of Issue #69 section 6 | Applied in this run? |
|---|---|
| Checkout failure or checkout timeout gives `INFRASTRUCTURE_FAILURE` | No. The checkout succeeded. |
| A timeout-induced installation or preparation stop gives `BUDGET_EXCEEDED` | No. Both phases succeeded. |
| A non-timeout installation failure gives `INFRASTRUCTURE_FAILURE` | No. |
| A non-timeout preparation failure gives `INFRASTRUCTURE_FAILURE` | No. |
| Bounded command seconds zero or less | No. The value was `5876`. |
| The budget expires during one Stage | No. No anchored diagnostic exists. |
| The budget expires after all Stages complete | No. |
| **A Stage fails for a product reason** | **Yes. The mesh Stage is `FAILED_EXIT_1`, and each later selected Stage is `NOT_ATTEMPTED`.** |

## 15. Budget and runs

| Field | Value |
|---|---|
| `openfoam-evidence` runs used | `1` |
| Maximum permitted runs | `2` |
| Run 2 started | No |
| Job start | `2026-09-14T14:53:37Z` |
| Job end | `2026-09-14T14:58:50Z` |
| Job duration | 5 minutes 13 seconds |
| Billable minutes | 6, because GitHub rounds each job up to the next whole minute |
| Maximum billable minutes | 240 |
| Job limit | 120 minutes. The job used about 4 percent of it. |
| Absolute capture deadline | Not reached. The margin was 5991 seconds. |

**Run 2 is not permitted.** The result is a product failure, and Issue #69 states that a product failure is final evidence for this Item. Run 3 is prohibited in every case.

## 16. Wall-clock time of each Stage

| Stage | Start | End | Wall-clock time |
|---|---|---|---|
| setup | `2026-09-14 14:58:43` | `2026-09-14 14:58:46` | `00:00:03` |
| mesh | `2026-09-14 14:58:46` | `2026-09-14 14:58:48` | `00:00:02` |
| flow | not started | not started | none |
| post-processing | not started | not started | none |

The complete batch took `00:00:05`. The installation phase used most of the job time.

## 17. What this run proves, and what it does not

**Proved by real execution:**

- OpenFOAM `v2506` installs on `ubuntu-24.04` through the pinned openfoam.com method.
- The setup Stage runs end to end against real OpenFOAM and reports `created`.
- `surfaceTransformPoints` writes the exact text `Set centre of rotation to`, and the setup parser reads the rotation centre correctly. This was the largest unverified assumption in the project.
- `surfaceCheck` output satisfies the bounds parser.
- `surfaceFeatureExtract`, `blockMesh`, and `decomposePar -force` complete against the committed dictionaries.
- The Stage result recording, the summary schemas, the Stage diagnostics, the failure propagation, and the consolidated run report behave against a real failure exactly as the contract tests describe.
- The bounded runner and the classifier behave correctly against a real non-zero status: `FAILED_EXIT_1` with no anchored diagnostic, and a job-control notice in the timeout log that changes nothing.

**Not proved:**

- Parallel `snappyHexMesh`, because `mpirun` refused eight ranks on four cores.
- `reconstructParMesh` and `checkMesh`, because the mesh Stage stopped first.
- The whole flow Stage, including `simpleFoam`.
- The whole post-processing Stage, including `foamToVTK` and the A7 point-data change.
- The transport Stage. It was not selected.
- Any scientific result. This report makes no scientific-validation claim.

## 18. Recommended next decisions

These are observations for the Product Owner. This Item makes no decision and changes no product file.

1. The committed default `NP="8"` cannot run on a four-core GitHub-hosted runner. A later Item must decide between a larger runner, a different committed default, and an `--oversubscribe` option. Each choice is a product decision that belongs to the Product Owner.
2. The capture glob of `openfoam-evidence` misses the dot-prefixed Failure Artifacts and the per-Case Stage logs. A later bounded Item can widen it.
3. The flow Stage, the post-processing Stage, and the A7 point-data change stay unverified against a real solver.
