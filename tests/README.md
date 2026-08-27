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

Section 23.D creates a non-empty reuse workspace before the stage-order
preflight, because that scenario does not select setup.

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
| Top-level help must display the documented `--stages` alias and the `--` end-of-options marker | #10 |

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
- **Section 23.B, top-level help completeness. Owner: Issue #10.** The
  `run_batch.sh` help does not display the documented `--stages` alias or the
  `--` end-of-options marker from specification Section 6.4. Both forms work;
  only the help text omits them. `cases/b_cli_help.sh` asserts every top-level
  option form that the current help displays and does not assert `--stages`
  or `--`. This suite does not assert the missing help forms.
