"""Parsers for all HOBL result CSV files.

Handles: power_light.csv, PerfMetrics.csv, Config.csv, run_info.csv, and ETL/trace files.
"""

import csv
import logging
import re
import socket
import subprocess
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
    "Mobility": "mobility",
    "Bitlocker State": "bitlocker_state",
    "DUT Type": "dut_type",
    "Usable RAM (GB)": "usable_ram_config_gb",
    "Boot Image Version": "LKG",
    "Hardware Version": "HWVersion",
}

_CONFIG_INT_FIELDS = {"memory_size_gb", "storage_size_gb", "battery_cycles",
                      "battery_capacity_wh", "battery_full_charge_mwh",
                      "battery_charge_pct", "screen_brightness_pct", "usable_ram_config_gb"}


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


def _get_host_name() -> str:
    """Get host name using OS command with socket fallback."""
    try:
        output = subprocess.run(
            ["hostname"],
            capture_output=True,
            text=True,
            check=False,
        )
        host = (output.stdout or "").strip()
        if host:
            return host
    except OSError:
        pass

    return socket.gethostname()


# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------

def parse_power_light(run_dir: Path) -> list[dict]:
    """Parse *_power_light.csv -- power rail readings in Watts.

    Returns list of {"name": str, "value": float, "unit": "W"}. When the same
    rail name appears more than once in a run, a 1-based ordering suffix is
    appended to every occurrence ("<name>_1", "<name>_2", ...) so the metric
    names stay unique (mirrors parse_perf_metrics). Names that appear only once
    are left unchanged.
    """
    filepath = _find_file(run_dir, "*_power_light.csv")
    if filepath is None:
        logger.warning("No *_power_light.csv found in %s", run_dir)
        return []

    rows = []
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
                rows.append((name, value))
    except OSError as e:
        logger.error("Failed to read %s: %s", filepath, e)
        return []

    # Count occurrences first so unique names stay clean and only duplicated
    # names get a "_<ordering>" suffix.
    name_totals: dict[str, int] = {}
    for name, _ in rows:
        name_totals[name] = name_totals.get(name, 0) + 1

    metrics = []
    order_counts: dict[str, int] = {}
    for name, value in rows:
        if name_totals[name] > 1:
            order = order_counts.get(name, 0) + 1
            order_counts[name] = order
            out_name = f"{name}_{order}"
        else:
            out_name = name
        metrics.append({"name": out_name, "value": value, "unit": "W"})

    logger.info("Parsed %d power metrics from %s", len(metrics), filepath.name)
    return metrics


def parse_perf_metrics(run_dir: Path) -> list[dict]:
    """Parse *_PerfMetrics.csv -- app launch durations.

    Returns list of {"name": str, "value": int, "unit": "ms"} to match the
    power_metrics shape. The headerless CSV contains Metric and Duration columns.
    The name is "<metric>_<ordering>", where ordering is a 1-based counter that
    increments each time a metric is repeated within the run.
    """
    filepath = _find_file(run_dir, "*_PerfMetrics.csv")
    if filepath is None:
        logger.info("No *_PerfMetrics.csv found in %s", run_dir)
        return []

    metrics = []
    order_counts: dict[str, int] = {}
    try:
        with open(filepath, "r", encoding="utf-8-sig") as f:
            for row in csv.reader(f):
                if len(row) < 2:
                    logger.warning("Skipping invalid perf row: %s", row)
                    continue
                try:
                    metric = row[0].strip()
                    duration = int(row[1].strip())
                except (ValueError, AttributeError) as e:
                    logger.warning("Skipping invalid perf row: %s (%s)", row, e)
                    continue
                if metric:
                    key = metric
                    order = order_counts.get(key, 0) + 1
                    order_counts[key] = order
                    name = f"{metric}_{order}"
                    metrics.append({"name": name, "value": duration, "unit": "ms"})
    except OSError as e:
        logger.error("Failed to read %s: %s", filepath, e)
        return []

    logger.info("Parsed %d perf metrics from %s", len(metrics), filepath.name)
    return metrics


def parse_teams_call_health(run_dir: Path) -> list[dict]:
    """Parse teams_call_health_info_rollup.csv -- Teams call quality metrics.

    Extracts values for the perf_metrics section:
      - teams_fps from the "Video Sent frame rate" row (unit "fps")
      - teams_video_resolution_width / teams_video_resolution_height from the
        "Video Sent Resolution" row (unit "px"), split from a "<width> x <height>"
        string.

    Returns list of {"name": str, "value": float|int, "unit": str}. Returns an
    empty list when the file is missing or empty.
    """
    filepath = _find_file(run_dir, "teams_call_health_info_rollup.csv")
    if filepath is None:
        logger.info("No teams_call_health_info_rollup.csv found in %s", run_dir)
        return []

    raw = _read_key_value_csv(filepath)
    if not raw:
        logger.info("teams_call_health_info_rollup.csv is empty in %s", run_dir)
        return []

    # Case-insensitive lookup of the rows we care about.
    lookup = {k.strip().lower(): v.strip() for k, v in raw.items()}
    metrics = []

    fps_raw = lookup.get("video sent frame rate")
    if fps_raw:
        match = re.search(r"[-+]?\d*\.?\d+", fps_raw)
        if match:
            metrics.append({"name": "teams_fps", "value": float(match.group()), "unit": "fps"})
        else:
            logger.warning("Could not parse Teams FPS from %r", fps_raw)

    res_raw = lookup.get("video sent resolution")
    if res_raw:
        # Split a "<width> x <height>" string (e.g. "424 x 240", optionally with a
        # trailing "px") into separate width and height metrics.
        match = re.search(r"(\d+)\s*[x*×]\s*(\d+)", res_raw, flags=re.IGNORECASE)
        if match:
            width, height = int(match.group(1)), int(match.group(2))
            metrics.append({"name": "teams_video_resolution_width", "value": width, "unit": "px"})
            metrics.append({"name": "teams_video_resolution_height", "value": height, "unit": "px"})
        else:
            logger.warning("Could not parse Teams Video Resolution from %r", res_raw)

    logger.info("Parsed %d Teams call health metrics from %s", len(metrics), filepath.name)
    return metrics


def parse_config(run_dir: Path) -> dict:
    """Parse Config.csv -- device configuration (31 fields)."""
    filepath = run_dir / "Config.csv"
    if not filepath.exists():
        filepath = run_dir / "config.csv"
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

    # OEM is derived from the same "DUT Type" column as dut_type. They can't both
    # live in _CONFIG_FIELD_MAP because a duplicate dict key would drop one of them.
    if "dut_type" in config:
        config["OEM"] = config["dut_type"]

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

    info = {"status": status, "HostName": _get_host_name()}

    # Config.csv's "Capture Time" is stamped during scenario setUp, so it marks when the
    # run started. Surface it under run_info as run_start_time.
    config_path = run_dir / "Config.csv"
    if not config_path.exists():
        config_path = run_dir / "config.csv"
    if config_path.exists():
        config_raw = _read_key_value_csv(config_path)
        if "Capture Time" in config_raw:
            info["run_start_time"] = config_raw["Capture Time"]

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
