# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from utilities.open_source.modules import import_run_user_only

def run():
    Params.setCalculated('scenario_section', __package__.split('.')[-1])
    run_user_only()
    return

def run_user_only():
    import_run_user_only('scenarios\\windows\\_library\\Teams\\teams_create_meeting')
    import_run_user_only('scenarios\\windows\\_library\\Teams\\teams_join_meeting')
    Params.setUserDefault('teams', 'duration', '600', desc='The time in seconds to call for. Default is 600s or 5min.', valOptions=['60', '120', '300', '600'])
    return
