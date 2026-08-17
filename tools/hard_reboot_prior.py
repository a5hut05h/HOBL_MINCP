# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from core.parameters import Params
from core.app_scenario import Scenario
import logging
import time
from random import *

class Tool(Scenario):
    '''
    Initiate a hard reboot (long press power button) before each scenario.
    Make sure this tool is listed first in the tool list so that it doesn't interrupt tracing or recording initiated by other tools.
    '''
    module = __module__.split('.')[-1]
    Params.setDefault(module, 'post_reboot_delay', '120', desc="How many seconds to wait after reboot to let the system settle before continuing with the scenario.")  # Adding time here can help ensure the device is maximally charged.

    def initCallback(self, scenario):
        hard_reboot_call = Params.get('global', 'hard_reboot_call')
        if hard_reboot_call != '':      
            self._host_call(hard_reboot_call)            
            logging.info("DUT will be getting hard rebooted.")
            time.sleep(15)
            self._wait_for_dut_comm()
            time.sleep(int(Params.get(self.module, 'post_reboot_delay')))
    
    def testBeginCallback(self):
        pass
        
    def testEndCallback(self):
        pass

    def dataReadyCallback(self):
        pass
