# M3 Numerical Convergence Backlog

## 1. Decision record

Classification: `DEFERRED_SCIENTIFIC_VALIDATION`.

Contract base SHA: `37606c7e6c139a8db55abd61e627eab44239859c`.

Approval: [human Owner decision 6118379564](https://github.com/derek-thl/ucfd_run_batch/issues/80#issuecomment-6118379564). Approved proposal: [M3_PIPELINE_FIRST_SCOPE_37606C7E_R1, B.1–B.9](https://github.com/derek-thl/ucfd_run_batch/issues/99#issuecomment-6109869034).

Planning admission: [#99 frontier 6118397810](https://github.com/derek-thl/ucfd_run_batch/issues/99#issuecomment-6118397810). The merged documentation PR and later exact-main frontier must record integration and effective authority. This memorandum does not declare M3 acceptance.

## 2. Original numerical requirements

The [Owner convergence decision](https://github.com/derek-thl/ucfd_run_batch/issues/80#issuecomment-5796082318), item 2, requires solver-reported convergence under approved `residualControl` values.

Preserve `1e-4` for U, p, and configured turbulence fields. Require the solver marker, actual configuration, final residuals, final time, and continuity record. Do not substitute end time or add a separate persistence window.

Continuity sufficiency and scientific comparisons still need applicable Owner criteria. Invent no tolerance.

## 3. Reason for deferral

The approved mainline priority is reproducible OpenFOAM v2512 runtime and pipeline compatibility.

M3 functional qualification is assessed independently from numerical convergence and scientific accuracy. The amendment takes effect only after the bounded contract, approved documentation integration, and an updated exact-main #99 frontier.

## 4. Preserved historical evidence

[Run 2, 35849247240](https://github.com/derek-thl/ucfd_run_batch/actions/runs/35849247240), attempt 1, used SHA `22e4a181ae614707eda706e10292323ea2f04352`.

The run used Case 7 Flow, Batch Workspace `src/batch_9`, stock OpenCFD v2512, and `simpleFoam -parallel`.

Artifact: [10747203822](https://github.com/derek-thl/ucfd_run_batch/actions/runs/35849247240/artifacts/10747203822), `openfoam-v2512-evidence`.

Archive SHA-256: `fa21ee8d6435bfa0fdf74b8343d980d50de99f91f463492b8353f800feeb3f2f`.

Solver log: `stage-logs/case_7/flow/log.simpleFoam`.

Log SHA-256: `4e804239079169543b3a8a5fcf74869d9bf482e351b9602e82a40cde915165ee`.

Preserve the [Run 2 review](https://github.com/derek-thl/ucfd_run_batch/issues/80#issuecomment-5794897911), [completed convergence assessment](https://github.com/derek-thl/ucfd_run_batch/issues/80#issuecomment-6104793419), and [Owner record result](https://github.com/derek-thl/ucfd_run_batch/issues/80#issuecomment-6105461931).

PR #98 is integrated at the contract base SHA. Its [post-merge CI](https://github.com/derek-thl/ucfd_run_batch/actions/runs/38070664556) passed. Collection capability does not prove complete M3 functional acceptance.

## 5. Results not established

M3 functional acceptance, numerical convergence, scientific accuracy, scientific regression, and Production Model Acceptance are not established by the records above.

Required flow VTU PointData and actual Case 7 mean speed remain unverified in Run 2. Synthetic metric fixture evidence is not Case 7 evidence.

Scientific mesh acceptance remains separate. No causal link from concavity to the convergence failure is established.

## 6. Known numerical failure

Run 2 reached Time 3000. The log contains zero `SIMPLE solution converged` markers.

At Time 3000, initial residuals include:

- Uy: `1.74519e-4`;
- p, first solve: `1.36639e-3`;
- p, second solve: `1.46973e-4`.

These values exceed `1e-4`. The approved convergence requirement failed. Small final linear-solver residuals and Stage success do not change this finding.

Retained final continuity values are local `8.16979e-9`, global `-2.12144e-10`, and cumulative `-3.26268e-5`. No approved continuity tolerance is available.

Run 2 reported 23912 concave cells and one failed mesh check. Keep this raw finding and its run identity.

## 7. Missing Run 2 configuration

Preserve `RUN_2_RUNTIME_CONTROL_RECORD=UNAVAILABLE`.

The retained artifact does not contain actual runtime bytes and hashes for `system/fvSolution`, `system/controlDict`, or `system/fvSchemes`. Complete referenced configuration and proof of runtime versions are also unavailable.

Tree paths and partial startup log values are not complete runtime records. Committed templates and later Case content do not repair this gap.

Do not reconstruct the missing records or repeat the completed search. Any future authorized record must identify its own run.

## 8. Deferred validation scope

[Issue #100](https://github.com/derek-thl/ucfd_run_batch/issues/100) owns deferred Case 7 Flow convergence work under [M5 Issue #81](https://github.com/derek-thl/ucfd_run_batch/issues/81).

The scope includes approved solver convergence, full applicable configuration provenance, residual history, continuity evidence, applicable mesh disposition, and scientific consistency/regression.

Solver-control, relaxation-factor, scheme, and iteration-limit optimization remain deferred candidates. This memorandum authorizes no change.

Preserve the original numerical criterion. Missing scientific criteria remain Owner decisions.

## 9. Risks and limits

After the amendment takes effect, record `NUMERICAL_CONVERGENCE=NOT_ACCEPTED_DEFERRED` and `SCIENTIFIC_REGRESSION_NOT_ESTABLISHED`. Deferral is not PASS.

Non-converged fields may support explicitly labeled pipeline interoperability testing only. They are not scientifically validated CFD results.

Retain the approved v2512 environment, selected Stage command paths, actual outputs, required PointData, actual mean speed, Failure Artifacts, capture integrity, and failure propagation.

Retain every configuration and resource requirement of the approved collector.

Under [#96](https://github.com/derek-thl/ucfd_run_batch/issues/96), invalid finite-volume control volumes and violations of accepted mesh limits remain blocking. Preserve concavity warnings. Missing scientific limits do not become PASS. Grant no blanket mesh waiver.

Functional pipeline qualification does not establish numerical convergence, CFD solution accuracy, scientific regression acceptance, or production-model acceptance.

## 10. Activation and dependency boundary

Activation condition: `DEFERRED_UNTIL_OWNER_DECLARED_MAINLINE_COMPLETE`.

The human Owner must declare accepted M1, M2 rights/build, M3 functional qualification, and M4 runtime/pipeline qualification on [#99](https://github.com/derek-thl/ucfd_run_batch/issues/99) with acceptance links.

The operational milestone excludes Issue #100, M5, and M6 scientific/full qualification. M5 and M6 remain necessary for full migration.

M3 functional acceptance must not depend on Issue #100. M5 or M6 completion must not be required to activate Issue #100.

The M3 dependency in [#78](https://github.com/derek-thl/ucfd_run_batch/issues/78) means M3 functional qualification. Source rights, M2 build, and transport authority remain separate.

## 11. Three-role responsibilities

Human Owner: declare activation, approve missing scientific criteria, approve any later execution budget, and decide scientific acceptance.

Architect: prepare bounded contracts and independently review exact commits, checks, and evidence. Do not implement this documentation or numerical work under the Architect role.

Implementer: act only after an approved contract and authorizing frontier. Keep the exact write allowlist. Publish commands, results, limitations, and evidence.

Activation and Issue creation authorize no execution. A later production decision must specify exact Case, SHA, purpose, scope, attempts, budget, and stop conditions.

At the approved contract base, production use is 215 of 237 minutes with 0 attempts left. Fixture use is 1 of 1 attempts and 46 seconds, with 0 attempts left. Unused time grants no attempt.

## 12. Related contracts

- [#80 M3 qualification](https://github.com/derek-thl/ucfd_run_batch/issues/80).
- [#96 mesh policy](https://github.com/derek-thl/ucfd_run_batch/issues/96) and [Owner policy decision](https://github.com/derek-thl/ucfd_run_batch/issues/96#issuecomment-6061264811).
- [#99 active Tracking Issue](https://github.com/derek-thl/ucfd_run_batch/issues/99).
- [#100 deferred Case 7 convergence child](https://github.com/derek-thl/ucfd_run_batch/issues/100).
- [#81 M5 scientific regression](https://github.com/derek-thl/ucfd_run_batch/issues/81) and [M5 deferral](https://github.com/derek-thl/ucfd_run_batch/issues/81#issuecomment-5707138248).
- [#76 migration roadmap](https://github.com/derek-thl/ucfd_run_batch/issues/76) and [#77 final qualification](https://github.com/derek-thl/ucfd_run_batch/issues/77).
- [RUN_BATCH_HANDOFF_SPEC.md, Section 30](../RUN_BATCH_HANDOFF_SPEC.md#30-m3-functional-qualification-and-deferred-scientific-validation).
