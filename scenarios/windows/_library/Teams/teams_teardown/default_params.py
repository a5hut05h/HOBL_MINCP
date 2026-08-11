# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from utilities.open_source.modules import import_run_user_only

def run():
    Params.setCalculated('scenario_section', __package__.split('.')[-1])
    run_user_only()
    return

def run_user_only():
    import_run_user_only('scenarios\\windows\\_library\\Teams\\teams_collect_logs')
    import_run_user_only('scenarios\\windows\\_library\\Teams\\teams_leave_meeting')
    Params.setUserDefault('teams', 'collect_MSTeams_Logs', '1', desc='Set to 1 to collect MS Teams logs of the meeting after exiting the meeting.', valOptions=['0', '1'])
    return
