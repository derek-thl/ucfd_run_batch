# UCFD run-batch Package Review

- Author: `derek-implementer`
- Date: 2026-08-27
- Reviewed `main` SHA: `68fdbcc413b29f4ec2a0c43bb3930e98891af57f`
- Report Issue: #14
- Classification: `DOCUMENTATION_ONLY`

**Authority note.** This report is analysis. It grants no implementation authority. Each proposal in this report needs its own Product Owner approval and its own Architect-bounded Issue before implementation.

---

## 1. Executive summary

The package is a five-stage OpenFOAM batch pipeline (~5,100 lines of self-contained Bash across six scripts). It is governed by a strong written contract (`docs/RUN_BATCH_HANDOFF_SPEC.md`, v4) and, since Issue #4, a 16-scenario automated acceptance suite that runs in GitHub Actions without OpenFOAM.

The current phase restores v4 conformance through small test-backed bug fixes. It is nearly complete: Pull Request #12 is in re-review; Issues #9 and #10 wait for Owner sequencing.

The dominant defect class is **"failure produces success"**. Five of the seven confirmed defects are variants of it. All share one root cause: each stage runner re-implements its own job management, locking, summary output, and failure accounting, and each copy drifted independently. Measured duplication: 25 helper functions are defined in 2 to 6 scripts each.

The highest-value maintainability investment is a shared stage library. The specification currently forbids it (Sections 3.3 and 26), so it requires an Owner-approved `SPEC_CHANGE`. The highest-value UX investments are a consolidated end-of-run report and a read-only status mode. The test suite built in the current phase is what makes the refactor safe; the roadmap below exploits that order.

## 2. Specification summary

The v4 specification (1,693 lines, 29 sections) is the normative contract. It exists so that independent agents can recreate, review, or modify the scripts without hidden conversation context.

| Area | Normative content |
|---|---|
| Purpose (S1) | `run_batch.sh` orchestrates; five stage runners are independent execution units. Pipeline: DOE CSV -> setup -> mesh -> flow -> transport -> post-processing. |
| CLI (S6) | Fixed canonical stage order regardless of input order; stage aliases; job precedence: stage override, then `-j`, then runner default; narrow integer `--save-times` at the top level; batch-ID extraction rules; duplicate-destination rejection. |
| Stage model (S3, S8) | Top level owns lifecycle, orchestration, and propagation. Runners own case discovery, OpenFOAM commands, restart semantics, and their own logs/summary/failure artifacts. Master-first script resolution with batch-local fallback. No shared library (S3.3). |
| I/O (S4, S9, S14-18) | `batch_<id>/case_<Case>/{flow,trd,vtk}`; exports `BATCH_CSV`, `BATCH_CSV_PATH`, `BATCH_NUMBER`, `BATCH_DIR`, `SCALAR_FIELD`; exact OpenFOAM command sequences per stage. |
| Errors (S12, S23.P) | Stage failure -> batch failure -> run failure; `--keep-going` attempts remaining batches, final status stays non-zero; the parallel scheduler must count child exit statuses. |
| Logging (S19) | Preflight facts, stage start/source/command/elapsed, failure exit codes, batch elapsed time on success and failure; `%q` escaping is display-only. |
| Parallelism (S10-12) | Three layers: batches x cases x MPI ranks; MPI oversubscription warning is advisory only; batch subshell isolation is required. |
| Resume (S7, S21) | Initialize vs reuse workspace rules with overwrite and CSV-identity guards; marker-based resume per stage; `FORCE_*` is explicit only. |
| Compatibility (S28-29) | A definition-of-done list of every externally observable behavior; baseline fingerprints identify v4. |
| Constraints (S5, S26-27) | GNU/Linux, Bash >= 4 (>= 4.3 for `-B > 1`), GNU coreutils, naive CSV. Non-goals: Python orchestrator, scheduler integration, shared library, RFC CSV parsing. Six recorded technical-debt items. |

**Current implementation behavior** conforms after the merged fixes (#4, #5, #7), with three tracked residual gaps: mesh/flow command-failure propagation (Issue #9), failure-artifact write-error hardening (Pull Request #12, in re-review), and top-level help omissions (Issue #10), plus the documented Section 27 debt.

## 3. Current architecture

Six self-contained scripts. `run_batch.sh` (1,009 lines) parses and validates once, preflights, then per batch: initializes or reuses the workspace, changes directory into it, exports the five environment variables, resolves each stage script master-first, and invokes it with `-i <csv> [-j N]` plus `--save-times` for transport only. Each runner re-parses its own CLI, rediscovers cases from the CSV, manages its own background-job pool (`jobs -rp` / `wait -n` loops), and writes its own summary CSV and failure file.

## 4. UX findings

- **Argument forwarding is verified correct.** `--save-times "60,120,300"` reaches transport as exactly two argv tokens (test 23.I). Stage job overrides and `SCALAR_FIELD` propagation are verified (23.J, 23.K). The top level uses arrays; `%q` output is display-only per S19.
- **Help** is complete for the five runners. The top level omits the documented `--stages` alias and the `--` marker (tracked: Issue #10).
- **Errors** generally name the object and the remedy. Runners exit `1` for both usage and runtime errors; the top level preserves the child's exact exit status (verified `exit=3`).
- **Progress is asymmetric.** Mesh and transport print rich progress with running-case detail; flow prints a minimal line; post prints none.
- **No consolidated final report.** After a failed multi-batch run, the operator joins five summary CSVs with two different schemas (7-column stage CSVs, 4-column post CSV) plus per-case logs.
- **No read-only observability.** Pipeline position per case is only discoverable by inspecting `restart.marker`, `flow.marker`, `transport.marker`, and `post_processing.complete` by hand.
- **Late tool failure.** `need_cmd` runs per stage at case start; a missing `foamToVTK` surfaces after mesh and flow already completed.
- **Setup exit trap.** Setup warns and exits `0` when rows fail (documented Section 27.2 exception). Automation reading exit codes misses partial setup failures.

## 5. Maintainability findings

- **Duplication (measured).** 25 helper functions are defined in 2 to 6 scripts each: `trim`, `lower`, `sanitize_token`, `make_case_id`, `append_summary`, `load_csv_header`, `need_cmd`, `die`/`info`/`warn`, `usage`, wait/slot loops, `show_progress`, `dict_get`, `detect_np`, `run_tee`, `has_constant_mesh`, time-directory helpers, `mark_failed`, and more. Copies have diverged: four summary schemas/lock styles exist. Every propagation fix so far was applied per file.
- **Global state.** All six scripts operate on file-scope globals; functions communicate through them. Acceptable for Bash, but it makes extraction the only realistic decomposition path.
- **Hidden working-directory contract.** Stage runners depend on being started inside `batch_<id>`: `run_batch.sh` changes directory before invoking, and runners default `OUT_DIR="./"`. The `-O` option exists but the orchestrator never forwards it. The S9 environment variables are a documented fallback; the working directory is not.
- **Stage knowledge in the top level.** The dual post-script name search (`run_postprocess_cases.sh` legacy) and the MPI hint that reads the flow `decomposeParDict` embed stage internals in the orchestrator.
- **Function size.** `preflight` (~90 lines), the per-batch body (~110 lines), and transport `run_one_case` + `solve_transport_case` (~150 lines combined) mix several responsibilities.
- **Compatibility risk concentration.** Master-first resolution (Section 27.6) means a master script change immediately affects reruns of old batches. Runner interfaces must stay frozen during refactoring.

## 6. Gap analysis

Priorities: `P0` correctness/contract violation; `P1` major UX/reliability; `P2` maintainability/architecture debt; `P3` optional.

| ID | Pri | Current behavior | Expected behavior | User impact | Root cause | Recommended change | Compat risk | Verification |
|---|---|---|---|---|---|---|---|---|
| G1 | P0 | Mesh/flow OpenFOAM command failure gives case `meshed`/`solved` and stage exit 0 | Failed case and non-zero stage (S23.P) | Silent bad results | Case body left of `\|\|` suppresses `set -e`; `die` exits the subshell past the failure handler | **Tracked: Issue #9** (approved, awaiting sequencing) | Low: restores documented behavior | Fake-command forced failures per stage |
| G2 | P0 | Artifact write error could give stage success | Write errors must not produce success | False green runs | Lock release masked the append status; wait loops discarded child exits | **Tracked: Pull Request #12** at `31cfe967` (in re-review) | Low | `/dev/full` artifact-write tests |
| G3 | P1 | Setup exits 0 with failed rows (warn only) | Operator-visible failure signal | Partial workspaces look successful | Documented Section 27.2 exception | Owner decision Issue: align the setup exit with the other stages, or keep it and document it loudly | Medium: automation may depend on exit 0 | New 23.P sub-case for setup |
| G4 | P1 | No consolidated end-of-run report | One per-batch/stage/case digest with failing-log paths | Slow failure triage | Reporting is owned per stage and never aggregated | Additive top-level report (`BEHAVIOR_CHANGE`; S15 guards artifacts) | Low: additive lines only | Golden-output contract test |
| G5 | P1 | No read-only status view | `--status` reports marker/signature state per case | Manual marker inspection | S21 evidence is never surfaced | New read-only CLI mode (`BEHAVIOR_CHANGE`) | Low: zero writes | New CLI contract scenario |
| G6 | P1 | Tools checked per stage at case start | Selected-stage tool preflight up front | Hours-late failures | `need_cmd` lives in runners only | Top-level advisory (or Owner-chosen hard) preflight | Low when advisory | Restricted-PATH preflight test |
| G7 | P2 | 25 helpers duplicated 2-6x, drifted | One shared implementation per concern | Recurring defect class; triple fix cost | S3.3 no-shared-library rule plus copy-paste growth | `master_batch/lib_batch_stage.sh` (`SPEC_CHANGE`); extract one concern per Pull Request | Medium; mitigate with frozen runner CLIs and the full suite per PR | 16-scenario suite plus three focused suites green each PR |
| G8 | P2 | Runners require cwd = batch dir; `-O` unused by the orchestrator | Explicit workspace argument or a documented cwd contract | Direct-invocation mistakes | Implicit cwd convention | Forward `-O "$BATCH_DIR"` (behavior-preserving); document in S9 | Low | Forwarding assertion in stub tests |
| G9 | P2 | Top-level save-times narrower than transport (S27.4) | One documented story | Operator confusion | Interfaces grew separately | Owner picks: widen the top level, or document the reason in both help texts (`SPEC_CHANGE`) | Low-medium | 23.I variants |
| G10 | P2 | Naive `IFS=','` CSV parsing (S27.1) | Loud rejection of quoted commas | Silent mis-parse | v4 simplification | Shared guard that rejects `"` in data rows (small `BEHAVIOR_CHANGE`) | Low | Malformed-CSV scenario |
| G11 | P2 | No static analysis in CI | ShellCheck gate | Masked-status bugs found only by human review | CI runs tests only | Add a ShellCheck job (`IMPLEMENTATION_ONLY`, CI allowlist) | None | CI run |
| G12 | P3 | Progress format varies; post has none | One format across runners | Cosmetic | Independent evolution | Unify inside the shared library (fold into G7) | Low | Log-format assertions |
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
|               [hidden cwd contract], export BATCH_*, SCALAR_FIELD   |
|               [hidden global state], master-first script resolve    |
|  run_stage(): logs command, preserves child exit status             |
+------+-------------+-----------+-------------+---------------+-----+
       | -i CSV -j N | -i -j     | -i -j       | -i -j         | -i -j
       |             |           |             | --save-times  |
       |             |           |             | "60,120,300"  |
       v             v           v             v (exact, 23.I) v
+-----------+ +-----------+ +-----------+ +----------------+ +-----------+
|setup_cases| |run_mesh_  | |run_flow_  | |run_transport_  | |run_post_  |
|.sh 1196ln | |cases 674ln| |cases 659ln| |cases.sh 891 ln | |cases 671ln|
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

1. Weak error propagation in mesh and flow (Issue #9): the one remaining false-success path.
2. Five copies of stage machinery: 25 functions with up to 6 definitions; four summary/lock/progress variants; per-file bug fixing.
3. Hidden working-directory contract: runners silently require invocation from `batch_<id>`.
4. Reporting never aggregates: failure triage crosses five CSVs and two schemas.
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
        | the template; SPEC_CHANGE   |   CSV parsing, locks, summary,
        | gate: S3.3 / S26)           |   record_case_result(),
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
(1) Contract stabilization      PR #12, Issue #9, Issue #10, G3 decision
   |
   v
(2) CLI/UX normalization        G4 report, G5 status, G6 preflight, G9 save-times
   |
   v
(3) Stage adapter boundary      G8 explicit -O forwarding, documented cwd contract
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
| (3) Adapter boundary | Orchestrator passes `-O "$BATCH_DIR"` explicitly; cwd contract documented | Runner defaults keep direct invocation working | None significant | Forwarding assertions in stub tests |
| (4) Shared utilities | One concern per PR: locking -> result recording -> job pool -> CSV parse -> progress | Runner CLIs, environment, schemas, markers all frozen | Behavioral drift during extraction | Entire suite green per PR; ShellCheck |

A full rewrite or a Python migration is **not** recommended: the contract suite proves the Bash implementation is testable, Section 26 lists a Python orchestrator as a non-goal, and no finding requires capabilities Bash lacks.

## 10. Proposed bounded Issues

| # | Proposal | Classification | Write surface | Non-goals | Acceptance / tests | Dependencies | Compatibility requirement |
|---|---|---|---|---|---|---|---|
| I-A | ShellCheck in CI (G11) | `IMPLEMENTATION_ONLY` | `.github/workflows/batch-contract.yml`, `tests/**` | No source changes; no autofix | CI job green with a pinned version and curated directives | none | No production change |
| I-B | Setup failure exit decision (G3) | `BEHAVIOR_CHANGE` | `src/master_batch/setup_cases.sh`, one focused test file, spec S14.8/S27.2 clause diff | No summary schema change | Failed row gives non-zero exit; skip rows unchanged | PR #12 merged | Exit-code consumers must be notified |
| I-C | Consolidated run report (G4) | `BEHAVIOR_CHANGE` | `src/run_batch.sh`, focused test | No schema or exit-code changes | Report lists per-stage case counts and failing log paths; golden test | Phase (1) complete | Additive output only |
| I-D | `--status` mode (G5) | `BEHAVIOR_CHANGE` | `src/run_batch.sh`, focused test, spec S6.4 addition | No writes; no OpenFOAM calls | Marker-derived state per case; read-only proven by tree diff | I-C optional | New flag only |
| I-E | Selected-stage tool preflight (G6) | `BEHAVIOR_CHANGE` | `src/run_batch.sh`, focused test | No per-case check removal | Missing tool named before stage 1 starts | Phase (1) complete | Advisory default |
| I-F | Explicit `-O` forwarding and cwd contract documentation (G8) | `BUG_FIX_WITHOUT_CONTRACT_CHANGE` | `src/run_batch.sh`, stub-test assertion, spec S9 note | No runner changes | Stubs record `-O <batch_dir>`; all suites green | Phase (1) complete | Runner defaults preserved |
| I-G | Shared stage library (G7, G12) | `SPEC_CHANGE` plus behavior-preserving refactor series | Spec S3.3/S26 diff first, then per PR: `src/master_batch/lib_batch_stage.sh` plus one runner concern plus tests | No CLI, schema, or marker changes ever | Each PR: full shared and focused suites green | I-A, phase (1), Owner spec approval | Frozen runner interfaces |

## 11. Recommended first bounded implementation Issue

**Land the in-flight work first:** the Architect re-review of Pull Request #12 at `31cfe9674cd2523187d7a6a6de47f021301608a1`, then Issues #9 and #10 in the Owner's sequence.

The first new item after that is **I-A (ShellCheck in CI)**: zero production risk, immediate review leverage, and it hardens the verification net that every later phase depends on.
