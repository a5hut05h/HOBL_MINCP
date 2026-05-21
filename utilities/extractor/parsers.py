"""Parsers for all HOBL result CSV files.

Handles: power_light.csv, PerfMetrics.csv, Config.csv, run_info.csv, and ETL/trace files.
"""

import csv
import logging
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Config.csv field mappings
# ---------------------------------------------------------------------------

_CONFIG_FIELD_MAP = {
    "Product": "product",
    "Product Mfg": "product_mfg",
    "Device Name": "device_name",
    "Serial Number": "serial_number",
    "OS Build": "os_build",
    "CPU Name": "cpu_name",
    "CPU Mfg": "cpu_mfg",
    "Integrated GPU": "integrated_gpu",
    "Discrete GPU": "discrete_gpu",
    "Display Resolution": "display_resolution",
    "Memory Mfg": "memory_mfg",
    "Memory Size (GB)": "memory_size_gb",
    "Storage Mfg": "storage_mfg",
    "Storage Size (GB)": "storage_size_gb",
    "Storage Firmware": "storage_firmware",
    "Battery 1 Cycle Count": "battery_cycles",
    "Battery Total Designed Capacity (Wh)": "battery_capacity_wh",
    "Battery Full Charge Capacity (mWh)": "battery_full_charge_mwh",
    "Battery Charge State (%)": "battery_charge_pct",
    "Screen Brightness (%)": "screen_brightness_pct",
    "Adaptive Brightness Sensor": "adaptive_brightness",
    "Power Plan": "power_plan",
    "Power Mode": "power_mode",
    "HOBL Version": "hobl_version",
    "Edge Version": "edge_version",
    "Teams Version": "teams_version",
    "Office Version": "office_version",
    "UEFI Version": "uefi_version",
    "Capture Time": "capture_time",
    "Mobility": "mobility",
    "Bitlocker State": "bitlocker_state",
}

_CONFIG_INT_FIELDS = {"memory_size_gb", "storage_size_gb", "battery_cycles",
                      "battery_capacity_wh", "battery_full_charge_mwh",
                      "battery_charge_pct", "screen_brightness_pct"}

_RUN_INFO_FIELD_MAP = {
    "Run Path": "run_path",
    "Run URL": "run_url",
    "Run Type": "run_type",
    "Run Number": "run_number",
    "Test Name": "test_name",
    "Scenario": "scenario",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _find_file(run_dir: Path, pattern: str) -> Optional[Path]:
    """Find a file matching a glob pattern in a run directory."""
    matches = list(run_dir.glob(pattern))
    if not matches:
        return None
    if len(matches) > 1:
        logger.warning("Multiple files matching %s in %s, using first", pattern, run_dir)
    return matches[0]


def _read_key_value_csv(filepath: Path) -> dict[str, str]:
    """Read a CSV with Key,Value rows into a dict."""
    raw = {}
    try:
        with open(filepath, "r", encoding="utf-8-sig") as f:
            for row in csv.reader(f):
                if len(row) >= 2:
                    raw[row[0].strip()] = row[1].strip()
    except OSError as e:
        logger.error("Failed to read %s: %s", filepath, e)
    return raw


# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------

def parse_power_light(run_dir: Path) -> list[dict]:
    """Parse *_power_light.csv -- power rail readings in Watts.

    Returns list of {"name": str, "value": float, "unit": "W"}
    """
    filepath = _find_file(run_dir, "*_power_light.csv")
    if filepath is None:
        logger.warning("No *_power_light.csv found in %s", run_dir)
        return []

    metrics = []
    try:
        with open(filepath, "r", encoding="utf-8-sig") as f:
            for row in csv.reader(f):
                if len(row) < 2:
                    continue
                name = row[0].strip()
                try:
                    value = float(row[1].strip())
                except ValueError:
                    logger.warning("Invalid value for metric %s: %s", name, row[1])
                    continue
                metrics.append({"name": name, "value": value, "unit": "W"})
    except OSError as e:
        logger.error("Failed to read %s: %s", filepath, e)
        return []

    logger.info("Parsed %d power metrics from %s", len(metrics), filepath.name)
    return metrics


def parse_perf_metrics(run_dir: Path) -> list[dict]:
    """Parse *_PerfMetrics.csv -- app launch durations.

    Returns list of {"pt": int, "metric": str, "duration_ms": int}
    """
    filepath = _find_file(run_dir, "*_PerfMetrics.csv")
    if filepath is None:
        logger.info("No *_PerfMetrics.csv found in %s", run_dir)
        return []

    metrics = []
    try:
        with open(filepath, "r", encoding="utf-8-sig") as f:
            for row in csv.DictReader(f):
                try:
                    pt = int(row.get("PT", "0").strip())
                    metric = row.get("Metric", "").strip()
                    duration = int(row.get("Duration", "0").strip())
                except (ValueError, AttributeError) as e:
                    logger.warning("Skipping invalid perf row: %s (%s)", row, e)
                    continue
                if metric:
                    metrics.append({"pt": pt, "metric": metric, "duration_ms": duration})
    except OSError as e:
        logger.error("Failed to read %s: %s", filepath, e)
        return []

    logger.info("Parsed %d perf metrics from %s", len(metrics), filepath.name)
    return metrics


def parse_config(run_dir: Path) -> dict:
    """Parse Config.csv -- device configuration (31 fields)."""
    filepath = run_dir / "Config.csv"
    if not filepath.exists():
        logger.warning("Config.csv not found in %s", run_dir)
        return {}

    raw = _read_key_value_csv(filepath)
    config = {}
    for csv_key, json_key in _CONFIG_FIELD_MAP.items():
        if csv_key in raw:
            value = raw[csv_key]
            if json_key in _CONFIG_INT_FIELDS:
                try:
                    value = int(value)
                except ValueError:
                    pass
            config[json_key] = value

    logger.info("Parsed %d config fields from Config.csv", len(config))
    return config


def parse_run_info(run_dir: Path) -> dict:
    """Parse run_info.csv + detect status from .PASS/.FAIL/.RUNNING markers."""
    if (run_dir / ".PASS").exists():
        status = "PASS"
    elif (run_dir / ".FAIL").exists():
        status = "FAIL"
    elif (run_dir / ".RUNNING").exists():
        status = "RUNNING"
    else:
        status = "UNKNOWN"

    info = {"status": status}

    filepath = run_dir / "run_info.csv"
    if not filepath.exists():
        logger.warning("run_info.csv not found in %s", run_dir)
        info["run_path"] = str(run_dir)
        parts = run_dir.name.rsplit("_", 1)
        info["scenario"] = parts[0] if len(parts) == 2 and parts[1].isdigit() else run_dir.name
        return info

    raw = _read_key_value_csv(filepath)
    for csv_key, json_key in _RUN_INFO_FIELD_MAP.items():
        if csv_key in raw:
            value = raw[csv_key]
            if json_key == "run_number":
                try:
                    value = int(value)
                except ValueError:
                    pass
            info[json_key] = value

    logger.info("Parsed run_info: scenario=%s, run=%s, status=%s",
                info.get("scenario"), info.get("run_number"), info.get("status"))
    return info


def parse_etl_files(run_dir: Path) -> list[dict]:
    """Find ETL/trace files and return their metadata.

    Returns list of {"name": str, "path": str, "size_bytes": int, "type": str}
    """
    files = []
    for pattern, file_type in [("*.etl", "etl"), ("*.trace", "trace")]:
        for f in sorted(run_dir.glob(pattern)):
            try:
                size = f.stat().st_size
            except OSError:
                size = 0
            files.append({"name": f.name, "path": str(f), "size_bytes": size, "type": file_type})

    logger.info("Found %d ETL/trace files in %s", len(files), run_dir.name)
    return files
