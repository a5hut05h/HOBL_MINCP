# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import scenarios.windows.enterprise_collab
from parameters import Params
Params.setParam("enterprise_collab", "minwin_workloads", "productivity file_explorer")
Params.setParam("enterprise_collab", "simple_office_launch", "0")
Params.setDefault("consumer_multitasker", "bg_heavy_capture", "0", desc="1 = run rolling WPR captures in parallel with the core trace. Debug use only because a second WPR session can perturb performance results.", valOptions=["0", "1"])
Params.setDefault("consumer_multitasker", "bg_heavy_capture_provider", "general_cpi_collector.wprp", desc="WPRP file from the providers directory for the rolling background capture.", valOptions=["@\\providers"])
Params.setDefault("consumer_multitasker", "bg_heavy_capture_interval", "5", desc="Rolling background capture segment length in minutes.", valOptions=[])

class MinCP_Workload_All(scenarios.windows.enterprise_collab.EnterpriseCollab):
    '''
    Microsoft Teams video call with 9 bot participants.
    Local camera and mic are on, other 9 participants are bots sending video and audio.
    '''
    rolling_wpr_param_section = "consumer_multitasker"