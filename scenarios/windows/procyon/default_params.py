# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from utilities.open_source.modules import import_run_user_only

def run():
    Params.setCalculated('scenario_section', __package__.split('.')[-1])
    run_user_only()
    Params.setDefault('procyon', 'test', 'office_productivity', desc='', valOptions=['office_productivity', 'essentials', 'video_playback_batterylife', 'photo_editing', 'video_editing', 'ai_computer_vision_winml', 'ai_computer_vision_snpe', 'ai_computer_vision_openvino', 'ai_computer_vision_tensorrt', 'ai_computer_vision_ryzenai'])
    Params.setDefault('procyon', 'loops', '1', desc='Number of time to iterate the benchmark', valOptions=[])
    Params.setDefault('procyon', 'key', '', desc='Procyon activation key to be used during setup', valOptions=[])
    Params.setDefault('procyon', 'host_path', '', desc='Path on host to Procyon setup files', valOptions=[])
    return

def run_user_only():
    import_run_user_only('scenarios\\windows\\_library\\procyon\\procyon_run')
    import_run_user_only('scenarios\\windows\\_library\\procyon\\procyon_setup')
    return
