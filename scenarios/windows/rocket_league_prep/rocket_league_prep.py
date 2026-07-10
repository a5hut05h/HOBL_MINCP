# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# Downloads/logs into steam sets it to offline mode and installs game. 
##

import os
import time
import logging

import core.app_scenario
from core.parameters import Params
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.common.by import By
import core.call_rpc as rpc


class RocketLeaguePrep(core.app_scenario.Scenario):
    module = __module__.split('.')[-1]

    # set default parameters
    Params.setDefault(module, 'steam_user', '', desc="Steam Username")
    Params.setDefault(module, 'steam_password', '', desc="Steam Password")
    Params.setDefault(module, 'steam_login_only', '0', desc="Flag for skipping steam/rocket league download and only log into steam.", valOptions=["1", "0"])

    # get parameters
    steam_user = Params.get(module, 'steam_user')
    steam_password = Params.get(module, 'steam_password')
    steam_login_only = Params.get(module, 'steam_login_only')

    is_prep = True


    def runTest(self):
        steam_path = "C:\\Program Files (x86)\\Steam"
        if self.steam_login_only == "0":
            # Skip the Steam download/install if the client is already present on the DUT
            if self._check_remote_file_exists("\"" + os.path.join(steam_path, "steam.exe") + "\"", in_exec_path=False):
                logging.info("Steam already installed, skipping download and install")
            else:
                logging.info("Downloading Steam")
                steam_install_path = os.path.join(self.dut_exec_path, "SteamSetup.exe")
                self._call(["powershell.exe", "wget \\\"https://steamcdn-a.akamaihd.net/client/installer/SteamSetup.exe\\\" -outfile " + steam_install_path])

                logging.info("Installing Steam")
                self._call(["cmd.exe", "/C start /wait " + steam_install_path + " /S"])
                #self._call(["powershell.exe", "-Command \"Start-Process -FilePath '" + steam_install_path + "' -ArgumentList '/S' -Wait\""])

                logging.info("Deleting steamsetup.exe")
                self._call(["cmd.exe", "/C del /F /Q \"" + steam_install_path + "\""], expected_exit_code="")

            logging.info("Removing Steam from Windows Startup")
            self._call(["powershell.exe", "-Command \"Remove-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'Steam' -Force -ErrorAction SilentlyContinue\""], expected_exit_code="")

            logging.info("Downloading steamcmd.exe to " + steam_path)
            self._call(["powershell.exe", "wget \\\"https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip\\\" -outfile '" + os.path.join(self.dut_exec_path, "steamcmd.zip") + "'"])
            #unzip steamcmd.zip
            self._call(["powershell.exe", "Expand-Archive -Path '" + os.path.join(self.dut_exec_path, "steamcmd.zip") + "' -DestinationPath '" + steam_path + "' -Force"])
            logging.info("Deleting steamcmd.zip")
            self._call(["cmd.exe", "/C del /F /Q \"" + os.path.join(self.dut_exec_path, "steamcmd.zip") + "\""], expected_exit_code="")

            logging.info("Installing Rocket League")
            steamcmd_path = os.path.join(steam_path, "steamcmd.exe")
            # self._call(["cmd.exe", "/C \"" + steamcmd_path + "\" +login anonymous +app_update 252950 validate +quit"])
            self._call(["cmd.exe", "/C \"\"" + steamcmd_path + "\" +login " + self.steam_user + " \"" + self.steam_password + "\" +app_update 252950 validate +quit\""], expected_exit_code="", timeout=2700)

            #Check if rocket league installed by verifying the install size (full game is ~39.5 GB)
            rl_path = os.path.join(steam_path, "steamapps", "common", "rocketleague")
            size_output = self._call(["powershell.exe", "-Command \"[math]::Round(((Get-ChildItem -Path '" + rl_path + "' -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1GB), 2)\""])
            try:
                rl_size_gb = float(size_output.strip())
            except:
                rl_size_gb = 0
            logging.info("Rocket League install size: " + str(rl_size_gb) + " GB")
            if rl_size_gb < 30:
                self._assert("Rocket League installation failed - install size " + str(rl_size_gb) + " GB is below the expected ~39.5 GB")
            

        
        logging.info("Launching WinAppDriver.exe on DUT")

        self._call([
            (self.dut_exec_path + "\\WindowsApplicationDriver\\WinAppDriver.exe"),
            (self.dut_resolved_ip + " " + self.app_port)],
            blocking=False
        )

        desired_caps = {}
        desired_caps["app"] = "Root"

        self.driver = self._launchApp(desired_caps)
        
        #start steam.exe
        steam_client = os.path.join(steam_path, "steam.exe")
        self._call(["cmd.exe", "/C start \"\" \"" + steam_client + "\""], blocking=False, expected_exit_code="")

        # Enter the Steam username into the sign-in edit box
        logging.info("Trying to log into steam")
        try:
            # Wait until the sign-in field appears (Steam can take a while to launch)
            sign_in_field = WebDriverWait(self.driver, 120).until(EC.presence_of_element_located((By.XPATH, '//Edit[contains(@Name,"SIGN IN WITH ACCOUNT NAME")]')))
            sign_in_field.click()
            time.sleep(1)   
            self._send_text(self.steam_user, 50)
            time.sleep(1)

            password_field = WebDriverWait(self.driver, 60).until(EC.presence_of_element_located((By.XPATH, '//Edit[contains(@Name,"PASSWORD")]')))

            password_field.click()
            time.sleep(1)
            self._send_text(self.steam_password, 50)
            time.sleep(1)
            self._send_text('\ue007', 50)
        except:
            logging.info("Sign in window not found. Checking if signed in already.")
        
        try:
            logging.info("Looking for library tab")
            WebDriverWait(self.driver, 60).until(EC.presence_of_element_located((By.XPATH, '//Text[contains(@Name,"LIBRARY")]')))
            logging.info("Found library tab. Steam is logged in")
        except:
            logging.info("Library tab not found.")

        logging.info("Looking for login config file")
        loginusers_path = os.path.join(steam_path, "config", "loginusers.vdf")
        # Quote the path so the space in "Program Files (x86)" doesn't break cmd's "if exist" check
        if self._check_remote_file_exists("\"" + loginusers_path + "\"", in_exec_path=False):
            logging.info("Setting Steam to offline mode in loginusers.vdf")
            ps_cmd = ("-Command \"(Get-Content '" + loginusers_path + "') "
                      "-replace '(\\\"WantsOfflineMode\\\"\\s+)\\\"0\\\"', '$1\\\"1\\\"' "
                      "-replace '(\\\"SkipOfflineModeWarning\\\"\\s+)\\\"0\\\"', '$1\\\"1\\\"' "
                      "| Set-Content '" + loginusers_path + "'\"")
            self._call(["powershell.exe", ps_cmd])
        else:
            self.fail("Could not locate logged in user config file. Assumption is steam did not log in properly.")
        
        # Kill steam and relaunch it so the offline mode is set. 
        try:
            logging.debug("Killing steam.exe")
            self._kill("steam.exe")
        except:
            pass
        time.sleep(10)
        self._call(["cmd.exe", "/C start \"\" \"" + steam_client + "\""], blocking=False, expected_exit_code="")
        time.sleep(10)

        # Launch Rocket League
        logging.info("Launching Rocket League")
        self._call(["cmd.exe", "/C start \"\" \"C:\\Program Files (x86)\\Steam\\steamapps\\common\\rocketleague\\Binaries\\Win64\\RocketLeague.exe\""], blocking=False, expected_exit_code="")
        
        try:
            WebDriverWait(self.driver, 75).until(EC.presence_of_element_located((By.XPATH, '//Button[contains(@Name,"OK")]'))).click()
        except:
            pass

        
        self.createPrepStatusControlFile()  


    def tearDown(self):
        core.app_scenario.Scenario.tearDown(self)




    def kill(self):
        try:
            logging.debug("Killing steam.exe")
            self._kill("steam.exe")
        except:
            pass
        try:
            logging.debug("Killing steamcmd.exe")
            self._kill("steamcmd.exe")
        except:
            pass
        try:
            self._kill("RocketLeague.exe")
        except:
          pass
