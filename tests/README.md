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
| 23.A | Bash syntax for all seven files | `cases/a_syntax.sh` |
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
| 23.U | Shared Stage library deployment foundation | `cases/u_shared_stage_library_deployment.sh` |
| 23.V | Shared Stage library locking characterization | `cases/v_shared_stage_library_locking.sh` |
| 23.W | Shared result-recording extraction | `cases/w_shared_stage_library_result_recording.sh` |
| 23.X | Shared Stage job-pool scheduling | `cases/x_shared_stage_library_job_pool.sh` |
| 23.Y | Shared Stage CSV parsing | `cases/y_shared_stage_library_csv_parsing.sh` |
| 23.Z | Shared Stage progress primitives | `cases/z_shared_stage_library_progress.sh` |

Section 23.D creates a non-empty reuse workspace before the stage-order
preflight, because that scenario does not select setup.

Section 23.V characterizes the Stage Runner mutual-exclusion behavior. The
assertions pass before and after the I-G1 extraction, because I-G1 moves only
acquisition and release mechanics. Every Stage Runner invocation has a finite
`timeout`, so a lock regression fails the scenario instead of waiting without a
limit. The scenario proves concurrent summary integrity through the field count
of every summary line, because a merged row or a partial row changes that count.
The scenario holds the exact `${SUMMARY_CSV}.lockdir` path to prove that each
Stage Runner waits on that path.

No Section 23.V characterization stays reduced. The mesh section runs four
concurrent Cases with `-j 4`, and it controls the state-file disappearance
instead of waiting for a rare race (Issue #41).

`show_running_cases` in `run_mesh_cases.sh` globs `_mesh_state/*.state` and then
reads each selected file with `awk`. A concurrent Case that removes a selected
state file before that read makes the `read` reach end of file, and `set -e`
stopped the Stage Runner. The race lost a summary row and gave status 1 even
when every Case succeeded.

The mesh section installs two wrappers in the isolated test workspace, outside
the repository worktree, and restores the earlier `PATH` before the next
section:

- The `blockMesh` wrapper records this Case at the hold and then waits for every
  other Case, so all four Cases are held together before the removal. The
  wrapper then waits for the race-control marker, and it keeps the hold for a
  bounded period after the marker appears. That post-marker hold matters,
  because the parent shell must reach its missing-path check while every Case is
  still held. A released Case would otherwise recreate the removed state file
  first, and the check would then see a present path. Each wait is finite, and a
  missing record or marker fails the Case.
- The `awk` wrapper delegates every call to the system `awk`, which it resolves
  before the wrapper directory enters `PATH`. Only the `show_running_cases`
  program that reads all five case, stage, message, updated, and log selectors
  can trigger the race control, and only when its file operand is a selected
  state file. The removal waits until every Case reached the hold. The parent
  shell waits inside `show_running_cases` for that call, so the wait keeps the
  Cases concurrent instead of blocking the job pool. The wrapper removes exactly
  one selected state file exactly once, confirms that the path is absent,
  delegates the same arguments, returns the delegated status, and records the
  program, the path, the single removal, and the delegated status only after that
  read. The `mesh_one_case` program reads only the stage selector, so it never
  matches.

The scenario fails when a Case did not reach the hold, when the marker is
absent, when the marker does not name the `show_running_cases` program and the
selected path, when the marker does not record one removal and a non-zero
delegated `awk` status, or when a wrapper reaches a finite wait. A run that
removed no selected state file is not valid evidence. The scenario also rejects
an active-Case line that carries the default-fill signature
`stage=running | mesh job active | updated=N/A`, because a stale selection must
not produce a fabricated record. The summary comparison sorts both sides, so it
proves Case identity and keeps the concurrent completion order free.

The Section 23.V transport Failure Artifact section holds three observations,
because Issue #42 corrected the transport progress read. A Failure Artifact on
`/dev/full` is a character device, and the transport progress line counted
Failure Artifact lines without a regular-file test, so the progress read took an
endless stream and the Stage Runner never completed.

- The solved `/dev/full` observation proves status 0, the exact solved summary
  row, `All transport jobs finished.`, and the transport marker.
- The failed `/dev/full` observation proves a non-zero status, the exact failed
  summary row, the `write error: No space left on device` diagnostic, the lock
  release, and no transport marker. The observation also keeps the per-Case
  `TRANSPORT FAILED:` line, because Issue #47 requires that line even when the
  Failure Artifact append fails.
- The readable regular Failure Artifact observation keeps the current progress
  behavior. Two Cases fail, so the progress line must report `failed=2`. The
  observation holds the exact progress line, so the field set, the field order,
  and the exact count are all proved. A constant failed count fails this
  observation, so the guard must still read a regular Failure Artifact.

Each observation rejects status `124`, because the 120-second `STAGE_TIMEOUT` is
only a test safety limit and never an accepted Stage result. Each `/dev/full`
observation verifies the exact seven-column header, exactly one data row, and
every field value of that row.

Section 23.X characterizes the job-pool scheduling of all five Stage Runners
and then proves that they delegate to the four shared helpers. Every assertion
uses a direct Stage Runner CLI or the Orchestrator CLI. Every control record
lives in a sibling directory under `CONTRACT_TEST_RUN_DIR`, so no record enters
a Batch Workspace.

Each Stage Runner runs four Cases with `-j 2` behind one named control command:
`surfaceTransformPoints` for setup, `blockMesh` for mesh, `simpleFoam` for flow,
`scalarTransportDeffFoam` for transport, and `foamToVTK` for post-processing.
The control identifies the Case from the working directory and the argument
vector, because post-processing calls its control three times per Case in three
directories and setup calls its control from a directory without a Case
component. A persistent seen marker keeps one entry for each Case, and a
separate active marker measures concurrency. The control holds each Case until
a second Case process is active, and a finite internal deadline releases every
participant. The scenario then proves that no Stage Runner exceeds two
concurrent Case processes, that two Case processes overlap, and that every Case
launches exactly once.

A fail token makes one Case fail while the parent is inside a job-pool wait. The
control fails before its parseable output, because setup reads its control
output and tolerates a non-zero control status. Each Stage Runner keeps its
exact failed status, summary rows, Failure Artifact bytes, marker behavior, and
failure message. A real Orchestrator invocation for each Stage keeps the
`Stage failed`, `Batch failed`, and overall failure behavior.

Two observations prove that a caller-owned wait counter stays load-bearing. A
suppression control replaces both the summary and the Failure Artifact with a
symbolic link to `/proc/version`, so only `FAILED_ROW_JOBS` for setup and
`JOB_FAILURES` for post-processing can keep the Stage result non-zero. The
post-processing observation uses one Case, because a failed append inside the
summary lock leaves that lock held and a second Case would wait without a limit.
That lock behavior is pre-existing.

A scenario-local `sleep` control records every sleep argument, so the scenario
proves that mesh and flow keep the 0.1-second post-cycle sleep, that setup,
transport, and post-processing gain none, and that the fallback path uses
0.5-second polling.

Three copied deployment units carry compatible instrumentation. The first
records shared-helper delegation and proves that setup uses the running-count
and free-slot helpers while the other four also use the wait-for-all helper.
That observation fails before the extraction, so it is the red evidence. The
second overrides only `batch_stage_job_pool_wait_n_supported` to return
non-zero, which forces the Bash 4.0 through 4.2 polling path and proves that the
fallback branch calls no wait-status callback. The third changes only the exact
Bash-version condition in the setup `wait_for_all_rows` function, which selects
the direct-PID older-Bash branch and proves that the setup final drain stays
caller-owned and unchanged.

Section 23.Y characterizes the CSV parsing of all five Stage Runners and then
proves that they delegate to the four shared parser helpers. Every assertion
uses a direct Stage Runner CLI. The base characterization group runs the
production deployment unit with no instrumentation, so every parsing result is
production behavior.

Most observations need no Case directory, because each Stage Runner selects and
trims the Case cell before it inspects the Case directory. A skipped row or a
failed row therefore reports the exact selected cell, and one CSV shape gives
one observation for each of the five Stage Runners.

The group covers a reordered header where the `Case` column is not column zero,
mixed-case and whitespace header names, a CRLF header and a CRLF data row, every
documented setup alias, caller alias priority, two header fields that normalize
to one key, an empty field between two commas, a missing field, a dropped
trailing empty field, a quoted comma, a doubled double quote, quote bytes, the
missing-column diagnostics, a header without a final newline, the empty, `NA`,
normalized and duplicate Case rules, blank rows, row numbers, the setup dynamic
stack headers, two DOE Batch CSV files in one invocation, and a header field
that normalizes to an empty string.

Three observations discriminate the Stage-specific trim behavior:

- A `"Case"` header stays accepted by post-processing, which removes one leading
  and one trailing double quote, and stays a required-column failure in setup,
  mesh, flow, and transport, which keep both quote bytes.
- A Case cell that holds one double quote normalizes to `NA` in mesh, flow, and
  transport, and becomes an empty Case in post-processing, so the two Case rules
  report different public messages.
- The setup summary echoes an invalid WS cell, so a quoted numeric value and a
  doubled double quote prove by exact bytes that the parser unescapes nothing.

The quoted-comma observation also rejects an RFC-compliant interpretation,
because the simple parser splits the value at the comma inside the quotes and
moves every later field by one index.

The multi-CSV observations use two `output_batch_*.csv` files in one invocation.
The second CSV holds fewer columns than the first CSV and puts `Case` first, so
a stale caller header element from the first CSV would move the Case column past
the last field of a second-CSV row. Two more observations omit a required column
from the second CSV, so no column index of the first CSV can resolve for the
second CSV. Post-processing keeps its current single-CSV selection.

A header field that normalizes to an empty string reaches the caller-owned
associative-index assignment, which the Bash runtime rejects. Each Stage Runner
keeps status `1`, writes no summary data row, writes no Failure Artifact data,
and runs no OpenFOAM command. The assertion requires the index variable name and
the runtime message, and it never compares a Bash-generated source line number.

Setup `STABILITY_COL` has no public consumer, so the base group proves that the
Stability column stays optional and changes no public result. The exact optional
alias vector is proven by the delegation group.

One copied deployment unit carries compatible instrumentation. Each instrumented
helper keeps the approved logic, output, and status, and appends one record to a
sibling directory outside every Batch Workspace. The records prove tokenization
through header parsing and cell lookup, the exact associative index of each
Stage Runner, and the exact alias vectors. The delegation group runs each Stage
Runner with `-j 1`, so no concurrent child appends to one record file. That
group fails before the extraction, so it is the red evidence.

The delegation CSV adds one `"note"` header that holds two quote bytes. The
normalization record holds the captured caller-callback output, which the
approved helper already assigns to one variable, so the record proves which
Stage Runner trim function ran inside the shared helper: post-processing records
`note` and the other four Stage Runners record `"note"`.

Section 23.Z characterizes the aggregate-progress timing gate and the
aggregate-progress active-process count of all five Stage Runners, and then
proves that the four aggregate-progress Stage Runners delegate to the shared
timing helper and to the existing shared active-count helper. Every assertion
uses a direct Stage Runner CLI.

The scenario installs one test-local `date` control. The control resolves the
real `date` before the control directory enters `PATH`, intercepts only the
exact one-argument call `date +%s`, and delegates every other argument vector
with the exact real status. Each intercepted call claims one sequence index
with an atomic `noclobber` creation, so the sequence update is finite and
concurrency-safe. The control repeats the final sequence value after the
sequence is exhausted. Only the four `show_progress` functions call `date +%s`,
so the record holds only aggregate-progress clock calls.

The timing assertions never require one fixed number of callback invocations. A
scenario oracle replays the recorded seconds through the exact current
arithmetic and prints the number of due decisions. The assertion compares that
number with the emitted progress lines, so an extra free-slot or final-drain
callback consumes one more recorded second and changes both sides in the same
way.

Two sequence shapes give the intended time transitions:

- An advancing sequence gives one gap below the interval and one gap at the
  exact interval, and then a tail that steps by more than the interval. Every
  forced call and every timing-reset call in that tail is due under the plain
  interval rule as well, so the oracle stays exact for mesh, flow, and
  transport.
- A single-value sequence keeps every call inside one interval. Only a forced
  call or a timing reset can then emit a second line. Mesh proves its forced
  final-drain calls, flow and transport prove both final timing resets, and
  setup proves that its final call is neither forced nor reset, because setup
  emits exactly one line and never reports `running=0/1`.

The clock-controlled timing group uses a concurrency limit of `1` and needs
`wait -n`. On Bash 4.0 through 4.2 the scenario reports a named skip for that
group only. Scenario X remains the required forced fallback-path evidence.

The Case controls hold one Case process until the parent Stage Runner records
one more clock call. An emitted progress line therefore observes an active Case,
and each free-slot and final-drain callback runs while a Case is active. The
mesh and transport running-Case detail observations use an overlap hold instead,
so two Cases are active at the same time. Every hold has a finite deadline,
preserves the exact argument vector, and returns the exact delegated status.

The uninstrumented group uses a fully due sequence, so every progress call
emits, and it asserts the exact final progress line of setup, mesh, flow, and
transport with the complete field set, the field order, and the current counter
values. Separate mixed observations give a non-default `created`, `dry_run`,
`meshed`, `continued`, `solved`, `skipped`, and `failed` value. The
post-processing observation proves the unchanged per-Case messages, the absent
aggregate-progress prefixes, and zero aggregate-progress clock calls.

The delegation group appends compatible instrumented definitions of
`batch_stage_progress_tick` and `batch_stage_job_pool_running_count` to one
copied library. Each definition keeps the production behavior and records one
call. `FUNCNAME` records only the calling function, which separates a
`show_progress` active-count call from a job-pool wait active-count call. The
records prove the exact interval and force argument of each Stage Runner, and
they prove one clock call for each timing-helper call. The group fails before
the extraction, so it is the red evidence.

Section 23.P covers the Issue #47 summary append-failure contract for mesh,
flow, and transport. Each Stage Runner has four controlled observations, and all
of them use a direct Stage Runner CLI or the Orchestrator CLI.

- The append-failure control wraps the last required Case command, `checkMesh`
  for mesh and `reconstructPar` for flow and transport. After that command and
  before the Case result append, the control moves the initialized summary to an
  evidence path and links the original summary path to `/proc/version`.
  `/proc/version` is readable and finite, it reports file size zero, and it
  rejects an append, so the append fails promptly and no later summary reader
  hangs or fails. The scenario proves those four properties before it uses the
  target. A directory gives different `awk` results on different hosts, and
  `/dev/full` can feed an endless stream to a later reader, so neither is used.
- The dual-failure control also replaces the Failure Artifact. Neither the
  summary nor the Failure Artifact can then record the failure, so only the
  private Case completion record keeps the Stage result non-zero. Each of those
  runs uses a test-local `TMPDIR`, and the scenario proves that the private
  accounting directory is removed after Stage exit.
- The lock-release regression prepends a test-local `rmdir` wrapper. The wrapper
  delegates the exact summary lock removal to the real `rmdir`, proves the
  removal, and then returns status `23`. That gives append status `0` with a
  non-zero release status, so the scenario proves that a successful append never
  hides a release failure. This regression passes before and after the Issue #47
  correction.
- The uncontrolled observations keep the exact successful summary bytes, the
  success message, the absent Failure Artifact, and the Case artifacts.

Every control uses a create-once marker, stays inside the isolated test
workspace, restores the earlier `PATH`, and runs under a finite timeout with
`LC_ALL=C`.

Section 23.W proves that the I-G2 result-recording extraction keeps every public
result-recording behavior. The scenario runs all five Stage Runners through
their direct CLIs and compares the complete summary bytes of each Stage against
expected bytes that the scenario builds from independent literal values. The
comparison appends one literal character to each side, so a trailing newline
byte stays significant inside command substitution.

Four Stage summaries use a Batch Workspace path component that holds a space, a
comma, a double quote, and an embedded newline, so one comparison proves that
each field stays enclosed in double quotes, that an inner double quote becomes
two double quotes, and that a comma and a newline stay inside their quoted
field. A setup row with an invalid wind speed and a Stage row with an empty
Case column prove that an empty field stays `""`.

Section 23.W also holds the current post-processing difference. The Case ID, the
Case directory, and the status keep their literal double-quote delimiters and add
no inner-quote escaping, so the Case directory field can hold one raw double
quote. Only the message field doubles an inner double quote. I-G2 does not
normalize post-processing to the other four Stage Runners.

Section 23.W covers the statuses that current public fixtures can produce. A
real setup run with flow and transport base folders gives `created`, and one
invalid row in the same run gives `failed`. The real setup run also needs
`surfaceCheck`, `surfaceTransformPoints`, and `foamDictionary`, so the section
adds scenario-local stubs that give the exact log text the Stage Runner parses
and restores the earlier `PATH` afterwards. A transport run with an existing
marker, an existing transport mesh, and an existing initial state gives
`continued`.

Section 23.W also holds one failed observation for each Stage Runner. Each
observation asserts the exact Failure Artifact path and bytes, the exact failed
summary row, and the existing non-zero Stage status. The setup Failure Artifact
records the DOE Batch CSV path and the row number. The mesh, flow, and transport
Failure Artifacts record the Case name. The post-processing Failure Artifact
records the Case ID.

One section proves a deterministic summary-row append failure. An external
`foamToVTK` wrapper runs after the post-processing Stage Runner writes its
header and before it appends a Case row. The wrapper moves the initialized
summary to an evidence path and creates a directory at the summary path, so the
next append redirection fails. The section proves that the Stage Runner returns
non-zero, keeps its failure diagnostic, and does not report success. The summary
lock is held across the row append, so a failed append ends the Case job before
the release and the lock directory survives. That is the current behavior.

One section proves shared-helper use without sourcing the library. It copies a
complete deployment unit into the isolated test workspace and appends compatible
instrumented implementations of the two approved helpers to the copied library.
Each instrumented helper keeps the production rendering and the production
append behavior and records one call outside the summary. Every copied Stage
Runner must produce a quote record and an append record. A Stage Runner that
keeps local result-recording mechanics produces no record, so this section fails
before the extraction.

Section 23.U builds real deployment units. Each scenario copies the production
Stage Runners and `lib_batch_stage.sh` into a temporary directory, so a scenario
controls the exact library shape beside each Stage Runner target. The scenario
does not use `make_stub_master` for a deployment-unit assertion, because a stage
stub carries no library-requirement declaration and keeps its current behavior.
The unreadable-library assertion is skipped and reported when `EUID` is `0`,
because the root identity can read a file with mode `000`.

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
