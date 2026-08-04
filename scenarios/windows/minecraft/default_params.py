# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from utilities.open_source.modules import import_run_user_only

def run():
    Params.setCalculated('scenario_section', __package__.split('.')[-1])
    run_user_only()
    Params.setDefault('minecraft', 'duration', '300', desc='Duration of Minecraft Game', valOptions=[])
    Params.setParam(None, 'loop_duration', '600')
    Params.setParam(None, 'final_loop_duration', '0')
    Params.setParam(None, 'loops', '1')
    Params.setParam(None, 'loop_counter', '1')
    return

def run_user_only():
    return
