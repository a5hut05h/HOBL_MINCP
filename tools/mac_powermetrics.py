# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from core.app_scenario import Scenario
import logging
import os


class Tool(Scenario):
    '''
    macOS-only lightweight power measurement tool based on powermetrics.
    '''
    module = __module__.split('.')[-1]
    PID_PARAM_KEY = 'powertool_pid'

    Params.setDefault(module, 'interval_ms', '1000', desc="powermetrics sample interval in ms.")
    Params.setDefault(module, 'samplers', 'battery,cpu_power,gpu_power,ane_power', desc="powermetrics -s sampler list.")
    Params.setDefault(module, 'output_file', 'powertrace.plist', desc="Output filename written in dut_data_path.")

    stopped = False

    def _require_macos(self):
        if self.platform.lower() != 'macos':
            msg = "mac_powermetrics requires platform=MacOS"
            logging.error(msg)
            self.fail(msg)

    def _stop_powermetrics_process(self):
        saved_pid = str(Params.get(self.module, self.PID_PARAM_KEY) or '').strip()
        if saved_pid.isdigit():
            logging.info(f"Stopping powermetrics PID: {saved_pid}")
            self._call(["bash", f"-c \"kill -9 {saved_pid}\""], expected_exit_code="", fail_on_exception=False)
        else:
            logging.warning("powermetrics PID was not set; using fallback kill")
            self._call(["bash", "-c \"pkill -x powermetrics\""], expected_exit_code="", fail_on_exception=False)

    def _prepare_temp_powermetrics_for_copyback(self):
        if not hasattr(self, 'remote_plist') or not hasattr(self, 'remote_temp_plist'):
            return

        if self._check_remote_file_exists(self.remote_plist, in_exec_path=False):
            cp_cmd = (
                f"cp '{self.remote_plist}' '{self.remote_temp_plist}' && "
                f"chmod 666 '{self.remote_temp_plist}'"
            )
            try:
                self._sudo_bash(cp_cmd)
                logging.info(f"Prepared temp powermetrics file for copyback: {self.remote_temp_plist}")

                # Remove the original root-owned plist after copying so full DUT directory
                # copyback doesn't have to package a potentially unstable writer artifact.
                self._sudo_bash(f"rm -f '{self.remote_plist}'")
                logging.info(f"Removed original powermetrics output after temp copy: {self.remote_plist}")
            except Exception as exp:
                logging.warning(f"Failed to prepare temp powermetrics output for copyback: {exp}")
        else:
            logging.warning(f"powermetrics output was not found: {self.remote_plist}")

    def _get_sudo_password(self):
        sudo_password = str(Params.get('global', 'dut_password') or '').strip()
        if not sudo_password and hasattr(self, 'password'):
            sudo_password = str(self.password or '').strip()
        return sudo_password

    def _sudo_bash(self, cmd):
        sudo_password = self._get_sudo_password()
        if sudo_password:
            escaped_password = sudo_password.replace("'", "'\"'\"'")
            full_cmd = (
                f"printf '%s\\n' '{escaped_password}' | "
                f"sudo -S -p '' bash -c '{cmd}'"
            )
        else:
            full_cmd = f"sudo -n bash -c '{cmd}'"
        return self._call(["bash", f"-c \"{full_cmd}\""], expected_exit_code="")

    def initCallback(self, scenario):
        self.scenario = scenario
        self.conn_timeout = False
        self.stopped = False
        self._require_macos()

        output_file = Params.get(self.module, 'output_file')
        self.remote_plist = f"{self.scenario.dut_data_path}/{output_file}"
        self.remote_temp_plist = f"{self.scenario.dut_data_path}/powermetrics_copyback_temp.plist"

        self._call(
            ["bash", f"-c \"rm -f '{self.remote_plist}' '{self.remote_temp_plist}'\""],
            expected_exit_code="",
            fail_on_exception=False,
        )

        interval_ms = Params.get(self.module, 'interval_ms')
        samplers = Params.get(self.module, 'samplers')

        cmd = (
            f"powermetrics -f plist -i {interval_ms} "
            f"-s {samplers} -o '{self.remote_plist}'"
        )

        logging.info(f"Starting powermetrics on DUT: {cmd}")
        launch_cmd = f"{cmd} > /tmp/powermetrics.log 2>&1 & echo $!"

        pid_output = self._sudo_bash(launch_cmd)
        lines = [line.strip() for line in str(pid_output).splitlines() if line.strip()]
        powermetrics_pid = next((line for line in reversed(lines) if line.isdigit()), "")

        if powermetrics_pid.isdigit():
            Params.setParam(self.module, self.PID_PARAM_KEY, powermetrics_pid)
            logging.info(f"powermetrics started with PID: {powermetrics_pid}")
        else:
            logging.warning("powermetrics PID could not be determined from launch output")

    def testEndCallback(self):
        if self.stopped:
            return

        self._stop_powermetrics_process()
        self._prepare_temp_powermetrics_for_copyback()

        self.stopped = True

    def dataReadyCallback(self):
        output_file = Params.get(self.module, 'output_file')
        host_final_path = os.path.join(self.scenario.result_dir, os.path.basename(output_file))
        host_temp_path = os.path.join(self.scenario.result_dir, os.path.basename(self.remote_temp_plist))

        if os.path.exists(host_temp_path):
            if os.path.exists(host_final_path):
                os.remove(host_final_path)
            os.replace(host_temp_path, host_final_path)
            logging.info(f"Normalized temp powermetrics file to final path: {host_final_path}")

        if os.path.exists(host_final_path):
            logging.info(f"powermetrics output available: {host_final_path}")
        else:
            logging.warning("powermetrics output was not copied back to host result directory")

        self._call(
            ["bash", f"-c \"rm -f '{self.remote_temp_plist}'\""],
            expected_exit_code="",
            fail_on_exception=False,
        )

    def testTimeoutCallback(self):
        self._stop_powermetrics_process()
        self._prepare_temp_powermetrics_for_copyback()
        self.stopped = True
        self.conn_timeout = True

    def testScenarioFailed(self):
        self._stop_powermetrics_process()
        self._prepare_temp_powermetrics_for_copyback()
        self.stopped = True

    def cleanup(self):
        self._stop_powermetrics_process()
        self._prepare_temp_powermetrics_for_copyback()
        self.stopped = True