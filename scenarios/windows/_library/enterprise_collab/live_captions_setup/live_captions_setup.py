# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import scenarios.app_scenario
from parameters import Params
import logging
import os
from . import default_params

# Description:
#   Automatically generated standard scenario.

#library to start live captions in youtube and teams meetings, and validate captions are being generated and saved to disk.
class LiveCaptions(scenarios.app_scenario.Scenario):
    # Set default parameters:
    default_params.run()

    actions = None

    def setUp(self):
        # Load actions JSON.
        actions_json = os.path.join(os.path.dirname(__file__), "live_captions_setup.json")
        self.actions = self.load_action_json(actions_json)

        # Call base class setUp() to dump config, call tool callbacks, and start measurment
        scenarios.app_scenario.Scenario.setUp(self)


    def runTest(self):
        # Execute all actions (flat structure - no Setup/Run Test/Teardown blocks)
        self.run_actions(self.actions)


    def tearDown(self):
        # Call base class tearDown() to stop measurment, copy back data from DUT, and call tool callbacks
        scenarios.app_scenario.Scenario.tearDown(self)

        # Execute Teardown actions, if they exist
        teardown_action = self._find_next_type("Teardown", json=self.actions)
        if teardown_action is not None:
            self.run_actions(teardown_action["children"])


    def kill(self):
        # In case of scenario failure or termination, kill any applications left open here:

        return