# v4 batch-runner contract tests

These tests give shared automated evidence for the v4 batch-runner contract in
`/docs/RUN_BATCH_HANDOFF_SPEC.md`.

The tests do not need an OpenFOAM installation.

## How to run

```bash
bash tests/run_contract_tests.sh
```

Run one scenario or a group of scenarios with a name filter:

```bash
bash tests/run_contract_tests.sh l_mesh
```

Keep the temporary workspaces for inspection:

```bash
KEEP_WORKSPACES=1 bash tests/run_contract_tests.sh
```

## Design

The public script CLI is the only test seam. No test calls a private function.

- Each scenario runs in its own process and in a new temporary workspace.
- No test writes into the repository working tree. The runner compares
  `git status --porcelain` before and after the suite.
- Cleanup targets only the temporary run directory that the runner creates.
- `tests/fakes/fake_cmd.sh` replaces every OpenFOAM command. One symlink per
  command name gives each fake its own name through `$0`.
- Each fake records the command name, the exact argument vector, the working
  directory, and selected environment values into `$FAKE_RECORD_DIR`.
- `assert_fakes_active` proves that `PATH` resolves every OpenFOAM command to
  the fake directory. A host with a real OpenFOAM installation cannot change a
  result.
- `tests/fakes/stage_stub.sh` replaces a stage script for the top-level
  `run_batch.sh` scenarios. Each stub records its argument vector, its working
  directory, and the exported cross-stage environment.

## Section 23 scenario map

| Specification | Scenario | Test file |
|---|---|---|
| 23.A | Bash syntax for all six scripts | `cases/a_syntax.sh` |
| 23.B | CLI help for all six scripts | `cases/b_cli_help.sh` |
| 23.C | Top-level multi-CSV dry-run | `cases/c_multi_csv_dry_run.sh` |
| 23.D | Canonical stage ordering | `cases/d_stage_ordering.sh` |
| 23.E | Overwrite safety | `cases/e_overwrite_safety.sh` |
| 23.F | Duplicate batch ID | `cases/f_duplicate_batch_id.sh` |
| 23.G | CSV mismatch protection | `cases/g_csv_mismatch.sh` |
| 23.H | Central stage-script precedence | `cases/h_central_script_precedence.sh` |
| 23.I | Exact `--save-times` forwarding | `cases/i_save_times_forwarding.sh` |
| 23.J | Stage-specific job counts | `cases/j_stage_jobs.sh` |
| 23.K | `SCALAR_FIELD` propagation | `cases/k_scalar_field_propagation.sh` |
| 23.L | Mesh `wallDistance` behavior | `cases/l_mesh_wall_distance.sh` |
| 23.M | Transport fresh behavior | `cases/m_transport_fresh.sh` |
| 23.N | Transport continuation behavior | `cases/n_transport_continuation.sh` |
| 23.O | Post-processing idempotency | `cases/o_post_idempotency.sh` |
| 23.P | Failure propagation | `cases/p_failure_propagation.sh` |
| 23.Q | Consolidated end-of-run report | `cases/q_consolidated_run_report.sh` |
| 23.R | Advisory selected-Stage tool preflight | `cases/r_selected_stage_tool_preflight.sh` |
| 23.S | Read-only status mode | `cases/s_read_only_status_mode.sh` |
| 23.T | Explicit Stage Runner output-directory forwarding | `cases/t_explicit_output_dir_forwarding.sh` |

Section 23.D creates a non-empty reuse workspace before the stage-order
preflight, because that scenario does not select setup.

Section 23.T reads the recorded Stage Runner argument vector, working directory,
and exported environment from `tests/fakes/stage_stub.sh`. The scenario compares
each vector against the exact Section 9.1 order, and it proves that the `-O`
value, the exported `BATCH_DIR`, and the recorded working directory are the same
path. One scenario uses a Batch Workspace path that holds a space, an ampersand,
a semicolon, and a dollar sign, so a split argument or an added escape fails the
comparison.

Section 23.S proves the read-only rule with two independent checks. The scenario
compares a recursive `find` listing and a `cksum` listing of the whole output
root before and after status mode. The scenario also puts poison commands on
`PATH` and poison stage scripts in the master directory and in the Batch
Workspace. Each poison command appends its own name to one log file. Status mode
passes only when that log file does not exist, so no OpenFOAM command and no
stage script ran.

Section 23.R builds a complete command directory inside its own workspace and
sets `PATH` to that directory only. The directory holds a symbolic link to each
platform utility that the Orchestrator needs, plus a stub for each advisory
command that the scenario keeps. A scenario therefore decides exactly which
command is absent, and a host with a real OpenFOAM or MPI installation cannot
change a result. Each scenario also proves that the named command really is
absent from its `PATH` before it asserts a warning. The `foamDictionary` stub
reads the requested entry from the given file, because the advisory detects the
flow solver through that interface.

Section 23.Q uses its own stage scripts instead of `tests/fakes/stage_stub.sh`,
because the report scenarios must control the stage summary content, the stage
result, and the batch completion order. One control directory holds the summary,
the forced failure, and the delay of each stage and batch. The scenario reads
only the console output and the Batch Workspace. No scenario reads an internal
`run_batch.sh` bookkeeping file, because that record is a private implementation
detail with no contract.

## Scope exclusions

Issue #4 adds contract tests only. Issue #4 does not change production code.

These assertions belong to the correction Issues that own the related
production files. This suite does not assert them:

| Confirmed gap | Owner Issue |
|---|---|
| Post-processing must exit non-zero for a missing requested case | #6 |
| Transport must exit non-zero for a missing required flow case | #6 |
| Flow must not require `reconstructPar` when `RECONSTRUCT_MODE=none` | #7 |
| Top-level overwrite must remove an existing empty destination | #5 |
| Top-level logging must report batch elapsed time on failure | #5 |

After those Issues merge, the combined suite covers the complete Section 23
matrix.

## Known contract gaps

These gaps appeared during the Issue #4 test work. They are not part of the
five confirmed gaps in Specification #3.

- **Section 23.P, mesh and flow stages. Restored by Issue #9.** A failed
  required OpenFOAM command inside `run_mesh_cases.sh` or `run_flow_cases.sh`
  previously did not fail the case: the case body runs on the left side of a
  `||` list, so `set -e` has no effect inside the body, and a `die` exited the
  whole background job past the failure handler. The Issue #9 correction runs
  each case body in an explicit subshell and makes the required-command
  wrappers (`run_step` in mesh, `run_tee` in flow) stop the case on failure.
  `cases/p_failure_propagation.sh` now asserts a failed summary row, the
  failure artifact, a non-zero stage, and no success marker for every required
  fresh-mesh and fresh-flow command.
- **Section 23.P, setup stage. Closed by Issue #24.** A failed setup row
  previously did not make the setup stage non-zero: `setup_cases.sh` recorded
  the failed row in `.setup_cases_failed` and printed a warning, but the final
  status stayed `0`. Specification Section 14.8 held this behavior as an
  accepted exception. The Issue #24 correction makes the setup stage runner
  return non-zero at stage completion when the failure artifact is not empty,
  and Section 14.8 now states the non-zero rule. The row job status, and not
  the size of the failure artifact alone, gives the final result. A failed
  record append therefore also gives a non-zero stage result.
  `cases/p_failure_propagation.sh` asserts the failed summary row, the failure
  artifact, the existing warning, the summary diagnostic, and a non-zero
  status for one failed row and for concurrent failed rows. The same scenario
  asserts that `run_batch.sh` marks the batch failed, that mesh does not start
  in the same batch, and that `--keep-going` still ends non-zero.

  Two scenarios need no OpenFOAM installation and no change to
  `tests/lib/harness.sh`:

  - The append-failure scenario points `.setup_cases_failed` at `/dev/full`.
    The stage runner can create and truncate that artifact, but every append
    fails and the artifact stays empty. The scenario first proves that these
    three conditions are true, and then proves the non-zero stage result.
  - The mixed non-dry-run scenario builds a small flow base folder and a small
    transport base folder, and it puts local `surfaceTransformPoints`,
    `surfaceCheck`, and `foamDictionary` stubs on `PATH`. The stubs give the
    exact log text that the setup stage runner parses. The scenario proves
    that the successful row keeps its Case directories, its `doe_row.csv`
    files, its setup metadata, its prepared field, and its case log, while the
    failed row makes the stage non-zero.
- **Section 23.B, top-level help completeness. Closed by Issue #10.** The
  `run_batch.sh` help previously did not display the documented `--stages`
  alias or the `--` end-of-options marker from specification Section 6.4. Both
  forms always worked in the parser; only the help text omitted them. The
  Issue #10 correction adds both forms to the help text and changes no parsing
  or runtime behavior. `cases/b_cli_help.sh` now asserts every option and alias
  in the Section 6.4 table, and it also proves by dry-run that the parser still
  accepts `--stages` and `--`.
