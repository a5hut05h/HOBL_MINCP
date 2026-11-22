# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from utilities.open_source.modules import import_run_user_only

def run():
    Params.setCalculated('scenario_section', __package__.split('.')[-1])
    run_user_only()
    Params.setParam(None, 'phase_reporting', '1')
    return

def run_user_only():
    import_run_user_only('..\\_library\\productivity\\prod_close', here=__file__)
    import_run_user_only('..\\_library\\productivity\\prod_kill', here=__file__)
    import_run_user_only('..\\_library\\productivity\\prod_open', here=__file__)
    import_run_user_only('..\\_library\\productivity\\prod_run', here=__file__)
    import_run_user_only('..\\_library\\productivity\\prod_setup', here=__file__)
    return
