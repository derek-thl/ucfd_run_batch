#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
generate_ucfd_doe_lhs_simple.py (Derek Lai, 2026-06-15)

Purpose
-------
Generate a UCFD DOE table from parameters defined directly in this Python file.

Sampling rules
--------------
1) Scalar/fixed value:
   "T_ref": 298.15
   -> one fixed level

2) Discrete values:
   "met__WD_deg": [-45.0, -22.5, 0.0, 22.5, 45.0]
   -> sampled from the listed discrete levels

3) Continuous range:
   "met__WS_mps": (1.0, 5.0)
   -> sampled continuously by standard Latin Hypercube Sampling

4) Backward-compatible discrete linspace levels:
   "P1_SEB_A__Cemit_ugpm3": (0.0, 1850.0, 3)
   -> expanded to discrete levels by numpy.linspace()

DOE naming convention
---------------------
Source parameters use:
    <FAB>_<STACK_ZONE>_<SIDE_ID>__<VARIABLE>_<UNIT>

Examples:
    P1_SEB_A__Uexit_mps
    P2_VOC_B__Cemit_ugpm3
    P3_AEX_A__Texit_K

Context parameters use:
    <DOMAIN>__<VARIABLE>_<UNIT>

Examples:
    met__WS_mps
    met__WD_deg
    amb__Tamb_K
    terrain__z0_m
"""

from __future__ import annotations

import argparse
import re
from functools import reduce
from operator import mul
from pathlib import Path
from typing import Any, Mapping, Sequence

import numpy as np
import pandas as pd
from scipy.stats.qmc import LatinHypercube


# =============================================================================
# 1. USER-EDITABLE DOE PARAMETER CONFIGURATION
# =============================================================================
# You only need to edit DOE_PARAMS.
#
# Parameter definition formats:
#
#   "parameter_name": fixed_value
#   "parameter_name": (low, high, n_levels)
#   "parameter_name": [value_1, value_2, value_3, ...]
#
# Examples:
#
#   "amb__Tamb_K": 298.15
#   "met__WS_mps": (0.0, 4.0)       # continuous range
#   "met__WS_mps": (0.0, 4.0, 5)    # discrete linspace levels
#   "met__WD_deg": [0.0, 135.0, 157.5, 180.0]
#
# =============================================================================

DOE_PARAMS: dict[str, Any] = {
    # Meteorological / inflow parameters
    # met__WS_mps is currently a discrete linspace DOE factor.
    # Use (0.5, 4.5) instead if continuous LHS sampling is desired.
    "met__WS_mps": [0.01, 0.2, 0.5, 1.0, 2.0, 5.0],  # discrete linspace levels
    "met__WD_deg": [0.0, 135.0, 175.5, 180.0],
    "met__stability": ["neutral", "stable"],
    "amb__RH_frac": 0.75,
    "amb__Pamb_Pa": 101300.00,
    "amb__Tamb_K": 301.15,
    "amb__Cbg_ugpm3": 0.0, # background concentration for all species, set to 0 to avoid confusion with source emissions
    "terrain__z0_m": 0.1,  # typical aerodynamic roughness, not varied in this DOE but can be added as needed
    # -------------------------------------------------------------------------
    # Source velocity parameters
    # Unit: m/s
    # Naming: <FAB>_<STACK_ZONE>_<SIDE_ID>__Uexit_mps
    # -------------------------------------------------------------------------

    "P1_SEB_A__Uexit_mps": 10.0,
    "P1_AEX_A__Uexit_mps": 10.0,
    "P1_SEX_A__Uexit_mps": 10.0,
    "P1_VOC_A__Uexit_mps": 10.0,
    "P1_SEB_B__Uexit_mps": 10.0,
    "P1_AEX_B__Uexit_mps": 10.0,
    "P1_SEX_B__Uexit_mps": 10.0,
    "P1_VOC_B__Uexit_mps": 10.0,

    "P2_SEB_A__Uexit_mps": 10.0,
    "P2_AEX_A__Uexit_mps": 10.0,
    "P2_SEX_A__Uexit_mps": 10.0,
    "P2_VOC_A__Uexit_mps": 10.0,
    "P2_SEB_B__Uexit_mps": 10.0,
    "P2_AEX_B__Uexit_mps": 10.0,
    "P2_SEX_B__Uexit_mps": 10.0,
    "P2_VOC_B__Uexit_mps": 10.0,

    "P3_SEB_A__Uexit_mps": 10.0,
    "P3_AEX_A__Uexit_mps": 10.0,
    "P3_SEX_A__Uexit_mps": 10.0,
    "P3_VOC_A__Uexit_mps": 10.0,
    "P3_SEB_B__Uexit_mps": 10.0,
    "P3_AEX_B__Uexit_mps": 10.0,
    "P3_SEX_B__Uexit_mps": 10.0,
    "P3_VOC_B__Uexit_mps": 10.0,

    # -------------------------------------------------------------------------
    # Source concentration parameters
    # Unit: ug/m3
    # Naming: <FAB>_<STACK_ZONE>_<SIDE_ID>__Cemit_ugpm3
    # -------------------------------------------------------------------------

    "P1_SEB_A__Cemit_ugpm3": 1500.0,
    "P1_AEX_A__Cemit_ugpm3": 550.0,
    "P1_SEX_A__Cemit_ugpm3": 750.0,
    "P1_VOC_A__Cemit_ugpm3": 750.0,
    "P1_SEB_B__Cemit_ugpm3": 1500.0,
    "P1_AEX_B__Cemit_ugpm3": 550.0,
    "P1_SEX_B__Cemit_ugpm3": 750.0,
    "P1_VOC_B__Cemit_ugpm3": 750.0,

    "P2_SEB_A__Cemit_ugpm3": (0.0, 1850.0, 2),
    "P2_AEX_A__Cemit_ugpm3": (0.0, 350.0, 2),
    "P2_SEX_A__Cemit_ugpm3": (0.0, 600.0, 2),
    "P2_VOC_A__Cemit_ugpm3": (0.0, 7000.0, 3),
    "P2_SEB_B__Cemit_ugpm3": (0.0, 1850.0, 2),
    "P2_AEX_B__Cemit_ugpm3": (0.0, 350.0, 2),
    "P2_SEX_B__Cemit_ugpm3": (0.0, 600.0, 2),
    "P2_VOC_B__Cemit_ugpm3": (0.0, 7000.0, 3),

    "P3_SEB_A__Cemit_ugpm3": 3750.0,
    "P3_AEX_A__Cemit_ugpm3": 350.0,
    "P3_SEX_A__Cemit_ugpm3": 200.0,
    "P3_VOC_A__Cemit_ugpm3": 1000.0,
    "P3_SEB_B__Cemit_ugpm3": 3750.0,
    "P3_AEX_B__Cemit_ugpm3": 350.0,
    "P3_SEX_B__Cemit_ugpm3": 200.0,
    "P3_VOC_B__Cemit_ugpm3": 1000.0,

    # -------------------------------------------------------------------------
    # Source emission temperature parameters
    # Unit: K
    # Naming: <FAB>_<STACK_ZONE>_<SIDE_ID>__Texit_K
    # -------------------------------------------------------------------------

    "P1_SEB_A__Texit_K": 298.15,
    "P1_AEX_A__Texit_K": 298.15,
    "P1_SEX_A__Texit_K": 298.15,
    "P1_VOC_A__Texit_K": 333.15,
    "P1_SEB_B__Texit_K": 298.15,
    "P1_AEX_B__Texit_K": 298.15,
    "P1_SEX_B__Texit_K": 298.15,
    "P1_VOC_B__Texit_K": 333.15,

    "P2_SEB_A__Texit_K": 298.15,
    "P2_AEX_A__Texit_K": 298.15,
    "P2_SEX_A__Texit_K": 298.15,
    "P2_VOC_A__Texit_K": 333.15,
    "P2_SEB_B__Texit_K": 298.15,
    "P2_AEX_B__Texit_K": 298.15,
    "P2_SEX_B__Texit_K": 298.15,
    "P2_VOC_B__Texit_K": 333.15,

    "P3_SEB_A__Texit_K": 298.15,
    "P3_AEX_A__Texit_K": 298.15,
    "P3_SEX_A__Texit_K": 298.15,
    "P3_VOC_A__Texit_K": 333.15,
    "P3_SEB_B__Texit_K": 298.15,
    "P3_AEX_B__Texit_K": 298.15,
    "P3_SEX_B__Texit_K": 298.15,
    "P3_VOC_B__Texit_K": 333.15,
}


# =============================================================================
# 2. DOE PARAMETER PARSING
# =============================================================================

SOURCE_PARAM_RE = re.compile(
    r"^P[0-9]+_(SEB|AEX|SEX|VOC)_[AB]__(Uexit_mps|Cemit_ugpm3|Texit_K)$"
)

CONTEXT_PARAM_RE = re.compile(
    r"^(met|amb|terrain)__[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)*$"
)


def to_snake_case(text: str) -> str:
    """Convert a column name into a simple snake_case string."""
    text = text.strip().lower()
    text = re.sub(r"[^a-z0-9]+", "_", text)
    text = re.sub(r"_+", "_", text)
    return text.strip("_")


def to_doe_case_name(text: str) -> str:
    """
    Convert DOE column name to lower-case while preserving the semantic
    double-underscore separator between entity_id and variable_key.

    Example:
        P1_SEB_A__Uexit_mps -> p1_seb_a__uexit_mps
    """
    parts = text.strip().split("__")

    clean_parts = []
    for part in parts:
        part = part.strip().lower()
        part = re.sub(r"[^a-z0-9]+", "_", part)
        part = re.sub(r"_+", "_", part)
        clean_parts.append(part.strip("_"))

    return "__".join(clean_parts)


def format_output_name(name: str, *, doe_case_columns: bool = False) -> str:
    """Return the output column name according to the selected naming mode."""
    return to_doe_case_name(name) if doe_case_columns else name


def validate_param_name(name: str) -> None:
    """Validate DOE parameter naming convention before sampling."""
    if SOURCE_PARAM_RE.fullmatch(name):
        return

    if CONTEXT_PARAM_RE.fullmatch(name):
        return

    raise ValueError(
        f"Invalid DOE parameter name: {name!r}. Expected either source format "
        "<FAB>_<STACK_ZONE>_<SIDE_ID>__<VARIABLE>_<UNIT>, for example "
        "P1_SEB_A__Uexit_mps, or context format <DOMAIN>__<VARIABLE>_<UNIT>, "
        "for example met__WS_mps."
    )


def is_continuous_range_spec(spec: Any) -> bool:
    """Return True if spec is a continuous range: (low, high)."""
    if not isinstance(spec, tuple) or len(spec) != 2:
        return False

    low, high = spec

    if isinstance(low, bool) or isinstance(high, bool):
        return False

    try:
        low_f = float(low)
        high_f = float(high)
    except (TypeError, ValueError):
        return False

    return np.isfinite(low_f) and np.isfinite(high_f)


def is_discrete_range_spec(spec: Any) -> bool:
    """Return True if spec is a discrete linspace definition: (low, high, n_levels)."""
    if not isinstance(spec, tuple) or len(spec) != 3:
        return False

    low, high, n_levels = spec

    if isinstance(n_levels, bool) or not isinstance(n_levels, int):
        return False

    try:
        low_f = float(low)
        high_f = float(high)
    except (TypeError, ValueError):
        return False

    return np.isfinite(low_f) and np.isfinite(high_f)


def expand_param_levels(
    name: str,
    spec: Any,
    *,
    round_digits: int | None = 6,
) -> list[Any]:
    """
    Expand one parameter definition into discrete DOE levels.

    Supported formats here:
    - scalar fixed value: 298.15 -> [298.15]
    - discrete linspace tuple: (0.0, 1.0, 3) -> [0.0, 0.5, 1.0]
    - discrete list: [0, 135, 180] -> [0, 135, 180]
    """
    if is_discrete_range_spec(spec):
        low, high, n_levels = spec
        low = float(low)
        high = float(high)

        if n_levels <= 0:
            raise ValueError(f"{name}: n_levels must be positive, got {n_levels}.")
        if high < low:
            raise ValueError(f"{name}: high must be >= low, got low={low}, high={high}.")

        if n_levels == 1:
            levels = np.array([low], dtype=float)
        else:
            levels = np.linspace(low, high, n_levels, dtype=float)

        if round_digits is not None:
            levels = np.round(levels, round_digits)

        return levels.tolist()

    if isinstance(spec, list):
        if len(spec) == 0:
            raise ValueError(f"{name}: discrete value list must be non-empty.")
        return list(spec)

    return [spec]


def normalize_doe_params(
    params: Mapping[str, Any],
    *,
    round_digits: int | None = 6,
) -> list[dict[str, Any]]:
    """
    Normalize DOE parameter definitions.

    Output item formats:
    - {"name": ..., "kind": "fixed", "value": ...}
    - {"name": ..., "kind": "discrete", "levels": [...]}
    - {"name": ..., "kind": "continuous", "low": ..., "high": ...}
    """
    if not params:
        raise ValueError("DOE_PARAMS must contain at least one parameter.")

    param_defs: list[dict[str, Any]] = []
    seen: set[str] = set()

    for name, spec in params.items():
        if not isinstance(name, str) or not name.strip():
            raise ValueError(f"Invalid parameter name: {name!r}")

        clean_name = name.strip()
        validate_param_name(clean_name)

        if clean_name in seen:
            raise ValueError(f"Duplicated parameter name: {clean_name}")
        seen.add(clean_name)

        if is_continuous_range_spec(spec):
            low, high = spec
            low = float(low)
            high = float(high)

            if high < low:
                raise ValueError(f"{clean_name}: high must be >= low, got low={low}, high={high}.")

            if high == low:
                param_defs.append({"name": clean_name, "kind": "fixed", "value": low})
            else:
                param_defs.append(
                    {"name": clean_name, "kind": "continuous", "low": low, "high": high}
                )
            continue

        levels = expand_param_levels(clean_name, spec, round_digits=round_digits)
        if len(levels) == 0:
            raise ValueError(f"{clean_name}: levels must be non-empty.")

        if len(levels) == 1:
            param_defs.append({"name": clean_name, "kind": "fixed", "value": levels[0]})
        else:
            param_defs.append({"name": clean_name, "kind": "discrete", "levels": levels})

    return param_defs


def count_full_factorial_cases(param_defs: Sequence[Mapping[str, Any]]) -> int | None:
    """
    Return theoretical full-factorial DOE case count.

    If any continuous range exists, the full-factorial count is not finite.
    """
    if any(param["kind"] == "continuous" for param in param_defs):
        return None

    return reduce(
        mul,
        (
            1 if param["kind"] == "fixed" else len(param["levels"])
            for param in param_defs
        ),
        1,
    )


# =============================================================================
# 3. LHS DOE GENERATION
# =============================================================================

def _sampling_dimension(param_defs: Sequence[Mapping[str, Any]]) -> int:
    """Return the effective LHS dimension for varying parameters."""
    dim = 0
    for param in param_defs:
        if param["kind"] == "continuous":
            dim += 1
        elif param["kind"] == "discrete":
            dim += 1
    return dim


def _build_row_from_unit_sample(
    unit_sample: np.ndarray,
    param_defs: Sequence[Mapping[str, Any]],
    *,
    round_digits: int | None = 6,
) -> list[Any]:
    """Map one LHS unit sample row into one DOE row."""
    row: list[Any] = []
    col = 0

    for param in param_defs:
        kind = param["kind"]

        if kind == "fixed":
            row.append(param["value"])
            continue

        u = float(unit_sample[col])
        col += 1

        if kind == "continuous":
            low = float(param["low"])
            high = float(param["high"])
            value = low + u * (high - low)

            if round_digits is not None:
                value = round(value, round_digits)

            row.append(value)
            continue

        levels = param["levels"]
        idx = min(int(np.floor(u * len(levels))), len(levels) - 1)
        row.append(levels[idx])

    return row


def _rows_to_dataframe(
    rows: Sequence[Sequence[Any]],
    param_defs: Sequence[Mapping[str, Any]],
    *,
    case_column: str = "Case",
    case_start: int = 0,
    case_prefix: str = "",
    doe_case_columns: bool = False,
) -> pd.DataFrame:
    """Convert sampled rows into a DOE dataframe."""
    param_names = [param["name"] for param in param_defs]
    column_names = [
        format_output_name(name, doe_case_columns=doe_case_columns)
        for name in param_names
    ]

    if doe_case_columns:
        case_column = to_doe_case_name(case_column)

    df = pd.DataFrame(rows, columns=column_names)

    if case_prefix:
        width = max(4, len(str(case_start + len(df) - 1)))
        case_ids = [f"{case_prefix}{i:0{width}d}" for i in range(case_start, case_start + len(df))]
    else:
        case_ids = list(range(case_start, case_start + len(df)))

    df.insert(0, case_column, case_ids)
    return df


def _row_to_key(row: Sequence[Any]) -> tuple[Any, ...]:
    """Create a hashable row key for uniqueness checks."""
    key: list[Any] = []

    for value in row:
        if isinstance(value, np.generic):
            value = value.item()

        if isinstance(value, float):
            key.append(round(value, 12))
        else:
            key.append(value)

    return tuple(key)


def _coerce_rng(rng: int | np.random.Generator | None) -> np.random.Generator:
    """Return a NumPy Generator from an rng-like input."""
    if isinstance(rng, np.random.Generator):
        return rng
    return np.random.default_rng(rng)


def generate_lhs_doe(
    param_defs: Sequence[Mapping[str, Any]],
    *,
    n_samples: int,
    rng: int | np.random.Generator | None = 42,
    case_start: int = 0,
    case_prefix: str = "",
    doe_case_columns: bool = False,
    unique: bool = True,
    max_attempts: int = 100,
    round_digits: int | None = 6,
) -> pd.DataFrame:
    """
    Generate an LHS DOE from mixed parameter types.

    - fixed value  -> constant column
    - discrete     -> map LHS unit samples to discrete levels
    - continuous   -> standard LHS sampling within [low, high]

    The rng parameter controls random-number generation. It may be:
    - None
    - an integer seed
    - a numpy.random.Generator instance
    """
    if n_samples <= 0:
        raise ValueError(f"n_samples must be positive, got {n_samples}.")

    total_cases = count_full_factorial_cases(param_defs)
    if unique and total_cases is not None and n_samples > total_cases:
        raise ValueError(
            f"Cannot generate {n_samples} unique rows because the theoretical "
            f"full-factorial space only has {total_cases} combinations."
        )

    dim = _sampling_dimension(param_defs)

    if dim == 0:
        base_row = _build_row_from_unit_sample(np.array([], dtype=float), param_defs, round_digits=round_digits)
        if unique and n_samples > 1:
            raise ValueError("All parameters are fixed; only 1 unique DOE row can be generated.")
        return _rows_to_dataframe(
            [base_row for _ in range(n_samples)],
            param_defs,
            case_start=case_start,
            case_prefix=case_prefix,
            doe_case_columns=doe_case_columns,
        )

    has_continuous = any(param["kind"] == "continuous" for param in param_defs)
    rng = _coerce_rng(rng)
    selected_rows: list[list[Any]] = []
    selected_keys: set[tuple[Any, ...]] = set()

    for _ in range(max_attempts):
    """ main sampling loop """
        remaining = n_samples - len(selected_rows)
        if remaining <= 0:
            break

        batch_size = remaining if (has_continuous or not unique) else max(remaining * 4, n_samples)
        lhs_seed = int(rng.integers(0, np.iinfo(np.int32).max))
        sampler = LatinHypercube(d=dim, seed=lhs_seed)
        unit_samples = sampler.random(n=batch_size)

        for unit_row in unit_samples:
            row = _build_row_from_unit_sample(unit_row, param_defs, round_digits=round_digits)

            if unique:
                row_key = _row_to_key(row)
                if row_key in selected_keys:
                    continue
                selected_keys.add(row_key)

            selected_rows.append(row)

            if len(selected_rows) >= n_samples:
                break

    if len(selected_rows) < n_samples:
        raise RuntimeError(
            f"Only generated {len(selected_rows)} unique LHS rows after {max_attempts} attempts. "
            "Try reducing -n, increasing --max-attempts, or using --allow-duplicates."
        )

    return _rows_to_dataframe(
        selected_rows[:n_samples],
        param_defs,
        case_start=case_start,
        case_prefix=case_prefix,
        doe_case_columns=doe_case_columns,
    )


def make_level_summary(
    param_defs: Sequence[Mapping[str, Any]],
    *,
    doe_case_columns: bool = False,
) -> pd.DataFrame:
    """Create a compact table describing DOE parameter definitions."""
    rows = []

    for param in param_defs:
        name = format_output_name(param["name"], doe_case_columns=doe_case_columns)

        if param["kind"] == "continuous":
            rows.append(
                {
                    "parameter": name,
                    "type": "continuous",
                    "n_levels": "continuous",
                    "levels": f"[{param['low']}, {param['high']}]",
                }
            )
        elif param["kind"] == "discrete":
            rows.append(
                {
                    "parameter": name,
                    "type": "discrete",
                    "n_levels": len(param["levels"]),
                    "levels": "; ".join(map(str, param["levels"])),
                }
            )
        else:
            rows.append(
                {
                    "parameter": name,
                    "type": "fixed",
                    "n_levels": 1,
                    "levels": str(param["value"]),
                }
            )

    return pd.DataFrame(rows)




def make_coverage_audit(
    df: pd.DataFrame,
    param_defs: Sequence[Mapping[str, Any]],
    *,
    doe_case_columns: bool = False,
) -> pd.DataFrame:
    """Create marginal coverage counts for all discrete DOE parameters."""
    rows: list[dict[str, Any]] = []

    for param in param_defs:
        if param["kind"] != "discrete":
            continue

        parameter = format_output_name(param["name"], doe_case_columns=doe_case_columns)
        if parameter not in df.columns:
            continue

        counts = df[parameter].value_counts(dropna=False)
        for level in param["levels"]:
            count = int(counts.get(level, 0))
            rows.append(
                {
                    "parameter": parameter,
                    "level": level,
                    "count": count,
                    "fraction": count / len(df) if len(df) else 0.0,
                }
            )

    return pd.DataFrame(rows)


def print_coverage_audit(coverage_df: pd.DataFrame) -> None:
    """Print a compact marginal coverage audit for discrete DOE parameters."""
    if coverage_df.empty:
        print("\nDOE coverage audit: no discrete DOE parameters found.")
        return

    print("\nDOE coverage audit for discrete parameters")
    print("------------------------------------------")

    for parameter, group in coverage_df.groupby("parameter", sort=False):
        items = [
            f"{row.level}: {int(row.count)}"
            for row in group.itertuples(index=False)
        ]
        print(f"{parameter}: " + ", ".join(items))

# =============================================================================
# 4. CLI
# =============================================================================

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Export an LHS-sampled UCFD DOE table from DOE_PARAMS defined in code. "
            "Discrete parameters are sampled by levels, fixed parameters stay constant, "
            "and continuous ranges are sampled directly within their intervals."
        )
    )
    parser.add_argument(
        "-n",
        "--samples",
        type=int,
        default=128,
        help="Number of LHS DOE samples to export. Default: 128",
    )
    parser.add_argument(
        "-s",
        "--seed",
        type=int,
        default=42,
        help="Seed used to initialize the RNG for LHS reproducibility. Default: 42",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=str,
        default="ucfd_doe_lhs.csv",
        help="Output LHS DOE CSV filename. Default: ucfd_doe_lhs.csv",
    )
    parser.add_argument(
        "--summary-output",
        type=str,
        default="",
        help="Optional output level summary CSV filename. If omitted, no summary CSV is written.",
    )
    parser.add_argument(
        "--coverage-output",
        type=str,
        default="",
        help="Optional output coverage audit CSV filename for discrete DOE parameters.",
    )
    parser.add_argument(
        "--no-coverage-audit",
        action="store_true",
        help="Do not print the marginal coverage audit for discrete DOE parameters.",
    )
    parser.add_argument(
        "--doe-case",
        action="store_true",
        help=(
            "Convert output DOE column names to lower-case while preserving "
            "the semantic double-underscore separator, e.g. "
            "P1_SEB_A__Uexit_mps -> p1_seb_a__uexit_mps."
        ),
    )
    parser.add_argument(
        "--snake-case",
        dest="doe_case",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--case-start",
        type=int,
        default=0,
        help="Starting integer for the Case column. Default: 0",
    )
    parser.add_argument(
        "--case-prefix",
        type=str,
        default="",
        help="Optional prefix for case IDs, e.g. UCFD_ -> UCFD_0000.",
    )
    parser.add_argument(
        "--allow-duplicates",
        action="store_true",
        help="Allow duplicated DOE rows. Default: unique rows only.",
    )
    parser.add_argument(
        "--max-attempts",
        type=int,
        default=100,
        help="Maximum retry attempts for unique DOE rows. Default: 100",
    )
    parser.add_argument(
        "--round-digits",
        type=int,
        default=6,
        help="Rounding digits for continuous values and discrete linspace-generated levels. Default: 6",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    param_defs = normalize_doe_params(DOE_PARAMS, round_digits=args.round_digits)
    total_cases = count_full_factorial_cases(param_defs)

    if total_cases is None:
        print("Full Factorial DOE cases: N/A (continuous ranges present)")
    else:
        print(f"Full Factorial DOE cases: {total_cases}")

    rng = np.random.default_rng(args.seed)

    df = generate_lhs_doe(
        param_defs,
        n_samples=args.samples,
        rng=rng,
        case_start=args.case_start,
        case_prefix=args.case_prefix,
        doe_case_columns=args.doe_case,
        unique=not args.allow_duplicates,
        max_attempts=args.max_attempts,
        round_digits=args.round_digits,
    )

    output_path = Path(args.output)
    df.to_csv(output_path, index=False)
    print(f"Wrote DOE table: {output_path} ({len(df)} rows, {len(df.columns)} columns)")

    if args.summary_output:
        summary_df = make_level_summary(param_defs, doe_case_columns=args.doe_case)
        summary_df.to_csv(Path(args.summary_output), index=False)
        print(f"Wrote level summary: {args.summary_output}")

    coverage_df = make_coverage_audit(df, param_defs, doe_case_columns=args.doe_case)

    if args.coverage_output:
        coverage_df.to_csv(Path(args.coverage_output), index=False)
        print(f"Wrote coverage audit: {args.coverage_output}")

    if not args.no_coverage_audit:
        print_coverage_audit(coverage_df)


if __name__ == "__main__":
    main()
