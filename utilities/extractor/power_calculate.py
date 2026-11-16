"""Derived power metrics and record time calculations for HOBL runs.

These are computed from already-parsed data (power_light.csv rails and hobl.log),
following the "Real world consistency workloads" dashboard spec.
"""

import csv
import logging
import re
from datetime import datetime
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


_PANTHERLAKE_SURFACE_RAILS = {
    "pm_emi_system",
    "pm_emi_memory_vdd2h",
    "pm_emi_display_backlight",
    "pm_emi_display_3p3v_panel",
    "pm_emi_storage_3p3v_ssd",
    "pm_emi_wifi_3p3v_wlan",
}

_CADMUS_ROMULUS_RAILS = {
    "pm_emi_sys",
    "pm_emi_sys_1a",
    "pm_emi_sys_1b",
    "pm_emi_lpddr_vdd2h_1p08v",
    "pm_emi_display_bklt",
    "pm_emi_display_panel_3p3v",
    "pm_emi_sys_rop_left",
    "pm_emi_sys_rop_right",
    "pm_emi_wifi_3p86v",
    "pm_emi_storage",
}


def _resolve_dut_type(rails: dict, dut_type: Optional[str]) -> Optional[str]:
    """Use an explicit DUT type, or infer one from a distinctive rail set."""
    if dut_type and dut_type.strip():
        return dut_type

    if _PANTHERLAKE_SURFACE_RAILS.issubset(rails):
        inferred = "Pantherlake/LunarLake surface"
        logger.info("Inferred dut_type %r from power rail names", inferred)
        return inferred

    if _CADMUS_ROMULUS_RAILS.issubset(rails):
        inferred = "Cadmus Romulus"
        logger.info("Inferred dut_type %r from power rail names", inferred)
        return inferred

    logger.warning("dut_type is blank and could not be inferred from power rail names")
    return None


def _sum_required_rails(rails: dict, *names: str) -> Optional[float]:
    """Sum rails only when every required source is available."""
    values = [rails.get(name) for name in names]
    if any(value is None for value in values):
        return None
    return sum(values)


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
        required = ("pm_emi_sys_1a", "pm_emi_sys_1b", "pm_emi_lpddr_vdd2h_1p08v")
        missing = [name for name in required if get(name) is None]
        if missing:
            logger.warning("Cannot calculate soc_power for %s; missing rails: %s",
                           dut_type, ", ".join(missing))
            return None
        sys_1a, sys_1b, lpddr = (get(name) for name in required)
        return (sys_1a + sys_1b) * 0.88 - (lpddr * 1.12)

    if dt == "heracles":
        vsys_core = get("pm_emi_vsys_core")
        memory = _return_memory_power(rails, dut_type)
        if vsys_core is None or memory is None:
            return None
        return vsys_core * 0.94 - memory

    logger.warning("Unknown dut_type %r; soc_power not computed", dut_type)
    return None

def _return_system_power(rails: dict, dut_type: Optional[str]) -> Optional[float]:
    """System power metric varies by platform (Pantherlake Surface has pm_emi_system, Pantherlake HP has pm_emi_system_bat)."""
    if not dut_type:
        return None

    dt = dut_type.strip().lower()

    rail_by_dut_type = {
        "pantherlake/lunarlake surface": "pm_emi_system",
        "heracles": "pm_emi_system",
        "hp chiharu": "pm_emi_system_bat",
        "cadmus denali": "pm_emi_system",
        "cadmus romulus": "pm_emi_sys",
        "purwa": "pm_emi_sys",
    }
    rail_name = rail_by_dut_type.get(dt)
    if rail_name is not None:
        value = rails.get(rail_name)
        if value is None:
            logger.warning("Cannot calculate system_power for %s; missing rail: %s",
                           dut_type, rail_name)
        return value

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
        return _sum_required_rails(rails, "pm_emi_vddq", "pm_emi_vdd2h")
    
    if dt == "hp chiharu":
        return _sum_required_rails(rails, "pm_emi_mem_vdd2h", "pm_emi_mem_vddq")
    
    if dt == "cadmus denali":
        return get("pm_emi_memory_vdd2h")

    if dt == "cadmus romulus":
        return get("pm_emi_lpddr_vdd2h_1p08v")
    
    if dt == "purwa":
        return _sum_required_rails(rails, "pm_emi_lpddr_vdd2h_1p08v", "pm_emi_lpddr_vdd2l_0p9v")

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
        return _sum_required_rails(rails, "pm_emi_display_backlight", "pm_emi_display_3p3v_panel")
    
    if dt == "heracles":
        return _sum_required_rails(rails, "pm_emi_bklt_in", "pm_emi_3p3v_panel_in")
    
    if dt == "hp chiharu":
        return get("pm_emi_display_panel_bl")
    
    if dt == "cadmus denali":
        return _sum_required_rails(rails, "pm_emi_display_bklt", "pm_emi_display_panel_3p3v")

    if dt == "cadmus romulus":
        return _sum_required_rails(rails, "pm_emi_display_bklt", "pm_emi_display_panel_3p3v")
    
    if dt == "purwa":
        return _sum_required_rails(rails, "pm_emi_display_bklt", "pm_emi_display_panel_3p3v")

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
        return get("pm_emi_display_panel_bl")
    
    if dt == "cadmus denali":
        return _sum_required_rails(rails, "pm_emi_display_bklt", "pm_emi_display_panel_3p3v")

    if dt == "cadmus romulus":
        return get("pm_emi_display_bklt")
    
    if dt == "purwa":
        return get("pm_emi_display_bklt")

    logger.warning("Unknown dut_type %r; display_light_power not computed", dut_type)
    return None

def _return_storage_power(rails: dict, dut_type: Optional[str]) -> Optional[float]:
    """Storage power metric varies by platform."""
    if not dut_type:
        return None

    def get(name):
        return rails.get(name)

    dt = dut_type.strip().lower()

    if dt == "pantherlake/lunarlake surface":
        return get("pm_emi_storage_3p3v_ssd")
    
    if dt == "heracles":
        return get("pm_emi_3p3v_ssd")
    
    if dt == "hp chiharu":
        return get("pm_emi_storage_ssd")
    
    if dt == "cadmus denali":
        return get("pm_emi_storage")

    if dt == "cadmus romulus":
        return get("pm_emi_storage")
    
    if dt == "purwa":
        return get("pm_emi_storage")

    logger.warning("Unknown dut_type %r; storage_power not computed", dut_type)
    return None

def _return_rop_power(rails: dict, dut_type: Optional[str]) -> Optional[float]:
    """ROP power metric varies by platform."""
    if not dut_type:
        return None

    def get(name):
        return rails.get(name)

    dt = dut_type.strip().lower()

    if dt == "pantherlake/lunarlake surface":
        return get("pm_emi_vsys_rop")
    
    if dt == "heracles":
        return get("pm_emi_vsys_rop")
    
    if dt == "hp chiharu":
        return get("pm_emi_vsys_rop")
    
    if dt == "cadmus denali":
        return _sum_required_rails(rails, "pm_emi_sys_rop_left", "pm_emi_sys_rop_right")

    if dt == "cadmus romulus":
        return _sum_required_rails(rails, "pm_emi_sys_rop_left", "pm_emi_sys_rop_right")
    
    if dt == "purwa":
        return _sum_required_rails(rails, "pm_emi_sys_rop_left", "pm_emi_sys_rop_right")

    logger.warning("Unknown dut_type %r; rop_power not computed", dut_type)
    return None

def _return_wifi_power(rails: dict, dut_type: Optional[str]) -> Optional[float]:
    """WiFi power metric varies by platform."""
    if not dut_type:
        return None

    def get(name):
        return rails.get(name)

    dt = dut_type.strip().lower()

    if dt == "pantherlake/lunarlake surface":
        return get("pm_emi_wifi_3p3v_wlan")
    
    if dt == "heracles":
        return get("pm_emi_3p86v_wifi")
    
    if dt == "hp chiharu":
        return get("pm_emi_wifi_3v")
    
    if dt == "cadmus denali":
        return 0.0

    if dt == "cadmus romulus":
        return get("pm_emi_wifi_3p86v")
    
    if dt == "purwa":
        return get("pm_emi_wifi_3p3v_wlan")

    logger.warning("Unknown dut_type %r; wifi_power not computed", dut_type)
    return None

# ---------------------------------------------------------------------------
# Platform corrections (kept in step with HOBL_Viewer's power_calculations.py)
# ---------------------------------------------------------------------------
# Rail names are matched on a normalised key (lowercase alphanumerics, trailing
# "w" dropped), so capitalisation, punctuation and a unit suffix do not matter.

_DISPLAY_BACKLIGHT_KEYS = ("pmemidisplaybklt", "pmemibkltin", "pmemidisplaybacklight")
_DISPLAY_PANEL_KEYS = ("pmemidisplaypanel3p3v", "pmemi3p3vpanelin", "pmemidisplaypanel")
_VSYS_CORE_KEYS = ("vsyscore", "pmemivsyscore")
_VSYS_ROP_KEYS = ("vsysrop", "pmemivsysrop")
_MINOS_SYSTEM_KEYS = ("pmemisystem", "pmemisys")
_MINOS_SOC_RAIL_KEYS = (
    ("pmicmt6363", "pmemipmicmt6363"),
    ("pmicmt6373", "pmemipmicmt6373"),
    ("cpup", "pmemicpup"),
    ("cpue", "pmemicpue"),
    ("gpum", "pmemigpum", "pmemigpumisc"),
    ("gpuc", "pmemigpuc", "pmemigpucompute"),
    ("core", "pmemicore", "pmemicpucore"),
    ("dla", "dlanpu", "pmemidla", "pmemidlanpu", "pmeminpu"),
)
_MINOS_GROUPED_RAILS = (
    ("memory_power", "pmemimemory"),
    ("cpu_power", "pmemicpu"),
    ("npu_power", "pmeminpu"),
    ("gpu_power", "pmemigpu"),
    ("storage_power", "pmemistorage"),
    ("wifi_bt_power", "pmemiwifi"),
    ("camera_power", "pmemicamera"),
    ("keyboard_trackpad_power", "pmemikeyboard"),
    ("sam_power", "pmemisam"),
    ("touch_power", "pmemitouch"),
)
# Everything a Purwa ROP residual subtracts from system power. touch_power is
# left out: outside Minos it is computed from the same trackpad rails as
# keyboard_trackpad_power, so including both would subtract the trackpad twice.
_PURWA_ROP_COMPONENTS = (
    "soc_power", "npu_power", "memory_power", "storage_power", "wifi_bt_power",
    "display_power", "audio_power", "camera_power", "sam_power",
    "keyboard_trackpad_power",
)


def _metric_key(name: str) -> str:
    key = re.sub(r"[^a-z0-9]", "", (name or "").lower())
    return key[:-1] if key.endswith("w") else key


def _platform_family(*identifiers: Optional[str]) -> Optional[str]:
    """Pick the corrected-formula family from the device name or DUT type."""
    keys = [_metric_key(str(value)) for value in identifiers if value]
    if any("heracles" in k or "hesrot" in k or "herrot" in k for k in keys):
        return "heracles"
    if any("minos" in k or "diomin" in k for k in keys):
        return "minos"
    if any("purwa" in k for k in keys):
        return "purwa"
    return None


def _first_rail(rails_by_key: dict, aliases) -> Optional[float]:
    return next((rails_by_key[k] for k in aliases if k in rails_by_key), None)


def _sum_rail_groups(rails_by_key: dict, *alias_groups) -> Optional[float]:
    """Sum one rail per alias group; None unless every group is present."""
    values = [_first_rail(rails_by_key, aliases) for aliases in alias_groups]
    if any(value is None for value in values):
        return None
    return sum(values)


def _sum_rail_prefix(rails_by_key: dict, prefix: str) -> Optional[float]:
    values = [v for k, v in rails_by_key.items() if k.startswith(prefix)]
    return sum(values) if values else None


def _apply_platform_formulas(calcs: dict, rails: dict, family: Optional[str]) -> None:
    """Overwrite `calcs` (name -> value or None) with the family's formulas.

    A formula only replaces a value when all of its inputs are present, so a run
    missing a rail keeps whatever the generic formulas produced.
    """
    if family is None:
        return
    rk = {_metric_key(name): value for name, value in rails.items()}

    def put(name, value):
        if value is not None:
            calcs[name] = value

    display = _sum_rail_groups(rk, _DISPLAY_BACKLIGHT_KEYS, _DISPLAY_PANEL_KEYS)

    if family == "heracles":
        put("memory_power", _sum_rail_prefix(rk, "pmemimemory"))
        put("display_power", display)
        core = _first_rail(rk, _VSYS_CORE_KEYS)
        rop = _first_rail(rk, _VSYS_ROP_KEYS)
        if core is not None and calcs.get("memory_power") is not None:
            calcs["soc_power"] = core * 0.94 - calcs["memory_power"]
        if core is not None and rop is not None:
            calcs["system_power"] = core + rop

    elif family == "minos":
        put("system_power", _first_rail(rk, _MINOS_SYSTEM_KEYS))
        soc = _sum_rail_groups(rk, *_MINOS_SOC_RAIL_KEYS)
        put("soc_power", None if soc is None else 0.85 * soc)
        put("display_power", _sum_rail_groups(rk, ("pmemidisplaypanel",), ("pmemidisplaybacklight",)))
        for name, prefix in _MINOS_GROUPED_RAILS:
            put(name, _sum_rail_prefix(rk, prefix))

    elif family == "purwa":
        put("display_power", display)
        total = calcs.get("system_power")
        parts = [calcs.get(name) for name in _PURWA_ROP_COMPONENTS]
        if total is not None and all(part is not None for part in parts):
            calcs["rop_power"] = total - sum(parts)


def calculate_power_metrics(power_metrics: list[dict], dut_type: Optional[str] = None,
                            device_name: Optional[str] = None) -> list[dict]:
    """Calculate aggregate power metrics from raw pm_emi_* rails.

    Formulas follow the "Real world consistency workloads" dashboard spec.
    Metrics whose source rails are not present in this run are omitted.
    `dut_type` selects the platform-specific formulas; if blank/unknown, those
    metrics are omitted. Heracles, Minos and Purwa runs (recognised from
    `device_name` or `dut_type`) then get the corrected formulas HOBL_Viewer
    applies, see _apply_platform_formulas.

    Returns list of {"name": str, "value": float, "unit": "W"}.
    """
    rail_samples: dict[str, list[float]] = {}
    for metric in power_metrics:
        if "name" not in metric or "value" not in metric:
            continue
        name = str(metric["name"]).strip().lower()
        value = metric["value"]
        if value is None:
            logger.warning("Skipping power metric %s with no value", name)
            continue
        rail_samples.setdefault(name, []).append(value)

    # Preserve numeric suffixes because they can be part of a real rail name,
    # such as pm_emi_cpu_cluster_0.
    rails = {name: sum(values) / len(values) for name, values in rail_samples.items()}
    dut_type = _resolve_dut_type(rails, dut_type)
    family = _platform_family(device_name, dut_type)
    # A Heracles or Purwa unit always gets that platform's generic formulas, even
    # when its DUT Type is blank, misspelled or names another platform.
    if family in ("heracles", "purwa") and (dut_type or "").strip().lower() != family:
        if dut_type:
            logger.warning("DUT type %r conflicts with %s device %r; using %s formulas",
                           dut_type, family, device_name, family)
        dut_type = family

    def get(name):
        return rails.get(name)

    def sum_present(*names):
        vals = [rails[n] for n in names if n in rails]
        return sum(vals) if vals else None

    def sum_prefix(*prefixes):
        vals = [v for n, v in rails.items() if any(n.startswith(p) for p in prefixes)]
        return sum(vals) if vals else None

    definitions = [
        ("system_power",            _return_system_power(rails, dut_type)),
        ("soc_power",               _calculate_soc_power(rails, dut_type)),
        ("memory_power",            _return_memory_power(rails, dut_type)),
        ("display_power",           _return_display_power(rails, dut_type)),
        ("display_logic_power",     _return_display_logic_power(rails, dut_type)),
        ("display_light_power",     _return_display_light_power(rails, dut_type)),
        ("audio_power",             sum_prefix("pm_emi_audio_")),
        ("touch_power",             sum_present("pm_emi_trackpad_3p3v", "pm_emi_trackpad_5v")),
        ("storage_power",           _return_storage_power(rails, dut_type)),
        ("camera_power",            0.0),
        ("rop_power",               _return_rop_power(rails, dut_type)),
        ("sam_power",               0.0),
        ("wifi_bt_power",           _return_wifi_power(rails, dut_type)),
        ("keyboard_trackpad_power", sum_present("pm_emi_trackpad_3p3v", "pm_emi_trackpad_5v")),
        ("cpu_power",               sum_prefix("pm_emi_cpu")),
        ("gpu_power",               sum_prefix("pm_emi_gpu")),
        ("npu_power",               sum_prefix("pm_emi_npu")),
        ("multimedia_power",        sum_present("pm_emi_multimedia", "pm_emi_mm")),
    ]

    calcs = dict(definitions)
    _apply_platform_formulas(calcs, rails, family)

    result = []
    for name, value in calcs.items():
        if value is not None:
            result.append({"name": name, "value": round(value, 6), "unit": "W"})

    logger.info("Calculated %d aggregate power metrics", len(result))
    return result


# ---------------------------------------------------------------------------
# Record time from hobl.log
# ---------------------------------------------------------------------------

_LOG_TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),(\d{3})")


# ---------------------------------------------------------------------------
# Battery life from Config.csv and system_power
# ---------------------------------------------------------------------------

def calculate_battery_life_hr(run_dir: Path, system_power_w: Optional[float]) -> Optional[float]:
    """Compute battery life in hours = design_capacity_wh / system_power_w.

    Reads `Battery Total Designed Capacity (Wh)` from `<run_dir>/Config.csv` (key,value
    rows). The value is already in Wh, so no unit conversion is needed. Returns None if
    the CSV is missing, the value can't be parsed, or `system_power_w` is missing/zero.
    """
    if system_power_w is None or system_power_w <= 0:
        logger.warning("system_power missing or non-positive; battery_life not computed")
        return None

    config_path = run_dir / "Config.csv"
    if not config_path.exists():
        config_path = run_dir / "config.csv"
    if not config_path.exists():
        logger.warning("Config.csv not found in %s", run_dir)
        return None

    design_wh = None
    try:
        with open(config_path, "r", encoding="utf-8-sig") as f:
            for row in csv.reader(f):
                if len(row) >= 2 and row[0].strip() == "Battery Total Designed Capacity (Wh)":
                    try:
                        design_wh = float(row[1].strip())
                    except ValueError:
                        logger.warning("Invalid Battery Total Designed Capacity (Wh) value: %s", row[1])
                    break
    except OSError as e:
        logger.error("Failed to read %s: %s", config_path, e)
        return None

    if design_wh is None:
        logger.warning("Battery Total Designed Capacity (Wh) row not found in %s", config_path)
        return None
    if design_wh <= 0:
        logger.warning("Non-positive battery capacity %s Wh; battery_life not computed", design_wh)
        return None

    battery_life_hr = design_wh / system_power_w
    logger.info("Battery life: %.3f hr (design_capacity=%.3f Wh, system_power=%.3f W)",
                battery_life_hr, design_wh, system_power_w)
    return battery_life_hr


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
