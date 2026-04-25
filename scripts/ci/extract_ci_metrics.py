#!/usr/bin/env python3
"""Extract CI_METRICS_JSON payload from cook command logs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract the last CI_METRICS_JSON line from a log file."
    )
    parser.add_argument("--log-file", required=True, help="Path to command output log")
    parser.add_argument(
        "--output-file",
        required=True,
        help="Path to write normalized metrics JSON",
    )
    return parser.parse_args()


def extract_metrics(log_text: str) -> dict:
    prefix = "CI_METRICS_JSON "
    payload = None
    for line in log_text.splitlines():
        if line.startswith(prefix):
            payload = line[len(prefix) :]
    if payload is None:
        raise ValueError("No CI_METRICS_JSON payload found in log")
    return json.loads(payload)


def main() -> int:
    args = parse_args()
    log_path = Path(args.log_file)
    out_path = Path(args.output_file)

    metrics = extract_metrics(log_path.read_text(encoding="utf-8"))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(metrics, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    total_ns = metrics.get("timings_ns", {}).get("total")
    assets = metrics.get("assets", {})
    print(
        "Extracted metrics: "
        f"assets_total={assets.get('total')}, "
        f"assets_cooked={assets.get('cooked')}, "
        f"total_ns={total_ns}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

