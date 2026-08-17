# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from utilities.open_source.modules import import_run_user_only

def run():
    Params.setCalculated('scenario_section', __package__.split('.')[-1])
    run_user_only()
    Params.setDefault('procyon_run', 'test_definition', 'office_productivity', desc='Workload to run', valOptions=['office_productivity', 'essentials', 'video_playback_batterylife', 'photo_editing', 'video_editing', 'ai_computer_vision_winml', 'ai_computer_vision_snpe', 'ai_computer_vision_openvino', 'ai_computer_vision_tensorrt', 'ai_computer_vision_ryzenai'])
    return

def run_user_only():
    return
