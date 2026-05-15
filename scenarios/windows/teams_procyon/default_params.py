# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from utilities.open_source.modules import import_run_user_only

def run():
    Params.setCalculated('scenario_section', __package__.split('.')[-1])
    run_user_only()
    Params.setDefault('procyon', 'test', 'office_productivity', desc='Workload to run', valOptions=['office_productivity', 'essentials', 'video_playback_batterylife', 'photo_editing', 'video_editing', 'ai_computer_vision_winml', 'ai_computer_vision_snpe', 'ai_computer_vision_openvino', 'ai_computer_vision_tensorrt', 'ai_computer_vision_ryzenai'])
    Params.setDefault('procyon', 'warmup_delay', '1800', desc='Number of seconds to wait and let the device warm up before starting the Procyon run.', valOptions=[])
    Params.setDefault('procyon', 'host_path', '', desc='The path on the host where the Procyon installer has been downloaded.', valOptions=[])
    Params.setDefault('procyon', 'key', '', desc='Procyon license key', valOptions=[])
    Params.setParam('teams', 'send_screen', '1')
    Params.setParam('teams', 'show_desktop', '1')
    Params.setParam('teams', 'number_of_bots', '1')
    Params.setParam('teams', 'send_video', '1')
    Params.setParam('teams', 'send_audio', '1')
    Params.setParam('teams', 'bots_send_video', '1')
    Params.setParam('teams', 'bots_send_audio', '1')
    Params.setParam('teams', 'bots_share_screen', '0')
    Params.setParam('teams', 'bots_force_subscribe_resolution', '0')
    Params.setParam(None, 'phase_reporting', '1')
    return

def run_user_only():
    import_run_user_only('scenarios\\windows\\_library\\Teams\\teams_setup')
    import_run_user_only('scenarios\\windows\\_library\\Teams\\teams_teardown')
    import_run_user_only('scenarios\\windows\\_library\\procyon\\procyon_run')
    import_run_user_only('scenarios\\windows\\_library\\procyon\\procyon_setup')
    import_run_user_only('scenarios\\windows\\_library\\run_command')
    import_run_user_only('scenarios\\windows\\_library\\window_move')
    Params.setUserDefault('teams', 'duration', '3600', desc='Sets the time in seconds for the test to run.', valOptions=['60', '120', '240', '300', '600', '900'])
    return
