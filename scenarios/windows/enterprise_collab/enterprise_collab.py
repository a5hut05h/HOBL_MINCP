# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import core.app_scenario
from core.parameters import Params
import logging
import os
import time
from . import default_params

# Description:
#   Automatically generated standard scenario.

class EnterpriseCollab(core.app_scenario.Scenario):

    prep_scenarios = ["edge_install", "web_prep", "teams_install", "office_install", "onedrive_prep", "productivity_prep"]
    rolling_wpr_param_section = None

    # Set default parameters:
    default_params.run()

    module = __module__.split('.')[-1]

    if Params.get(module, "perf_run") == "1":
        logging.info("Adding perf_utc tool for parsing perf metrics")
        Params.setParam("global", "tools", "+perf_utc")

    actions = None

    def setUp(self):
        # Load actions JSON.
        actions_json = os.path.join(os.path.dirname(__file__), "enterprise_collab.json")
        self.actions = self.load_action_json(actions_json)

        # Execute Setup actions, if they exist
        setup_action = self._find_next_type("Setup", json=self.actions)
        if setup_action is not None:
            self.run_actions(setup_action["children"])

        # Call base class setUp() to dump config, call tool callbacks, and start measurment
        core.app_scenario.Scenario.setUp(self)

        self._start_rolling_wpr_capture()


    def _rolling_wpr_settings(self):
        section = self.rolling_wpr_param_section
        return (
            Params.get(section, "bg_heavy_capture"),
            Params.get(section, "bg_heavy_capture_provider"),
            Params.get(section, "bg_heavy_capture_interval"),
        )


    def _start_rolling_wpr_capture(self):
        self._rolling_wpr_started = False
        self._rolling_wpr_output = None
        if self.rolling_wpr_param_section is None:
            return

        enabled, provider, interval_value = self._rolling_wpr_settings()
        if enabled != "1":
            return

        try:
            interval_minutes = int(interval_value)
        except (TypeError, ValueError):
            self.fail(f"Rolling WPR interval must be an integer, got: {interval_value}")
            return
        if not 1 <= interval_minutes <= 1440:
            self.fail(f"Rolling WPR interval must be between 1 and 1440 minutes, got: {interval_minutes}")
            return

        if not provider or os.path.basename(provider) != provider or not provider.lower().endswith(".wprp"):
            self.fail(f"Invalid rolling WPR provider name: {provider}")
            return

        source_dir = os.path.dirname(__file__)
        provider_source = self.resolve(os.path.join("providers", provider))
        if not os.path.isfile(provider_source):
            self.fail(f"Rolling WPR provider not found: {provider_source}")
            return

        capture_source = os.path.join(source_dir, "rolling_wpr_capture.ps1")
        stop_source = os.path.join(source_dir, "stop_rolling_wpr.ps1")
        self._upload(provider_source, self.dut_exec_path)
        self._upload(capture_source, self.dut_exec_path)
        self._upload(stop_source, self.dut_exec_path)

        section = self.rolling_wpr_param_section
        instance_name = {
            "consumer_multitasker": "consumerMultitaskerHeavy",
            "enterprise_collab": "enterpriseCollabHeavy",
        }[section]
        output_dir = os.path.join(self.dut_exec_path, f"{section}_heavy")
        capture_script = os.path.join(self.dut_exec_path, "rolling_wpr_capture.ps1")
        provider_path = os.path.join(self.dut_exec_path, provider)

        logging.info(
            f"Starting rolling WPR capture: provider={provider}, interval={interval_minutes}m, "
            f"instance={instance_name}. The additional WPR session can perturb performance results."
        )
        self._call([
            "cmd.exe",
            f'/C start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File '
            f'"{capture_script}" -WprpPath "{provider_path}" -OutputDir "{output_dir}" '
            f'-RunName "{self.testname}" -InstanceName "{instance_name}" '
            f'-IntervalMinutes {interval_minutes}',
        ], expected_exit_code="", blocking=False)

        self._rolling_wpr_started = True
        self._rolling_wpr_instance = instance_name
        self._rolling_wpr_output = os.path.join(output_dir, self.testname)


    def _stop_rolling_wpr_capture(self):
        if not getattr(self, "_rolling_wpr_started", False):
            return

        stop_script = os.path.join(self.dut_exec_path, "stop_rolling_wpr.ps1")
        try:
            self._call([
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", stop_script,
                "-InstanceName", self._rolling_wpr_instance,
                "-RunName", self.testname,
            ], expected_exit_code="")
        except Exception as ex:
            logging.warning(f"Failed to stop rolling WPR capture: {ex}")
        finally:
            self._rolling_wpr_started = False


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
        self._stop_rolling_wpr_capture()

        # Call base class tearDown() to stop measurment, copy back data from DUT, and call tool callbacks
        core.app_scenario.Scenario.tearDown(self)

        rolling_output = getattr(self, "_rolling_wpr_output", None)
        if rolling_output:
            try:
                if self._check_remote_file_exists(rolling_output, in_exec_path=False):
                    self._copy_data_from_remote(self.result_dir, source=rolling_output)
            except Exception as ex:
                logging.warning(f"Best-effort rolling WPR capture pull failed: {ex}")

        # Execute Teardown actions, if they exist
        teardown_action = self._find_next_type("Teardown", json=self.actions)
        if teardown_action is not None:
            self.run_actions(teardown_action["children"])


    def kill(self):
        # In case of scenario failure or termination, kill any applications left open here:

        self._stop_rolling_wpr_capture()

        #Kill teams related processes
        try:
            if self.platform.lower() == "w365":
                self._run_with_inputinject("cmd.exe /c tasklist /nh /fo csv /fi \"IMAGENAME eq 'Video.UI.exe'\"")
            else:
                self._kill("Video.UI.exe")
        except:
            pass
        
        try:
            if self.platform.lower() == "w365":
                self._run_with_inputinject("cmd.exe /c tasklist /nh /fo csv /fi \"IMAGENAME eq 'Microsoft.Media.Player.exe'\"")
            else:
                self._kill("Microsoft.Media.Player.exe")
        except:
            pass

        try:
            if self.platform.lower() == "w365":
                self._run_with_inputinject("cmd.exe /c tasklist /nh /fo csv /fi \"IMAGENAME eq 'ms-teams.exe'\"")
            else:
                self._kill("ms-teams.exe", force = True)
        except:
            pass

        try:
            # Do it again because some windows can still be left open
            if self.platform.lower() == "w365":
                self._run_with_inputinject("cmd.exe /c tasklist /nh /fo csv /fi \"IMAGENAME eq 'ms-teams.exe'\"")
            else:
                self._kill("ms-teams.exe", force = True)
        except:
            pass

        time.sleep(3)
         # Kill web browser and web_replay
        try:
            self._kill("msedge.exe")
        except:
            pass
        try:
            self._kill("chrome.exe")
        except:
            pass

        time.sleep(3)
        self._web_replay_kill()

        time.sleep(3)
        #Kill Timers
        try:
            self._kill("SimpleTimer.exe")
        except:
            pass

        # Kill office apps
        try:
            self._kill("Outlook.exe Excel.exe Powerpnt.exe Winword.exe OneNote.exe")
        except:
            pass

        # Kill Powershell
        try:
            # self._kill("powershell.exe")
            logging.info("Logging here because Powershell kill is commented out")
            pass
        except:
            pass

        return