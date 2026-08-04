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

    # Mid-workload Connected Standby sleep using the same primitive the standby
    # library (_library/misc/standby/code_W33UMT.py) uses: button.exe -s <ms>.
    # We do NOT disconnect Wi-Fi - per perf-team feedback we want REAL CS so
    # post-resume scenarios exercise the heavy resume overheads, not a 30s
    # Wi-Fi reconnect window.
    #
    # Prereq: 'button_install' is in PerfStress.prep_scenarios so the kernel
    # driver and arch-correct button.exe are already installed at
    # C:\hobl_bin\button\button.exe.
    sleep_duration_seconds = 30

    logging.info(f'Starting mid-workload Connected Standby checkpoint (duration={sleep_duration_seconds}s)')

    button_exe = os.path.join(scenario.dut_exec_path, "button", "button.exe")
    duration_ms = int(sleep_duration_seconds) * 1000
    # 'timeout 3 > NUL' matches the standby library: gives this RPC a moment to
    # return before button.exe puts the DUT into CS.
    cmd_str = f'/C timeout 3 > NUL && "{button_exe}" -s {duration_ms}'
    logging.info(f'DUT command: cmd.exe {cmd_str}')
    try:
        scenario._call(["cmd.exe", cmd_str], blocking=False)
        time.sleep(2)
    except Exception:
        logging.error(" ERROR - button.exe not found on DUT. Run scenarios/windows/button_install "
                      "first, or verify global:dut_architecture in the profile INI.")
        return

    # With real Connected Standby the DUT does NOT drop the network (Wi-Fi/NIC
    # stays attached during CS), so the previous unreachable->reachable probe
    # never fired and just wasted the full sleep window plus a 30s grace. Per
    # perf-team feedback: a fixed wait covering the sleep duration plus
    # a small post-resume settle is what the scenario actually needs.
    if Params.get('global', 'local_execution') != '1':
        post_resume_settle_seconds = 5
        total_wait = sleep_duration_seconds + post_resume_settle_seconds
        logging.info(f'Waiting {total_wait}s for Connected Standby + resume to complete')
        time.sleep(total_wait)
        scenario._wait_for_dut_comm()
        logging.info('DUT communication restored after sleep/resume checkpoint')

    # Resume immediately into the next action - the whole point of sleep/resume
    # in a stress run is to measure resume-under-stress behavior, so we do not
    # add a quiet settle window here.
    scenario._sleep_to_now()
