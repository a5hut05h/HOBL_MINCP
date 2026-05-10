# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import core.app_scenario
from core.parameters import Params
import logging
import os
from . import default_params

# Description:
#   Automatically generated standard scenario.

class TeamsProcyon(core.app_scenario.Scenario):
    module = __module__.split('.')[-1]

    prep_scenarios = ["teams_install", "office_install"]

    # Set default parameters:
    default_params.run()

    actions = None

    def setUp(self):
        # Load actions JSON.
        actions_json = os.path.join(os.path.dirname(__file__), "teams_procyon.json")
        self.actions = self.load_action_json(actions_json)

        # Execute Setup actions, if they exist
        setup_action = self._find_next_type("Setup", json=self.actions)
        if setup_action is not None:
            self.run_actions(setup_action["children"])

        # Call base class setUp() to dump config, call tool callbacks, and start measurment
        core.app_scenario.Scenario.setUp(self)


    def prep(self):
        # if not self.checkPrepStatusNew([(self.module, self.prep_version)]):
        #     return

        logging.info("Preparing for first use.")
        self.target = f"{self.dut_exec_path}\\Procyon"

        logging.info(f"Uploading Procyon files to {self.dut_exec_path}")
        self._upload(self.resolve(f"scenarios\\windows\\{self.module}\\Procyon"), self.dut_exec_path)

        cmd = ("-ExecutionPolicy Bypass" f" -File {self.target}\\x86_Procyon_Setup.ps1")

        self._call(["powershell.exe", cmd], log_output=False, fail_on_exception=False, expected_exit_code="")

        self.createPrepStatusControlFile()


    def runTest(self):
        # Execute Run Test actions, if they exist
        runtest_action = self._find_next_type("Run Test", json=self.actions)
        if runtest_action is not None:
            self.run_actions(runtest_action["children"])
            return

        # If no "Run Test", "Setup", or "Teardown" specified, then just execute the whole list
        setup_action = self._find_next_type("Setup", json=self.actions)
        teardown_action = self._find_next_type("Teardown", json=self.actions)
        if runtest_action is None and setup_action is None and teardown_action is None:
            self.run_actions(self.actions)


    def tearDown(self):
        # Call base class tearDown() to stop measurment, copy back data from DUT, and call tool callbacks
        core.app_scenario.Scenario.tearDown(self)

        # Execute Teardown actions, if they exist
        teardown_action = self._find_next_type("Teardown", json=self.actions)
        if teardown_action is not None:
            self.run_actions(teardown_action["children"])


    def kill(self):
        self._call([
            "powershell.exe",
            f"Get-CimInstance Win32_Process | Where-Object {{ $_.CommandLine -like '*Procyon*' }} | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }}"
        ], expected_exit_code="")
