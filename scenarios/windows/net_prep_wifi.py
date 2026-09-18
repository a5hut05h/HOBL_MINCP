# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
Params.setParam("net_prep", "connection", "Wi-Fi")
import scenarios.windows.net_prep

class NetPrepWiFi(scenarios.windows.net_prep.NetPrep):
    '''
    Set device routing table to prefer Wi-Fi connection between DUT and HOBL Host, to ensure that prep scenarios do not run over cellular.
    '''
    pass