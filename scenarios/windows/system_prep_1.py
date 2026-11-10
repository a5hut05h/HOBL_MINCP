# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import os

from core.parameters import Params
from scenarios.windows.system_prep import SystemPrep


class SystemPrep1(SystemPrep):
    """Runs system prep after uploading a selected wallpaper to the DUT."""

    module = __module__.split('.')[-1]
    Params.setDefault(module, "hibernate_enabled", "1", desc="Enables or disables hibernation on the device", valOptions=["0", "1"])
    Params.setDefault(module, "telemetry_enabled", "0", desc="Enables or disables the gathering of optional diagnostic data in the OS", valOptions=["0", "1"])
    Params.setDefault(module, "theme", "current", desc="Change the Windows theme", valOptions=["current", "light", "dark"])
    Params.setDefault(module, "wallpaper", "LabWallpaper.png", desc="Uploads and applies an image from utilities\\open_source\\DesktopImages")
    Params.setDefault(module, "final_reboot", "1", desc="Sets if the device will reboot at the conclusion of daily_prep", valOptions=["0", "1"])
    Params.setDefault(module, "bpm_pcc_blm_disable", "0", desc="Disable BPM, PCC, and BLM", valOptions=["0", "1"])

    def runTest(self):
        wallpaper = Params.get(self.module, "wallpaper")
        if not wallpaper or wallpaper != os.path.basename(wallpaper):
            raise ValueError("Wallpaper must be a file name from utilities\\open_source\\DesktopImages: " + wallpaper)

        wallpaper_source = os.path.join("utilities", "open_source", "DesktopImages", wallpaper)
        if not os.path.isfile(wallpaper_source):
            raise FileNotFoundError("Wallpaper image not found: " + wallpaper_source)

        wallpaper_destination = os.path.join(self.dut_exec_path, "DesktopImages")
        self._remote_make_dir(wallpaper_destination)
        self._upload(wallpaper_source, wallpaper_destination)

        super().runTest()
