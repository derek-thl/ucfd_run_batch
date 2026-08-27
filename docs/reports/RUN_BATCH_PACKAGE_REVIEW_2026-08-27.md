# UCFD run-batch Package Review

- Author: `derek-implementer`
- Date: 2026-08-27
- Code snapshot reviewed: `main` at `68fdbcc413b29f4ec2a0c43bb3930e98891af57f`
- Workflow status as of: Issue #1 frontier `PR_15_SNAPSHOT_CORRECTIONS_REQUIRED`, 2026-08-27T14:28Z, when `main` was `121c8bebae663278c86299477fe54f9ddc85dba8`
- Report Issue: #14
- Classification: `DOCUMENTATION_ONLY`

**Authority note.** This report is analysis. It grants no implementation authority. Each proposal in this report needs its own Product Owner approval and its own Architect-bounded Issue before implementation.

**Snapshot note.** Two different times occur in this report. Every code observation, line count, and measurement describes the fixed snapshot `68fdbcc4`. Every Issue and Pull Request status describes the workflow status time above. A code observation at `68fdbcc4` stays true for that snapshot after a later merge changes `main`. Statements about status always name the status time or the exact commit.

---

## 1. Executive summary

The package is a five-stage OpenFOAM batch pipeline (~5,100 lines of self-contained Bash across six scripts). It is governed by a strong written contract (`docs/RUN_BATCH_HANDOFF_SPEC.md`, v4) and, since Issue #4, a 16-scenario automated acceptance suite that runs in GitHub Actions without OpenFOAM.

The current phase restores v4 conformance through small test-backed bug fixes. At the status time it is nearly complete: Pull Request #12 merged as `121c8beb` and closed the Issue #6 scope; Pull Request #16 for Issue #9 is approved at exact commit `317b219b` and waits for the Owner merge; Issue #10 stays blocked until Issue #9 merges.

The dominant defect class is **"failure produces success"**. Five of the seven confirmed defects are variants of it. All share one root cause: each stage runner re-implements its own job management, locking, summary output, and failure accounting, and each copy drifted independently. Measured duplication: 36 helper functions are defined in 2 to 6 scripts each.

The highest-value maintainability investment is a shared stage library. The specification does not forbid one: Section 3.3 says agents SHOULD preserve the self-contained deployment unless a separate reviewed change introduces a library, and Section 26 lists a common library as not required. Introducing one is therefore a reviewed deviation from a SHOULD-level property and needs an Owner-approved `SPEC_CHANGE` that updates the deployment rules. The highest-value UX investments are a consolidated end-of-run report and a read-only status mode. The test suite built in the current phase is what makes the refactor safe; the roadmap below exploits that order.

## 2. Specification summary

The v4 specification (1,693 lines, 29 sections) is the normative contract. It exists so that independent agents can recreate, review, or modify the scripts without hidden conversation context.

| Area | Normative content |
|---|---|
| Purpose (S1) | `run_batch.sh` orchestrates; five stage runners are independent execution units. Pipeline: DOE CSV -> setup -> mesh -> flow -> transport -> post-processing. |
| CLI (S6) | Fixed canonical stage order regardless of input order; stage aliases; job precedence: stage override, then `-j`, then runner default; narrow integer `--save-times` at the top level; batch-ID extraction rules; duplicate-destination rejection. |
| Stage model (S3, S8) | Top level owns lifecycle, orchestration, and propagation. Runners own case discovery, OpenFOAM commands, restart semantics, and their own logs/summary/failure artifacts. Master-first script resolution with batch-local fallback. Agents SHOULD preserve self-contained scripts; a library needs a separate reviewed change (S3.3). |
| I/O (S4, S9, S14-18) | `batch_<id>/case_<Case>/{flow,trd,vtk}`; exports `BATCH_CSV`, `BATCH_CSV_PATH`, `BATCH_NUMBER`, `BATCH_DIR`, `SCALAR_FIELD`; exact OpenFOAM command sequences per stage. |
| Errors (S12, S23.P) | Stage failure -> batch failure -> run failure; `--keep-going` attempts remaining batches, final status stays non-zero; the parallel scheduler must count child exit statuses. |
| Logging (S19) | Preflight facts, stage start/source/command/elapsed, failure exit codes, batch elapsed time on success and failure; `%q` escaping is display-only. |
| Parallelism (S10-12) | Three layers: batches x cases x MPI ranks; MPI oversubscription warning is advisory only; batch subshell isolation is required. |
| Resume (S7, S21) | Initialize vs reuse workspace rules with overwrite and CSV-identity guards; marker-based resume per stage; `FORCE_*` is explicit only. |
| Compatibility (S28-29) | A definition-of-done list of every externally observable behavior; baseline fingerprints identify v4. |
| Constraints (S5, S26-27) | GNU/Linux, Bash >= 4 (>= 4.3 for `-B > 1`), GNU coreutils, naive CSV. Non-goals (not required by v4): Python orchestrator, scheduler integration, common shell library, RFC CSV parsing. Section 26 allows them as separate reviewed future changes. Six recorded technical-debt items. |

**Implementation behavior at the `68fdbcc4` snapshot** conforms after the merged fixes (#4, #5, #7), with three residual gaps at that snapshot: mesh and flow command-failure propagation; a missing requested post-processing case and a missing transport flow prerequisite that still produced false success, plus unhardened failure-artifact write errors; and top-level help omissions. The documented Section 27 debt also applies.

**Status of those gaps at the status time.** The second gap is closed: Pull Request #12 merged as `121c8beb` and completed the Issue #6 scope. The first gap has an approved fix that is not merged: Pull Request #16 for Issue #9 at exact commit `317b219b`. The third gap stays open as Issue #10, blocked until Issue #9 merges.

## 3. Current architecture

Six self-contained scripts. `run_batch.sh` (1,009 lines) parses and validates once, preflights, then per batch: initializes or reuses the workspace, changes directory into it, exports the five environment variables, resolves each stage script master-first, and invokes it with `-i <csv> [-j N]` plus `--save-times` for transport only. Each runner re-parses its own CLI, rediscovers cases from the CSV, manages its own background-job pool (`jobs -rp` / `wait -n` loops), and writes its own summary CSV and failure file.

## 4. UX findings

- **Argument forwarding is verified correct.** `--save-times "60,120,300"` reaches transport as exactly two argv tokens (test 23.I). Stage job overrides and `SCALAR_FIELD` propagation are verified (23.J, 23.K). The top level uses arrays; `%q` output is display-only per S19.
- **Help** is complete for the five runners. The top level omits the documented `--stages` alias and the `--` marker (tracked: Issue #10).
- **Errors** generally name the object and the remedy. Runners exit `1` for both usage and runtime errors; the top level preserves the child's exact exit status (verified `exit=3`).
- **Progress is asymmetric.** Mesh and transport print aggregate progress with running-case detail; flow prints a minimal aggregate line; post prints per-case processing, conversion, skip, and completion messages but has no aggregate progress counter.
- **No consolidated final report.** After a failed multi-batch run, the operator joins five summary CSVs with three different column layouts (10-column setup, 7-column mesh/flow/transport, 4-column post) plus per-case logs.
- **No read-only observability.** Pipeline position per case is only discoverable by inspecting `restart.marker`, `flow.marker`, `transport.marker`, and `post_processing.complete` by hand.
- **Late tool failure.** `need_cmd` runs per stage at case start; a missing `foamToVTK` surfaces after mesh and flow already completed.
- **Setup exit trap.** Setup warns and exits `0` when rows fail (documented Section 27.2 exception). Automation reading exit codes misses partial setup failures.

## 5. Maintainability findings

- **Duplication (measured).** Counting method, at base `68fdbcc4`, over the six scripts (`run_batch.sh`, `setup_cases.sh`, `run_mesh_cases.sh`, `run_flow_cases.sh`, `run_transport_cases.sh`, `run_post_processing_cases.sh`): extract every function-definition line with `grep -E '^(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)'`, take the function name from each match, deduplicate names inside each script, and exclude `main`. A name counts as duplicated when two or more scripts define it. By this method, 36 helper function names are defined in 2 to 6 scripts each. The full set, with the script count in parentheses: `usage`(6), `info`(6), `die`(6), `trim`(5), `sanitize_token`(5), `need_cmd`(5), `make_case_id`(5), `lower`(5), `load_csv_header`(5), `append_summary`(5), `warn`(4), `show_progress`(4), `find_csv_files`(4), `find_col`(4), `csv_quote`(4), `wait_for_free_slot`(3), `validate_config`(3), `safe_path_token`(3), `run_tee`(3), `run_cmd`(3), `remove_nonzero_time_dirs`(3), `process_csv`(3), `has_nonzero_time_dir`(3), `has_constant_mesh`(3), `dict_get`(3), `detect_np`(3), `count_total_cases`(3), `wait_for_slot`(2), `wait_for_all_jobs`(2), `validate_global_config`(2), `mark_failed`(2), `has_cmd`(2), `get_cell_from_row`(2), `get_cell`(2), `dispatch_case_row`(2), `count_status`(2). Copies have diverged: three summary column layouts (setup, mesh/flow/transport, post) and multiple lock styles exist. Every propagation fix so far was applied per file.
- **Global state.** All six scripts operate on file-scope globals; functions communicate through them. Acceptable for Bash, but it makes extraction the only realistic decomposition path.
- **Working-directory contract.** Specification Section 8 requires each selected stage script to run with the batch workspace as its current working directory; `run_batch.sh` implements this with `cd`, and runners default `OUT_DIR="./"`. The behavior is documented and conforming. The design observation stands: the `-O` option exists but the orchestrator never forwards it, so the workspace travels implicitly through the process state instead of an explicit argument. Making `-O` forwarding explicit is a design proposal, not a defect.
- **Stage knowledge in the top level.** The dual post-script name search (`run_postprocess_cases.sh` legacy) and the MPI hint that reads the flow `decomposeParDict` embed stage internals in the orchestrator.
- **Function size.** `preflight` (~90 lines), the per-batch body (~110 lines), and transport `run_one_case` + `solve_transport_case` (~150 lines combined) mix several responsibilities.
- **Compatibility risk concentration.** Master-first resolution (Section 27.6) means a master script change immediately affects reruns of old batches. Runner interfaces must stay frozen during refactoring.

## 6. Gap analysis

Priorities: `P0` correctness/contract violation; `P1` major UX/reliability; `P2` maintainability/architecture debt; `P3` optional.

The "Behavior at `68fdbcc4`" column describes the fixed code snapshot only. The "Recommended change" column names the workflow status at the status time in the report header.

| ID | Pri | Behavior at `68fdbcc4` | Expected behavior | User impact | Root cause | Recommended change | Compat risk | Verification |
|---|---|---|---|---|---|---|---|---|
| G1 | P0 | Mesh/flow OpenFOAM command failure gives case `meshed`/`solved` and stage exit 0 | Failed case and non-zero stage (S23.P) | Silent bad results | Case body left of `\|\|` suppresses `set -e`; `die` exits the subshell past the failure handler | **Tracked: Issue #9.** Pull Request #16 is approved at exact commit `317b219b` and is not merged at the status time | Low: restores documented behavior | Fake-command forced failures per stage |
| G2 | P0 | A missing requested post case and a missing transport flow prerequisite produce false success, and an artifact write error can also give stage success | Missing prerequisites and write errors must fail the stage (S17.4, S18.5, S23.P) | False green runs | Missing-case paths skip the failure artifact; the lock release masked the append status; wait loops discarded child exits | **Closed at the status time.** Pull Request #12 carried the complete Issue #6 scope and merged as `121c8beb` | Low | Missing-case scenarios plus `/dev/full` artifact-write tests |
| G3 | P1 | Setup exits 0 with failed rows (warn only) | Operator-visible failure signal | Partial workspaces look successful | Documented Section 27.2 exception | Owner decision Issue: align the setup exit with the other stages, or keep it and document it loudly | Medium: automation may depend on exit 0 | New 23.P sub-case for setup |
| G4 | P1 | No consolidated end-of-run report | One per-batch/stage/case digest with failing-log paths | Slow failure triage | Reporting is owned per stage and never aggregated | Additive top-level report (`BEHAVIOR_CHANGE`; S19 is the applicable logging and summary contract, and S3.1 gives top-level logging to `run_batch.sh`; per-stage artifacts stay under S15.5, S16.6, S17.9, and S18.5) | Low: additive lines only | Golden-output contract test |
| G5 | P1 | No read-only status view | `--status` reports marker/signature state per case | Manual marker inspection | S21 evidence is never surfaced | New read-only CLI mode (`BEHAVIOR_CHANGE`) | Low: zero writes | New CLI contract scenario |
| G6 | P1 | Tools checked per stage at case start | Selected-stage tool preflight up front | Hours-late failures | `need_cmd` lives in runners only | Top-level advisory (or Owner-chosen hard) preflight | Low when advisory | Restricted-PATH preflight test |
| G7 | P2 | 36 helpers duplicated 2-6x, drifted | One shared implementation per concern | Recurring defect class; triple fix cost | Copy-paste growth under the S3.3 SHOULD-level self-contained property | `master_batch/lib_batch_stage.sh`; a reviewed `SPEC_CHANGE` updates the S3.3/S26 deployment rules first, then extract one concern per Pull Request | Medium; mitigate with frozen runner CLIs and the full suite per PR | 16-scenario suite plus three focused suites green each PR |
| G8 | P2 | The documented S8 cwd rule is the only workspace channel; `-O` exists but is never forwarded | Owner/Architect decision: keep the S8 cwd-only contract, or additionally forward `-O` explicitly | Direct-invocation mistakes outside the orchestrator | Design choice recorded in S8, not a defect | Design proposal: forward `-O "$BATCH_DIR"` in addition to the S8 cwd rule; needs a reviewed S8/S9 contract note | Low | Forwarding assertion in stub tests |
| G9 | P2 | Top-level save-times narrower than transport (S27.4) | One documented story | Operator confusion | Interfaces grew separately | Owner picks: widen the top level, or document the reason in both help texts (`SPEC_CHANGE`) | Low-medium | 23.I variants |
| G10 | P2 | Naive `IFS=','` CSV parsing (S27.1) | Loud rejection of quoted commas | Silent mis-parse | v4 simplification | Shared guard that rejects `"` in data rows (small `BEHAVIOR_CHANGE`) | Low | Malformed-CSV scenario |
| G11 | P2 | No static analysis in CI | ShellCheck gate | Masked-status bugs found only by human review | CI runs tests only | Add a ShellCheck job (`IMPLEMENTATION_ONLY`, CI allowlist) | None | CI run |
| G12 | P3 | Progress formats vary; post has no aggregate progress counter | One format across runners | Cosmetic | Independent evolution | Unify inside the shared library (fold into G7) | Low | Log-format assertions |
| G13 | P3 | S28 fingerprints go stale after every merge | Auto-generated table or removal | Documentation drift | Static spec text | CI-generated fingerprints or delete S28 (`SPEC_CHANGE`, doc) | None | CI artifact |
| G14 | P3 | No smoke test with real OpenFOAM | Optional real-solver smoke lane | Fakes cannot catch solver-argument drift | CI has no OpenFOAM | Optional manual-dispatch workflow on an OpenFOAM host | None | Manual run evidence |

Test-layer coverage today: CLI contract (23.B) yes; argument forwarding (23.I/J/K) yes; orchestration (23.C/D/H) yes; failure paths (23.P plus focused suites) yes; resume/reuse (23.L-O) yes; parallel execution partial (keep-going covered; no `-B > 2` stress); real-solver smoke absent (G14).

## 7. Current architecture diagram

```text
User
 |  bash run_batch.sh -B 2 -j 4 --stage transport --save-times "60,120,300" output_batch_*.csv
 v
+---------------------------------------------------------------------+
| run_batch.sh (1,009 ln)                                             |
|  main(): CLI parse - validate - normalize_stage_selection           |
|  preflight(): batch-ID extraction, dup guard, CSV identity guard,   |
|               MPI hint (reads flow decomposeParDict)                |
|               [stage-specific logic]                                |
|  print_batch_plan(): dry-run                                        |
|  run_all_batches_{sequential,parallel}(): scheduling, keep-going,   |
|               child-status counting                                 |
|  run_batch() (subshell): init/reuse workspace, cd batch_<id>        |
|               (cwd rule documented in S8), export BATCH_*,          |
|               SCALAR_FIELD [hidden global state], master-first      |
|               script resolve                                        |
|  run_stage(): logs command, preserves child exit status             |
+------+-------------+-----------+-------------+---------------+-----+
       | -i CSV -j N | -i -j     | -i -j       | -i -j         | -i -j
       |             |           |             | --save-times  |
       |             |           |             | "60,120,300"  |
       v             v           v             v (exact, 23.I) v
+-----------+ +-----------+ +-----------+ +----------------+ +-----------+
|setup_cases| |run_mesh_  | |run_flow_  | |run_transport_  | |run_post_  |
|.sh 1196ln | |cases 674ln| |cases 658ln| |cases.sh 878 ln | |cases 658ln|
+-----------+ +-----------+ +-----------+ +----------------+ +-----------+
|re-parse   | |re-parse   | |re-parse   | |re-parse CLI    | |re-parse   |
|CSV parse  | |CSV parse  | |CSV parse  | |CSV parse       | |CSV parse  |
|[duplicated| |job pool   | |job pool   | |save-time norm  | |job pool   |
| validation| |summary +  | |summary +  | |fresh/continue  | |summary +  |
| x5]       | |fail file  | |fail file  | |job pool        | |fail file  |
|warn-only  | |[weak error| |[weak error| |summary + fail  | |(4-column  |
|exit S27.2 | | prop: #9] | | prop: #9] | |(hardened PR#12)| | schema)   |
+-----+-----+ +-----+-----+ +-----+-----+ +-------+--------+ +-----+-----+
      |             |             |               |                |
      v             v             v               v                v
  case dirs     blockMesh...  simpleFoam... scalarTransport...  foamToVTK
                +-------- OpenFOAM via PATH (mpirun -np <NP>) --------+
```

### Current architecture pain points

These pain points describe the `68fdbcc4` snapshot.

1. Weak error propagation in mesh and flow: the one remaining false-success path at that snapshot. Issue #9 tracks it, and Pull Request #16 holds an approved fix at commit `317b219b` that is not merged at the status time.
2. Five copies of stage machinery: 36 functions with up to 6 definitions; four summary/lock/progress variants; per-file bug fixing.
3. Single-channel workspace passing: the documented S8 cwd rule is the only workspace channel; `-O` is never forwarded, so direct invocation outside the orchestrator must reproduce the cwd convention by hand.
4. Reporting never aggregates: failure triage crosses five CSVs with three column layouts.
5. Stage knowledge bleeding upward: the MPI hint and the legacy post-name search live in the orchestrator.
6. Setup's warn-only exit: the last stage whose failure does not gate the exit code.

## 8. Target architecture diagram

Incremental target. Still Bash; the external v4 CLI contract stays frozen.

```text
                     User
                       |  (CLI unchanged: frozen v4 contract)
                       v
        +------------------------------+
        | run_batch.sh - thin frontend |
        |  parse once -> validate once |
        |  -> normalize once           |
        +--------------+---------------+
                       v
        +------------------------------+
        | Normalized run configuration |
        | (stages, jobs, save-times,   |
        |  scalar field, paths)        |
        +--------------+---------------+
                       v
        +------------------------------+
        | Batch orchestrator           |
        |  workspace init/reuse,       |
        |  scheduling, keep-going,     |
        |  run-report aggregation      |
        +---+----+----+----+----+------+
            v    v    v    v    v        one uniform adapter call:
         setup mesh flow transport post  runner -i CSV -O "$BATCH_DIR"
            |    |    |    |    |        [-j N] [stage options]
        +---+----+----+----+----+-----+  plus documented BATCH_* env
        | master_batch/lib_batch_stage|
        | .sh (sourced; ships with    |  single owner of:
        | the template; a reviewed    |   CSV parsing, locks, summary,
        | SPEC_CHANGE updates S3.3/S26|   record_case_result(),
        |                             |   stage_final_gate(),
        |                             |   job pool, progress format
        +--------------+--------------+
                       v
                 OpenFOAM via PATH
Verification net on every PR: 16-scenario shared suite,
three focused suites, ShellCheck.
```

Raw CLI arguments cross exactly one boundary (frontend to runners) in their already-contract-tested form; everything else travels as normalized configuration. Runner CLIs and the exported environment stay byte-compatible, so old batches rerun unchanged.

## 9. Current to target migration path

```text
CURRENT
   |
   v
(1) Contract stabilization      PR #12 merged, Issue #9 approved, Issue #10, G3 decision
   |
   v
(2) CLI/UX normalization        G4 report, G5 status, G6 preflight, G9 save-times
   |
   v
(3) Stage adapter boundary      G8 decision: explicit -O forwarding in addition to the S8 cwd rule
   |
   v
(4) Shared execution utilities  G7/G12 library, one concern per PR
   |
   v
TARGET
```

| Transition | What changes | What stays compatible | Main risk | Required regression test |
|---|---|---|---|---|
| (1) Stabilization | Failure gates in mesh/flow; setup exit policy; help text | All CLIs, schemas, restart semantics | An over-tight gate breaks legitimate skip paths | Full 23.P plus focused failure suites |
| (2) CLI/UX normalization | Additive run report, `--status`, tool preflight, save-times story | Every existing invocation and output line | Output additions break log scrapers | Golden-output plus new CLI scenarios |
| (3) Adapter boundary | If the Owner adopts the G8 proposal: the orchestrator passes `-O "$BATCH_DIR"` in addition to the S8 cwd rule, with a reviewed S8/S9 contract note | Runner defaults and the S8 cwd behavior keep direct invocation working | None significant | Forwarding assertions in stub tests |
| (4) Shared utilities | One concern per PR: locking -> result recording -> job pool -> CSV parse -> progress | Runner CLIs, environment, schemas, markers all frozen | Behavioral drift during extraction | Entire suite green per PR; ShellCheck |

A full rewrite or a Python migration is **not** recommended: the contract suite proves the Bash implementation is testable, Section 26 lists a Python orchestrator as a non-goal, and no finding requires capabilities Bash lacks.

## 10. Proposed bounded Issues

| # | Proposal | Classification | Write surface | Non-goals | Acceptance / tests | Dependencies | Compatibility requirement |
|---|---|---|---|---|---|---|---|
| I-A | ShellCheck in CI (G11) | `IMPLEMENTATION_ONLY` | `.github/workflows/batch-contract.yml`, `tests/**` | No source changes; no autofix | CI job green with a pinned version and curated directives | none | No production change |
| I-B | Setup failure exit decision (G3) | `BEHAVIOR_CHANGE` | `src/master_batch/setup_cases.sh`, one focused test file, spec S14.8/S27.2 clause diff | No summary schema change | Failed row gives non-zero exit; skip rows unchanged | PR #12 merged | Exit-code consumers must be notified |
| I-C | Consolidated run report (G4) | `BEHAVIOR_CHANGE` with a specification clause diff | `src/run_batch.sh`, focused test, `docs/RUN_BATCH_HANDOFF_SPEC.md` clauses S19 (top-level MUST-log list) and S23 (new acceptance sub-case) | No schema, marker, or exit-code changes; no stage-runner changes; no per-stage artifact changes under S15.5, S16.6, S17.9, S18.5 | Clause level: S19 gains the report block in the top-level MUST-log list and removes no existing line; S23 gains one sub-case that asserts every added line. Code level: the report lists per-stage case counts and failing log paths; a golden-output test asserts the exact block | Phase (1) complete; Owner approval of the S19 clause diff | Additive output only; existing log lines and their order stay unchanged |
| I-D | `--status` mode (G5) | `BEHAVIOR_CHANGE` | `src/run_batch.sh`, focused test, spec S6.4 addition | No writes; no OpenFOAM calls | Marker-derived state per case; read-only proven by tree diff | I-C optional | New flag only |
| I-E | Selected-stage tool preflight (G6) | `BEHAVIOR_CHANGE` with a specification clause diff | `src/run_batch.sh`, focused test, `docs/RUN_BATCH_HANDOFF_SPEC.md` clauses S19 (preflight result line), S5 (OpenFOAM tools in `PATH`), and S23 (new acceptance sub-case); S3.1 already gives preflight validation to `run_batch.sh` and needs no diff | No per-case `need_cmd` removal from any runner; no runner changes; no new hard failure in the advisory default | Clause level: S19 states the tool-preflight line, S5 states which commands each selected stage requires, and S23 gains one sub-case. Code level: a restricted-`PATH` test proves the missing tool is named before stage 1 starts and that the advisory default leaves every exit status unchanged | Phase (1) complete; Owner approval of the S19/S5 clause diff and of the advisory-versus-hard default | Advisory default; a hard-failure mode needs a separate Owner decision |
| I-F | Explicit `-O` forwarding in addition to the S8 cwd rule (G8) | Design decision; `BEHAVIOR_CHANGE` with a reviewed S8/S9 contract note | `src/run_batch.sh`, stub-test assertion, spec S8/S9 note | No runner changes; the S8 cwd rule stays | Stubs record `-O <batch_dir>`; all suites green | Phase (1) complete; Owner adoption of G8 | Runner defaults and cwd behavior preserved |
| I-G | Shared stage library (G7, G12) | `SPEC_CHANGE` plus behavior-preserving refactor series | Spec S3.3/S26 diff first, then per PR: `src/master_batch/lib_batch_stage.sh` plus one runner concern plus tests | No CLI, schema, or marker changes ever | Each PR: full shared and focused suites green | I-A, phase (1), Owner spec approval | Frozen runner interfaces |

## 11. Recommended first bounded implementation Issue

**Land the in-flight work first.** At the status time, Pull Request #12 has merged as `121c8beb`. The remaining in-flight work is the Owner merge of Pull Request #16 at approved commit `317b219b` for Issue #9, then Issue #10 in the Owner's sequence.

The first new item after that is **I-A (ShellCheck in CI)**: zero production risk, immediate review leverage, and it hardens the verification net that every later phase depends on.
