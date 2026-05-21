# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from utilities.open_source.modules import import_run_user_only

def run():
    Params.setCalculated('scenario_section', __package__.split('.')[-1])
    run_user_only()
    Params.setDefault('mac_enterprise_collab', 'loops', '1', desc='', valOptions=[])
    Params.setDefault('mac_enterprise_collab', 'background_teams', '1', desc='', valOptions=['0', '1'])
    Params.setDefault('mac_enterprise_collab', 'background_timers', '1', desc='', valOptions=['0', '1'])
    Params.setDefault('mac_enterprise_collab', 'background_onedrive_copy', '1', desc='', valOptions=['0', '1'])
    Params.setDefault('mac_enterprise_collab', 'workloads', 'productivity', desc='', valOptions=['productivity'])
    Params.setDefault('mac_enterprise_collab', 'simple_office_launch', '0', desc='', valOptions=['0', '1'])
    Params.setDefault('mac_enterprise_collab', 'battery_threshold', '30', desc='', valOptions=['20', '30', '40', '50'])
    Params.setDefault('mac_enterprise_collab', 'isDischarged', '0', desc='', valOptions=['0', '1'])
    Params.setParam(None, 'web_replay_run', '1')
    Params.setParam(None, 'loop_count', '0')
    Params.setParam(None, 'success_count', '0')
    return

def run_user_only():
    import_run_user_only('scenarios\\macos\\_library\\Teams\\teams_setup')
    import_run_user_only('scenarios\\macos\\_library\\Teams\\teams_teardown')
    import_run_user_only('scenarios\\macos\\_library\\enterprise_collab\\onedrive_upload_setup')
    import_run_user_only('scenarios\\macos\\_library\\enterprise_collab\\timers_setup')
    import_run_user_only('scenarios\\macos\\_library\\power\\check_battery_percentage')
    import_run_user_only('scenarios\\macos\\_library\\power\\powertool_setup')
    import_run_user_only('scenarios\\macos\\_library\\power\\powertool_teardown')
    import_run_user_only('scenarios\\macos\\_library\\productivity\\prod_close')
    import_run_user_only('scenarios\\macos\\_library\\productivity\\prod_kill')
    import_run_user_only('scenarios\\macos\\_library\\productivity\\prod_open')
    import_run_user_only('scenarios\\macos\\_library\\productivity\\prod_setup')
    import_run_user_only('scenarios\\macos\\_library\\web\\web_close_browser')
    import_run_user_only('scenarios\\macos\\_library\\web\\web_close_tabs')
    import_run_user_only('scenarios\\macos\\_library\\web\\web_kill')
    import_run_user_only('scenarios\\macos\\_library\\web\\web_run_12')
    import_run_user_only('scenarios\\macos\\_library\\web\\web_run_minmac')
    import_run_user_only('scenarios\\macos\\_library\\web\\web_setup')
    return
