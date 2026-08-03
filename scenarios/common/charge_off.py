# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# charge_off
# 
# Turns off the device charger.
# Intended to be included at the beginning of a test plan
#
# Setup instructions:
#   Specify the command to call to turn off the charger for the "charge_off_call" parameter in your parameters file.
##

import logging
import core.app_scenario
from core.parameters import Params
from utilities.open_source.widgets import Widgets


class ChargeOff(core.app_scenario.Scenario):
    module = __module__.split('.')[-1]

    # Override collection of config data, traces, and execution of callbacks 

    # Prevent any tools from running
    Params.setOverride('global', 'prep_tools', '')

    # Get parameters
    charge_off_call = Params.get('global', 'charge_off_call')

    widgets = Widgets()

    is_prep = True

    def setUp(self):
        # Don't call base setUp so that we don't interact with DUT.
        return

    def runTest(self):
        logging.info("Attempting to turn off charger...")
        if self.charge_off_call == '':
            logging.warning("No charge_off_call specified.  Manually turn off charger to continue.")
            self.widgets.about("Disconnect Charger", "Manually disconnect charger.")
        else:
            self._host_call(self.charge_off_call)
            logging.info("Charger turned off.")

    def tearDown(self):
        # Don't call base tearDown so that we don't interact with DUT.
        return

    def kill(self):
        # Prevent base kill routine from running
        return 0
        
