#!/usr/bin/env python3
"""
Prepare paired flow-domain VTI training samples.

For each case listed in output_batch_#.csv:

    input_data/<case_id>.vti
        <- case_<id>/vtk/flow_0.vtu
        using the input contract

    output_data/<case_id>.vti
        <- the numerically greatest flow_latest_#.vtu
        using the output contract

The preparation script selects source files. The shared transform treats every
file as a generic VTK source and discovers field names, types, roles,
associations, and channels exclusively from the selected contract.

The --write-pt flag optionally writes corresponding PyTorch .pt files.
Both transforms use the same frozen normalization statistics.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys

from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


CASE_ALIASES = ("Case", "case")
LATEST_PATTERN = re.compile(r"^flow_latest_(\d+)\.vtu$", re.IGNORECASE)


@dataclass(frozen=True)
class CaseTask:
    case_id: str
    row_number: int
    input_vtu: Path
    output_vtu: Path


@dataclass(frozen=True)
class TaskResult:
    case_id: str
    row_number: int
    input_vtu: str
    output_vtu: str
    input_pt: str
    output_pt: str
    input_vti: str
    output_vti: str
    status: str
    message: str


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    bundle_dir = script_dir / "shared_cfd_transform_native_vtk_bundle"

    parser = argparse.ArgumentParser(
        description=(
            "Prepare paired flow_0/flow_latest VTI training samples "
            "from an output_batch CSV."
        )
    )
    parser.add_argument(
        "batch_csv",
        type=Path,
        help="Input output_batch_#.csv file.",
    )
    parser.add_argument(
        "--cases-root",
        type=Path,
        default=None,
        help=(
            "Directory containing case_<id> directories. "
            "Default: directory containing batch_csv."
        ),
    )
    parser.add_argument(
        "--input-data",
        type=Path,
        required=True,
        help="Output directory for transformed flow_0 .vti files.",
    )
    parser.add_argument(
        "--output-data",
        type=Path,
        required=True,
        help="Output directory for transformed flow_latest .vti files.",
    )
    parser.add_argument(
        "--transform",
        type=Path,
        default=bundle_dir / "shared_cfd_transform_native_vtk.py",
        help="Path to shared_cfd_transform_native_vtk.py.",
    )
    parser.add_argument(
        "--input-contract",
        type=Path,
        default=(
            bundle_dir
            / "flow_training_input_contract.example.json"
        ),
        help=(
            "Transform contract for flow/0 input data. "
            "Expected channels: Ux, Uy, Uz, p, wallDistance "
            "and fluid_mask."
        ),
    )
    parser.add_argument(
        "--output-contract",
        type=Path,
        default=(
            bundle_dir
            / "flow_training_output_contract.example.json"
        ),
        help=(
            "Transform contract for the selected flow_latest source. "
            "Expected target channels: Ux, Uy, Uz and p."
        ),
    )
    parser.add_argument(
        "--normalization",
        type=Path,
        default=bundle_dir / "normalization_stats.example.json",
        help="Frozen normalization statistics.",
    )
    parser.add_argument(
        "--input-scenario",
        type=Path,
        default=None,
        help="Optional scenario JSON/YAML forwarded to input transforms.",
    )
    parser.add_argument(
        "--output-scenario",
        type=Path,
        default=None,
        help="Optional scenario JSON/YAML forwarded to output transforms.",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=1,
        help=(
            "Maximum concurrent transform processes (default: 1). "
            "Each process may use substantial memory."
        ),
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing requested outputs and metadata.",
    )
    parser.add_argument(
        "--write-pt",
        action="store_true",
        help=(
            "Also write PyTorch .pt files beside the default .vti files. "
            "VTU preprocessing is performed only once."
        ),
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Return a nonzero exit status if any case fails.",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=None,
        help=(
            "Manifest CSV path. Default: flow_dataset_manifest.csv "
            "in the parent directory of --output-data."
        ),
    )
    return parser.parse_args()


def clean_cell(value: str | None) -> str:
    return (value or "").strip()


def make_case_id(raw_case: str) -> str:
    value = clean_cell(raw_case)
    value = re.sub(r"\s+", "_", value)
    value = re.sub(r"[^0-9A-Za-z._-]", "_", value)
    value = re.sub(r"_+", "_", value).strip("_")

    if not value:
        raise ValueError("Empty Case value")

    if value.startswith("case_"):
        return value
    return f"case_{value}"


def find_case_column(fieldnames: Iterable[str]) -> str:
    normalized = {
        clean_cell(name).lower(): name
        for name in fieldnames
        if name is not None
    }
    for alias in CASE_ALIASES:
        actual = normalized.get(alias.lower())
        if actual is not None:
            return actual
    raise ValueError(
        f"CSV is missing a Case column; accepted aliases={CASE_ALIASES}"
    )


def find_case_vtk_directory(cases_root: Path, case_id: str) -> Path:
    """
    Locate the VTK directory for one case.

    Supported layouts include:

        <root>/<case_id>/vtk
        <root>/<case_id>/flow/vtk
        <root>/cases/<case_id>/vtk
        <root>/cases/<case_id>/flow/vtk
    """
    case_candidates = [
        cases_root / case_id,
        cases_root / "cases" / case_id,
    ]

    # Also locate case directories nested below cases_root.
    case_candidates.extend(
        path
        for path in cases_root.rglob(case_id)
        if path.is_dir()
    )

    vtk_candidates: set[Path] = set()

    for case_dir in case_candidates:
        for vtk_dir in (
            case_dir / "vtk",
            case_dir / "flow" / "vtk",
        ):
            if (vtk_dir / "flow_0.vtu").is_file():
                vtk_candidates.add(vtk_dir.resolve())

        # Support an additional intermediate directory while requiring that
        # the discovered vtk directory belongs to this exact case.
        for input_file in case_dir.rglob("flow_0.vtu"):
            if input_file.parent.name == "vtk":
                vtk_candidates.add(input_file.parent.resolve())

    # Final fallback: search by source file and inspect its ancestors.
    if not vtk_candidates:
        for input_file in cases_root.rglob("flow_0.vtu"):
            ancestor_names = {
                parent.name
                for parent in input_file.parents
            }
            if case_id in ancestor_names:
                vtk_candidates.add(input_file.parent.resolve())

    if not vtk_candidates:
        raise FileNotFoundError(
            f"Cannot find flow_0.vtu for {case_id!r} below "
            f"{cases_root}. Supported layouts are "
            f"'{case_id}/vtk' and '{case_id}/flow/vtk'."
        )

    if len(vtk_candidates) > 1:
        locations = ", ".join(
            str(path) for path in sorted(vtk_candidates)
        )
        raise RuntimeError(
            f"Multiple VTK directories found for {case_id}: {locations}"
        )

    return next(iter(vtk_candidates))


def select_latest_vtu(vtk_dir: Path) -> Path:
    candidates: list[tuple[int, Path]] = []

    for path in vtk_dir.glob("flow_latest_*.vtu"):
        match = LATEST_PATTERN.match(path.name)
        if match:
            candidates.append((int(match.group(1)), path.resolve()))

    if not candidates:
        raise FileNotFoundError(
            f"No flow_latest_#.vtu found in {vtk_dir}"
        )

    # A training pair needs one final output. Select the greatest numeric ID.
    candidates.sort(key=lambda item: (item[0], item[1].name))
    return candidates[-1][1]


def discover_tasks(
    batch_csv: Path,
    cases_root: Path,
) -> tuple[list[CaseTask], list[TaskResult]]:
    tasks: list[CaseTask] = []
    failures: list[TaskResult] = []
    seen: set[str] = set()

    with batch_csv.open("r", encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames is None:
            raise ValueError(f"CSV has no header: {batch_csv}")

        case_column = find_case_column(reader.fieldnames)

        for row_number, row in enumerate(reader, start=2):
            try:
                case_id = make_case_id(row.get(case_column, ""))

                if case_id in seen:
                    raise ValueError(f"Duplicate case in CSV: {case_id}")
                seen.add(case_id)

                vtk_dir = find_case_vtk_directory(
                    cases_root,
                    case_id,
                )

                input_vtu = (vtk_dir / "flow_0.vtu").resolve()
                if not input_vtu.is_file():
                    raise FileNotFoundError(
                        f"Missing input file: {input_vtu}"
                    )

                output_vtu = select_latest_vtu(vtk_dir)

                tasks.append(
                    CaseTask(
                        case_id=case_id,
                        row_number=row_number,
                        input_vtu=input_vtu,
                        output_vtu=output_vtu,
                    )
                )
            except Exception as exc:
                raw_case = clean_cell(row.get(case_column, ""))
                failures.append(
                    TaskResult(
                        case_id=raw_case or f"row_{row_number}",
                        row_number=row_number,
                        input_vtu="",
                        output_vtu="",
                        input_pt="",
                        output_pt="",
                        input_vti="",
                        output_vti="",
                        status="discovery_failed",
                        message=str(exc),
                    )
                )

    return tasks, failures


def run_transform(
    *,
    python_executable: str,
    transform_script: Path,
    contract: Path,
    normalization: Path,
    source_vtu: Path,
    destination_vti: Path,
    destination_pt: Path | None,
    metadata_path: Path,
    sample_id: str,
    overwrite: bool,
    scenario: Path | None = None,
) -> tuple[str, str]:
    requested_outputs = [destination_vti, metadata_path]
    if destination_pt is not None:
        requested_outputs.append(destination_pt)

    if not overwrite and all(path.is_file() for path in requested_outputs):
        return "skipped", "all requested outputs already exist"

    for path in requested_outputs:
        path.parent.mkdir(parents=True, exist_ok=True)

    command = [
        python_executable,
        str(transform_script),
        "--source",
        str(source_vtu),
        "--contract",
        str(contract),
        "--normalization",
        str(normalization),
        "--output",
        str(destination_vti),
        "--metadata",
        str(metadata_path),
        "--sample-id",
        sample_id,
    ]

    if scenario is not None:
        command.extend(["--scenario", str(scenario)])

    if destination_pt is not None:
        command.extend(
            [
                "--pt-output",
                str(destination_pt),
            ]
        )

    existed_before = {
        path: path.exists()
        for path in requested_outputs
    }

    completed = subprocess.run(
        command,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    if completed.returncode != 0:
        # Only remove files newly created by this failed execution.
        for path, previously_existed in existed_before.items():
            if not previously_existed:
                path.unlink(missing_ok=True)

        stderr_lines = [
            line.strip()
            for line in completed.stderr.splitlines()
            if line.strip()
        ]
        transform_errors = [
            line
            for line in stderr_lines
            if line.startswith("TRANSFORM_ERROR:")
        ]
        detail = (
            transform_errors[-1]
            if transform_errors
            else completed.stderr.strip() or completed.stdout.strip()
        )
        raise RuntimeError(
            f"Transform exited with code {completed.returncode}: {detail}"
        )

    missing_outputs = [
        path for path in requested_outputs
        if not path.is_file()
    ]
    if missing_outputs:
        raise RuntimeError(
            "Transform reported success but did not create: "
            + ", ".join(str(path) for path in missing_outputs)
        )

    created = ", ".join(str(path) for path in requested_outputs)
    return "created", f"created: {created}"


def process_case(
    task: CaseTask,
    args: argparse.Namespace,
) -> TaskResult:
    input_vti = (
        args.input_data / f"{task.case_id}.vti"
    ).resolve()
    output_vti = (
        args.output_data / f"{task.case_id}.vti"
    ).resolve()

    input_pt = (
        (args.input_data / f"{task.case_id}.pt").resolve()
        if args.write_pt
        else None
    )
    output_pt = (
        (args.output_data / f"{task.case_id}.pt").resolve()
        if args.write_pt
        else None
    )

    input_metadata = (
        args.input_data / f"{task.case_id}.metadata.json"
    ).resolve()
    output_metadata = (
        args.output_data / f"{task.case_id}.metadata.json"
    ).resolve()

    try:
        input_status, input_message = run_transform(
            python_executable=sys.executable,
            transform_script=args.transform,
            contract=args.input_contract,
            normalization=args.normalization,
            source_vtu=task.input_vtu,
            destination_pt=input_pt,
            destination_vti=input_vti,
            metadata_path=input_metadata,
            sample_id=f"{task.case_id}:flow_0",
            overwrite=args.overwrite,
            scenario=args.input_scenario,
        )

        output_status, output_message = run_transform(
            python_executable=sys.executable,
            transform_script=args.transform,
            contract=args.output_contract,
            normalization=args.normalization,
            source_vtu=task.output_vtu,
            destination_pt=output_pt,
            destination_vti=output_vti,
            metadata_path=output_metadata,
            sample_id=f"{task.case_id}:{task.output_vtu.stem}",
            overwrite=args.overwrite,
            scenario=args.output_scenario,
        )

        return TaskResult(
            case_id=task.case_id,
            row_number=task.row_number,
            input_vtu=str(task.input_vtu),
            output_vtu=str(task.output_vtu),
            input_pt=str(input_pt) if input_pt is not None else "",
            output_pt=str(output_pt) if output_pt is not None else "",
            input_vti=str(input_vti),
            output_vti=str(output_vti),
            status="ok",
            message=(
                f"input={input_status}: {input_message}; "
                f"output={output_status}: {output_message}"
            ),
        )
    except Exception as exc:
        return TaskResult(
            case_id=task.case_id,
            row_number=task.row_number,
            input_vtu=str(task.input_vtu),
            output_vtu=str(task.output_vtu),
            input_pt=str(input_pt) if input_pt is not None else "",
            output_pt=str(output_pt) if output_pt is not None else "",
            input_vti=str(input_vti),
            output_vti=str(output_vti),
            status="transform_failed",
            message=str(exc),
        )


def write_manifest(path: Path, results: list[TaskResult]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)

    fieldnames = [
        "case_id",
        "row_number",
        "input_vtu",
        "output_vtu",
        "input_pt",
        "output_pt",
        "input_vti",
        "output_vti",
        "status",
        "message",
    ]

    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(
            stream,
            fieldnames=fieldnames,
        )
        writer.writeheader()

        for result in sorted(
            results,
            key=lambda item: (item.row_number, item.case_id),
        ):
            writer.writerow(
                {
                    name: getattr(result, name)
                    for name in fieldnames
                }
            )


def verify_transform_cli(
    python_executable: str,
    transform_script: Path,
) -> None:
    """Fail fast if the transform does not support the generic --source CLI."""
    completed = subprocess.run(
        [python_executable, str(transform_script), "--help"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    help_text = completed.stdout + completed.stderr

    if completed.returncode != 0:
        raise SystemExit(
            f"Transform script failed to start: {transform_script}\n"
            f"{help_text.strip()}"
        )
    if "--source" not in help_text:
        raise SystemExit(
            f"Transform script {transform_script} does not support "
            "--source. Update shared_cfd_transform_native_vtk.py or point "
            "--transform at a compatible version."
        )
    for legacy_flag in ("--flow", "--trd"):
        if legacy_flag in help_text:
            raise SystemExit(
                f"Transform script {transform_script} still exposes the "
                f"legacy {legacy_flag} option and is incompatible."
            )


def main() -> int:
    args = parse_args()

    args.batch_csv = args.batch_csv.expanduser().resolve()
    args.cases_root = (
        args.cases_root.expanduser().resolve()
        if args.cases_root is not None
        else args.batch_csv.parent
    )
    args.input_data = args.input_data.expanduser().resolve()
    args.output_data = args.output_data.expanduser().resolve()
    args.transform = args.transform.expanduser().resolve()
    args.input_contract = args.input_contract.expanduser().resolve()
    args.output_contract = args.output_contract.expanduser().resolve()
    args.normalization = args.normalization.expanduser().resolve()

    args.input_scenario = (
        args.input_scenario.expanduser().resolve()
        if args.input_scenario is not None
        else None
    )
    args.output_scenario = (
        args.output_scenario.expanduser().resolve()
        if args.output_scenario is not None
        else None
    )

    if args.manifest is None:
        args.manifest = (
            args.output_data.parent / "flow_dataset_manifest.csv"
        ).resolve()
    else:
        args.manifest = args.manifest.expanduser().resolve()

    if args.input_data == args.output_data:
        raise SystemExit(
            "--input-data and --output-data must be different directories."
        )

    if args.jobs < 1:
        raise SystemExit("--jobs must be >= 1")

    required_files = (
        args.batch_csv,
        args.transform,
        args.input_contract,
        args.output_contract,
        args.normalization,
        *(
            path
            for path in (args.input_scenario, args.output_scenario)
            if path is not None
        ),
    )
    for path in required_files:
        if not path.is_file():
            raise SystemExit(f"Required file not found: {path}")

    verify_transform_cli(sys.executable, args.transform)

    args.input_data.mkdir(parents=True, exist_ok=True)
    args.output_data.mkdir(parents=True, exist_ok=True)

    tasks, results = discover_tasks(args.batch_csv, args.cases_root)

    print(
        json.dumps(
            {
                "batch_csv": str(args.batch_csv),
                "cases_root": str(args.cases_root),
                "input_contract": str(args.input_contract),
                "output_contract": str(args.output_contract),
                "discovered_cases": len(tasks),
                "discovery_failures": len(results),
                "jobs": args.jobs,
                "primary_output_format": ".vti",
                "write_pt": args.write_pt,
            },
            indent=2,
        )
    )

    for failure in results:
        print(
            f"[{failure.status}] row={failure.row_number} "
            f"case={failure.case_id}: {failure.message}",
            file=sys.stderr,
            flush=True,
        )

    with ThreadPoolExecutor(max_workers=args.jobs) as executor:

        futures = {
            executor.submit(process_case, task, args): task
            for task in tasks
        }

        for future in as_completed(futures):
            result = future.result()
            results.append(result)
            print(
                f"[{result.status}] {result.case_id}: {result.message}",
                flush=True,
            )

    manifest = args.manifest
    write_manifest(manifest, results)

    failure_count = sum(
        result.status not in {"ok"}
        for result in results
    )

    print(
        json.dumps(
            {
                "status": "ok" if failure_count == 0 else "partial_failure",
                "total": len(results),
                "successful": len(results) - failure_count,
                "failed": failure_count,
                "manifest": str(manifest),
            },
            indent=2,
        )
    )

    if failure_count and args.strict:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())