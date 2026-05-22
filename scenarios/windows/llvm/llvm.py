# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# LLVM Build Workload
##

import logging
import os
import scenarios.app_scenario
from parameters import Params
from datetime import datetime

class Llvm(scenarios.app_scenario.Scenario):

    module = __module__.split('.')[-1]
    prep_version = "9"
    resources = module + "_resources"


    # Set default parameters
    Params.setDefault(module, 'loops', '1')


    def setUp(self):
        # Get parameters
        self.platform = Params.get('global', 'platform')
        self.loops = Params.get(self.module, 'loops')

        self.target = f"{self.dut_exec_path}\\{self.resources}"

        # Test if already set up
        if self.checkPrepStatus([self.module + self.prep_version]):
            logging.info("Preparing for first use.")

            # Copy over resources to DUT
            logging.info(f"Uploading test files to {self.target}")
            self._upload(f"scenarios\\windows\\{self.module}\\{self.resources}", self.dut_exec_path)

            # Execute prep script
            logging.info("Executing prep, this may take 30-60 minutes...")
            try:
                self._call(["pwsh", f"{self.target}\\{self.module}_prep.ps1"])
            finally:
                self._copy_data_from_remote(self.result_dir)
            self.createPrepStatusControlFile(self.prep_version)

        # Call base class setUp() to dump config, call tool callbacks, and start measurement
        scenarios.app_scenario.Scenario.setUp(self)


    def runTest(self):
        start_time = datetime.now().astimezone().isoformat()
        for i in range(int(self.loops)):
            logging.info(f"Running loop {i + 1}")
            # Disable fail_on_exception because ninja build output includes LLVM source
            # filenames containing "Exception" (e.g., exception handling code), which
            # triggers a false positive in _call's output scanning.
            self._call(["pwsh", f"{self.target}\\{self.module}_run.ps1 -startTime {start_time}"], fail_on_exception=False)


    def tearDown(self):
        logging.info("Performing teardown.")
        # Call base class tearDown() to stop measurement, copy back data from DUT, and call tool callbacks
        scenarios.app_scenario.Scenario.tearDown(self)


    def kill(self):
        try:
            logging.debug("Killing powershell shell")
            self._kill("pwsh.exe")
        except:
            pass
