# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# Ollama building Workload
##

import logging
import os
import core.app_scenario
from core.parameters import Params
from datetime import datetime

class Ollama(core.app_scenario.Scenario):

    module = __module__.split('.')[-1]
    prep_version = "7"
    resources = module + "_resources"


    # Set default parameters
    Params.setDefault(module, 'loops', '1')
    Params.setDefault(module, 'use_custom_ollama', 'false', valOptions=["true", "false"])
    Params.setDefault(module, 'custom_resources_path', '')


    def setUp(self):
        # Get parameters
        self.platform = Params.get('global', 'platform')
        self.loops = Params.get(self.module, 'loops')
        self.use_custom_ollama = Params.get(self.module, 'use_custom_ollama').lower() == 'true'
        self.custom_resources_path = Params.get(self.module, 'custom_resources_path')

        self.target = f"{self.dut_exec_path}\\{self.resources}"

        # Test if already set up
        if self.checkPrepStatus([self.module + self.prep_version]):
            logging.info("Preparing for first use.")

            # Copy over resources to DUT
            logging.info(f"Uploading test files to {self.target}")
            self._upload(f"scenarios\\windows\\{self.module}\\{self.resources}", self.dut_exec_path)

            # Upload custom resources (ollama zip) to the DUT
            if self.custom_resources_path:
                if not os.path.isdir(self.custom_resources_path):
                    logging.error(f"Custom resources path not found: {self.custom_resources_path}")
                    raise FileNotFoundError(f"Custom resources path not found: {self.custom_resources_path}")
                logging.info(f"Uploading custom resources from {self.custom_resources_path} to {self.dut_exec_path}")
                self._upload(self.custom_resources_path, self.dut_exec_path)
                folder_name = os.path.basename(self.custom_resources_path)
                self.custom_resources_dut_path = f"{self.dut_exec_path}\\{folder_name}"
            else:
                self.custom_resources_dut_path = ""

            # Validate combinations on host before invoking prep on the DUT
            if self.use_custom_ollama and not self.custom_resources_dut_path:
                raise ValueError("use_custom_ollama=true requires custom_resources_path to point to a folder containing the ollama-windows-*.zip")

            # Excute prep script
            logging.info("Executing prep, this make take 10-15 minutes...")
            prep_cmd = f"{self.target}\\{self.module}_prep.ps1"
            if self.custom_resources_dut_path:
                prep_cmd += f' -customResourcesPath "{self.custom_resources_dut_path}"'
            if self.use_custom_ollama:
                prep_cmd += " -useCustomOllama"
            try:
                self._call(["pwsh", prep_cmd], timeout=3600)
            finally:
                self._copy_data_from_remote(self.result_dir)
            self.createPrepStatusControlFile(self.prep_version)

        # Start server in background
        logging.info("Starting server")
        try:
            self._call(["pwsh", f"{self.target}\\{self.module}_setup.ps1"], timeout=7200)
        finally:
            self._copy_data_from_remote(self.result_dir)

        # Call base class setUp() to dump config, call tool callbacks, and start measurment
        core.app_scenario.Scenario.setUp(self)


    def runTest(self):
        start_time = datetime.now().astimezone().isoformat()
        for i in range(int(self.loops)):
            logging.info(f"Running loop {i + 1}")
            self._call(["pwsh", f"{self.target}\\{self.module}_run.ps1 -startTime {start_time}"])


    def tearDown(self):
        logging.info("Performing teardown.")
        # Call base class tearDown() to stop measurment, copy back data from DUT, and call tool callbacks
        core.app_scenario.Scenario.tearDown(self)

        logging.info("Executing teardown script.")
        self._call(["pwsh", f"{self.target}\\{self.module}_teardown.ps1"])


    def kill(self):
        try:
            logging.debug("Killing powershell, go, and ollama")
            self._kill("pwsh.exe")
            self._kill("go.exe")
            self._kill("ollama.exe")
        except:
            pass

