# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# Check if rundown_abl_prep scenarios have all passed, and if so, launch rundown_abl plan
##

import core.app_scenario
from core.parameters import Params
# Import the module (not the Prep class) so unittest's test loader does not
# discover Prep as a TestCase in this module and run it. We only want to use
# Prep.get_prep_scenarios() as a helper.
import scenarios.common.prep as prep_module
import fnmatch
import os
import requests
import logging
import core.arguments
from urllib.parse import (
    urlparse,
    urlunparse,
    urlencode
)

class RunPlansIfPrepsPassed(core.app_scenario.Scenario):
    module = __module__.split('.')[-1]

    # Set default parameters
    Params.setDefault(module, 'prep_list', "abl_active cs_floor lvp teams", desc="List of prep scenarios to check the status of", multiple=True)
    Params.setDefault(module, 'plans_to_launch', "hobl.ps1 hobl_phm.ps1 hobl_etl.ps1", valOptions=["@\\testplans"], desc="List of plans to launch if preps have passed, in order", multiple=True)

    # Get Parameters
    prep_list = Params.get(module, 'prep_list').split()
    plans_to_launch = Params.get(module, 'plans_to_launch').split()
    dashboard_url = Params.get('global', 'dashboard_url')
    dut_architecture = Params.get('global', 'dut_architecture')
    study_type = Params.getOverride('global', 'study_type')

    is_prep = True


    def setUp(self):
        # Don't call base setUp so that we don't interact with DUT
        return


    def runTest(self):
        # Create an instance of the Prep scenario to use its get_prep_scenarios() function, 
        # which will check the status of preps in the hierarchy under the specified scenarios 
        # and return a list of any that still need to be run.
        prep_instance = prep_module.Prep()
        prep_instance.scenarios_to_prep = self.prep_list
        scenarios_needing_prep = prep_instance.get_prep_scenarios()

        
        # If get_prep_scenarios() returns an empty list, all preps have been completed
        if len(scenarios_needing_prep) == 0:
            logging.info("All required preps have been completed. Proceeding to launch plans.")
            args = core.arguments.args
            params_file = args.profile
            profile = os.path.basename(params_file).rsplit('.',1)[0]

            url = urlunparse(
                urlparse(self.dashboard_url)._replace(
                    path="/plan/RunPlan"
                )
            )

            study_type_param = ""

            if self.study_type:
                study_type_param = f"&studyType={self.study_type}"

            for plan in self.plans_to_launch:
                if plan == "hobl_phm.ps1" and self.dut_architecture.lower() != "x64":
                    logging.info("Skipping hobl_phm.ps1 because dut_architecture is not x64")
                    continue

                response = requests.get(url + "?profile=" + profile + "&plan=" + plan + study_type_param)
                logging.info("Launching " + plan + " for profile " + profile + ": " + str(response))
        else:
            # Preps still pending
            prep_names = []
            for p in scenarios_needing_prep:
                if isinstance(p, tuple):
                    prep_names.append(p[0])
                else:
                    prep_names.append(p)
            logging.warning(f"The following preps are still pending: {', '.join(prep_names)}")
            self._assert(f"Preps still pending: {', '.join(prep_names)}")


    def tearDown(self):
        # Don't call base tearDown so that we don't interact with DUT
        return


    def kill(self):
        # Prevent base kill routine from running
        return 0
