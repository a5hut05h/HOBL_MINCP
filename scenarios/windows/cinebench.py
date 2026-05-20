# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import os
import time
from core.parameters import Params
import core.app_scenario

class Cinebench(core.app_scenario.Scenario):
    """
    The Cinebench benchmark.
    """
    module = __module__.split('.')[-1]

    Params.setDefault(module, 'duration', '60', desc="Minimum run time in seconds")
    Params.setDefault(module, 'workload', 'multi_core', desc="Workload type: single_core or multi_core", valOptions=["single_core", "multi_core"])
    prep_version = "1"

    def setUp(self):    
        self.duration = int(Params.get(self.module, 'duration'))
        self.workload = Params.get(self.module, 'workload')
        self.dut_arch = Params.get('global', 'dut_architecture')

        self.package_name = f"cinebench-2024-{self.dut_arch}"
        self.cinebench_path = f"c:\\{self.package_name}\\cb_2024.exe"
        self.out_filename = "cinebench_output.txt"

        host_path = f"scenarios\\cinebench_resources\\{self.package_name}"
        # Test if already set up
        if self.checkPrepStatus([self.module + self.prep_version]):
            self._check_and_download(f"{self.package_name}", path = "scenarios\\cinebench_resources")
            # Rename local cinebench.exe on host to avoid benchmark blocker
            if not os.path.exists(f"{host_path}\\cb_2024.exe"):
                os.rename(f"{host_path}\\cinebench.exe", f"{host_path}\\cb_2024.exe")
            self._upload(f"{host_path}", "c:\\")
            self.createPrepStatusControlFile(self.prep_version)

        super().setUp()


    def runTest(self):
        if self.workload == 'single_core':
            workload_arg = 'g_CinebenchCpu1Test=true'
        else:
            workload_arg = 'g_CinebenchCpuXTest=true'
        logging.info("Cinebench started.")
        self._call(["cmd.exe", f'/c start /B /wait "parent" {self.cinebench_path} {workload_arg} g_CinebenchMinimumTestDuration={self.duration} > {self.dut_data_path}\\{self.out_filename}"'], timeout=self.duration + 2700)
        logging.info("Cinebench completed.")


    def tearDown(self):
        logging.info("Tearing down Cinebench scenario.")
        # Download output file
        self._copy_data_from_remote(dest = self.result_dir, source = self.dut_data_path + '\\' + self.out_filename, single_file=True)

        # Extract score from output file
        output_file = os.path.join(self.result_dir, self.out_filename)
        logging.info(f"Extracting score from {output_file}")
        with open(output_file, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip().startswith("CB "):
                    parts = line.split()
                    if len(parts) >= 2:
                        try:
                            score = float(parts[1])
                        except ValueError:
                            logging.error(f"Failed to convert score to float: {parts[1]}")

        # Write score to cinebench.csv
        with open(self.result_dir + '\\cinebench.csv', 'w') as out:
            out.write(f"Cinebench Score,{score}\n")

        super().tearDown()
        logging.info(f"Cinebench score: {score}")
