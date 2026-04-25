#!/usr/bin/env python3
"""Compare current CI metrics against a rolling baseline from prior workflow runs."""

from __future__ import annotations

import argparse
import io
import json
import statistics
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class MetricRule:
    key: str
    json_path: tuple[str, ...]
    threshold_pct: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Check performance regressions by comparing current metrics to the "
            "median of the last N successful workflow runs."
        )
    )
    parser.add_argument("--metrics-file", required=True, help="Current run metrics JSON path")
    parser.add_argument("--repo", required=True, help="GitHub repository in owner/name form")
    parser.add_argument(
        "--workflow",
        default="test.yml",
        help="Workflow file name or workflow id used for baseline history",
    )
    parser.add_argument("--branch", default="main", help="Baseline branch to query")
    parser.add_argument("--window", type=int, default=10, help="Number of runs to compare against")
    parser.add_argument(
        "--min-samples",
        type=int,
        default=5,
        help="Minimum baseline samples before gating a metric",
    )
    parser.add_argument(
        "--artifact-name",
        default="cook-metrics-json",
        help="Artifact name containing metrics JSON",
    )
    parser.add_argument(
        "--artifact-file",
        default="cook-metrics.json",
        help="Expected JSON file name inside artifact zip",
    )
    parser.add_argument("--token", default="", help="GitHub token with actions:read access")
    parser.add_argument("--current-run-id", default="", help="Current run id to ignore in history")
    parser.add_argument(
        "--absolute-tolerance-ms",
        type=float,
        default=10.0,
        help="Absolute timing tolerance added to each threshold bound",
    )
    parser.add_argument(
        "--output-report",
        default="",
        help="Optional report file path for machine-readable regression output",
    )
    parser.add_argument(
        "--no-fail-on-regression",
        action="store_true",
        help="Report regressions but do not return non-zero",
    )
    parser.add_argument("--threshold-total-pct", type=float, default=0.15)
    parser.add_argument("--threshold-cook-pct", type=float, default=0.15)
    parser.add_argument("--threshold-scan-pct", type=float, default=0.20)
    parser.add_argument("--threshold-dependency-pct", type=float, default=0.20)
    parser.add_argument("--threshold-cache-write-pct", type=float, default=0.20)
    return parser.parse_args()


def github_get_json(url: str, token: str) -> dict[str, Any]:
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if token:
        req.add_header("Authorization", f"Bearer {token}")

    with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310
        return json.loads(resp.read().decode("utf-8"))


def github_get_bytes(url: str, token: str) -> bytes:
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if token:
        req.add_header("Authorization", f"Bearer {token}")

    with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310
        return resp.read()


def get_json_path(data: dict[str, Any], path: tuple[str, ...]) -> int | float | None:
    node: Any = data
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return None
        node = node[key]
    if isinstance(node, (int, float)):
        return node
    return None


def load_metrics_from_artifact_zip(zip_bytes: bytes, artifact_file: str) -> dict[str, Any] | None:
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        names = zf.namelist()
        target = artifact_file if artifact_file in names else None
        if target is None:
            json_names = [name for name in names if name.endswith(".json")]
            if not json_names:
                return None
            target = json_names[0]
        with zf.open(target) as handle:
            return json.loads(handle.read().decode("utf-8"))


def fetch_recent_metrics(
    repo: str,
    workflow: str,
    branch: str,
    token: str,
    artifact_name: str,
    artifact_file: str,
    window: int,
    current_run_id: str,
) -> tuple[list[dict[str, Any]], list[int]]:
    runs_url = (
        f"https://api.github.com/repos/{repo}/actions/workflows/{workflow}/runs"
        f"?branch={branch}&status=success&per_page=100"
    )
    runs = github_get_json(runs_url, token).get("workflow_runs", [])

    metrics_list: list[dict[str, Any]] = []
    run_ids: list[int] = []
    for run in runs:
        run_id = int(run["id"])
        if current_run_id and str(run_id) == str(current_run_id):
            continue
        artifacts_url = f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100"
        artifacts = github_get_json(artifacts_url, token).get("artifacts", [])

        artifact = next(
            (
                item
                for item in artifacts
                if item.get("name") == artifact_name and not item.get("expired", False)
            ),
            None,
        )
        if artifact is None:
            continue

        archive_url = artifact.get("archive_download_url")
        if not archive_url:
            continue

        try:
            zip_bytes = github_get_bytes(archive_url, token)
            metrics = load_metrics_from_artifact_zip(zip_bytes, artifact_file)
        except Exception:
            continue

        if metrics is None:
            continue

        metrics_list.append(metrics)
        run_ids.append(run_id)
        if len(metrics_list) >= window:
            break

    return metrics_list, run_ids


def main() -> int:
    args = parse_args()
    current_metrics = json.loads(Path(args.metrics_file).read_text(encoding="utf-8"))
    report: dict[str, Any] = {
        "window_requested": args.window,
        "window_available": 0,
        "baseline_run_ids": [],
        "regressions": [],
        "checks": [],
    }

    rules = [
        MetricRule("timings_ns.total", ("timings_ns", "total"), args.threshold_total_pct),
        MetricRule("timings_ns.cook", ("timings_ns", "cook"), args.threshold_cook_pct),
        MetricRule("timings_ns.scan", ("timings_ns", "scan"), args.threshold_scan_pct),
        MetricRule(
            "timings_ns.dependency_graph",
            ("timings_ns", "dependency_graph"),
            args.threshold_dependency_pct,
        ),
        MetricRule(
            "timings_ns.cache_write",
            ("timings_ns", "cache_write"),
            args.threshold_cache_write_pct,
        ),
    ]

    if not args.token:
        print("No GitHub token provided; skipping regression check.")
        if args.output_report:
            out_path = Path(args.output_report)
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return 0

    try:
        baseline_metrics, baseline_run_ids = fetch_recent_metrics(
            repo=args.repo,
            workflow=args.workflow,
            branch=args.branch,
            token=args.token,
            artifact_name=args.artifact_name,
            artifact_file=args.artifact_file,
            window=args.window,
            current_run_id=args.current_run_id,
        )
    except Exception as exc:
        baseline_metrics, baseline_run_ids = [], []
        report["baseline_error"] = str(exc)
        print(f"Failed to load baseline metrics ({exc}); skipping regression gate.")

    report["window_available"] = len(baseline_metrics)
    report["baseline_run_ids"] = baseline_run_ids

    if not baseline_metrics:
        print("No baseline artifacts found; skipping regression gate for this run.")
    else:
        abs_tol_ns = int(args.absolute_tolerance_ms * 1_000_000.0)
        for rule in rules:
            current_val = get_json_path(current_metrics, rule.json_path)
            if current_val is None:
                report["checks"].append(
                    {
                        "metric": rule.key,
                        "status": "missing_current_metric",
                    }
                )
                continue

            values: list[float] = []
            for baseline in baseline_metrics:
                val = get_json_path(baseline, rule.json_path)
                if val is not None:
                    values.append(float(val))

            if len(values) < args.min_samples:
                report["checks"].append(
                    {
                        "metric": rule.key,
                        "status": "insufficient_baseline",
                        "samples": len(values),
                        "min_samples": args.min_samples,
                    }
                )
                continue

            baseline_median = statistics.median(values)
            allowed_max = baseline_median * (1.0 + rule.threshold_pct) + abs_tol_ns
            ratio = (float(current_val) / baseline_median) if baseline_median > 0 else 1.0
            is_regression = float(current_val) > allowed_max

            check = {
                "metric": rule.key,
                "status": "regression" if is_regression else "ok",
                "current": current_val,
                "baseline_median": baseline_median,
                "allowed_max": allowed_max,
                "ratio_vs_median": ratio,
                "threshold_pct": rule.threshold_pct,
                "samples": len(values),
            }
            report["checks"].append(check)
            if is_regression:
                report["regressions"].append(check)

        if report["regressions"]:
            print("Performance regressions detected:")
            for regression in report["regressions"]:
                print(
                    f"  - {regression['metric']}: "
                    f"current={regression['current']} "
                    f"median={regression['baseline_median']:.0f} "
                    f"allowed_max={regression['allowed_max']:.0f} "
                    f"ratio={regression['ratio_vs_median']:.3f}"
                )
        else:
            print(
                f"Performance check passed using {len(baseline_metrics)} baseline run(s)."
            )

    if args.output_report:
        out_path = Path(args.output_report)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if report["regressions"] and not args.no_fail_on_regression:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
