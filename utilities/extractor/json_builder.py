"""Combines parsed CSV data into a single JSON document per HOBL run."""

import json
import logging
from pathlib import Path

from utilities.extractor.parsers import (
    parse_config,
    parse_etl_files,
    parse_perf_metrics,
    parse_power_light,
    parse_run_info,
)
from utilities.extractor.power_calculate import (
    calculate_battery_life_hr,
    calculate_power_metrics,
    calculate_record_time_min,
)

logger = logging.getLogger(__name__)


def extract_run(run_dir: Path) -> dict | None:
    """Extract all metrics from a single HOBL run directory into a JSON-ready dict.

    Args:
        run_dir: Path to a HOBL run directory (e.g., C:\\hobl_results\\Power\\mincp_base_008)

    Returns:
        Combined dict with run_info, device_config, power_metrics, perf_metrics.
        None if the run is not in PASS state.
    """
    run_dir = Path(run_dir)

    if not run_dir.is_dir():
        logger.error("Not a directory: %s", run_dir)
        return None

    # Parse run info first to check status
    ri = parse_run_info(run_dir)

    if ri.get("status") != "PASS":
        logger.info("Skipping %s (status=%s)", run_dir.name, ri.get("status"))
        return None

    # Parse all data sources
    device_config = parse_config(run_dir)
    power = parse_power_light(run_dir)
    power_calc = calculate_power_metrics(power, dut_type=device_config.get("dut_type"))
    record_time = calculate_record_time_min(run_dir)
    if record_time is not None:
        power_calc.append({"name": "record_time", "value": round(record_time, 6), "unit": "min"})
    sys_power = next((m["value"] for m in power_calc if m["name"] == "system_power"), None)
    battery_life = calculate_battery_life_hr(run_dir, sys_power)
    if battery_life is not None:
        power_calc.append({"name": "battery_life", "value": round(battery_life, 6), "unit": "hour"})
    perf = parse_perf_metrics(run_dir)
    etl = parse_etl_files(run_dir)

    result = {
        "run_info": ri,
        "device_config": device_config,
        "power_metrics": power,
        "power_calculation": power_calc,
        "perf_metrics": perf,
        "etl_files": etl,
    }

    logger.info("Extracted run %s: %d power metrics, %d perf metrics, %d ETL/trace files",
                run_dir.name, len(power), len(perf), len(etl))
    return result


def extract_all(results_dir: Path, include_failed: bool = False) -> list[dict]:
    """Extract all completed HOBL runs from a results directory.

    Args:
        results_dir: Path containing run subdirectories (e.g., C:\\hobl_results\\Power)
        include_failed: If True, also extract runs with .FAIL status

    Returns:
        List of extracted run dicts.
    """
    results_dir = Path(results_dir)
    if not results_dir.is_dir():
        logger.error("Not a directory: %s", results_dir)
        return []

    runs = []
    for sub in sorted(results_dir.iterdir()):
        if not sub.is_dir():
            continue

        # Check status markers
        if not include_failed and not (sub / ".PASS").exists():
            logger.debug("Skipping %s (no .PASS marker)", sub.name)
            continue

        result = extract_run(sub)
        if result is not None:
            runs.append(result)

    logger.info("Extracted %d runs from %s", len(runs), results_dir)
    return runs


def save_json(data: dict | list, output_path: Path, indent: int = 2) -> None:
    """Write extracted data to a JSON file."""
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=indent, ensure_ascii=False)
    logger.info("Saved JSON to %s", output_path)
