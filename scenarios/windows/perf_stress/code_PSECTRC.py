# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import os
from parameters import Params

def run(scenario):
    logging.debug('Executing code block: code_PSECTRC.py (early trace start)')

    if Params.get('perf_stress', 'stress_run') != '1':
        logging.info('Skipping early trace start because stress_run is disabled')
        return

    src_dir = os.path.dirname(__file__)
    repo_root = os.path.abspath(os.path.join(src_dir, "..", "..", ".."))
    dut_bin_dir = r"C:\hobl_bin"

    # Upload only the files needed for trace collection.
    trace_files = [
        os.path.join(src_dir, "collect_5min_traces.ps1"),
        os.path.join(repo_root, "providers", "general_cpi_collector.wprp"),
    ]

    scenario._remote_make_dir(dut_bin_dir)
    for src_file in trace_files:
        if not os.path.isfile(src_file):
            scenario.fail(f"Required file missing: {src_file}")
        logging.info(f"Uploading to DUT {dut_bin_dir}: {src_file}")
        scenario._upload(src_file, dut_bin_dir)

    # Start trace collection in background immediately
    collect_ps = rf"{dut_bin_dir}\collect_5min_traces.ps1"
    run_name = scenario.testname  # e.g. perf_stress_142
    logging.info(f"Starting collect_5min_traces.ps1 in minimized window (early), RunName={run_name}.")
    scenario._call([
        "cmd.exe",
        f'/C start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{collect_ps}" -RunName "{run_name}"',
    ], expected_exit_code="", blocking=False)

    scenario._sleep_to_now()
