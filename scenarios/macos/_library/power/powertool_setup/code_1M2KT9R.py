# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
from core.parameters import Params


def run(scenario):
    logging.debug('Executing code block: code_1M2KT9R.py')

    module = getattr(scenario, '_module', '') or scenario.__module__.split('.')[-1]
    plist_path = f"{scenario.dut_data_path}/powermetrics.plist"
    cmd = (
        "powermetrics -f plist -i 1000 "
        f"-s battery,cpu_power,gpu_power,ane_power -o {plist_path}"
    )

    sudo_password = str(Params.get('global', 'dut_password') or '').strip()
    if not sudo_password and hasattr(scenario, 'password'):
        sudo_password = str(scenario.password or '').strip()

    logging.info("Starting powermetrics on DUT...")
    if sudo_password:
        escaped_password = sudo_password.replace("'", "'\"'\"'")
        launch_cmd = (
            f"printf '%s\\n' '{escaped_password}' | "
            f"sudo -S -p '' {cmd} > /tmp/powermetrics.log 2>&1 & echo $!"
        )
    else:
        launch_cmd = f"sudo -n {cmd} > /tmp/powermetrics.log 2>&1 & echo $!"

    pid_output = scenario._call([
        "bash",
        f"-c \"{launch_cmd}\""
    ], expected_exit_code="")

    lines = [line.strip() for line in str(pid_output).splitlines() if line.strip()]
    powertool_pid = next((line for line in reversed(lines) if line.isdigit()), "")

    if powertool_pid.isdigit():
        Params.setParam(module, 'powertool_pid', powertool_pid)
        logging.info(f"powermetrics started with PID: {powertool_pid}")
    else:
        logging.warning("powermetrics PID could not be determined from launch command output")