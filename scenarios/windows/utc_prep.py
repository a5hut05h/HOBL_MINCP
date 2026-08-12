# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from builtins import *
import logging
import core.app_scenario
import time
from core.parameters import Params


class UtcPrep(core.app_scenario.Scenario):
    module = __module__.split('.')[-1]

    Params.setDefault(module, 'enable', '1')
    enable = Params.get(module, 'enable')

    def runTest(self):
        sideload_dir = "C:\\ProgramData\\Microsoft\\Diagnosis\\Sideload"

        # C:\hobl\HOBL_MINCP\utilities\proprietary\ParseUtc\ConsumerMultitaskerPTs.xml
        # C:\Users\aadityaaren\Downloads\downloadedFile_allnew.xml
        if self.enable == '1':
            self._upload("utilities\\proprietary\\ParseUtc\\ConsumerMultitaskerPTs.xml", sideload_dir)
            self._call(["cmd.exe", f'/C copy /Y "{sideload_dir}\\ConsumerMultitaskerPTs.xml" "{sideload_dir}\\UtcPerftrack.xml"'])
            self._upload("utilities\\proprietary\\ParseUtc\\DisableAllUploads.json", sideload_dir)
            self._call(["cmd.exe", '/C reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection" /v AllowTelemetry /t REG_DWORD /d 3 /f > null 2>&1'])
            self._call(["cmd.exe", '/C reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\Windows Error Reporting" /v DisableWerUpload /t REG_DWORD /d 1 /f > null 2>&1'])
        else:
            self._call(["cmd.exe", '/C reg delete "HKLM\\SOFTWARE\\Microsoft\\Windows\\Windows Error Reporting" /v DisableWerUpload /f > null 2>&1'])
            self._call(["cmd.exe", '/C reg add "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection" /v AllowTelemetry /t REG_DWORD /d 1 /f > null 2>&1'])
            self._call(["cmd.exe", f'/C del /f "{sideload_dir}\\UtcPerftrack.xml"'])
            self._call(["cmd.exe", f'/C del /f "{sideload_dir}\\DisableAllUploads.json"'])

        rebootDut(self)

def rebootDut(self):
    logging.info("Rebooting DUT")
    try:
        self._call(["cmd.exe",  "/C shutdown.exe /r /f /t 5"])
    except:
        pass
    time.sleep(20)
    self._wait_for_dut_comm()
    logging.info("Reboot complete")
    return