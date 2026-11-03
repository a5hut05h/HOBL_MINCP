"""Run from the repo root: python -m unittest utilities.extractor.test_power_calculate"""

import unittest

from utilities.extractor.power_calculate import calculate_power_metrics


def _calc(rails: dict, **kwargs) -> dict:
    metrics = [{"name": n, "value": v, "unit": "W"} for n, v in rails.items()]
    return {m["name"]: m["value"] for m in calculate_power_metrics(metrics, **kwargs)}


class HeraclesTests(unittest.TestCase):
    RAILS = {
        "pm_emi_vsys_core": 10.0,
        "pm_emi_vsys_rop": 1.5,
        "pm_emi_memory_vddq": 0.5,
        "pm_emi_memory_vdd2h": 1.5,
        "pm_emi_3p3v_panel_in": 0.4,
        "pm_emi_bklt_in": 0.6,
    }

    def test_recognised_by_device_name_with_blank_dut_type(self):
        out = _calc(self.RAILS, device_name="QC-HES-ROT-11")
        self.assertAlmostEqual(out["memory_power"], 2.0)
        self.assertAlmostEqual(out["display_power"], 1.0)
        self.assertAlmostEqual(out["soc_power"], 7.4)
        self.assertAlmostEqual(out["system_power"], 11.5)

    def test_device_name_overrides_conflicting_dut_type(self):
        rails = dict(self.RAILS, pm_emi_3p3v_ssd=0.3, pm_emi_3p86v_wifi=0.2)
        out = _calc(rails, dut_type="Pantherlake/LunarLake surface", device_name="QC-SUR-HES-ROT-11")
        self.assertAlmostEqual(out["storage_power"], 0.3)
        self.assertAlmostEqual(out["wifi_bt_power"], 0.2)
        self.assertAlmostEqual(out["rop_power"], 1.5)
        self.assertAlmostEqual(out["display_light_power"], 0.6)

    def test_system_needs_both_vsys_rails(self):
        rails = {k: v for k, v in self.RAILS.items() if k != "pm_emi_vsys_rop"}
        out = _calc(rails, dut_type="Heracles")
        self.assertNotIn("system_power", out)
        self.assertAlmostEqual(out["soc_power"], 7.4)


class MinosTests(unittest.TestCase):
    def test_builds_minos_calculations(self):
        rails = {
            "pm_emi_sys": 20.0,
            "PMIC_MT6363": 1.0, "PMIC_MT6373": 2.0, "CPU_P": 3.0, "CPU_E": 4.0,
            "pm_emi_gpu_misc": 5.0, "pm_emi_gpu_compute": 6.0,
            "pm_emi_cpu_core": 7.0, "pm_emi_npu": 8.0,
            "pm_emi_memory_0": 1.1, "pm_emi_memory_1": 1.2,
            "pm_emi_display_panel": 0.4, "pm_emi_display_backlight": 0.6,
            "pm_emi_camera_0": 0.5, "pm_emi_sam_0": 0.8,
        }
        out = _calc(rails, device_name="NV-DIO-MIN-09")
        self.assertEqual(out["system_power"], 20.0)
        self.assertAlmostEqual(out["soc_power"], 30.6)
        self.assertAlmostEqual(out["memory_power"], 2.3)
        self.assertAlmostEqual(out["display_power"], 1.0)
        self.assertAlmostEqual(out["camera_power"], 0.5)
        self.assertAlmostEqual(out["sam_power"], 0.8)

    def test_soc_needs_all_eight_rails(self):
        out = _calc({"pm_emi_sys": 20.0, "PMIC_MT6363": 1.0}, device_name="minos")
        self.assertEqual(out["system_power"], 20.0)
        self.assertNotIn("soc_power", out)


class PurwaTests(unittest.TestCase):
    RAILS = {
        "pm_emi_sys": 10.0,
        "pm_emi_sys_1a": 3.0, "pm_emi_sys_1b": 2.0,
        "pm_emi_lpddr_vdd2h_1p08v": 0.5, "pm_emi_lpddr_vdd2l_0p9v": 0.2,
        "pm_emi_display_bklt": 0.6, "pm_emi_display_panel_3p3v": 0.4,
        "pm_emi_storage": 0.3, "pm_emi_wifi_3p3v_wlan": 0.2,
        "pm_emi_npu": 0.1, "pm_emi_audio_5v": 0.05, "pm_emi_trackpad_3p3v": 0.05,
    }

    def test_rop_is_system_minus_components(self):
        out = _calc(self.RAILS, device_name="QC-LAM-PURWA-01")
        self.assertAlmostEqual(out["display_power"], 1.0)
        # soc 3.84 + npu 0.1 + memory 0.7 + storage 0.3 + wifi 0.2 + display 1.0
        # + audio 0.05 + trackpad 0.05 (once, not again as touch_power)
        self.assertAlmostEqual(out["rop_power"], 10.0 - 6.24, places=5)

    def test_rop_left_alone_when_a_component_is_missing(self):
        rails = {k: v for k, v in self.RAILS.items() if k != "pm_emi_npu"}
        rails.update(pm_emi_sys_rop_left=0.7, pm_emi_sys_rop_right=0.3)
        out = _calc(rails, device_name="QC-LAM-PURWA-01")
        self.assertAlmostEqual(out["rop_power"], 1.0)


class OtherDevicesTests(unittest.TestCase):
    def test_non_family_devices_unchanged(self):
        out = _calc({"pm_emi_system": 9.0, "pm_emi_vsys_core": 10.0, "pm_emi_vsys_rop": 1.5},
                    dut_type="Pantherlake/LunarLake surface", device_name="ITL-PTL-MAA-07")
        self.assertEqual(out["system_power"], 9.0)


if __name__ == "__main__":
    unittest.main()
