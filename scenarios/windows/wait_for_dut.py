# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# Idle at the Desktop
#
# Setup instructions:
#   None
##

import logging
import core.app_scenario
from core.parameters import Params
import core.call_rpc as rpc
import json
import time

class WaitForDut(core.app_scenario.Scenario):

    is_prep = True
    hide_ui = False

    module = __module__.split('.')[-1]
    # Override parameters
    Params.setOverride("global", "tools", "")

    def setUp(self):
        # Intentionally not calling base method to prevent extraneous call attempts to DUT
        return

    def runTest(self):
        self._wait_for_dut_comm()

    def tearDown(self):
        # Intentionally not calling base method
        return
