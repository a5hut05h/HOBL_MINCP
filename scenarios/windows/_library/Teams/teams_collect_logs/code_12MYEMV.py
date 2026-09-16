# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging

def run(scenario):
    logging.debug('Executing code block: code_12MYEMV.py')
    logs_dir = scenario.dut_data_path + "\\MSTeamsLogs"
    scenario._remote_make_dir(logs_dir, delete=True)
    if scenario.platform.lower() == "w365":
        scenario._run_with_inputinject('powershell Move-Item -Path "~\Downloads\MSTeams*" -Destination "' + logs_dir + '"')
    elif scenario.platform.lower() == "windows":
        scenario._call(["powershell.exe", 'Move-Item -Path "~\Downloads\MSTeams*" -Destination "' + logs_dir + '"'])
    else:
        raise AssertionError("Not Implimented")