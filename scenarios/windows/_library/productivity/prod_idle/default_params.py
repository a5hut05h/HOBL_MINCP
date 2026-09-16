# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from utilities.open_source.modules import import_run_user_only

def run():
    Params.setCalculated('scenario_section', __package__.split('.')[-1])
    run_user_only()
    Params.setDefault('prod_idle', 'idle_time', '111', desc='Idle time between each app switch, - 3s', valOptions=[])
    return

def run_user_only():
    import_run_user_only('scenarios\\windows\\_library\\productivity\\prod_excel_switchto')
    import_run_user_only('scenarios\\windows\\_library\\productivity\\prod_onenote_switchto')
    import_run_user_only('scenarios\\windows\\_library\\productivity\\prod_outlook_switchto')
    import_run_user_only('scenarios\\windows\\_library\\productivity\\prod_powerpoint_switchto')
    import_run_user_only('scenarios\\windows\\_library\\productivity\\prod_word_switchto')
    return
