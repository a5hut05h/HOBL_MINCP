# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# PyTorch Inferencing Workload
##

import logging
import os
import core.app_scenario
from core.parameters import Params
from datetime import datetime

class PytorchInf(core.app_scenario.Scenario):

    module = __module__.split('.')[-1]
    prep_version = "13"
    # prep_scenarios = [(module, prep_version)]
    resources = module + "_resources"


    # Set default parameters
    Params.setDefault(module, 'loops', '2')
    Params.setDefault(module, 'use_custom_pytorch_wheel', 'false')
    Params.setDefault(module, 'install_cuda', 'false')
    Params.setDefault(module, 'install_cudnn', 'false')
    Params.setDefault(module, 'custom_resources_path', '')
    Params.setDefault(module, 'use_gpu', 'true')


    def setUp(self):
        # Get parameters
        self.platform = Params.get('global', 'platform')
        self.loops = Params.get(self.module, 'loops')
        self.use_custom_pytorch_wheel = Params.get(self.module, 'use_custom_pytorch_wheel').lower() == 'true'
        self.install_cuda = Params.get(self.module, 'install_cuda').lower() == 'true'
        self.install_cudnn = Params.get(self.module, 'install_cudnn').lower() == 'true'
        self.custom_resources_path = Params.get(self.module, 'custom_resources_path')
        self.use_gpu = Params.get(self.module, 'use_gpu').lower() == 'true'

        self.target = f"{self.dut_exec_path}\\{self.resources}"

        self.prep()

        # Call base class setUp() to dump config, call tool callbacks, and start measurment
        core.app_scenario.Scenario.setUp(self)


    def prep(self):
        # Test if already set up
        if not self.checkPrepStatusNew([(self.module, self.prep_version)]):
            return

        logging.info("Preparing for first use.")

        # Copy over resources to DUT
        logging.info(f"Uploading test files to {self.target}")
        self._upload(f"scenarios\\windows\\{self.module}\\{self.resources}", self.dut_exec_path)

        # Upload custom resources (wheels, installers) to the DUT
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

        # Excute prep script
        logging.info("Executing prep, this make take 10-15 minutes...")
        if self.platform.lower() == "macos":
            try:
                self._call(["zsh", f"{self.target}/{self.module}_prep.sh"])
            finally:
                self._copy_data_from_remote(self.result_dir)
        else:
            prep_cmd = f"{self.target}\\{self.module}_prep.ps1"
            if self.custom_resources_dut_path:
                prep_cmd += f' -customResourcesPath "{self.custom_resources_dut_path}"'
            if self.use_custom_pytorch_wheel:
                prep_cmd += " -useCustomPyTorchWheel"
            if self.install_cuda:
                prep_cmd += " -installCuda"
            if self.install_cudnn:
                prep_cmd += " -installCudnn"
            try:
                self._call(["pwsh", prep_cmd])
            finally:
                self._copy_data_from_remote(self.result_dir)
        self.createPrepStatusControlFile(self.prep_version)


    def runTest(self):
        start_time = datetime.now().astimezone().isoformat()
        for i in range(int(self.loops)):
            logging.info(f"Running loop {i + 1}")
            run_cmd = f"{self.target}\\{self.module}_run.ps1 -startTime {start_time}"
            if not self.use_gpu:
                run_cmd += " -noGpu"
            self._call(["pwsh", run_cmd])

            # TODO: Do we need to call teardown script between each loop to clear cache?


    def tearDown(self):
        logging.info("Performing teardown.")
        # Call base class tearDown() to stop measurment, copy back data from DUT, and call tool callbacks
        core.app_scenario.Scenario.tearDown(self)

        logging.info("Executing teardown script.")
        self._call(["pwsh", f"{self.target}\\{self.module}_teardown.ps1"])


    def kill(self):
        try:
            logging.debug("Killing python process")
            self._kill("python.exe")
        except:
            pass

