#!/usr/bin/env python3
"""
shared_cfd_transform_native_vtk.py

Reference native-VTK implementation of a deterministic Shared CFD Transform for a UCFD
Digital Twin pipeline.

Implemented stages
------------------
1. Read and assemble VTK-family source data.
2. Inspect and validate field metadata.
3. Harmonize point/cell association for interpolation.
4. Map coordinates and field units.
5. Resample to a canonical cell-centered physical grid.
6. Derive geometry and boundary features.
7. Construct physical, target, loss, metric, and padding masks.
8. Encode scalar, angular, and categorical scenario parameters.
9. Apply frozen train-only normalization statistics.
10. Apply model-shape padding.
11. Build PyTorch tensors and provenance metadata.
12. Optionally invert output normalization and remove model padding.
13. Write VTI output and optionally serialize a PyTorch payload.

Typical prediction task represented by the example contract
------------------------------------------------------------
Inputs:
    Ux, Uy, Uz, p, wallDistance, signed_distance, masks, scenario channels
Target:
    T

Important:
- The script never fits normalization statistics.
- Field units and coordinate transforms are explicit contract values.
- OpenFOAM incompressible ``p`` is often kinematic pressure, not Pa. Configure
  ``value_scale`` explicitly; do not rely on the example value.
- ``T`` is treated as a tracer/concentration field, not temperature.
- A VTP surface alone cannot provide a volumetric U/p/T field. Surface-only
  blocks may be present, but required volumetric fields must exist on at least
  one volumetric block.
- The canonical spatial tensors use [C, Z, Y, X]. VTK export is intentionally
  not implemented here; keep tensor-to-VTK order conversion in a dedicated
  VTI writer.
- VTI and PyTorch mask arrays are selected through
  contract.derived_features.output_channels and
  contract.derived_features.mask_channel_map.

Dependencies:
    numpy
    scipy
    torch
    vtk  (native VTK Python wrappers; PyVista is not required)

Example:
    python shared_cfd_transform_native_vtk.py \
        --flow flow.vtu \
        --trd tracer.vtu \
        --contract shared_cfd_transform_contract.example.json \
        --normalization normalization_stats.example.json \
        --scenario scenario.example.json \
        --output transformed_sample.vti \
        --pt-output transformed_sample.pt \
        --metadata transformed_sample.metadata.json \
        --sample-id case_0001
 """

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import math
import os
import platform
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterator, Mapping, MutableMapping, Sequence

import numpy as np
import torch
from scipy.ndimage import binary_erosion, distance_transform_edt

try:
    import vtk
    from vtk.util.numpy_support import numpy_to_vtk, vtk_to_numpy
except ImportError as exc:  # pragma: no cover - dependency error path
    raise SystemExit(
        "Native VTK Python bindings are required. Install dependencies with:\n"
        "  python -m pip install numpy scipy torch vtk"
    ) from exc


# -----------------------------------------------------------------------------
# Typed failures
# -----------------------------------------------------------------------------


class TransformError(RuntimeError):
    """Base class for deterministic transform failures."""


class ContractError(TransformError):
    """The transform contract is invalid or incompatible with the inputs."""


class SourceDataError(TransformError):
    """The VTK-family source files cannot be read or assembled safely."""


class FieldMetadataError(TransformError):
    """A field is absent, ambiguous, non-numeric, or has invalid components."""


class ResamplingError(TransformError):
    """A source field cannot be resampled under the declared policy."""


class NormalizationError(TransformError):
    """Frozen normalization assets are missing or invalid."""


class InvariantError(TransformError):
    """A required mask, shape, or tensor invariant is violated."""


# -----------------------------------------------------------------------------
# Utility functions
# -----------------------------------------------------------------------------


def load_mapping(path: Path) -> dict[str, Any]:
    """Load JSON or YAML without silently accepting unknown extensions."""
    suffix = path.suffix.lower()
    text = path.read_text(encoding="utf-8")
    if suffix == ".json":
        data = json.loads(text)
    elif suffix in {".yaml", ".yml"}:
        try:
            import yaml
        except ImportError as exc:  # pragma: no cover
            raise ContractError(
                "YAML input requires PyYAML. Install with: pip install pyyaml"
            ) from exc
        data = yaml.safe_load(text)
    else:
        raise ContractError(f"Unsupported mapping format: {path}")
    if not isinstance(data, dict):
        raise ContractError(f"Top-level document must be an object: {path}")
    return data


def canonical_json_bytes(data: Mapping[str, Any]) -> bytes:
    return json.dumps(
        data,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        default=json_default,
    ).encode("utf-8")


def json_default(value: Any) -> Any:
    if dataclasses.is_dataclass(value):
        return dataclasses.asdict(value)
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, torch.Tensor):
        return value.detach().cpu().tolist()
    raise TypeError(f"Object is not JSON serializable: {type(value)!r}")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_array(array: np.ndarray) -> str:
    contiguous = np.ascontiguousarray(array)
    digest = hashlib.sha256()
    digest.update(str(contiguous.dtype).encode("ascii"))
    digest.update(np.asarray(contiguous.shape, dtype=np.int64).tobytes())
    digest.update(contiguous.tobytes())
    return digest.hexdigest()


def sha256_tensor(tensor: torch.Tensor) -> str:
    return sha256_array(tensor.detach().cpu().contiguous().numpy())


def require_keys(mapping: Mapping[str, Any], keys: Sequence[str], context: str) -> None:
    missing = [key for key in keys if key not in mapping]
    if missing:
        raise ContractError(f"{context} is missing keys: {missing}")


def as_float_tuple3(value: Sequence[Any], context: str) -> tuple[float, float, float]:
    if len(value) != 3:
        raise ContractError(f"{context} must contain exactly 3 values.")
    result = tuple(float(v) for v in value)
    if not np.all(np.isfinite(result)):
        raise ContractError(f"{context} contains non-finite values: {result}")
    return result  # type: ignore[return-value]


def as_int_tuple3(value: Sequence[Any], context: str) -> tuple[int, int, int]:
    if len(value) != 3:
        raise ContractError(f"{context} must contain exactly 3 values.")
    result = tuple(int(v) for v in value)
    if any(v <= 0 for v in result):
        raise ContractError(f"{context} must contain positive integers: {result}")
    return result  # type: ignore[return-value]


def ensure_numeric_array(array: np.ndarray, context: str) -> np.ndarray:
    result = np.asarray(array)
    if not np.issubdtype(result.dtype, np.number):
        raise FieldMetadataError(f"{context} is not numeric: dtype={result.dtype}")
    return result


def finite_fraction(array: np.ndarray) -> float:
    if array.size == 0:
        return 0.0
    return float(np.isfinite(array).sum() / array.size)


def normalize_path_list(paths: Sequence[str] | None) -> list[Path]:
    return [Path(path).expanduser().resolve() for path in (paths or [])]


# -----------------------------------------------------------------------------
# Contracts and transform output
# -----------------------------------------------------------------------------


@dataclass(frozen=True)
class GridContract:
    """Canonical cell-centered physical grid."""

    cell_center_origin_xyz: tuple[float, float, float]
    spacing_xyz: tuple[float, float, float]
    dimensions_xyz: tuple[int, int, int]
    model_shape_zyx: tuple[int, int, int] | None
    divisibility_zyx: tuple[int, int, int]
    padding_alignment: str

    @property
    def physical_shape_zyx(self) -> tuple[int, int, int]:
        nx, ny, nz = self.dimensions_xyz
        return nz, ny, nx

    @property
    def spacing_zyx(self) -> tuple[float, float, float]:
        dx, dy, dz = self.spacing_xyz
        return dz, dy, dx

    def cell_centers_xyz(self) -> np.ndarray:
        ox, oy, oz = self.cell_center_origin_xyz
        dx, dy, dz = self.spacing_xyz
        nx, ny, nz = self.dimensions_xyz
        x = ox + np.arange(nx, dtype=np.float64) * dx
        y = oy + np.arange(ny, dtype=np.float64) * dy
        z = oz + np.arange(nz, dtype=np.float64) * dz
        zz, yy, xx = np.meshgrid(z, y, x, indexing="ij")
        # C-order ravel keeps X as the fastest-varying dimension.
        return np.column_stack(
            (
                xx.ravel(order="C"),
                yy.ravel(order="C"),
                zz.ravel(order="C"),
            )
        )

    def physical_bounds_xyz(self) -> tuple[float, float, float, float, float, float]:
        ox, oy, oz = self.cell_center_origin_xyz
        dx, dy, dz = self.spacing_xyz
        nx, ny, nz = self.dimensions_xyz
        return (
            ox - 0.5 * dx,
            ox + (nx - 0.5) * dx,
            oy - 0.5 * dy,
            oy + (ny - 0.5) * dy,
            oz - 0.5 * dz,
            oz + (nz - 0.5) * dz,
        )


@dataclass(frozen=True)
class CoordinateContract:
    """Affine map from source coordinates to project-local coordinates."""

    source_length_unit: str
    target_length_unit: str
    length_scale: float
    rotation_source_to_target: np.ndarray
    translation_target_xyz: np.ndarray

    def map_points(self, points: np.ndarray) -> np.ndarray:
        scaled = np.asarray(points, dtype=np.float64) * self.length_scale
        return scaled @ self.rotation_source_to_target.T + self.translation_target_xyz

    def map_vectors(self, vectors: np.ndarray, value_scale: float) -> np.ndarray:
        scaled = np.asarray(vectors, dtype=np.float64) * value_scale
        return scaled @ self.rotation_source_to_target.T


@dataclass(frozen=True)
class FieldSpec:
    """Spatial field contract."""

    source_group: str
    source_name: str
    output_channels: tuple[str, ...]
    role: str
    kind: str
    required: bool
    expected_components: int
    preferred_source_association: str | None
    interpolation: str
    extrapolation_policy: str
    fill_value_physical: float
    source_unit: str
    target_unit: str
    value_scale: float
    value_offset: float
    rotate_vector: bool
    require_volumetric_source: bool
    minimum_valid_fraction: float

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> "FieldSpec":
        require_keys(
            data,
            [
                "source_group",
                "source_name",
                "output_channels",
                "role",
                "kind",
            ],
            "field spec",
        )
        channels = tuple(str(v) for v in data["output_channels"])
        if not channels:
            raise ContractError("field.output_channels cannot be empty.")
        kind = str(data["kind"]).lower()
        expected = int(
            data.get(
                "expected_components",
                3 if kind == "vector" else 1,
            )
        )
        if expected != len(channels):
            raise ContractError(
                f"Field {data['source_name']!r}: expected_components={expected} "
                f"but output_channels={channels}"
            )
        association = data.get("preferred_source_association")
        if association is not None:
            association = str(association).upper()
            if association not in {"POINT", "CELL"}:
                raise ContractError(
                    "preferred_source_association must be POINT or CELL."
                )
        role = str(data["role"]).upper()
        if role not in {"INPUT", "TARGET", "AUXILIARY"}:
            raise ContractError(f"Unsupported field role: {role}")
        interpolation = str(data.get("interpolation", "linear")).lower()
        if interpolation not in {"linear", "nearest"}:
            raise ContractError(f"Unsupported interpolation: {interpolation}")
        extrapolation = str(
            data.get("extrapolation_policy", "MARK_INVALID")
        ).upper()
        if extrapolation not in {"ERROR", "MARK_INVALID"}:
            raise ContractError(
                f"Extrapolation policy {extrapolation!r} is not implemented. "
                "Supported policies are ERROR and MARK_INVALID."
            )

        return cls(
            source_group=str(data["source_group"]),
            source_name=str(data["source_name"]),
            output_channels=channels,
            role=role,
            kind=kind,
            required=bool(data.get("required", True)),
            expected_components=expected,
            preferred_source_association=association,
            interpolation=interpolation,
            extrapolation_policy=extrapolation,
            fill_value_physical=float(data.get("fill_value_physical", 0.0)),
            source_unit=str(data.get("source_unit", "unspecified")),
            target_unit=str(data.get("target_unit", "unspecified")),
            value_scale=float(data.get("value_scale", 1.0)),
            value_offset=float(data.get("value_offset", 0.0)),
            rotate_vector=bool(data.get("rotate_vector", kind == "vector")),
            require_volumetric_source=bool(
                data.get("require_volumetric_source", True)
            ),
            minimum_valid_fraction=float(
                data.get("minimum_valid_fraction", 0.0)
            ),
        )


@dataclass
class SourceBlock:
    source_group: str
    source_path: Path
    block_path: str
    priority: int
    mesh: vtk.vtkDataSet
    file_sha256: str
    is_volumetric: bool
    bounds_xyz: tuple[float, float, float, float, float, float]


@dataclass(frozen=True)
class PaddingMetadata:
    physical_shape_zyx: tuple[int, int, int]
    model_shape_zyx: tuple[int, int, int]
    pad_before_zyx: tuple[int, int, int]
    pad_after_zyx: tuple[int, int, int]
    alignment: str


@dataclass(frozen=True)
class TransformedSample:
    x: torch.Tensor
    y: torch.Tensor | None
    masks: dict[str, torch.Tensor]
    global_features: torch.Tensor | None
    metadata: dict[str, Any]


# -----------------------------------------------------------------------------
# Frozen normalization
# -----------------------------------------------------------------------------


class FrozenNormalizer:
    """Apply and invert exported train-only normalization statistics."""

    def __init__(self, document: Mapping[str, Any], source_path: Path):
        if document.get("frozen") is not True:
            raise NormalizationError(
                "Normalization document must contain frozen=true."
            )
        channels = document.get("channels")
        if not isinstance(channels, dict):
            raise NormalizationError(
                "Normalization document must contain a channels object."
            )
        self.document = dict(document)
        self.channels: dict[str, Mapping[str, Any]] = channels
        self.source_path = source_path
        self.hash = sha256_bytes(canonical_json_bytes(self.document))

    def require(self, channel_name: str) -> Mapping[str, Any]:
        if channel_name not in self.channels:
            raise NormalizationError(
                f"Frozen normalization is missing channel {channel_name!r}."
            )
        spec = self.channels[channel_name]
        if not isinstance(spec, dict):
            raise NormalizationError(
                f"Normalization entry for {channel_name!r} must be an object."
            )
        return spec

    def apply(
        self,
        channel_name: str,
        values: np.ndarray,
    ) -> np.ndarray:
        """Apply frozen normalization to physical values."""
        spec = self.require(channel_name)
        method = str(spec.get("method", "identity")).lower()
        x = np.asarray(values, dtype=np.float64)

        if method == "identity":
            y = x

        elif method == "zscore":
            scale = self._positive(
                float(spec["std"]),
                f"{channel_name}.std",
            )
            y = (x - float(spec["mean"])) / scale

        elif method == "robust_zscore":
            scale = self._positive(
                float(spec["scale"]),
                f"{channel_name}.scale",
            )
            y = (x - float(spec["median"])) / scale

        elif method == "minmax":
            minimum = float(spec["min"])
            maximum = float(spec["max"])
            input_span = self._positive(
                maximum - minimum,
                f"{channel_name}.max-min",
            )

            output_range = spec.get("output_range", [0.0, 1.0])
            if (
                not isinstance(output_range, Sequence)
                or isinstance(output_range, (str, bytes))
                or len(output_range) != 2
            ):
                raise NormalizationError(
                    f"{channel_name}.output_range must contain two values."
                )

            out_lo = float(output_range[0])
            out_hi = float(output_range[1])
            output_span = self._positive(
                out_hi - out_lo,
                f"{channel_name}.output_range span",
            )
            y = out_lo + (x - minimum) * output_span / input_span

        elif method == "log1p_zscore":
            scale = self._positive(
                float(spec["std"]),
                f"{channel_name}.std",
            )
            epsilon = float(spec.get("epsilon", 0.0))
            if not math.isfinite(epsilon):
                raise NormalizationError(
                    f"{channel_name}.epsilon must be finite."
                )

            shifted = x + epsilon
            if np.any(shifted <= -1.0):
                raise NormalizationError(
                    f"{channel_name}: x + epsilon must be greater than -1."
                )

            y = (
                np.log1p(shifted) - float(spec["mean"])
            ) / scale

        elif method == "signed_log1p_zscore":
            scale = self._positive(
                float(spec["std"]),
                f"{channel_name}.std",
            )
            transformed = np.sign(x) * np.log1p(np.abs(x))
            y = (
                transformed - float(spec["mean"])
            ) / scale

        else:
            raise NormalizationError(
                f"{channel_name}: unsupported method {method!r}."
            )

        if not np.all(np.isfinite(y)):
            raise NormalizationError(
                f"{channel_name}: normalization produced non-finite values."
            )

        return y.astype(np.float32, copy=False)

    def apply_scalar(self, channel_name: str, value: float) -> float:
        array = self.apply(
            channel_name,
            np.asarray([value], dtype=np.float64),
        )
        return float(array[0])

    def inverse(
        self,
        channel_name: str,
        values: np.ndarray,
    ) -> np.ndarray:
        """Invert frozen normalization and return physical values."""
        spec = self.require(channel_name)
        method = str(spec.get("method", "identity")).lower()
        y = np.asarray(values, dtype=np.float64)

        if method == "identity":
            x = y

        elif method == "zscore":
            scale = self._positive(
                float(spec["std"]),
                f"{channel_name}.std",
            )
            x = y * scale + float(spec["mean"])

        elif method == "robust_zscore":
            scale = self._positive(
                float(spec["scale"]),
                f"{channel_name}.scale",
            )
            x = y * scale + float(spec["median"])

        elif method == "minmax":
            minimum = float(spec["min"])
            maximum = float(spec["max"])
            input_span = self._positive(
                maximum - minimum,
                f"{channel_name}.max-min",
            )

            output_range = spec.get("output_range", [0.0, 1.0])
            if (
                not isinstance(output_range, Sequence)
                or isinstance(output_range, (str, bytes))
                or len(output_range) != 2
            ):
                raise NormalizationError(
                    f"{channel_name}.output_range must contain two values."
                )

            out_lo = float(output_range[0])
            out_hi = float(output_range[1])
            output_span = self._positive(
                out_hi - out_lo,
                f"{channel_name}.output_range span",
            )
            x = minimum + (y - out_lo) * input_span / output_span

        elif method == "log1p_zscore":
            scale = self._positive(
                float(spec["std"]),
                f"{channel_name}.std",
            )
            epsilon = float(spec.get("epsilon", 0.0))
            if not math.isfinite(epsilon):
                raise NormalizationError(
                    f"{channel_name}.epsilon must be finite."
                )

            transformed = y * scale + float(spec["mean"])
            with np.errstate(over="ignore", invalid="ignore"):
                x = np.expm1(transformed) - epsilon

        elif method == "signed_log1p_zscore":
            scale = self._positive(
                float(spec["std"]),
                f"{channel_name}.std",
            )
            transformed = y * scale + float(spec["mean"])
            with np.errstate(over="ignore", invalid="ignore"):
                x = (
                    np.sign(transformed)
                    * np.expm1(np.abs(transformed))
                )

        else:
            raise NormalizationError(
                f"{channel_name}: unsupported method {method!r}."
            )

        if not np.all(np.isfinite(x)):
            raise NormalizationError(
                f"{channel_name}: inverse normalization produced "
                "non-finite values."
            )

        return x.astype(np.float32, copy=False)

    @staticmethod
    def _positive(value: float, context: str) -> float:
        if not math.isfinite(value) or value <= 0.0:
            raise NormalizationError(
                f"{context} must be finite and positive; got {value}."
            )
        return value


# -----------------------------------------------------------------------------
# Shared CFD transform
# -----------------------------------------------------------------------------


class SharedCFDTransform:
    """Contract-driven CFD preprocessing shared by training and inference."""

    def __init__(
        self,
        contract: Mapping[str, Any],
        normalizer: FrozenNormalizer,
        contract_path: Path,
    ):
        self.contract = dict(contract)
        self.contract_path = contract_path
        self.contract_hash = sha256_bytes(canonical_json_bytes(self.contract))
        self.normalizer = normalizer

        self.grid = self._parse_grid_contract(self.contract)
        self.coordinate = self._parse_coordinate_contract(self.contract)
        self.field_specs = self._parse_field_specs(self.contract)
        self.input_channels = tuple(
            str(v) for v in self.contract.get("input_channels", [])
        )
        self.target_channels = tuple(
            str(v) for v in self.contract.get("target_channels", [])
        )

        if not self.input_channels and not self.target_channels:
            raise ContractError(
                "At least one input or target channel is required."
            )

        self.conflict_policy = str(
            self.contract.get("source_assembly", {}).get(
                "conflict_policy",
                "REGION_PRIORITY",
            )
        ).upper()
        if self.conflict_policy not in {
            "ERROR_ON_OVERLAP",
            "REGION_PRIORITY",
            "VALIDITY_PRIORITY",
            "WEIGHTED_BLEND",
        }:
            raise ContractError(
                f"Unsupported source conflict policy: {self.conflict_policy}"
            )

        self._validate_output_config(self.contract)
        self.mask_output_channel_map = (
            self._parse_mask_output_channel_map(self.contract)
        )
        self._validate_channel_contract()

    # ------------------------------------------------------------------
    # Contract parsing
    # ------------------------------------------------------------------

    @staticmethod
    def _validate_output_config(
        contract: Mapping[str, Any],
    ) -> None:
        """Validate output options and reject obsolete mask selection."""
        output = contract.get("output")
        if output is None:
            return
        if not isinstance(output, Mapping):
            raise ContractError("contract.output must be an object.")
        if "mask_fields" in output:
            raise ContractError(
                "output.mask_fields is obsolete. Use "
                "derived_features.output_channels and "
                "derived_features.mask_channel_map."
            )

    @staticmethod
    def _parse_grid_contract(
        contract: Mapping[str, Any],
    ) -> GridContract:
        grid = contract.get("grid")
        if not isinstance(grid, dict):
            raise ContractError("contract.grid must be an object.")
        physical = grid.get("physical_grid")
        if not isinstance(physical, dict):
            raise ContractError("grid.physical_grid must be an object.")
        require_keys(
            physical,
            ["cell_center_origin_xyz", "spacing_xyz", "dimensions_xyz"],
            "grid.physical_grid",
        )
        origin = as_float_tuple3(
            physical["cell_center_origin_xyz"],
            "cell_center_origin_xyz",
        )
        spacing = as_float_tuple3(
            physical["spacing_xyz"],
            "spacing_xyz",
        )
        if any(v <= 0.0 for v in spacing):
            raise ContractError(f"spacing_xyz must be positive: {spacing}")
        dimensions = as_int_tuple3(
            physical["dimensions_xyz"],
            "dimensions_xyz",
        )

        model = grid.get("model_grid", {})
        if not isinstance(model, dict):
            raise ContractError("grid.model_grid must be an object.")
        explicit_shape = model.get("tensor_shape_zyx")
        model_shape = (
            as_int_tuple3(explicit_shape, "model_grid.tensor_shape_zyx")
            if explicit_shape is not None
            else None
        )
        divisibility = as_int_tuple3(
            model.get("divisibility_zyx", [16, 16, 16]),
            "model_grid.divisibility_zyx",
        )
        alignment = str(model.get("padding_alignment", "symmetric")).lower()
        if alignment not in {"symmetric", "end"}:
            raise ContractError(
                "padding_alignment must be 'symmetric' or 'end'."
            )
        return GridContract(
            cell_center_origin_xyz=origin,
            spacing_xyz=spacing,
            dimensions_xyz=dimensions,
            model_shape_zyx=model_shape,
            divisibility_zyx=divisibility,
            padding_alignment=alignment,
        )

    @staticmethod
    def _parse_coordinate_contract(
        contract: Mapping[str, Any],
    ) -> CoordinateContract:
        coord = contract.get("coordinate_map", {})
        if not isinstance(coord, dict):
            raise ContractError("coordinate_map must be an object.")
        rotation = np.asarray(
            coord.get("rotation_source_to_target", np.eye(3)),
            dtype=np.float64,
        )
        if rotation.shape != (3, 3):
            raise ContractError(
                "rotation_source_to_target must have shape [3,3]."
            )
        identity_error = np.max(np.abs(rotation @ rotation.T - np.eye(3)))
        determinant = float(np.linalg.det(rotation))
        if identity_error > 1e-6 or not np.isclose(
            determinant, 1.0, atol=1e-6
        ):
            raise ContractError(
                "rotation_source_to_target must be a proper orthonormal "
                f"rotation; orthogonality_error={identity_error:.3e}, "
                f"det={determinant:.6f}"
            )
        translation = np.asarray(
            coord.get("translation_target_xyz", [0.0, 0.0, 0.0]),
            dtype=np.float64,
        )
        if translation.shape != (3,):
            raise ContractError(
                "translation_target_xyz must contain 3 values."
            )
        length_scale = float(coord.get("length_scale", 1.0))
        if not math.isfinite(length_scale) or length_scale <= 0.0:
            raise ContractError("coordinate_map.length_scale must be > 0.")
        return CoordinateContract(
            source_length_unit=str(
                coord.get("source_length_unit", "unspecified")
            ),
            target_length_unit=str(
                coord.get("target_length_unit", "unspecified")
            ),
            length_scale=length_scale,
            rotation_source_to_target=rotation,
            translation_target_xyz=translation,
        )

    @staticmethod
    def _parse_field_specs(
        contract: Mapping[str, Any],
    ) -> tuple[FieldSpec, ...]:
        raw = contract.get("fields")
        if not isinstance(raw, list) or not raw:
            raise ContractError("contract.fields must be a non-empty list.")
        return tuple(FieldSpec.from_mapping(item) for item in raw)

    @staticmethod
    def _parse_output_mask_fields(
        contract: Mapping[str, Any],
    ) -> tuple[str, ...] | None:
        """
        Parse masks shared by VTI and PyTorch output.

        None: output.mask_fields omitted; write all masks.
        Empty tuple: write no masks.
        """
        output_config = contract.get("output")
        if output_config is None:
            return None
        if not isinstance(output_config, dict):
            raise ContractError("contract.output must be an object.")
        if "mask_fields" not in output_config:
            return None

        raw_fields = output_config["mask_fields"]
        if not isinstance(raw_fields, list):
            raise ContractError(
                "output.mask_fields must be an array of mask names."
            )

        fields: list[str] = []
        seen: set[str] = set()

        for index, raw_name in enumerate(raw_fields):
            if not isinstance(raw_name, str):
                raise ContractError(
                    f"output.mask_fields[{index}] must be a string."
                )

            name = raw_name.strip()
            if not name:
                raise ContractError(
                    f"output.mask_fields[{index}] cannot be empty."
                )
            if name.startswith("mask_"):
                raise ContractError(
                    f"output.mask_fields[{index}]={name!r} must use the "
                    "internal mask name without the 'mask_' prefix."
                )
            if name in seen:
                raise ContractError(
                    f"Duplicate output mask field: {name!r}."
                )

            seen.add(name)
            fields.append(name)

        return tuple(fields)

    @staticmethod
    def _parse_mask_output_channel_map(
        contract: Mapping[str, Any],
    ) -> dict[str, str]:
        """Parse output-channel to internal-mask mappings."""
        derived = contract.get("derived_features")
        if not isinstance(derived, Mapping):
            raise ContractError(
                "contract.derived_features must be an object."
            )

        raw_output_channels = derived.get("output_channels", [])
        if not isinstance(raw_output_channels, list):
            raise ContractError(
                "derived_features.output_channels must be an array."
            )

        output_channels: list[str] = []
        seen: set[str] = set()

        for index, raw_channel in enumerate(raw_output_channels):
            if not isinstance(raw_channel, str) or not raw_channel.strip():
                raise ContractError(
                    "derived_features.output_channels"
                    f"[{index}] must be a non-empty string."
                )

            channel = raw_channel.strip()
            if channel in seen:
                raise ContractError(
                    f"Duplicate derived output channel: {channel!r}."
                )

            seen.add(channel)
            output_channels.append(channel)

        raw_mask_map = derived.get("mask_channel_map", {})
        if not isinstance(raw_mask_map, Mapping):
            raise ContractError(
                "derived_features.mask_channel_map must be an object."
            )

        mask_map: dict[str, str] = {}
        for raw_channel, raw_mask_name in raw_mask_map.items():
            if not isinstance(raw_channel, str) or not raw_channel.strip():
                raise ContractError(
                    "derived_features.mask_channel_map keys must be "
                    "non-empty strings."
                )
            if (
                not isinstance(raw_mask_name, str)
                or not raw_mask_name.strip()
            ):
                raise ContractError(
                    "derived_features.mask_channel_map values must be "
                    "non-empty strings."
                )

            channel = raw_channel.strip()
            mask_name = raw_mask_name.strip()

            if channel not in seen:
                raise ContractError(
                    "derived_features.mask_channel_map contains channel "
                    f"{channel!r}, but it is not listed in "
                    "derived_features.output_channels."
                )

            mask_map[channel] = mask_name

        return {
            channel: mask_map[channel]
            for channel in output_channels
            if channel in mask_map
        }


    def _validate_channel_contract(self) -> None:
        if len(set(self.input_channels)) != len(self.input_channels):
            raise ContractError("input_channels contains duplicate names.")
        if len(set(self.target_channels)) != len(self.target_channels):
            raise ContractError("target_channels contains duplicate names.")

        produced: set[str] = set()
        field_roles: dict[str, str] = {}

        for spec in self.field_specs:
            overlap = produced.intersection(spec.output_channels)
            if overlap:
                raise ContractError(
                    f"Duplicate output channels from field specs: "
                    f"{sorted(overlap)}"
                )

            for channel in spec.output_channels:
                field_roles[channel] = spec.role
            produced.update(spec.output_channels)

        derived = self.contract.get("derived_features", {})
        if not isinstance(derived, Mapping):
            raise ContractError(
                "contract.derived_features must be an object."
            )

        derived_channels = tuple(
            str(name) for name in derived.get("output_channels", [])
        )

        implemented_derived = set(self.mask_output_channel_map)
        if bool(derived.get("derive_signed_distance", True)):
            implemented_derived.add(
                str(
                    derived.get(
                        "signed_distance_name",
                        "signed_distance",
                    )
                )
            )

        unimplemented_derived = sorted(
            set(derived_channels) - implemented_derived
        )
        if unimplemented_derived:
            raise ContractError(
                "Derived output channels have no runtime producer: "
                f"{unimplemented_derived}. Each derived channel must be the "
                "configured signed-distance channel or appear in "
                "derived_features.mask_channel_map."
            )

        for name in derived_channels:
            if name in produced:
                raise ContractError(
                    f"Duplicate derived channel: {name}"
                )
            produced.add(name)

        global_scenario_channels: set[str] = set()
        scenario_parameters = self.contract.get(
            "scenario_parameters",
            [],
        )
        if not isinstance(scenario_parameters, list):
            raise ContractError(
                "scenario_parameters must be an array."
            )

        for index, parameter in enumerate(scenario_parameters):
            if not isinstance(parameter, Mapping):
                raise ContractError(
                    f"scenario_parameters[{index}] must be an object."
                )

            raw_channels = parameter.get("output_channels")
            if not isinstance(raw_channels, list) or not raw_channels:
                raise ContractError(
                    f"scenario_parameters[{index}].output_channels must "
                    "be a non-empty array."
                )

            representation = str(
                parameter.get("representation", "")
            ).lower()
            if representation not in {"broadcast", "global"}:
                raise ContractError(
                    f"scenario_parameters[{index}].representation must be "
                    "'broadcast' or 'global'."
                )

            for raw_name in raw_channels:
                if not isinstance(raw_name, str) or not raw_name.strip():
                    raise ContractError(
                        f"scenario_parameters[{index}].output_channels "
                        "must contain non-empty strings."
                    )

                name = raw_name.strip()
                if name in produced or name in global_scenario_channels:
                    raise ContractError(
                        f"Duplicate scenario channel: {name!r}."
                    )

                if representation == "broadcast":
                    produced.add(name)
                else:
                    global_scenario_channels.add(name)

        global_spatial_overlap = global_scenario_channels.intersection(
            (*self.input_channels, *self.target_channels)
        )
        if global_spatial_overlap:
            raise ContractError(
                "Global scenario features cannot appear in spatial input or "
                f"target channels: {sorted(global_spatial_overlap)}"
            )

        for channel in dict.fromkeys(
            (
                *self.input_channels,
                *self.target_channels,
                *sorted(global_scenario_channels),
            )
        ):
            self.normalizer.require(channel)

    # ------------------------------------------------------------------
    # Source data loading and metadata inspection
    # ------------------------------------------------------------------

    def read_and_assemble_sources(
        self,
        source_groups: Mapping[str, Sequence[Path]],
    ) -> list[SourceBlock]:
        """Read VTK-family files and materialize each leaf as vtkUnstructuredGrid."""
        blocks: list[SourceBlock] = []
        priority = 0
        for source_group, paths in source_groups.items():
            for path in paths:
                if not path.exists():
                    raise SourceDataError(f"Source file does not exist: {path}")
                file_hash = sha256_file(path)
                loaded = self._read_vtk_data_object(path)

                leaf_count = 0
                for block_path, mesh in self._iter_leaf_blocks(
                    loaded,
                    root_name=path.name,
                ):
                    if (
                        mesh is None
                        or mesh.GetNumberOfPoints() == 0
                        or mesh.GetNumberOfCells() == 0
                    ):
                        continue

                    # vtkImageData and vtkRectilinearGrid use implicit point
                    # coordinates. vtkAppendFilter converts every vtkDataSet
                    # leaf to an explicit-point vtkUnstructuredGrid so the same
                    # affine coordinate map can be applied consistently.
                    mapped = self._materialize_explicit_point_set(mesh)
                    self._replace_dataset_points(
                        mapped,
                        self.coordinate.map_points(
                            vtk_to_numpy(mapped.GetPoints().GetData())
                        ),
                    )
                    is_volumetric = self._is_volumetric(mapped)
                    bounds = tuple(float(v) for v in mapped.GetBounds())
                    blocks.append(
                        SourceBlock(
                            source_group=source_group,
                            source_path=path,
                            block_path=block_path,
                            priority=priority,
                            mesh=mapped,
                            file_sha256=file_hash,
                            is_volumetric=is_volumetric,
                            bounds_xyz=bounds,  # type: ignore[arg-type]
                        )
                    )
                    priority += 1
                    leaf_count += 1

                if leaf_count == 0:
                    raise SourceDataError(
                        f"No non-empty vtkDataSet leaf objects found in {path}"
                    )

        if not blocks:
            raise SourceDataError("No source blocks were assembled.")
        return blocks

    @staticmethod
    def _read_vtk_data_object(path: Path) -> vtk.vtkDataObject:
        """
        Read common legacy, XML, VTKHDF, and OpenFOAM marker files.

        A .pvd collection is deliberately rejected because selecting a concrete
        time step belongs in request/asset resolution, not in this deterministic
        spatial transform.
        """
        suffix = path.suffix.lower()
        if suffix == ".pvd":
            raise SourceDataError(
                "PVD collections are not accepted directly. Resolve one "
                "concrete time step/file before calling SharedCFDTransform."
            )

        xml_readers = {
            ".vtu": vtk.vtkXMLUnstructuredGridReader,
            ".vtp": vtk.vtkXMLPolyDataReader,
            ".vti": vtk.vtkXMLImageDataReader,
            ".vtr": vtk.vtkXMLRectilinearGridReader,
            ".vts": vtk.vtkXMLStructuredGridReader,
            ".vtm": vtk.vtkXMLMultiBlockDataReader,
        }

        if suffix in xml_readers:
            reader = xml_readers[suffix]()
        elif suffix == ".vtk":
            reader = vtk.vtkGenericDataObjectReader()
        elif suffix == ".foam":
            reader_type = getattr(vtk, "vtkOpenFOAMReader", None)
            if reader_type is None:
                raise SourceDataError(
                    "This VTK build does not provide vtkOpenFOAMReader."
                )
            reader = reader_type()
        elif suffix in {".vtkhdf", ".hdf"}:
            reader_type = getattr(vtk, "vtkHDFReader", None)
            if reader_type is None:
                raise SourceDataError(
                    "This VTK build does not provide vtkHDFReader."
                )
            reader = reader_type()
        else:
            raise SourceDataError(
                f"Unsupported VTK-family file extension {suffix!r}: {path}"
            )

        reader.SetFileName(str(path))
        try:
            reader.Update()
        except Exception as exc:
            raise SourceDataError(f"Failed to read {path}: {exc}") from exc

        error_code = int(reader.GetErrorCode()) if hasattr(
            reader, "GetErrorCode"
        ) else 0
        if error_code != 0:
            try:
                error_name = vtk.vtkErrorCode.GetStringFromErrorCode(
                    error_code
                )
            except Exception:
                error_name = f"VTK error code {error_code}"
            raise SourceDataError(f"Failed to read {path}: {error_name}")

        output = reader.GetOutputDataObject(0)
        if output is None and hasattr(reader, "GetOutput"):
            output = reader.GetOutput()
        if output is None:
            raise SourceDataError(f"Reader returned no data object for {path}")

        copied = output.NewInstance()
        copied.DeepCopy(output)
        return copied

    def _iter_leaf_blocks(
        self,
        data: vtk.vtkDataObject,
        root_name: str,
    ) -> Iterator[tuple[str, vtk.vtkDataSet]]:
        if data.IsA("vtkDataSet"):
            yield root_name, data
            return

        if data.IsA("vtkCompositeDataSet"):
            iterator = data.NewIterator()
            if hasattr(iterator, "VisitOnlyLeavesOn"):
                iterator.VisitOnlyLeavesOn()
            if hasattr(iterator, "SkipEmptyNodesOn"):
                iterator.SkipEmptyNodesOn()
            iterator.InitTraversal()
            while not iterator.IsDoneWithTraversal():
                child = iterator.GetCurrentDataObject()
                flat_index = int(iterator.GetCurrentFlatIndex())
                metadata = iterator.GetCurrentMetaData()
                block_name: str | None = None
                try:
                    name_key = vtk.vtkCompositeDataSet.NAME()
                    if metadata is not None and metadata.Has(name_key):
                        block_name = str(metadata.Get(name_key))
                except Exception:
                    block_name = None
                label = block_name or f"Block-{flat_index:04d}"
                child_path = f"{root_name}/{label}"

                if child is not None:
                    if child.IsA("vtkDataSet"):
                        yield child_path, child
                    elif child.IsA("vtkCompositeDataSet"):
                        # Defensive fallback for composite iterators that do
                        # not honor VisitOnlyLeavesOn in a particular VTK build.
                        yield from self._iter_leaf_blocks(child, child_path)
                    else:
                        raise SourceDataError(
                            f"Unsupported composite leaf {child.GetClassName()} "
                            f"at {child_path}; expected vtkDataSet."
                        )
                iterator.GoToNextItem()
            return

        raise SourceDataError(
            f"Unsupported VTK data object in {root_name}: "
            f"{data.GetClassName()}"
        )


    @staticmethod
    def _copy_dataset_structure(
        mesh: vtk.vtkDataSet,
    ) -> vtk.vtkDataSet:
        """Copy geometry and topology without unrelated data arrays."""
        copied = mesh.NewInstance()
        copied.CopyStructure(mesh)
        return copied

    @staticmethod
    def _deep_copy_dataset(mesh: vtk.vtkDataSet) -> vtk.vtkDataSet:
        copied = mesh.NewInstance()
        copied.DeepCopy(mesh)
        return copied

    @staticmethod
    def _materialize_explicit_point_set(
        mesh: vtk.vtkDataSet,
    ) -> vtk.vtkUnstructuredGrid:
        append = vtk.vtkAppendFilter()
        append.AddInputData(mesh)
        append.MergePointsOff()
        append.Update()
        output = vtk.vtkUnstructuredGrid()
        output.DeepCopy(append.GetOutput())
        if output.GetPoints() is None:
            raise SourceDataError(
                f"Could not materialize explicit points for {mesh.GetClassName()}"
            )
        return output

    @staticmethod
    def _replace_dataset_points(
        mesh: vtk.vtkPointSet,
        points_xyz: np.ndarray,
    ) -> None:
        points_array = np.ascontiguousarray(points_xyz, dtype=np.float64)
        if points_array.ndim != 2 or points_array.shape[1] != 3:
            raise SourceDataError(
                f"Mapped point array must have shape [N,3], got "
                f"{points_array.shape}."
            )
        if points_array.shape[0] != mesh.GetNumberOfPoints():
            raise SourceDataError(
                "Mapped point count does not match source point count."
            )
        vtk_array = numpy_to_vtk(points_array, deep=True)
        vtk_points = vtk.vtkPoints()
        vtk_points.SetData(vtk_array)
        mesh.SetPoints(vtk_points)
        mesh.Modified()

    @staticmethod
    def _array_names(attributes: vtk.vtkDataSetAttributes) -> list[str]:
        names: list[str] = []
        for index in range(attributes.GetNumberOfArrays()):
            name = attributes.GetArrayName(index)
            if name:
                names.append(str(name))
        return names

    @staticmethod
    def _is_volumetric(mesh: vtk.vtkDataSet) -> bool:
        # Cell dimension is a topology-level test and avoids computing a full
        # Volume array merely to determine whether a block contains 3D cells.
        for cell_id in range(mesh.GetNumberOfCells()):
            cell = mesh.GetCell(cell_id)
            if cell is not None and cell.GetCellDimension() == 3:
                return True
        return False

    def inspect_and_validate_field_metadata(
        self,
        blocks: Sequence[SourceBlock],
    ) -> dict[str, Any]:
        report: dict[str, Any] = {
            "blocks": [],
            "fields": {},
        }

        for block in blocks:
            report["blocks"].append(
                {
                    "source_group": block.source_group,
                    "source_path": str(block.source_path),
                    "block_path": block.block_path,
                    "priority": block.priority,
                    "dataset_type": block.mesh.GetClassName(),
                    "n_points": int(block.mesh.GetNumberOfPoints()),
                    "n_cells": int(block.mesh.GetNumberOfCells()),
                    "is_volumetric": block.is_volumetric,
                    "bounds_xyz": list(block.bounds_xyz),
                    "point_arrays": sorted(
                        self._array_names(block.mesh.GetPointData())
                    ),
                    "cell_arrays": sorted(
                        self._array_names(block.mesh.GetCellData())
                    ),
                }
            )

        for spec in self.field_specs:
            matches: list[dict[str, Any]] = []
            for block in blocks:
                if block.source_group != spec.source_group:
                    continue
                associations = self._field_associations(
                    block.mesh,
                    spec.source_name,
                )
                if not associations:
                    continue
                if len(associations) > 1 and (
                    spec.preferred_source_association is None
                ):
                    raise FieldMetadataError(
                        f"{spec.source_group}:{spec.source_name!r} exists in "
                        f"both point and cell data on {block.block_path}. "
                        "Set preferred_source_association explicitly."
                    )
                association = (
                    spec.preferred_source_association
                    if spec.preferred_source_association in associations
                    else associations[0]
                )
                array = self._get_associated_array(
                    block.mesh,
                    spec.source_name,
                    association,
                )
                array = ensure_numeric_array(
                    array,
                    f"{block.block_path}:{spec.source_name}",
                )
                components = 1 if array.ndim == 1 else int(array.shape[1])
                if components != spec.expected_components:
                    raise FieldMetadataError(
                        f"{block.block_path}:{spec.source_name} has "
                        f"{components} components; expected "
                        f"{spec.expected_components}."
                    )
                if array.ndim not in {1, 2}:
                    raise FieldMetadataError(
                        f"{block.block_path}:{spec.source_name} must have "
                        f"rank 1 or 2, got shape={array.shape}."
                    )
                if finite_fraction(array) == 0.0:
                    raise FieldMetadataError(
                        f"{block.block_path}:{spec.source_name} contains no "
                        "finite values."
                    )
                matches.append(
                    {
                        "source_path": str(block.source_path),
                        "block_path": block.block_path,
                        "association": association,
                        "shape": list(array.shape),
                        "dtype": str(array.dtype),
                        "finite_fraction": finite_fraction(array),
                        "is_volumetric": block.is_volumetric,
                    }
                )

            volumetric_matches = [
                match for match in matches if match["is_volumetric"]
            ]
            if spec.required and not matches:
                raise FieldMetadataError(
                    f"Required field {spec.source_group}:{spec.source_name!r} "
                    "was not found."
                )
            if (
                spec.required
                and spec.require_volumetric_source
                and not volumetric_matches
            ):
                raise FieldMetadataError(
                    f"Required volumetric field "
                    f"{spec.source_group}:{spec.source_name!r} was found only "
                    "on surface/non-volumetric blocks. A VTP surface alone "
                    "cannot populate a 3D canonical volume."
                )
            report["fields"][
                f"{spec.source_group}:{spec.source_name}"
            ] = matches
        return report

    @staticmethod
    def _field_associations(
        mesh: vtk.vtkDataSet,
        name: str,
    ) -> list[str]:
        associations: list[str] = []
        if mesh.GetPointData().HasArray(name):
            associations.append("POINT")
        if mesh.GetCellData().HasArray(name):
            associations.append("CELL")
        return associations

    @staticmethod
    def _get_associated_vtk_array(
        mesh: vtk.vtkDataSet,
        name: str,
        association: str,
    ) -> vtk.vtkDataArray:
        if association == "POINT":
            abstract_array = mesh.GetPointData().GetAbstractArray(name)
        elif association == "CELL":
            abstract_array = mesh.GetCellData().GetAbstractArray(name)
        else:
            raise FieldMetadataError(f"Unsupported association: {association}")

        if abstract_array is None:
            raise FieldMetadataError(
                f"Array {name!r} is missing from {association} data."
            )
        if not abstract_array.IsA("vtkDataArray"):
            raise FieldMetadataError(
                f"Array {name!r} in {association} data is non-numeric "
                f"({abstract_array.GetClassName()})."
            )
        return abstract_array

    @classmethod
    def _get_associated_array(
        cls,
        mesh: vtk.vtkDataSet,
        name: str,
        association: str,
    ) -> np.ndarray:
        vtk_array = cls._get_associated_vtk_array(
            mesh,
            name,
            association,
        )
        return np.asarray(vtk_to_numpy(vtk_array))

    @staticmethod
    def _clear_attribute_arrays(mesh: vtk.vtkDataSet) -> None:
        # Keep geometry/topology only. Processing a single declared field at a
        # time prevents unrelated arrays or duplicate point/cell names from
        # affecting native VTK conversion/probe behavior.
        mesh.GetPointData().Initialize()
        mesh.GetCellData().Initialize()

    @staticmethod
    def _add_numpy_array(
        mesh: vtk.vtkDataSet,
        name: str,
        association: str,
        values: np.ndarray,
    ) -> None:
        contiguous = np.ascontiguousarray(values)
        vtk_array = numpy_to_vtk(contiguous, deep=True)
        vtk_array.SetName(name)
        attributes = (
            mesh.GetPointData()
            if association == "POINT"
            else mesh.GetCellData()
        )
        attributes.AddArray(vtk_array)
        if vtk_array.GetNumberOfComponents() == 3:
            attributes.SetVectors(vtk_array)
        elif vtk_array.GetNumberOfComponents() == 1:
            attributes.SetScalars(vtk_array)
        mesh.Modified()

    def _prepare_field_on_block(
        self,
        block: SourceBlock,
        spec: FieldSpec,
    ) -> tuple[vtk.vtkDataSet, str, dict[str, Any]] | None:
        associations = self._field_associations(
            block.mesh,
            spec.source_name,
        )
        if not associations:
            return None

        if len(associations) > 1:
            association = spec.preferred_source_association
            if association is None:
                raise FieldMetadataError(
                    f"Ambiguous association for {spec.source_name!r} on "
                    f"{block.block_path}."
                )
            if association not in associations:
                raise FieldMetadataError(
                    f"Preferred association {association} is unavailable for "
                    f"{spec.source_name!r} on {block.block_path}."
                )
        else:
            association = associations[0]

        original = self._get_associated_array(
            block.mesh,
            spec.source_name,
            association,
        )
        original = ensure_numeric_array(
            original,
            f"{block.block_path}:{spec.source_name}",
        ).astype(np.float64, copy=False)

        if spec.kind == "vector":
            if spec.value_offset != 0.0:
                raise ContractError(
                    f"Vector field {spec.source_name!r} cannot use a nonzero "
                    "value_offset."
                )
            converted = (
                self.coordinate.map_vectors(original, spec.value_scale)
                if spec.rotate_vector
                else original * spec.value_scale
            )
        else:
            converted = original * spec.value_scale + spec.value_offset

        mesh = self._copy_dataset_structure(block.mesh)
        self._add_numpy_array(
            mesh,
            spec.source_name,
            association,
            converted,
        )

        # Continuous fields become point data for cell-shape interpolation.
        # Nearest/categorical fields become cell data so vtkProbeFilter copies
        # the containing-cell value without smoothing across category IDs.
        use_nearest = (
            spec.interpolation == "nearest"
            or spec.kind in {"categorical", "binary_mask", "region_id"}
        )

        if use_nearest:
            if association == "POINT":
                converter = vtk.vtkPointDataToCellData()
                converter.SetInputData(mesh)
                converter.PassPointDataOff()
                if spec.kind in {
                    "categorical",
                    "binary_mask",
                    "region_id",
                }:
                    converter.CategoricalDataOn()
                converter.Update()
                mesh = self._deep_copy_dataset(converter.GetOutput())
                harmonized_from = "POINT"
                harmonized_to = "CELL"
            else:
                harmonized_from = "CELL"
                harmonized_to = "CELL"
            interpolation_association = "CELL"
        else:
            if association == "CELL":
                converter = vtk.vtkCellDataToPointData()
                converter.SetInputData(mesh)
                converter.PassCellDataOff()
                converter.Update()
                mesh = self._deep_copy_dataset(converter.GetOutput())
                harmonized_from = "CELL"
                harmonized_to = "POINT"
            else:
                harmonized_from = "POINT"
                harmonized_to = "POINT"
            interpolation_association = "POINT"

        provenance = {
            "source_group": block.source_group,
            "source_path": str(block.source_path),
            "block_path": block.block_path,
            "priority": block.priority,
            "source_association": association,
            "harmonized_from": harmonized_from,
            "harmonized_to": harmonized_to,
            "canonical_association": "CELL",
            "source_unit": spec.source_unit,
            "target_unit": spec.target_unit,
            "value_scale": spec.value_scale,
            "value_offset": spec.value_offset,
            "vector_rotated": bool(
                spec.kind == "vector" and spec.rotate_vector
            ),
            "interpolation": spec.interpolation,
            "interpolation_association": interpolation_association,
            "probe_filter": "vtkProbeFilter",
            "probe_locator_prototype": "vtkStaticCellLocator",
            "is_volumetric": block.is_volumetric,
        }
        return mesh, interpolation_association, provenance

    @staticmethod
    def _make_target_polydata(points_xyz: np.ndarray) -> vtk.vtkPolyData:
        points_array = np.ascontiguousarray(points_xyz, dtype=np.float64)
        vtk_points = vtk.vtkPoints()
        vtk_points.SetData(numpy_to_vtk(points_array, deep=True))
        target = vtk.vtkPolyData()
        target.SetPoints(vtk_points)
        target.Modified()
        return target

    @staticmethod
    def _probe_field(
        target_points: vtk.vtkPolyData,
        source: vtk.vtkDataSet,
        field_name: str,
    ) -> tuple[np.ndarray, np.ndarray]:
        probe = vtk.vtkProbeFilter()
        probe.SetInputData(target_points)
        probe.SetSourceData(source)
        probe.PassCellArraysOff()
        probe.PassPointArraysOff()
        probe.PassFieldArraysOff()
        # vtkStaticCellLocator is more robust than the default jump-and-walk
        # locator for many unstructured CFD meshes. Keep a compatibility
        # fallback for older VTK Python wheels.
        if hasattr(probe, "SetCellLocatorPrototype"):
            probe.SetCellLocatorPrototype(vtk.vtkStaticCellLocator())
        probe.Update()

        output = probe.GetOutput()
        sampled_array = output.GetPointData().GetArray(field_name)
        if sampled_array is None:
            raise ResamplingError(
                f"vtkProbeFilter did not return field {field_name!r}."
            )
        valid_array = output.GetPointData().GetArray(
            probe.GetValidPointMaskArrayName()
        )
        if valid_array is None:
            raise ResamplingError(
                "vtkProbeFilter did not return vtkValidPointMask."
            )

        # Copy because the NumPy views returned by vtk_to_numpy reference VTK
        # memory owned by the local filter output.
        values = np.array(vtk_to_numpy(sampled_array), copy=True)
        valid = np.array(vtk_to_numpy(valid_array), copy=True).astype(
            bool,
            copy=False,
        )
        return values, valid

    def resample_to_canonical_grid(
        self,
        blocks: Sequence[SourceBlock],
    ) -> tuple[
        dict[str, np.ndarray],
        dict[str, np.ndarray],
        dict[str, Any],
    ]:
        centers_xyz = self.grid.cell_centers_xyz()
        target_points = self._make_target_polydata(centers_xyz)
        shape_zyx = self.grid.physical_shape_zyx

        channels: dict[str, np.ndarray] = {}
        validity_by_channel: dict[str, np.ndarray] = {}
        resampling_provenance: dict[str, Any] = {}

        for spec in self.field_specs:
            candidates = [
                block
                for block in blocks
                if block.source_group == spec.source_group
                and (
                    not spec.require_volumetric_source
                    or block.is_volumetric
                )
            ]

            sampled_values: list[np.ndarray] = []
            sampled_validity: list[np.ndarray] = []
            sampled_provenance: list[dict[str, Any]] = []

            for block in candidates:
                prepared = self._prepare_field_on_block(block, spec)
                if prepared is None:
                    continue
                mesh, _association, provenance = prepared

                try:
                    values, valid = self._probe_field(
                        target_points,
                        mesh,
                        spec.source_name,
                    )
                except Exception as exc:
                    if isinstance(exc, TransformError):
                        raise
                    raise ResamplingError(
                        f"Native VTK probing failed for {block.block_path}: "
                        f"{exc}"
                    ) from exc

                values = np.asarray(values, dtype=np.float64)
                finite_rows = (
                    np.isfinite(values)
                    if values.ndim == 1
                    else np.all(np.isfinite(values), axis=1)
                )
                valid &= finite_rows
                sampled_values.append(values)
                sampled_validity.append(valid)
                provenance["valid_fraction_on_canonical_grid"] = float(
                    valid.mean()
                )
                sampled_provenance.append(provenance)

            if not sampled_values:
                if spec.required:
                    raise ResamplingError(
                        f"No compatible blocks could resample "
                        f"{spec.source_group}:{spec.source_name!r}."
                    )
                continue

            assembled, valid = self._assemble_region_samples(
                sampled_values,
                sampled_validity,
                sampled_provenance,
                spec,
            )

            valid_fraction_value = float(valid.mean())
            if valid_fraction_value < spec.minimum_valid_fraction:
                raise ResamplingError(
                    f"{spec.source_name!r} valid fraction "
                    f"{valid_fraction_value:.6f} is below contract minimum "
                    f"{spec.minimum_valid_fraction:.6f}."
                )

            if spec.extrapolation_policy == "ERROR" and not np.all(valid):
                invalid_count = int((~valid).sum())
                raise ResamplingError(
                    f"{spec.source_name!r} has {invalid_count} canonical cells "
                    "outside the source mesh under extrapolation_policy=ERROR."
                )

            fill = spec.fill_value_physical
            assembled = np.asarray(assembled, dtype=np.float64)
            if assembled.ndim == 1:
                assembled[~valid] = fill
                component_arrays = [assembled]
            else:
                assembled[~valid, :] = fill
                component_arrays = [
                    assembled[:, component]
                    for component in range(assembled.shape[1])
                ]

            for channel_name, flat_component in zip(
                spec.output_channels,
                component_arrays,
                strict=True,
            ):
                volume = np.asarray(flat_component).reshape(
                    shape_zyx,
                    order="C",
                )
                channels[channel_name] = volume.astype(
                    np.float32,
                    copy=False,
                )
                validity_by_channel[channel_name] = valid.reshape(
                    shape_zyx,
                    order="C",
                )
                resampling_provenance[channel_name] = {
                    "source_field": spec.source_name,
                    "source_group": spec.source_group,
                    "role": spec.role,
                    "kind": spec.kind,
                    "target_unit": spec.target_unit,
                    "valid_fraction": valid_fraction_value,
                    "extrapolation_policy": spec.extrapolation_policy,
                    "fill_value_physical": fill,
                    "region_sources": sampled_provenance,
                }

        return channels, validity_by_channel, resampling_provenance

    def _assemble_region_samples(
        self,
        values: Sequence[np.ndarray],
        validity: Sequence[np.ndarray],
        provenance: Sequence[Mapping[str, Any]],
        spec: FieldSpec,
    ) -> tuple[np.ndarray, np.ndarray]:
        if len(values) != len(validity):
            raise InvariantError("Region values/validity length mismatch.")

        valid_stack = np.stack(validity, axis=0)
        overlap_count = valid_stack.sum(axis=0)
        if (
            self.conflict_policy == "ERROR_ON_OVERLAP"
            and np.any(overlap_count > 1)
        ):
            raise ResamplingError(
                f"{spec.source_name!r}: "
                f"{int(np.sum(overlap_count > 1))} canonical cells are covered "
                "by multiple source regions under ERROR_ON_OVERLAP."
            )

        output_shape = values[0].shape
        output = np.full(output_shape, np.nan, dtype=np.float64)
        output_valid = np.zeros(validity[0].shape, dtype=bool)

        if self.conflict_policy in {
            "ERROR_ON_OVERLAP",
            "REGION_PRIORITY",
        }:
            order = sorted(
                range(len(values)),
                key=lambda idx: int(provenance[idx]["priority"]),
            )
            for idx in order:
                take = validity[idx] & ~output_valid
                output[take] = values[idx][take]
                output_valid[take] = True

        elif self.conflict_policy == "VALIDITY_PRIORITY":
            order = sorted(
                range(len(values)),
                key=lambda idx: (
                    -float(np.mean(validity[idx])),
                    int(provenance[idx]["priority"]),
                ),
            )
            for idx in order:
                take = validity[idx] & ~output_valid
                output[take] = values[idx][take]
                output_valid[take] = True

        elif self.conflict_policy == "WEIGHTED_BLEND":
            if values[0].ndim == 1:
                numerator = np.zeros_like(values[0], dtype=np.float64)
                denominator = np.zeros_like(values[0], dtype=np.float64)
            else:
                numerator = np.zeros_like(values[0], dtype=np.float64)
                denominator = np.zeros(
                    (values[0].shape[0], 1),
                    dtype=np.float64,
                )
            for region_values, region_valid in zip(
                values,
                validity,
                strict=True,
            ):
                weight = region_valid.astype(np.float64)
                if region_values.ndim == 2:
                    weight = weight[:, None]
                numerator += np.where(weight > 0, region_values, 0.0) * weight
                denominator += weight
            safe = denominator > 0
            output = np.divide(
                numerator,
                denominator,
                out=np.full_like(numerator, np.nan),
                where=safe,
            )
            output_valid = overlap_count > 0

        return output, output_valid

    # ------------------------------------------------------------------
    # Geometry, boundaries, masks, and scenario encoding
    # ------------------------------------------------------------------

    def derive_geometry_and_boundary_features(
        self,
        channels: MutableMapping[str, np.ndarray],
        validity: Mapping[str, np.ndarray],
        blocks: Sequence[SourceBlock],
        scenario: Mapping[str, Any],
    ) -> tuple[dict[str, np.ndarray], dict[str, Any]]:
        config = self.contract.get("derived_features", {})
        if not isinstance(config, dict):
            raise ContractError("derived_features must be an object.")

        shape = self.grid.physical_shape_zyx
        reference_channel = str(
            config.get("fluid_reference_channel", "Ux")
        )
        if reference_channel not in validity:
            raise ContractError(
                f"fluid_reference_channel {reference_channel!r} has no "
                "resampling validity mask."
            )
        fluid_mask = np.array(
            validity[reference_channel],
            dtype=bool,
            copy=True,
        )
        if fluid_mask.shape != shape:
            raise InvariantError(
                f"Validity mask for {reference_channel!r} has shape "
                f"{fluid_mask.shape}; expected {shape}."
            )

        domain_mode = str(
            config.get("domain_mask_mode", "source_bounds")
        ).lower()
        if domain_mode == "canonical_extent":
            domain_mask = np.ones(shape, dtype=bool)
        elif domain_mode == "source_bounds":
            volumetric_bounds = [
                block.bounds_xyz
                for block in blocks
                if block.is_volumetric
                and block.source_group
                == str(config.get("domain_source_group", "flow"))
            ]
            if not volumetric_bounds:
                raise ContractError(
                    "domain_mask_mode=source_bounds requires at least one "
                    "volumetric source block."
                )
            xmin = min(v[0] for v in volumetric_bounds)
            xmax = max(v[1] for v in volumetric_bounds)
            ymin = min(v[2] for v in volumetric_bounds)
            ymax = max(v[3] for v in volumetric_bounds)
            zmin = min(v[4] for v in volumetric_bounds)
            zmax = max(v[5] for v in volumetric_bounds)
            points = self.grid.cell_centers_xyz()
            inside = (
                (points[:, 0] >= xmin)
                & (points[:, 0] <= xmax)
                & (points[:, 1] >= ymin)
                & (points[:, 1] <= ymax)
                & (points[:, 2] >= zmin)
                & (points[:, 2] <= zmax)
            )
            domain_mask = inside.reshape(shape, order="C")
        else:
            raise ContractError(
                f"Unsupported domain_mask_mode: {domain_mode}"
            )

        fluid_mask &= domain_mask
        solid_mask = domain_mask & ~fluid_mask
        outside_mask = ~domain_mask

        masks: dict[str, np.ndarray] = {
            "domain_mask": domain_mask,
            "fluid_mask": fluid_mask,
            "solid_mask": solid_mask,
            "outside_mask": outside_mask,
        }

        wall_distance_name = str(
            config.get("wall_distance_channel", "wallDistance")
        )
        wall_distance = channels.get(wall_distance_name)
        wall_distance_valid: np.ndarray | None = None

        if wall_distance is not None:
            if wall_distance_name not in validity:
                raise ContractError(
                    f"Wall-distance channel {wall_distance_name!r} has no "
                    "resampling validity mask."
                )

            wall_distance = np.asarray(
                wall_distance,
                dtype=np.float64,
            )
            if wall_distance.shape != shape:
                raise InvariantError(
                    f"Wall-distance channel {wall_distance_name!r} has shape "
                    f"{wall_distance.shape}; expected {shape}."
                )

            wall_distance_valid = (
                np.asarray(
                    validity[wall_distance_name],
                    dtype=bool,
                )
                & np.isfinite(wall_distance)
            )

        if bool(config.get("derive_signed_distance", True)):
            # EDT provides a deterministic fallback wherever wallDistance
            # was not sampled from valid source data.
            fluid_distance = distance_transform_edt(
                fluid_mask,
                sampling=self.grid.spacing_zyx,
            )

            if (
                wall_distance is not None
                and wall_distance_valid is not None
            ):
                use_wall_distance = (
                    fluid_mask & wall_distance_valid
                )
                fluid_distance[use_wall_distance] = np.maximum(
                    wall_distance[use_wall_distance],
                    0.0,
                )

            solid_distance = distance_transform_edt(
                solid_mask,
                sampling=self.grid.spacing_zyx,
            )
            signed_distance = np.zeros(shape, dtype=np.float64)
            signed_distance[fluid_mask] = fluid_distance[fluid_mask]
            signed_distance[solid_mask] = -solid_distance[solid_mask]

            signed_distance_name = str(
                config.get(
                    "signed_distance_name",
                    "signed_distance",
                )
            )
            channels[signed_distance_name] = signed_distance.astype(
                np.float32,
                copy=False,
            )

        near_wall_threshold = float(
            config.get(
                "near_wall_threshold",
                1.5 * min(self.grid.spacing_xyz),
            )
        )
        if (
            not math.isfinite(near_wall_threshold)
            or near_wall_threshold < 0.0
        ):
            raise ContractError(
                "derived_features.near_wall_threshold must be finite "
                "and non-negative."
            )

        fluid_eroded = binary_erosion(
            fluid_mask,
            structure=np.ones((3, 3, 3), dtype=bool),
            border_value=0,
        )
        fluid_boundary_mask = fluid_mask & ~fluid_eroded

        if wall_distance is not None and wall_distance_valid is not None:
            near_wall_mask = (
                fluid_mask
                & wall_distance_valid
                & (wall_distance <= near_wall_threshold)
            )
        else:
            near_wall_mask = fluid_boundary_mask

        masks["near_wall_mask"] = near_wall_mask
        masks["fluid_boundary_mask"] = fluid_boundary_mask

        face_masks = self._make_grid_face_masks(shape)
        masks.update(face_masks)

        wind_parameter = config.get("wind_direction_parameter")
        if wind_parameter is not None and wind_parameter in scenario:
            wind_unit_xy = self._angle_to_toward_unit_xy(
                float(scenario[wind_parameter]),
                config.get("wind_direction_convention", {}),
            )
            inlet_name, outlet_name = self._select_wind_faces(wind_unit_xy)
            masks["wind_inlet_mask"] = (
                face_masks[inlet_name] & fluid_mask
            )
            masks["wind_outlet_mask"] = (
                face_masks[outlet_name] & fluid_mask
            )
        else:
            inlet_name = None
            outlet_name = None

        configured_target_reference = config.get(
            "target_valid_reference_channel"
        )

        if self.target_channels:
            target_valid_channels = (
                (str(configured_target_reference),)
                if configured_target_reference is not None
                else self.target_channels
            )

            target_valid = np.ones(shape, dtype=bool)
            for channel_name in target_valid_channels:
                if channel_name not in validity:
                    raise ContractError(
                        f"Target-valid channel {channel_name!r} has no "
                        "resampling validity mask."
                    )

                channel_validity = np.asarray(
                    validity[channel_name],
                    dtype=bool,
                )
                if channel_validity.shape != shape:
                    raise InvariantError(
                        f"Validity mask for {channel_name!r} has shape "
                        f"{channel_validity.shape}; expected {shape}."
                    )
                target_valid &= channel_validity

            target_valid &= domain_mask
        else:
            target_valid_channels = ()
            target_valid = np.zeros(shape, dtype=bool)

        masks["target_valid_mask"] = target_valid
        masks["loss_mask"] = target_valid & fluid_mask
        masks["metric_mask"] = target_valid & fluid_mask

        self._validate_mask_invariants(masks)

        derived_output_channels = {
            str(value) for value in config.get("output_channels", [])
        }
        mask_channel_map = config.get("mask_channel_map", {})
        if not isinstance(mask_channel_map, Mapping):
            raise ContractError(
                "derived_features.mask_channel_map must be an object."
            )

        for channel_name, mask_name in mask_channel_map.items():
            channel_name = str(channel_name)
            mask_name = str(mask_name)

            if channel_name not in derived_output_channels:
                raise ContractError(
                    f"Mask-derived channel {channel_name!r} is absent from "
                    "derived_features.output_channels."
                )
            if mask_name not in masks:
                raise ContractError(
                    f"Unknown mask {mask_name!r} for derived channel "
                    f"{channel_name!r}."
                )

            channels[channel_name] = masks[mask_name].astype(
                np.float32,
                copy=False,
            )

        provenance = {
            "fluid_reference_channel": reference_channel,
            "target_valid_channels": list(target_valid_channels),
            "domain_mask_mode": domain_mode,
            "near_wall_threshold": near_wall_threshold,
            "wind_inlet_face": inlet_name,
            "wind_outlet_face": outlet_name,
            "mask_fractions": {
                name: float(np.mean(mask))
                for name, mask in masks.items()
            },
        }
        return masks, provenance

    @staticmethod
    def _make_grid_face_masks(
        shape_zyx: tuple[int, int, int],
    ) -> dict[str, np.ndarray]:
        nz, ny, nx = shape_zyx
        result: dict[str, np.ndarray] = {}
        for name in (
            "x_min_face_mask",
            "x_max_face_mask",
            "y_min_face_mask",
            "y_max_face_mask",
            "z_min_face_mask",
            "z_max_face_mask",
        ):
            result[name] = np.zeros((nz, ny, nx), dtype=bool)
        result["x_min_face_mask"][:, :, 0] = True
        result["x_max_face_mask"][:, :, -1] = True
        result["y_min_face_mask"][:, 0, :] = True
        result["y_max_face_mask"][:, -1, :] = True
        result["z_min_face_mask"][0, :, :] = True
        result["z_max_face_mask"][-1, :, :] = True
        return result

    @staticmethod
    def _select_wind_faces(
        toward_unit_xy: np.ndarray,
    ) -> tuple[str, str]:
        normals = {
            "x_min_face_mask": np.asarray([-1.0, 0.0]),
            "x_max_face_mask": np.asarray([1.0, 0.0]),
            "y_min_face_mask": np.asarray([0.0, -1.0]),
            "y_max_face_mask": np.asarray([0.0, 1.0]),
        }
        scores = {
            name: float(np.dot(toward_unit_xy, normal))
            for name, normal in normals.items()
        }
        inlet = min(scores, key=scores.get)
        outlet = max(scores, key=scores.get)
        return inlet, outlet

    @staticmethod
    def _angle_to_toward_unit_xy(
        angle_degrees: float,
        convention: Mapping[str, Any],
    ) -> np.ndarray:
        """
        Convert an API angle to a project XY unit vector pointing *toward* flow.

        Supported zero directions:
            positive_x, positive_y, negative_x, negative_y
        Supported rotation:
            clockwise, counterclockwise
        Supported semantic:
            from, toward
        """
        zero = str(
            convention.get("zero_direction", "positive_y")
        ).lower()
        rotation = str(
            convention.get("rotation", "clockwise")
        ).lower()
        semantic = str(
            convention.get("semantic", "from")
        ).lower()

        zero_angle_math = {
            "positive_x": 0.0,
            "positive_y": math.pi / 2.0,
            "negative_x": math.pi,
            "negative_y": -math.pi / 2.0,
        }.get(zero)
        if zero_angle_math is None:
            raise ContractError(f"Unsupported zero_direction: {zero}")
        sign = -1.0 if rotation == "clockwise" else 1.0
        if rotation not in {"clockwise", "counterclockwise"}:
            raise ContractError(f"Unsupported angle rotation: {rotation}")

        theta = zero_angle_math + sign * math.radians(angle_degrees)
        vector = np.asarray([math.cos(theta), math.sin(theta)])
        if semantic == "from":
            vector = -vector
        elif semantic != "toward":
            raise ContractError(f"Unsupported angle semantic: {semantic}")
        return vector / np.linalg.norm(vector)

    def encode_scenario_parameters(
        self,
        scenario: Mapping[str, Any],
        channels: MutableMapping[str, np.ndarray],
    ) -> tuple[np.ndarray | None, list[str], dict[str, Any]]:
        global_values: list[float] = []
        global_names: list[str] = []
        shape = self.grid.physical_shape_zyx
        provenance: dict[str, Any] = {}

        for parameter in self.contract.get("scenario_parameters", []):
            if not isinstance(parameter, dict):
                raise ContractError(
                    "Each scenario parameters entry must be an object."
                )
            require_keys(
                parameter,
                ["name", "type", "representation", "output_channels"],
                "scenario parameter",
            )
            name = str(parameter["name"])
            if name not in scenario:
                if "default" in parameter:
                    raw_value = parameter["default"]
                    used_default = True
                else:
                    raise ContractError(
                        f"Scenario is missing required parameter {name!r}."
                    )
            else:
                raw_value = scenario[name]
                used_default = False

            parameter_type = str(parameter["type"]).lower()
            representation = str(parameter["representation"]).lower()
            output_channels = [
                str(v) for v in parameter["output_channels"]
            ]

            if parameter_type == "scalar":
                if len(output_channels) != 1:
                    raise ContractError(
                        f"Scalar {name!r} must have one output channel."
                    )
                values = [float(raw_value)]

            elif parameter_type == "angle":
                if len(output_channels) != 2:
                    raise ContractError(
                        f"Angle {name!r} must have sin/cos output channels."
                    )
                vector = self._angle_to_toward_unit_xy(
                    float(raw_value),
                    parameter.get("convention", {}),
                )
                # Mathematical toward-angle encoding.
                values = [float(vector[1]), float(vector[0])]
                # output order is conventionally [sin(theta), cos(theta)]

            elif parameter_type == "categorical":
                categories = [str(v) for v in parameter.get("categories", [])]
                if not categories:
                    raise ContractError(
                        f"Categorical {name!r} has no categories."
                    )
                raw_string = str(raw_value)
                if raw_string not in categories:
                    raise ContractError(
                        f"Unknown category {raw_string!r} for {name!r}; "
                        f"allowed={categories}"
                    )
                if len(output_channels) != len(categories):
                    raise ContractError(
                        f"Categorical {name!r} requires one output channel "
                        "per category."
                    )
                values = [
                    1.0 if raw_string == category else 0.0
                    for category in categories
                ]
            else:
                raise ContractError(
                    f"Unsupported scenario parameter type: {parameter_type}"
                )

            if representation == "broadcast":
                for channel_name, value in zip(
                    output_channels,
                    values,
                    strict=True,
                ):
                    channels[channel_name] = np.full(
                        shape,
                        value,
                        dtype=np.float32,
                    )
            elif representation == "global":
                global_names.extend(output_channels)
                global_values.extend(values)
            else:
                raise ContractError(
                    f"Unsupported representation {representation!r} for "
                    f"{name!r}."
                )

            provenance[name] = {
                "raw_value": raw_value,
                "used_default": used_default,
                "type": parameter_type,
                "representation": representation,
                "output_channels": output_channels,
            }

        if global_values:
            global_array = np.asarray(global_values, dtype=np.float32)
        else:
            global_array = None
        return global_array, global_names, provenance

    @staticmethod
    def _validate_mask_invariants(
        masks: Mapping[str, np.ndarray],
    ) -> None:
        domain = masks["domain_mask"]
        fluid = masks["fluid_mask"]
        solid = masks["solid_mask"]
        target_valid = masks["target_valid_mask"]
        loss = masks["loss_mask"]

        if np.any(fluid & solid):
            raise InvariantError("fluid_mask intersects solid_mask.")
        if np.any((fluid | solid) & ~domain):
            raise InvariantError(
                "fluid_mask or solid_mask extends outside domain_mask."
            )
        if np.any(loss & ~target_valid):
            raise InvariantError(
                "loss_mask is not a subset of target_valid_mask."
            )

    # ------------------------------------------------------------------
    # Normalization, padding, tensors, and inverse transform
    # ------------------------------------------------------------------

    def apply_frozen_normalization(
        self,
        channels: Mapping[str, np.ndarray],
        global_features: np.ndarray | None,
        global_feature_names: Sequence[str],
    ) -> tuple[dict[str, np.ndarray], np.ndarray | None]:
        normalized: dict[str, np.ndarray] = {}
        needed = set(self.input_channels).union(self.target_channels)
        for name in needed:
            if name not in channels:
                raise ContractError(
                    f"Required model channel {name!r} was not produced."
                )
            normalized[name] = self.normalizer.apply(name, channels[name])

        if global_features is not None:
            if len(global_features) != len(global_feature_names):
                raise InvariantError(
                    "global_features/global_feature_names length mismatch."
                )
            normalized_global = np.asarray(
                [
                    self.normalizer.apply_scalar(name, float(value))
                    for name, value in zip(
                        global_feature_names,
                        global_features,
                        strict=True,
                    )
                ],
                dtype=np.float32,
            )
        else:
            normalized_global = None
        return normalized, normalized_global

    def _resolve_model_shape(self) -> tuple[int, int, int]:
        physical = self.grid.physical_shape_zyx
        if self.grid.model_shape_zyx is not None:
            model = self.grid.model_shape_zyx
            if any(m < p for m, p in zip(model, physical, strict=True)):
                raise ContractError(
                    f"model_shape_zyx={model} is smaller than "
                    f"physical_shape_zyx={physical}."
                )
            if any(
                m % d != 0
                for m, d in zip(
                    model,
                    self.grid.divisibility_zyx,
                    strict=True,
                )
            ):
                raise ContractError(
                    f"Explicit model_shape_zyx={model} is not divisible by "
                    f"{self.grid.divisibility_zyx}."
                )
            return model

        return tuple(
            int(math.ceil(p / d) * d)
            for p, d in zip(
                physical,
                self.grid.divisibility_zyx,
                strict=True,
            )
        )  # type: ignore[return-value]

    def _padding_metadata(self) -> PaddingMetadata:
        physical = self.grid.physical_shape_zyx
        model = self._resolve_model_shape()
        total = tuple(
            m - p for m, p in zip(model, physical, strict=True)
        )
        if self.grid.padding_alignment == "symmetric":
            before = tuple(v // 2 for v in total)
        else:
            before = (0, 0, 0)
        after = tuple(
            v - b for v, b in zip(total, before, strict=True)
        )
        return PaddingMetadata(
            physical_shape_zyx=physical,
            model_shape_zyx=model,
            pad_before_zyx=before,  # type: ignore[arg-type]
            pad_after_zyx=after,  # type: ignore[arg-type]
            alignment=self.grid.padding_alignment,
        )

    def apply_model_padding(
        self,
        normalized_channels: Mapping[str, np.ndarray],
        masks: Mapping[str, np.ndarray],
    ) -> tuple[
        dict[str, np.ndarray],
        dict[str, np.ndarray],
        PaddingMetadata,
    ]:
        padding = self._padding_metadata()
        before = padding.pad_before_zyx
        after = padding.pad_after_zyx
        pad_width = tuple(
            (b, a) for b, a in zip(before, after, strict=True)
        )

        padding_config = self.contract.get("padding", {})
        physical_pad_values = padding_config.get(
            "channel_pad_values_physical", {}
        )
        if not isinstance(physical_pad_values, dict):
            raise ContractError(
                "padding.channel_pad_values_physical must be an object."
            )

        padded_channels: dict[str, np.ndarray] = {}
        for channel_name, array in normalized_channels.items():
            if channel_name not in physical_pad_values:
                raise ContractError(
                    f"No explicit physical padding value for model channel "
                    f"{channel_name!r}."
                )
            pad_physical = float(physical_pad_values[channel_name])
            pad_normalized = self.normalizer.apply_scalar(
                channel_name, pad_physical
            )
            padded_channels[channel_name] = np.pad(
                array,
                pad_width,
                mode="constant",
                constant_values=pad_normalized,
            ).astype(np.float32, copy=False)

        padded_masks: dict[str, np.ndarray] = {}
        for mask_name, mask in masks.items():
            padded_masks[mask_name] = np.pad(
                np.asarray(mask, dtype=bool),
                pad_width,
                mode="constant",
                constant_values=False,
            )

        padding_mask = np.ones(
            padding.model_shape_zyx,
            dtype=bool,
        )
        z0, y0, x0 = before
        pz, py, px = padding.physical_shape_zyx
        padding_mask[z0 : z0 + pz, y0 : y0 + py, x0 : x0 + px] = False
        padded_masks["padding_mask"] = padding_mask

        if np.any(
            padded_masks["padding_mask"] & padded_masks["domain_mask"]
        ):
            raise InvariantError(
                "padding_mask intersects padded domain_mask."
            )

        for name, array in padded_channels.items():
            if array.shape != padding.model_shape_zyx:
                raise InvariantError(
                    f"Padded channel {name!r} has shape {array.shape}; "
                    f"expected {padding.model_shape_zyx}."
                )
        return padded_channels, padded_masks, padding

    def build_tensors(
        self,
        padded_channels: Mapping[str, np.ndarray],
        padded_masks: Mapping[str, np.ndarray],
        normalized_global: np.ndarray | None,
    ) -> tuple[
        torch.Tensor,
        torch.Tensor | None,
        dict[str, torch.Tensor],
        torch.Tensor | None,
    ]:
        x_np = np.stack(
            [
                padded_channels[name]
                for name in self.input_channels
            ],
            axis=0,
        )
        x = torch.from_numpy(
            np.ascontiguousarray(x_np, dtype=np.float32)
        )

        if self.target_channels:
            y_np = np.stack(
                [
                    padded_channels[name]
                    for name in self.target_channels
                ],
                axis=0,
            )
            y = torch.from_numpy(
                np.ascontiguousarray(y_np, dtype=np.float32)
            )
        else:
            y = None

        mask_tensors = {
            name: torch.from_numpy(
                np.ascontiguousarray(mask[None, ...], dtype=bool)
            )
            for name, mask in padded_masks.items()
        }

        global_tensor = (
            torch.from_numpy(
                np.ascontiguousarray(normalized_global, dtype=np.float32)
            )
            if normalized_global is not None
            else None
        )

        if x.ndim != 4:
            raise InvariantError(f"x must be [C,Z,Y,X], got {x.shape}.")
        if y is not None and y.ndim != 4:
            raise InvariantError(f"y must be [C,Z,Y,X], got {y.shape}.")
        return x, y, mask_tensors, global_tensor

    def transform(
        self,
        source_groups: Mapping[str, Sequence[Path]],
        scenario: Mapping[str, Any],
        sample_id: str,
    ) -> TransformedSample:
        blocks = self.read_and_assemble_sources(source_groups)
        metadata_report = self.inspect_and_validate_field_metadata(blocks)

        channels, validity, resampling_provenance = (
            self.resample_to_canonical_grid(blocks)
        )
        masks, geometry_provenance = (
            self.derive_geometry_and_boundary_features(
                channels,
                validity,
                blocks,
                scenario,
            )
        )
        global_features, global_names, scenario_provenance = (
            self.encode_scenario_parameters(scenario, channels)
        )
        normalized_channels, normalized_global = (
            self.apply_frozen_normalization(
                channels,
                global_features,
                global_names,
            )
        )
        padded_channels, padded_masks, padding = self.apply_model_padding(
            normalized_channels,
            masks,
        )
        x, y, mask_tensors, global_tensor = self.build_tensors(
            padded_channels,
            padded_masks,
            normalized_global,
        )

        unavailable_output_masks = {
            mask_name
            for mask_name in self.mask_output_channel_map.values()
            if mask_name not in mask_tensors
        }
        if unavailable_output_masks:
            raise ContractError(
                "derived_features.mask_channel_map references unavailable "
                f"masks: {sorted(unavailable_output_masks)}. "
                f"Available masks: {sorted(mask_tensors)}."
            )

        metadata = {
            "sample_id": sample_id,
            "contract_path": str(self.contract_path),
            "contract_sha256": self.contract_hash,
            "normalization_path": str(self.normalizer.source_path),
            "normalization_sha256": self.normalizer.hash,
            "source_report": metadata_report,
            "grid": {
                "cell_center_origin_xyz": list(
                    self.grid.cell_center_origin_xyz
                ),
                "spacing_xyz": list(self.grid.spacing_xyz),
                "dimensions_xyz": list(self.grid.dimensions_xyz),
            },
            "padding": dataclasses.asdict(padding),
            "channel_order": {
                "x": list(self.input_channels),
                "y": list(self.target_channels),
                "global_features": list(global_names),
            },
            "tensor_layout": {
                "sample": "C,Z,Y,X",
                "batch": "B,C,Z,Y,X",
                "vtk_logical_dimensions": "X,Y,Z",
            },
            "derived_features": {
                "output_channels": [
                    str(value)
                    for value in self.contract.get(
                        "derived_features",
                        {},
                    ).get("output_channels", [])
                ],
                "mask_channel_map": dict(
                    self.mask_output_channel_map
                ),
            },
            "resampling": resampling_provenance,
            "geometry_and_masks": geometry_provenance,
            "scenario": scenario_provenance,
            "tensor_hashes": {
                "x_sha256": sha256_tensor(x),
                "y_sha256": sha256_tensor(y) if y is not None else None,
                "global_features_sha256": (
                    sha256_tensor(global_tensor)
                    if global_tensor is not None
                    else None
                ),
                "masks_sha256": {
                    name: sha256_tensor(tensor)
                    for name, tensor in mask_tensors.items()
                },
            },
            "runtime": {
                "python": platform.python_version(),
                "platform": platform.platform(),
                "numpy": np.__version__,
                "torch": torch.__version__,
                "vtk": vtk.vtkVersion.GetVTKVersion(),
                "vtk_backend": "native_vtk_python_wrappers",
            },
        }
        return TransformedSample(
            x=x,
            y=y,
            masks=mask_tensors,
            global_features=global_tensor,
            metadata=metadata,
        )

    def inverse_prediction(
        self,
        prediction: torch.Tensor | np.ndarray,
        metadata: Mapping[str, Any],
        output_channels: Sequence[str] | None = None,
    ) -> dict[str, np.ndarray]:
        """
        Remove model padding and invert frozen output normalization.

        Input:
            prediction [Cout, Zp, Yp, Xp] or [1, Cout, Zp, Yp, Xp]
        Output:
            dict[channel_name] -> physical [Z, Y, X] float32 array
        """
        array = (
            prediction.detach().cpu().numpy()
            if isinstance(prediction, torch.Tensor)
            else np.asarray(prediction)
        )
        if array.ndim == 5:
            if array.shape[0] != 1:
                raise InvariantError(
                    "inverse_prediction accepts only batch size 1."
                )
            array = array[0]
        if array.ndim != 4:
            raise InvariantError(
                f"prediction must be [C,Z,Y,X], got {array.shape}."
            )

        names = tuple(output_channels or self.target_channels)
        if array.shape[0] != len(names):
            raise InvariantError(
                f"prediction has {array.shape[0]} channels but names={names}."
            )

        padding = metadata["padding"]
        before = tuple(int(v) for v in padding["pad_before_zyx"])
        physical = tuple(int(v) for v in padding["physical_shape_zyx"])
        z0, y0, x0 = before
        pz, py, px = physical
        cropped = array[:, z0 : z0 + pz, y0 : y0 + py, x0 : x0 + px]

        return {
            name: self.normalizer.inverse(name, cropped[index])
            for index, name in enumerate(names)
        }


# -----------------------------------------------------------------------------
# CLI and example assets
# -----------------------------------------------------------------------------


def selected_output_masks(
    sample: TransformedSample,
) -> dict[str, torch.Tensor]:
    """
    Return masks selected by the derived-feature contract.

    Dictionary keys are output channel names. Values are tensors retrieved
    using the corresponding internal names from mask_channel_map.
    """
    derived = sample.metadata.get("derived_features")
    if not isinstance(derived, Mapping):
        raise InvariantError(
            "metadata.derived_features must be an object."
        )

    output_channels = derived.get("output_channels", [])
    mask_channel_map = derived.get("mask_channel_map", {})

    if not isinstance(output_channels, list):
        raise InvariantError(
            "metadata.derived_features.output_channels must be an array."
        )
    if not isinstance(mask_channel_map, Mapping):
        raise InvariantError(
            "metadata.derived_features.mask_channel_map must be an object."
        )

    selected: dict[str, torch.Tensor] = {}
    for output_channel in output_channels:
        if not isinstance(output_channel, str):
            raise InvariantError(
                "Derived output channel names must be strings."
            )

        if output_channel not in mask_channel_map:
            continue

        mask_name = mask_channel_map[output_channel]
        if not isinstance(mask_name, str):
            raise InvariantError(
                f"Mask mapping for {output_channel!r} must be a string."
            )
        if mask_name not in sample.masks:
            raise InvariantError(
                f"Output channel {output_channel!r} references unavailable "
                f"mask {mask_name!r}."
            )

        selected[output_channel] = sample.masks[mask_name]

    return selected


# -----------------------------------------------------------------------------
# CLI and example assets
# -----------------------------------------------------------------------------


def write_sample_metadata(
    sample: TransformedSample,
    metadata_path: Path,
) -> None:
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(
        json.dumps(
            sample.metadata,
            indent=2,
            ensure_ascii=False,
            default=json_default,
        )
        + "\n",
        encoding="utf-8",
    )


def save_transformed_vti(
    sample: TransformedSample,
    output_path: Path,
    metadata_path: Path,
) -> None:
    """Save normalized tensors and selected masks as VTK ImageData."""
    output_path.parent.mkdir(parents=True, exist_ok=True)

    metadata = sample.metadata
    grid = metadata["grid"]
    padding = metadata["padding"]
    channel_order = metadata["channel_order"]

    model_shape_zyx = tuple(
        int(v) for v in padding["model_shape_zyx"]
    )
    pad_before_zyx = tuple(
        int(v) for v in padding["pad_before_zyx"]
    )

    nz, ny, nx = model_shape_zyx
    pad_z, pad_y, pad_x = pad_before_zyx

    center_origin_x, center_origin_y, center_origin_z = (
        float(v) for v in grid["cell_center_origin_xyz"]
    )
    spacing_x, spacing_y, spacing_z = (
        float(v) for v in grid["spacing_xyz"]
    )

    image = vtk.vtkImageData()
    image.SetOrigin(
        center_origin_x - pad_x * spacing_x - 0.5 * spacing_x,
        center_origin_y - pad_y * spacing_y - 0.5 * spacing_y,
        center_origin_z - pad_z * spacing_z - 0.5 * spacing_z,
    )
    image.SetSpacing(spacing_x, spacing_y, spacing_z)
    image.SetDimensions(nx + 1, ny + 1, nz + 1)

    def add_cell_array(name: str, values_zyx: np.ndarray) -> None:
        values = np.asarray(values_zyx)
        if values.shape != model_shape_zyx:
            raise InvariantError(
                f"VTI array {name!r} has shape {values.shape}; "
                f"expected {model_shape_zyx}."
            )

        flat = np.ascontiguousarray(values).ravel(order="C")
        vtk_array = numpy_to_vtk(flat, deep=True)
        vtk_array.SetName(name)
        image.GetCellData().AddArray(vtk_array)

    x_array = sample.x.detach().cpu().numpy()
    for index, channel_name in enumerate(channel_order["x"]):
        add_cell_array(str(channel_name), x_array[index])

    if sample.y is not None:
        y_array = sample.y.detach().cpu().numpy()
        for index, channel_name in enumerate(channel_order["y"]):
            add_cell_array(str(channel_name), y_array[index])

    for output_channel, mask_tensor in selected_output_masks(sample).items():
        mask_array = mask_tensor.detach().cpu().numpy()
        if mask_array.ndim != 4 or mask_array.shape[0] != 1:
            raise InvariantError(
                f"Mask channel {output_channel!r} must have shape "
                f"[1,Z,Y,X], got {mask_array.shape}."
            )

        add_cell_array(
            output_channel,
            mask_array[0].astype(np.uint8, copy=False),
        )

    writer = vtk.vtkXMLImageDataWriter()
    writer.SetFileName(str(output_path))
    writer.SetInputData(image)

    if writer.Write() != 1:
        raise TransformError(f"Failed to write VTI output: {output_path}")

    write_sample_metadata(sample, metadata_path)


def save_transformed_sample(
    sample: TransformedSample,
    output_path: Path,
    metadata_path: Path,
) -> None:
    """Save tensors and the same contract-selected masks as PyTorch data."""
    output_path.parent.mkdir(parents=True, exist_ok=True)

    masks = {
        name: tensor.detach().cpu()
        for name, tensor
        in selected_output_masks(sample).items()
    }

    payload = {
        "x": sample.x.detach().cpu(),
        "y": (
            sample.y.detach().cpu()
            if sample.y is not None
            else None
        ),
        "masks": masks,
        "global_features": (
            sample.global_features.detach().cpu()
            if sample.global_features is not None
            else None
        ),
        "metadata": sample.metadata,
    }

    torch.save(payload, output_path)
    write_sample_metadata(sample, metadata_path)


# -----------------------------------------------------------------------------
# CLI and example assets
# -----------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the contract-driven Shared CFD Transform."
    )
    parser.add_argument(
        "--flow",
        nargs="+",
        help="One or more flow VTK-family files containing U, p, wallDistance.",
    )
    parser.add_argument(
        "--trd",
        nargs="+",
        help="One or more tracer VTK-family files containing T.",
    )
    parser.add_argument(
        "--contract",
        type=Path,
        help="Transform contract in JSON or YAML.",
    )
    parser.add_argument(
        "--normalization",
        type=Path,
        help="Frozen normalization statistics in JSON or YAML.",
    )
    parser.add_argument(
        "--scenario",
        type=Path,
        help=(
            "Optional scenario parameters in JSON or YAML. "
            "An empty scenario is used when omitted."
        ),
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Primary transformed VTK ImageData output (.vti).",
    )
    parser.add_argument(
        "--pt-output",
        type=Path,
        default=None,
        help="Optionally also write a PyTorch payload (.pt or .pth).",
    )
    parser.add_argument(
        "--metadata",
        type=Path,
        help="Output provenance metadata (.json).",
    )
    parser.add_argument(
        "--sample-id",
        default="sample",
        help="Stable sample/case identifier.",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    required_args = {
        "--flow": args.flow,
        "--contract": args.contract,
        "--normalization": args.normalization,
        "--output": args.output,
        "--metadata": args.metadata,
    }
    missing = [name for name, value in required_args.items() if not value]
    if missing:
        parser.error(f"Missing required arguments: {', '.join(missing)}")

    contract_path = args.contract.expanduser().resolve()
    normalization_path = args.normalization.expanduser().resolve()

    contract = load_mapping(contract_path)
    normalization = load_mapping(normalization_path)

    if args.scenario is not None:
        scenario_path = args.scenario.expanduser().resolve()
        scenario = load_mapping(scenario_path)
    else:
        scenario_path = None
        scenario = {}

    normalizer = FrozenNormalizer(normalization, normalization_path)
    transform = SharedCFDTransform(
        contract=contract,
        normalizer=normalizer,
        contract_path=contract_path,
    )
    source_groups = {
        "flow": normalize_path_list(args.flow),
        "trd": normalize_path_list(args.trd),
    }

    sample = transform.transform(
        source_groups=source_groups,
        scenario=scenario,
        sample_id=args.sample_id,
    )

    output_path = args.output.expanduser().resolve()
    metadata_path = args.metadata.expanduser().resolve()

    if output_path.suffix.lower() != ".vti":
        raise ContractError(
            "--output must have a .vti extension. "
            "Use --pt-output for optional PyTorch output."
        )

    pt_output_path: Path | None = None
    if args.pt_output is not None:
        pt_output_path = args.pt_output.expanduser().resolve()

        if pt_output_path.suffix.lower() not in {".pt", ".pth"}:
            raise ContractError(
                "--pt-output must have a .pt or .pth extension."
            )

        if pt_output_path == output_path:
            raise ContractError(
                "--output and --pt-output must be different paths."
            )

    # Primary output: VTK ImageData.
    save_transformed_vti(
        sample,
        output_path,
        metadata_path,
    )

    # Optional additional PyTorch payload. The transform is not repeated.
    if pt_output_path is not None:
        save_transformed_sample(
            sample,
            pt_output_path,
            metadata_path,
        )

    print(
        json.dumps(
            {
                "status": "ok",
                "sample_id": args.sample_id,
                "x_shape": list(sample.x.shape),
                "y_shape": (
                    list(sample.y.shape)
                    if sample.y is not None
                    else None
                ),
                "global_features_shape": (
                    list(sample.global_features.shape)
                    if sample.global_features is not None
                    else None
                ),
                "output": str(output_path),
                "output_format": ".vti",
                "pt_output": (
                    str(pt_output_path)
                    if pt_output_path is not None
                    else None
                ),
                "output_mask_fields": list(
                    selected_output_masks(sample)
                ),
                "metadata": str(metadata_path),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except TransformError as exc:
        print(f"TRANSFORM_ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
