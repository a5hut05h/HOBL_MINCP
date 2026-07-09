# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# code_PSECPYK.py - Final Python stress kill at the very end of Run Test.
#
# Under heavy CPU stress the base-class
# tearDown chain (web_kill -> prod_kill -> teams_teardown -> DiagTrack restart)
# stretches significantly because the python percentile_stress.py process is
# still pinning every core. Killing the stress process here - as the LAST job
# in the main run phase, while WPR is still capturing - keeps teardown wall
# time bounded on multi-iteration unattended runs and avoids extending the
# core trace by tens of seconds of tear-down activity.

import logging
import os
import subprocess

from parameters import Params


def run(scenario):
    logging.debug('Executing code block: code_PSECPYK.py (final python stress kill)')

    if Params.get('perf_stress', 'stress_run') != '1':
        logging.info('stress_run=0 - no python stress to kill')
        return

    # Preferred path: the same script kill() uses. It retries Win32_Process
    # matches and tolerates already-dead processes.
    stop_script = os.path.join(scenario.dut_exec_path, "stop_perfStress_background.ps1")
    try:
        scenario._call([
            "cmd.exe",
            f"/C powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"{stop_script}\""
        ], expected_exit_code="")
    except Exception as ex:
        logging.warning(f"stop_perfStress_background.ps1 failed in code_PSECPYK: {ex}")

    # Belt-and-suspenders fallback in case the script did not catch every
    # python launcher variant under load.
    for proc_name in ["python.exe", "py.exe", "pythonw.exe"]:
        try:
            scenario._kill(proc_name, force=True)
        except subprocess.TimeoutExpired:
            logging.warning(f" WARNING - Timed out killing {proc_name} in code_PSECPYK")
        except Exception:
            pass

    scenario._sleep_to_now()
