"""Derived power metrics and record time calculations for HOBL runs.

These are computed from already-parsed data (power_light.csv rails and hobl.log),
following the "Real world consistency workloads" dashboard spec.
"""

import logging
import re
from datetime import datetime
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Derived power metrics (per dashboard spec)
# ---------------------------------------------------------------------------

def _calculate_soc_power(rails: dict, dut_type: Optional[str]) -> Optional[float]:
    """SOC power formula varies by platform; see dashboard spec."""
    if not dut_type:
        return None

    def get(name):
        return rails.get(name)

    def sum_prefix(*prefixes):
        vals = [v for n, v in rails.items() if any(n.startswith(p) for p in prefixes)]
        return sum(vals) if vals else None

    dt = dut_type.strip().lower()

    if dt in ("pantherlake/lunarlake surface", "hp chiharu"):
        return sum_prefix("pm_emi_cpu")

    if dt == "cadmus denali":
        return sum_prefix("pm_emi_cpu", "pm_emi_gpu", "pm_emi_npu")

    if dt in ("cadmus romulus", "purwa"):
        sys_1a = get("pm_emi_sys_1a")
        sys_1b = get("pm_emi_sys_1b")
        lpddr  = get("pm_emi_lpddr_vdd2h_1p08v")
        if sys_1a is None or sys_1b is None or lpddr is None:
            return 0.0
        return (sys_1a + sys_1b) * 0.88 - (lpddr * 1.12)

    if dt == "heracles":
        vsys_core = get("pm_emi_vsys_core")
        memory = _return_memory_power(rails, dut_type)
        if vsys_core is None or memory is None:
            return 0.0
        return vsys_core * 0.94 - memory

    logger.warning("Unknown dut_type %r; soc_power not computed", dut_type)
    return None

def _return_system_power(rails: dict, dut_type: Optional[str]) -> Optional[float]:
    """System power metric varies by platform (Pantherlake Surface has pm_emi_system, Pantherlake HP has pm_emi_system_bat)."""
    if not dut_type:
        return None

    def get(name):
        return rails.get(name)

    dt = dut_type.strip().lower()

    if dt in ("pantherlake/lunarlake surface", "heracles"):
        return get("pm_emi_system")
    
    if dt == "hp chiharu":
        return get("pm_emi_system_bat")
    
    if dt == "cadmus denali":
        return get("pm_emi_system")

    if dt in ("cadmus romulus", "purwa"):
        return get("pm_emi_sys")

    logger.warning("Unknown dut_type %r; system_power not computed", dut_type)
    return None

def _return_memory_power(rails: dict, dut_type: Optional[str]) -> Optional[float]:
    """Memory power metric varies by platform."""
    if not dut_type:
        return None

    def get(name):
        return rails.get(name)

    dt = dut_type.strip().lower()

    if dt == "pantherlake/lunarlake surface":
        return get("pm_emi_memory_vdd2h")
    
    if dt == "heracles":
        return get("pm_emi_vddq") + get("pm_emi_memory") + get("pm_emi_vdd2h")
    
    if dt == "hp chiharu":
        return get("pm_emi_memory_vdd2h") + get("pm_emi_memory_vddq")
    
    if dt == "cadmus denali":
        return get("pm_emi_memory_vdd2h")

    if dt == "cadmus romulus":
        return get("pm_emi_lpddr_vdd2h_1p08v")
    
    if dt == "purwa":
        return get("pm_emi_lpddr_vdd2h_1p08v") + get("pm_emi_lpddr_vdd2l_0p9v")

    logger.warning("Unknown dut_type %r; memory_power not computed", dut_type)
    return None

def _return_display_power(rails: dict, dut_type: Optional[str]) -> Optional[float]:
    """Display power metric varies by platform."""
    if not dut_type:
        return None

    def get(name):
        return rails.get(name)

    dt = dut_type.strip().lower()

    if dt == "pantherlake/lunarlake surface":
        return get("pm_emi_display_backlight") + get("pm_emi_display_3p3v_panel")
    
    if dt == "heracles":
        return get("pm_emi_bklt_in") + get("pm_emi_3p3v_panel_in")
    
    if dt == "hp chiharu":
        return get("pm_emi_display_panel_bl")
    
    if dt == "cadmus denali":
        return get("pm_emi_display_bklt") + get("pm_emi_display_panel_3p3v")

    if dt == "cadmus romulus":
        return get("pm_emi_display_bklt") + get("pm_emi_display_panel_3p3v")
    
    if dt == "purwa":
        return get("pm_emi_display_bklt") + get("pm_emi_display_panel_3p3v")

    logger.warning("Unknown dut_type %r; display_power not computed", dut_type)
    return None

def _return_display_logic_power(rails: dict, dut_type: Optional[str]) -> Optional[float]:
    """Display logic power metric varies by platform."""
    if not dut_type:
        return None

    def get(name):
        return rails.get(name)

    dt = dut_type.strip().lower()

    if dt == "pantherlake/lunarlake surface":
        return 0.0
    
    if dt == "heracles":
        return 0.0
    
    if dt == "hp chiharu":
        return get("pm_emi_display_panel_logic")
    
    if dt == "cadmus denali":
        return 0.0

    if dt == "cadmus romulus":
        return 0.0
    
    if dt == "purwa":
        return 0.0

    logger.warning("Unknown dut_type %r; display_logic_power not computed", dut_type)
    return None

def _return_display_light_power(rails: dict, dut_type: Optional[str]) -> Optional[float]:
    """Display light power metric varies by platform."""
    if not dut_type:
        return None

    def get(name):
        return rails.get(name)

    dt = dut_type.strip().lower()

    if dt == "pantherlake/lunarlake surface":
        return get("pm_emi_display_backlight")
    
    if dt == "heracles":
        return get("pm_emi_bklt_in")
    
    if dt == "hp chiharu":
        return 0.0
    
    if dt == "cadmus denali":
        return get("pm_emi_display_bklt") + get("pm_emi_display_panel_3p3v")

    if dt == "cadmus romulus":
        return get("pm_emi_display_bklt")
    
    if dt == "purwa":
        return get("pm_emi_display_bklt")

    logger.warning("Unknown dut_type %r; display_light_power not computed", dut_type)
    return None


def calculate_power_metrics(power_metrics: list[dict], dut_type: Optional[str] = None) -> list[dict]:
    """Calculate aggregate power metrics from raw pm_emi_* rails.

    Formulas follow the "Real world consistency workloads" dashboard spec.
    Metrics whose source rails are not present in this run are given value 0.0.
    `dut_type` selects the platform-specific SOC power formula; if blank/unknown,
    soc_power is omitted.

    Returns list of {"name": str, "value": float, "unit": "W"}.
    """
    rails = {m["name"]: m["value"] for m in power_metrics if "name" in m and "value" in m}

    def get(name):
        return rails.get(name)

    def sum_present(*names):
        vals = [rails[n] for n in names if n in rails]
        return sum(vals) if vals else None

    def sum_prefix(*prefixes):
        vals = [v for n, v in rails.items() if any(n.startswith(p) for p in prefixes)]
        return sum(vals) if vals else None

    definitions = [
        ("memory_power",            _return_memory_power(rails, dut_type)),
        ("display_power",           _return_display_power(rails, dut_type)),
        ("display_logic_power",     _return_display_logic_power(rails, dut_type)),
        ("display_light_power",     _return_display_light_power(rails, dut_type)),
        ("audio_power",             sum_prefix("pm_emi_audio_")),
        ("touch_power",             sum_present("pm_emi_trackpad_3p3v", "pm_emi_trackpad_5v")),
        ("storage_power",           get("pm_emi_storage_3p3v_ssd")),
        ("camera_power",            0.0),
        ("rop_power",               get("pm_emi_vsys_rop")),
        ("sam_power",               0.0),
        ("wifi_bt_power",           get("pm_emi_wifi_3p3v_wlan")),
        ("keyboard_trackpad_power", sum_present("pm_emi_trackpad_3p3v", "pm_emi_trackpad_5v")),
        ("cpu_power",               sum_prefix("pm_emi_cpu")),
        ("gpu_power",               sum_prefix("pm_emi_gpu")),
        ("npu_power",               sum_prefix("pm_emi_npu")),
        ("multimedia_power",        sum_present("pm_emi_multimedia", "pm_emi_mm")),
        ("system_power",            _return_system_power(rails, dut_type)),
        ("soc_power",               _calculate_soc_power(rails, dut_type)),
    ]

    result = []
    for name, value in definitions:
        if value is None:
            value = 0.0
        result.append({"name": name, "value": round(value, 6), "unit": "W"})

    logger.info("Calculated %d aggregate power metrics", len(result))
    return result


# ---------------------------------------------------------------------------
# Record time from hobl.log
# ---------------------------------------------------------------------------

_LOG_TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),(\d{3})")


def _parse_log_timestamp(line: str) -> Optional[datetime]:
    m = _LOG_TS_RE.match(line)
    if not m:
        return None
    try:
        return datetime.strptime(f"{m.group(1)}.{m.group(2)}000", "%Y-%m-%d %H:%M:%S.%f")
    except ValueError:
        return None


def calculate_record_time_min(run_dir: Path) -> Optional[float]:
    """Compute record time in minutes from hobl.log (last_ts - first_ts)."""
    log_path = run_dir / "hobl.log"
    if not log_path.exists():
        logger.warning("hobl.log not found in %s", run_dir)
        return None

    first_ts = None
    last_ts = None
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                ts = _parse_log_timestamp(line)
                if ts is None:
                    continue
                if first_ts is None:
                    first_ts = ts
                last_ts = ts
    except OSError as e:
        logger.error("Failed to read %s: %s", log_path, e)
        return None

    if first_ts is None or last_ts is None:
        logger.warning("No timestamps parsed from %s", log_path)
        return None

    delta_min = (last_ts - first_ts).total_seconds() / 60.0
    logger.info("Record time from hobl.log: %.3f min", delta_min)
    return delta_min
