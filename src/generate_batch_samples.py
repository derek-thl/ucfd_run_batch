#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
generate_batch_samples.py (Derek Lai, 2026-06-11)

Purpose
-------
Split a CSV file into smaller batch CSV files.

Usage
-----
python generate_batch_samples.py [input_csv] [-b BATCH_SIZE] [-p OUTPUT_PREFIX]

Arguments
---------
input_csv: Input CSV file to split. Default: ucfd_doe_lhs.csv
-b, --batch-size: Number of rows per batch CSV. Default: 16
-p, --output-prefix: Output CSV prefix. Default: output_batch

"""


import argparse
from pathlib import Path

import pandas as pd


def split_csv(input_csv: str, batch_size: int = 16, output_prefix: str = "output_batch") -> None:
    """Split a CSV file into smaller batch CSV files."""
    input_path = Path(input_csv)

    if not input_path.exists():
        raise FileNotFoundError(f"Input CSV file not found: {input_path}")

    df = pd.read_csv(input_path)

    for i in range(0, len(df), batch_size):
        batch_df = df.iloc[i:i + batch_size]
        batch_id = i // batch_size
        output_csv = f"{output_prefix}_{batch_id}.csv"
        batch_df.to_csv(output_csv, index=False)
        print(f"Wrote {output_csv}: {len(batch_df)} rows")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Split a CSV file into smaller batch CSV files."
    )
    parser.add_argument(
        "input_csv",
        nargs="?",
        default="ucfd_doe_lhs.csv",
        help="Input CSV file to split. Default: ucfd_doe_lhs.csv",
    )
    parser.add_argument(
        "-b",
        "--batch-size",
        type=int,
        default=16,
        help="Number of rows per batch CSV. Default: 16",
    )
    parser.add_argument(
        "-p",
        "--output-prefix",
        type=str,
        default="output_batch",
        help="Output CSV prefix. Default: output_batch",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    split_csv(
        input_csv=args.input_csv,
        batch_size=args.batch_size,
        output_prefix=args.output_prefix,
    )


if __name__ == "__main__":
    main()