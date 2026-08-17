# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# Disable adaptive color
##

import time
import logging

import core.app_scenario
from core.parameters import Params
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.common.action_chains import ActionChains


class SurfaceAppPrep(core.app_scenario.Scenario):
    module = __module__.split('.')[-1]
    Params.setDefault(module, "surface_app_prep_enabled", "0", desc="Enables or disables surface_app_prep execution.  Disabled by default since it is only useful on Surface devices.", valOptions=["0", "1"])

    is_prep = True


    def runTest(self):
        logging.info("Launching WinAppDriver.exe on DUT")

        self._call([
            (self.dut_exec_path + "\\WindowsApplicationDriver\\WinAppDriver.exe"),
            (self.dut_resolved_ip + " " + self.app_port)],
            blocking=False
        )

        desired_caps = {}
        desired_caps["app"] = "Root"

        self.driver = self._launchApp(desired_caps)

        try:
            self._call(["cmd.exe", '/C start ms-surface-app:camera-audio-exp'], timeout=10)
            time.sleep(2)

        # try:
        #     self._call(["cmd.exe", '/C start shell:AppsFolder\Microsoft.SurfaceHub_8wekyb3d8bbwe!App'], timeout=10)
        #     time.sleep(2)

        #     try:
        #         self.driver.find_element_by_name("Let's go").click()
        #         time.sleep(2)
        #     except:
        #         logging.warning("'Lets go' button not found, may have already been launched.")

        #     try:
        #         self.driver.find_element_by_name("Get started").click()
        #         time.sleep(2)
        #     except:
        #         logging.warning("'Get started' button not found, may have already been launched.")

        #     try:
        #         elem = self.driver.find_element_by_name("Windows Studio effects")
        #         elem.click()
        #         time.sleep(2)
        #         ActionChains(self.driver).send_keys(Keys.TAB).perform()
        #         # elem.send_keys(Keys.TAB)
        #         time.sleep(1)
        #         ActionChains(self.driver).send_keys(Keys.ENTER).perform()
        #         # elem.send_keys(Keys.ENTER)
        #         time.sleep(2)
        #     except:
        #         logging.warning("'Windows Studio effects' button not found, may not be supported on this device.")


            try:
                self.driver.find_element_by_name("Close Surface").click()
                time.sleep(1)
            except:
                logging.warning("'Close' button not found.")

            # It can take 2 tries
            try:
                self.driver.find_element_by_name("Close Surface").click()
                time.sleep(1)
            except:
                pass

        except:
            logging.warning("Could not launch Surface Hub, may not exist on this device.")

        time.sleep(1)

        self.driver.close()
        self.createPrepStatusControlFile()


    def tearDown(self):
        core.app_scenario.Scenario.tearDown(self)

        logging.debug("Killing SurfaceApp.exe")
        self._kill("SurfaceApp.exe")

        logging.debug("Killing WinAppDriver.exe")
        self._kill("WinAppDriver.exe")


    def kill(self):
        try:
            logging.debug("Killing SurfaceApp.exe")
            self._kill("SurfaceApp.exe")
        except:
            pass

        try:
            logging.debug("Killing WinAppDriver.exe")
            self._kill("WinAppDriver.exe")
        except:
            pass
