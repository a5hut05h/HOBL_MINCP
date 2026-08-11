# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from utilities.open_source.modules import import_run_user_only

def run():
    Params.setCalculated('scenario_section', __package__.split('.')[-1])
    run_user_only()
    return

def run_user_only():
    import_run_user_only('scenarios\\windows\\_library\\Teams\\teams_collect_call_health')
    import_run_user_only('scenarios\\windows\\_library\\Teams\\teams_stop_screenshare')
    Params.setUserDefault('teams', 'access_key', '-1', desc='The access key for the Teams Bots Server. Contact HOBL Support to inquire for a key.', valOptions=[])
    Params.setUserDefault('teams', 'send_screen', '0', desc='Set to 1 to have the DUT share its screen in the meeting.', valOptions=['0', '1'])
    Params.setUserDefault('teams', 'collect_call_health', '1', desc='Set to 1 to have the call health data collected.', valOptions=['0', '1'])
    return
