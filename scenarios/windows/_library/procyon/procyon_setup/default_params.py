# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from utilities.open_source.modules import import_run_user_only

def run():
    Params.setCalculated('scenario_section', __package__.split('.')[-1])
    run_user_only()
    Params.setDefault('procyon_setup', 'host_path', '', desc='Path on host to Procyon setup files', valOptions=[])
    Params.setDefault('procyon_setup', 'key', '', desc='Procyon license key', valOptions=[])
    return

def run_user_only():
    return
