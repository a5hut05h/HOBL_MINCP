"""
//--------------------------------------------------------------
//
// HOBL
// Copyright(c) Microsoft Corporation
// All rights reserved.
//
// MIT License
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files(the ""Software""),
// to deal in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell copies
// of the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED *AS IS*, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
// INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE AUTHORS
// OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF
// OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
//--------------------------------------------------------------
"""

##
# Run Full Version of Blender to support more scenes
##

import csv
import os
import logging
import core.app_scenario
from core.parameters import Params

class Blender(core.app_scenario.Scenario):

    module = __module__.split('.')[-1]
    prep_version = "1"

    # Set default parameters
    Params.setDefault('blender', 'device_type', 'CPU', desc='Specify the device type for rendering.', valOptions=['CPU', 'CUDA', 'OPTIX', 'IGPU'])
    Params.setDefault('blender', 'add_cpu', '0', desc='Specify whether to add CPU rendering alongside the selected device.', valOptions=['0', '1'])
    Params.setDefault('blender', 'scene', 'lone-monk.blend', desc='Name of blender file to render. If downloaded manually, place it in the blender_resources directory.')

    # Get parameters
    device_type = Params.get('blender', 'device_type')
    add_cpu = Params.get('blender', 'add_cpu')
    scene = Params.get('blender', 'scene')

    prep_run_only = Params.get('global', 'prep_run_only') == "1"

    def setUp(self):
        self.prep()

        # Call base class setUp() to dump config, call tool callbacks, and start measurment
        core.app_scenario.Scenario.setUp(self)


    def prep(self):
        if not self.checkPrepStatusNew([(self.module, self.prep_version)]):
            return

        logging.info("Preparing for first use")

        # attempt to download and install pugetbench. 
        logging.info("blender not found. Downloading and installing.")
        self._call(["powershell.exe", "wget \\\"https://mirrors.ocf.berkeley.edu/blender/release/Blender5.2/blender-5.2.0-windows-x64.msi\\\" -outfile " + self.dut_exec_path + "\\blender.msi"])
    
        logging.info("Installing blender...")
        self._call(["cmd.exe", "/C start /wait " + self.dut_exec_path + "\\blender.msi" + "  /passive /norestart"], expected_exit_code="")

        # create blender_resources directory in scenario.dut_exec_path
        logging.info("Making blender_resources directory for scenes")
        self._call(["cmd.exe", "/C mkdir " + self.dut_exec_path + "\\blender_resources"], expected_exit_code="")
    
        logging.info("Downloading lone monk blend file")
        self._call(["powershell.exe", "wget \\\"https://download.blender.org/demo/cycles/lone-monk_cycles_and_exposure-node_demo.blend\\\" -outfile " + self.dut_exec_path + "\\blender_resources\\lone-monk.blend"])

        try:
            # Delete blender.msi
            self._call(["cmd.exe", "/C del " + self.dut_exec_path + "\\blender.msi"])
        except:
            pass
        

        self.createPrepStatusControlFile(self.prep_version)


    def runTest(self):
        if self.device_type == "IGPU": # Override using integrated GPU with ONEAPI as thats whats used for blender.
            self.device_type = "ONEAPI" 

        if self.device_type != "CPU" and self.add_cpu == "1":
            self.device_type += "+CPU"
        logging.info(f"Using device type: {self.device_type}")
        logging.info(f"Rendering scene: {self.scene}")

        if self.device_type == "CPU":
            timeout_time = 9000 # 2.5 hours for rendering if using CPU
        else:
            timeout_time = 3600 # 1 hour for rendering if not using CPU

        # Call Blender with the downloaded blend file.
        logging.info("Rendering blender scene")
        blender_command = (
            "$blenderExe = Join-Path $env:ProgramFiles 'Blender Foundation\\Blender 5.2\\blender.exe'; "
            f"& $blenderExe -b \"" + self.dut_exec_path + f"\\blender_resources\\{self.scene}\" "
            f"-f 4 -- --cycles-device {self.device_type} --cycles-print-stats *>&1 | Out-File -FilePath 'C:\\hobl_data\\blender_log.txt' -Encoding utf8"
        )
        self._call(["powershell.exe", blender_command], timeout=timeout_time, expected_exit_code="")


    def tearDown(self):
        if self.prep_run_only:
            return

        self._copy_data_from_remote(self.result_dir, self.dut_data_path + "\\blender_log.txt", single_file=True)
        self.report_render_time()

        # Call base class tearDown() to stop measurment, copy back data from DUT, and call tool callbacks
        core.app_scenario.Scenario.tearDown(self)

    def report_render_time(self):
        # Parse the blender render time. 
        blender_log = os.path.join(self.result_dir, "blender_log.txt")
        if not os.path.exists(blender_log):
            logging.error(f"Blender output not found at {blender_log}; render time unavailable.")
            self.fail(f"Blender output not found at {blender_log}; render time unavailable.")
            return

        finished_line = None
        # Out-File -Encoding utf8 adds a BOM on PS 5.1 but not PS 7+; utf-8-sig handles both.
        with open(blender_log, "r", encoding="utf-8-sig", errors="ignore") as f:
            for line in f:
                if "Finished" in line:
                    finished_line = line

        if not finished_line or not finished_line.strip():
            logging.error("Could not find 'Finished' line in Blender output; render time unavailable.")
            self.fail("Could not find 'Finished' line in Blender output; render time unavailable.  Check blender_log.txt to see details")
            return

        render_time = finished_line.strip().split()[0]
        logging.info(f"Blender render time: {render_time}")

        csv_path = os.path.join(self.result_dir, "blender_render_time.csv")
        with open(csv_path, "w", encoding="utf-8", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["scenario_runtime", render_time])


    def kill(self):
        try:
            self._kill("blender.exe")
        except:
            pass
        try:
            self._kill("powershell.exe")
        except:
            pass