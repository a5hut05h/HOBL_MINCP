# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import os
import time
from parameters import Params


def run(scenario):
    logging.debug('Executing code block: code_PSECSLP1.py')

    if Params.get('perf_stress', 'sleep_resume_midrun') != '1':
        logging.info('Skipping mid-workload sleep/resume checkpoint because sleep_resume_midrun is disabled')
        return

    # Mid-workload sleep/resume using the same approach as cs_floor scenario.
    # cs_floor_wrapper.cmd disconnects WiFi, then calls button.exe -s to trigger
    # actual Connected Standby sleep. After the sleep duration, WiFi reconnects.
    # Total budget: ~30s sleep + ~30s reconnect = ~60s
    wifi_off_duration_seconds = 30

    wrapper = os.path.join(scenario.dut_exec_path, 'cs_floor_resources', 'cs_floor_wrapper.cmd')

    logging.info(f'Starting mid-workload sleep/resume checkpoint (wifi_off={wifi_off_duration_seconds}s)')

    # Exactly matching cs_floor.py Connected Standby path:
    #   self._call(["cmd.exe", "/C " + wrapper + ' ' + wifi_off_duration + " " + dut_exec_path], blocking=False)
    #   time.sleep(2)
    try:
        cmd = os.path.join(scenario.dut_exec_path, "cs_floor_resources", "cs_floor_wrapper.cmd") + \
              ' ' + str(wifi_off_duration_seconds) + " " + scenario.dut_exec_path
        logging.info(f'DUT command: cmd.exe /C {cmd}')
        scenario._call(["cmd.exe", "/C " + cmd], blocking=False)
        time.sleep(2)
    except Exception:
        logging.error("cs_floor_wrapper.cmd or button.exe not found on DUT")

    # Wait for DUT to go to sleep and come back, using the framework's
    # built-in _wait_for_dut_comm() which is the same method cs_floor uses.
    if Params.get('global', 'local_execution') != '1':
        logging.info(f'Waiting {wifi_off_duration_seconds + 60}s for DUT to sleep and resume')
        time.sleep(wifi_off_duration_seconds + 10)

        logging.info('Waiting for DUT communication to restore')
        scenario._wait_for_dut_comm()
        logging.info('DUT communication restored after sleep/resume')

    # Give input stack/UI a short settle window before continuing.
    time.sleep(10)
    scenario._sleep_to_now()
