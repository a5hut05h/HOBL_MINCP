# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# MLPerf Client Workload
##

import logging
import os
import core.app_scenario
from core.parameters import Params
import time

class MacMlperf(core.app_scenario.Scenario):

    module = __module__.split('.')[-1]
    prep_version = "6"
    resources = module + "_resources"


    # Set default parameters
    Params.setDefault(module, 'loops', '1')
    Params.setDefault(module, 'config_file', 'macOS_MLX_GPU.json')


    def setUp(self):
        # Get parameters
        self.platform = Params.get('global', 'platform')
        self.loops = Params.get(self.module, 'loops')
        self.config_file = Params.get(self.module, 'config_file')

        self.artifact_name = 'mlperf-mac'
        self.mlperf_client_package = 'mlperf-client-offline-macOS.zip'
        self.mlperf_client_zip_path = f'{self.dut_exec_path}/mac_mlperf/{self.mlperf_client_package}'
        self.mlperf_client_path = f'{self.dut_exec_path}/mac_mlperf/phi3.5'

        self.target = f"{self.dut_exec_path}/{self.resources}"

        # Test if already set up
        if self.checkPrepStatus([self.module + self.prep_version]):
            logging.info("Preparing for first use.")

            # Download offline package
            logging.info("Downloading offline package to Host.")
            self._check_and_download(f"{self.artifact_name}", path = f"scenarios\\macos\\{self.module}")
            logging.info("Uploading offline package to DUT.")
            self._upload(f"scenarios\\macos\\{self.module}\\{self.artifact_name}\\{self.mlperf_client_package}", f"{self.dut_exec_path}/{self.module}")

            # Create SUDO_ASKPASS helper script to automate sudo password entry
            self._call(["zsh", f"-c \"echo '#!/bin/sh\necho {self.password}' > {self.dut_exec_path}/get_password.sh\""])
            self._call(["zsh", f"-c \"chmod 700 {self.dut_exec_path}/get_password.sh\""])

            # Copy over resources to DUT
            logging.info(f"Uploading test files to {self.target}")
            self._upload(f"scenarios\\MacOS\\{self.module}\\{self.resources}", self.dut_exec_path)

            # Execute prep script with mlperf_client_path argument
            logging.info("Executing prep...")
            arg = ''
            if self.mlperf_client_zip_path != '':
                arg = f"{self.mlperf_client_zip_path}"
            try:
                self._call(["zsh", f"{self.target}/{self.module}_prep.sh {arg}"], fail_on_exception=False)
            finally:
                self._copy_data_from_remote(self.result_dir)
            self.createPrepStatusControlFile(self.prep_version)

        # Call base class setUp() to dump config, call tool callbacks, and start measurement
        core.app_scenario.Scenario.setUp(self)


    def runTest(self):
        for i in range(int(self.loops)):
            logging.info(f"Running loop {i + 1}")
            self._call(["zsh", f"{self.target}/{self.module}_run.sh {self.mlperf_client_path}/{self.config_file}"], timeout=7200)


    def tearDown(self):
        logging.info("Performing teardown.")
        # Call base class tearDown() to stop measurement, copy back data from DUT, and call tool callbacks
        core.app_scenario.Scenario.tearDown(self)


    def kill(self):
        return
        try:
            logging.debug("Killing mlperf-mac")
            # self._kill("mlperf-mac")
        except:
            pass
